#!/bin/bash
#
# UFW 防火墙管理
#
# @command      firewall
# @name         防火墙
# @group        security
# @order        15
# @privilege    root
# @requires_lib >= 4.12
# @provides     firewall
# @provides_unit ext:ufw.service
# @args         [--action=<status|install|allow|delete|reload|enable|disable|restart|uninstall>] [--ports=<端口、a:b 范围或规则序号的列表>] [--proto=<both|tcp|udp>] [--from=<CIDR>] [--ambiguous=<num|port>] [--confirm-sensitive=<y|n>] [--confirm-delete] [--confirm-delete-rules] [--confirm-enable] [--disable-firewall=<y|n>] [--confirm-uninstall-firewall=<确认串>]
# @description  增删规则、启停与重启防火墙、装卸 UFW
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# ufw 的输出在不同 locale 下措辞不同，而下面要靠文本判定结果。
# 所有调用统一注入 LC_ALL=C，别指望机器上的 locale 是什么。
readonly UFW_ENV='LC_ALL=C'

readonly UFW_UNIT='ufw.service'

# 装 ufw 的是本脚本，所以这份组件记录归它维护 —— uninstall 按这份清单
# 反向 purge，登记与卸载必须在同一个文件里，分居两处迟早对不上
readonly FIREWALL_ID='firewall'

# 规则表是不是已经被总览打过了 —— 打过就别在删除动作里再来一遍
UFW_RULES_SHOWN=0

# 不限来源地放行这些端口，等于把一个通常只该本机或内网访问的服务开到公网。
# 这些服务的默认配置多半没有密码或只有弱认证，对外之后被扫到是几分钟的事。
#
# **只警告，不拦**：给特定来源开放数据库是正当需求（给了真正的来源限制时
# 这里根本不会触发；`0.0.0.0/0` 与 `::/0` 不算，它们写着限制实为全网），
# 拦下来会挡住合理用法。但一声不吭也不行 —— 放行是这个界面里唯一提高暴露面
# 的动作，从前它比删规则、停防火墙都松，后两者各有确认与硬保护，
# 它连一句提示都没有
readonly -a UFW_SENSITIVE_PORTS=(
    '3306=MySQL/MariaDB' '5432=PostgreSQL' '6379=Redis'
    '27017=MongoDB' '11211=Memcached' '9200=Elasticsearch'
    '5984=CouchDB' '2375=Docker API（明文）' '2376=Docker API'
    '2019=Caddy 管理接口'
)

# Docker 把自己的 DNAT/FORWARD 规则插在 UFW 的 INPUT 链之前，`docker run -p`
# 发布的端口因此完全绕过这份规则表 —— 用户看着 `default deny incoming`，
# 实际上被 -p 发布过的端口仍然全网可达。只在这台机器确实有 docker 时提示：
# 判据用 probe::component_version docker（lib/probe.sh 现成接口，认 dockerd
# 而不是 docker 命令，理由见该函数注释），没装则空字符串，不新增探测接口。
warn_docker_bypass() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || return 0
    os::warn 'docker 发布的端口（-p）不经过 UFW 的 INPUT 链，这份规则表管不到它们。要收住这个口子，用 oneserver network 把容器端口绑定到指定地址（写的是 /etc/docker/daemon.json 的 "ip"）'
    return 0
}

# 上一次 ufw_apply 是否真的改变了系统状态（新增/真删掉了一条规则），
# 而不是命中「本来就是这样」。**调用方靠它决定要不要注册回滚、要不要重载**——
# 回滚一条「本来就存在」的规则会删掉用户自己加的东西；
# 全部规则都命中「已存在」时还去 reload 是一次没必要的 netfilter 重建。
OS_UFW_APPLY_CHANGED=0

# ufw 的退出码不足以判断结果：加一条已存在的规则也返回 0，
# 删一条不存在的规则同样返回 0。**必须看输出文本**，所以这里用
# os::run_out 而不是 os::run —— 「有副作用且需要 stdout」正是它的格子（D9）。
ufw_apply() {
    local label=${1} mode=${2}
    shift 2
    OS_UFW_APPLY_CHANGED=0

    # **desc 必须是固定字符串**（规范最后一句，lint 有检查）。所以这里按
    # mode 分两支各写一个字面量，而不是把拼好的 label 传进去。
    # 丢的只是 desc 里的端口号 —— 审计日志记的是渲染后的整条命令
    # （`ufw allow 8080/tcp`），一个字都没少；屏幕上的 label 也照旧带端口号。
    #
    # 不写 out=$(os::run_out ...)：那是子 shell，OS_RUN_STATUS 与
    # OS_RUN_SKIPPED 都出不来。结果在 OS_RUN_OUTPUT 里。
    if [[ ${mode} == delete ]]; then
        os::run_out --allow-fail --env "${UFW_ENV}" '删除 UFW 规则' -- ufw "$@" || true
    else
        os::run_out --allow-fail --env "${UFW_ENV}" '放行 UFW 端口' -- ufw "$@" || true
    fi
    local out=${OS_RUN_OUTPUT}
    local -i rc=${OS_RUN_STATUS}

    # dry-run 下命令没跑，输出必然是空的 —— 不能拿它去判定结果，
    # 否则会打出「✓ 放行 8080/tcp」，让预演看起来像已经做完了（D15）。
    # 按「会改变」保守处理：dry-run 下游的 os::run（reload）本就会被各自的
    # dry-run 分支跳过，这里不拦不会造成真实副作用，拦了反而会让预演
    # 少打一行「将要 reload」。
    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        OS_UFW_APPLY_CHANGED=1
        return 0
    fi

    if [[ ${mode} == delete ]]; then
        case ${out} in
            # ufw **未激活**时删一条存在的规则打的是「Rules updated」，
            # 只有激活状态下才打「Rule deleted」—— 同一个动作、同样的退出码 0，
            # 两种措辞。只认后者的话，刚装完还没 enable 的机器上，
            # 每一次成功的删除都会被报成失败（F4 回归时在干净容器里撞见）。
            *'Rule deleted'* | *'Rules updated'*)
                OS_UFW_APPLY_CHANGED=1
                os::ok "${label}"
                ;;
            *'Could not delete'* | *'not found'* | *'non-existent'*)
                os::info "${label}：规则不存在，已是目标状态"
                ;;
            *)
                os::err "${label} 失败"
                os::debug "ufw 输出：${out}"
                return 1
                ;;
        esac
        return 0
    fi

    if [[ ${rc} -ne 0 ]]; then
        os::err "${label} 失败"
        os::debug "ufw 输出：${out}"
        return 1
    fi
    case ${out} in
        *Skipping*) os::info "${label}：规则已存在，已是目标状态" ;;
        *)
            OS_UFW_APPLY_CHANGED=1
            os::ok "${label}"
            ;;
    esac
    return 0
}

# 把 probe::listening_scoped 的 `对外<TAB>仅本地` 拆进两个变量。
#
# **不能用 `IFS=$'\t' read -r a b`**：TAB 属于 IFS 空白字符，read 会吃掉
# 前导的那一个 —— 值形如 `<TAB>6379`（一个对外端口都没有、全是 loopback）时，
# 本地端口会被读进「对外」那个变量，界面于是把只听 127.0.0.1 的服务
# 报成「启用后将无法从外部访问」，正是这次要修掉的那个毛病原样重现。
# 参数扩展没有这个行为，空的第一段就是空。
ufw_split_scoped() {
    # 局部变量一律带 __ 前缀：这是个出参函数，调用方把变量名传进来，
    # 名字撞上的话 printf -v 写的就是本函数自己的局部变量，外面什么都拿不到
    local __raw=${1} __pub=${2} __loc=${3}
    printf -v "${__pub}" '%s' "${__raw%%$'\t'*}"
    if [[ ${__raw} == *$'\t'* ]]; then
        printf -v "${__loc}" '%s' "${__raw#*$'\t'}"
    else
        printf -v "${__loc}" '%s' ''
    fi
    return 0
}

# 重载，但只在防火墙确实启用时。未启用时 `ufw reload` 是一次空操作
# （实测输出 `Firewall not enabled (skipping reload)`，退出码仍是 0），
# 照打一句「已重载」只会让人以为刚改的规则已经生效
ufw_reload_if_active() {
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::info '防火墙未启用，规则已写入 /etc/ufw，启用后才开始生效'
        return 0
    fi
    os::run --env "${UFW_ENV}" '重载 UFW 使规则生效' -- ufw reload
    return 0
}

# 把 "80,443 8080" 这样的输入洗成端口数组，顺带剥掉 /tcp 之类的后缀。
# **端口范围（`6000:6010`）原样保留**：ufw 原生支持这种写法，从前这里
# 只认纯数字，`6000:6010/tcp` 会被拒成「不是数字」—— 一个 ufw 能做、
# 这个界面偏偏做不到的事
parse_ports() {
    local raw=${1//,/ }
    local -a out=()
    local p lo hi
    local IFS=' '
    # **一律经 `10#` 强制十进制**：bash 算术把前导零读成八进制，于是 `080`
    # 撞上「08 不是合法八进制数字」当场报错，用户收到的是一句「端口 080
    # 超出范围」——跟真正的原因毫无关系；而 `07` 会安静地按 7 过校验，
    # 却把 `07` 原样交给 ufw。规范化之后存进 out，两头都对得上
    for p in ${raw}; do
        p=${p%%/*}
        if [[ ${p} =~ ^([0-9]+):([0-9]+)$ ]]; then
            lo=$((10#${BASH_REMATCH[1]}))
            hi=$((10#${BASH_REMATCH[2]}))
            ((lo >= 1 && lo <= 65535)) || os::die 2 "端口 ${lo} 超出范围"
            ((hi >= 1 && hi <= 65535)) || os::die 2 "端口 ${hi} 超出范围"
            ((lo < hi)) || os::die 2 "端口范围「${p}」的起点必须小于终点"
            out+=("${lo}:${hi}")
            continue
        fi
        [[ ${p} =~ ^[0-9]+$ ]] || {
            os::die 2 "端口「${p}」不是数字，也不是 6000:6010 这样的范围"
        }
        p=$((10#${p}))
        ((p >= 1 && p <= 65535)) || os::die 2 "端口 ${p} 超出范围"
        out+=("${p}")
    done
    [[ ${#out[@]} -gt 0 ]] || os::die 2 "没有给出任何端口"
    printf '%s\n' "${out[@]}"
}

# 这个端口表达式覆不覆盖某个具体端口。**范围要展开来看** ——
# 支持了 `6000:6010` 之后，SSH 保护再拿字符串相等去比就漏了：
# 删「20:30」时 `20:30 == 22` 不成立，一条覆盖 SSH 端口的删除会被放过去，
# 而那正是这个保护唯一要拦的事
port_covers() {
    local expr=${1} want=${2} lo hi
    # **被问的那一侧必须是个具体端口**，否则退回字面比较。少了这道闸，
    # `port_covers 6000:6010 6000:6010`（机器上有一条范围规则、enable 界面
    # 拿它跟自己比时就会这样）会把 `6000:6010` 塞进算术上下文，bash 当场
    # 抛 `arithmetic syntax error` 打在用户屏幕上，判定结果还是错的
    [[ ${want} =~ ^[0-9]+$ ]] || {
        [[ ${expr} == "${want}" ]]
        return
    }
    if [[ ${expr} =~ ^([0-9]+):([0-9]+)$ ]]; then
        lo=${BASH_REMATCH[1]}
        hi=${BASH_REMATCH[2]}
        ((want >= lo && want <= hi)) && return 0
        return 1
    fi
    [[ ${expr} == "${want}" ]]
}

# 用空格把若干个词连起来。**文件头把 IFS 设成了 $'\n\t'**，所以 `${arr[*]}`
# 在这个脚本里是用换行连的 —— 打进 JSON 字段与屏幕消息里就是一串折行（D91）。
# 把 `local IFS=' '` 关在一个函数里，别让它漏到别的调用上。
ufw_join() {
    local IFS=' '
    printf '%s' "$*"
    return 0
}

# 从 `ufw show added` 的原文里挑出已经放行的端口，
# 一行一个 `端口<TAB>来源范围<TAB>协议`。
# 来源范围为 any（谁都能进）、from（只对指定来源开）或 iface（只对指定网卡）。
#
# **协议这一列不能省。** 少了它，一条 `ufw allow 53/udp` 会让 53/tcp 被算成
# 「已放行」，于是启用后真会被挡的那个端口不进警告清单 —— lib/firewall.sh
# 的注释里记着同一个坑：web.sh 真机上就是因为正则少了协议锚点，
# 一条 `8730/udp` 被读成「TCP 已放行」，面板从此打不开而屏幕上一句话都没有。
# 协议为空表示这条规则两种协议都覆盖（`ufw allow 443` 就是这样）。
#
# **这是「启用防火墙后哪些端口还通」的唯一可靠依据**：规则在 ufw 停用时
# 照样存在，而 `ufw status` 那时一条都读不出来（见 probe::ufw_added_rules）。
#
# 四类行被排除，各有理由：
#   - `ufw route allow …` 走 FORWARD 链，管的是过路流量，跟本机端口通不通无关
#   - `deny` / `reject` 是拦截规则，把它算成「已放行」正好反了
#   - `allow out …` 管的是本机往外连，跟「外面能不能连进来」无关
#   - `ufw allow OpenSSH` 这种应用配置名解析不出端口号 —— 端口藏在
#     /etc/ufw/applications.d 里，要 `ufw app info` 才拿得到。这里跳过它，
#     调用方据此少算的后果只是「多提醒一个其实已放行的端口」，
#     比反过来（漏掉一个真会被挡的端口）安全
#
# multiport（`80,443`）两种写法都只认第一个端口，剩下的落进「少算」那一侧。
ufw_added_ports() {
    local raw=${1} line act port scope proto rawport
    local -a words=()
    while IFS= read -r line; do
        [[ ${line} == 'ufw '* ]] || continue
        line=${line#ufw }
        [[ ${line} == 'route '* ]] && continue
        act=${line%% *}
        [[ ${act} == 'allow' || ${act} == 'limit' ]] || continue
        # `allow out …` 管的是本机往外连，跟「外面能不能连进来」无关。
        # 算成已放行的话，界面会说「80 已有规则」，而入站其实一条都没有 ——
        # 这个方向的错（说通实际不通）比漏报一条严重
        [[ ${line} == "${act} out "* ]] && continue
        # 注释先剥掉再判来源：`comment 'from office'` 里的 from 不是来源限制
        [[ ${line} == *' comment '* ]] && line=${line%% comment *}
        # 三种放行范围。**网卡限定不是「对谁都开」**：`allow in on eth0 to any
        # port 80` 只放行从 eth0 进来的流量，算成 any 会让界面说「80 对所有人
        # 开着」。来源限定排在后面，两个条件都有时按更贴近用户关心的那个说
        scope='any'
        [[ ${line} == *' on '* ]] && scope='iface'
        [[ ${line} == *' from '* ]] && scope='from'
        # 两种写法：`allow 443/tcp` 与 `allow from X to any port 3306 proto tcp`。
        # 捕获类**不含逗号**：`port 80,443` 这种 multiport 写法，捕到 `80,443`
        # 会在下面的数字校验上整条落空，两个端口一起漏掉；只捕 `80` 至少认出
        # 一个，剩下那个落进「少算」那一侧，方向是安全的
        proto=''
        if [[ ${line} =~ [[:space:]]port[[:space:]]+([0-9:]+) ]]; then
            port=${BASH_REMATCH[1]}
            # 协议在这种写法里跟在末尾：`… to any port 3306 proto tcp`。
            # 先把端口存下来再匹配，第二次 =~ 会覆盖 BASH_REMATCH
            [[ ${line} =~ [[:space:]]proto[[:space:]]+([a-z]+) ]] && proto=${BASH_REMATCH[1]}
        else
            # **取最后一个词，不是动作后面那个。** 简写形式里端口永远在行尾，
            # 而前面可能夹着方向与网卡：`allow in 443/tcp`、
            # `allow in on eth0 443/tcp` 都是合法写法。从前取 `${line#allow }`
            # 的第一个词，这两种会取到 `in`，整条规则被当成解析不出端口丢掉 ——
            # 一个明明放行了的端口于是被报成「没放行」。
            # 经数组取词而不是 `${line##* }`：后者遇上行尾空白会取到空串
            IFS=' ' read -ra words <<<"${line}"
            [[ ${#words[@]} -gt 0 ]] || continue
            rawport=${words[-1]}
            port=${rawport%%/*}
            [[ ${rawport} == */* ]] && proto=${rawport#*/}
            # multiport 简写只认第一个端口，与上面 `port 80,443` 那条路一致 ——
            # 两个分支对同一种写法给出不同结果，是下一个人踩坑的地方
            port=${port%%,*}
        fi
        # 范围写法（`6000:6010`）原样留着，比对交给 port_covers 展开 ——
        # 只认纯数字的话，一条 `allow 6000:6010/tcp` 覆盖到的端口会被
        # 全部当成「没放行」再报一遍
        [[ ${port} =~ ^[0-9]+(:[0-9]+)?$ ]] || continue
        printf '%s\t%s\t%s\n' "${port}" "${scope}" "${proto}"
    done <<<"${raw}"
    return 0
}

# 某个端口最宽松的那种放行范围（any / from / iface），一条规则都没有时为空。
# any 一出现就是最宽松，不必再看下去 —— 一个端口可以同时有好几条规则，
# 只要其中一条不限来源，它就是对谁都开着的。
# 第三个参数给协议时只看该协议的规则，理由同 ufw_port_in。
ufw_scope_of() {
    local want=${1} list=${2} pr=${3-} port scope proto best=''
    while IFS=$'\t' read -r port scope proto || [[ -n ${port} ]]; do
        [[ -n ${port} ]] || continue
        port_covers "${port}" "${want}" || continue
        [[ -z ${pr} || -z ${proto} || ${proto} == "${pr}" ]] || continue
        [[ ${scope} == 'any' ]] && {
            printf 'any'
            return 0
        }
        [[ -z ${best} ]] && best=${scope}
    done <<<"${list}"
    printf '%s' "${best}"
    return 0
}

# 某个端口在不在这一串 `端口<TAB>范围<TAB>协议` 里。
#
# 第二个参数给 'any' 时只认不限来源的那种 —— 一条
# `allow from 10.0.0.0/8 to any port 3306` 不该让人以为 3306 对谁都开着；
# 给空则任何放行范围都算数。第四个参数给协议时只看该协议的规则。
ufw_port_in() {
    local want=${1} need=${2-} list=${3} pr=${4-} port scope proto
    while IFS=$'\t' read -r port scope proto || [[ -n ${port} ]]; do
        # 规则那一侧可能是范围，要展开了比：`allow 6000:6010/tcp` 放行的是
        # 其中每一个端口，拿字符串相等去比，6005 会被判成没放行
        [[ -n ${port} ]] || continue
        port_covers "${port}" "${want}" || continue
        # **协议要对上。** 规则没写协议就是两种都覆盖（`ufw allow 443`），
        # 写了就必须相同 —— 少这一道，一条 `allow 53/udp` 会让 53/tcp
        # 被算成已放行，那个真会被挡的端口就不进警告清单了
        [[ -z ${pr} || -z ${proto} || ${proto} == "${pr}" ]] || continue
        [[ -z ${need} || ${scope} == "${need}" ]] && return 0
    done <<<"${list}"
    return 1
}

# ------------------------------------------------------------------

# 「没装」与「装了但没开」是两回事，必须分开说：ufw 不在时 `ufw status` 探不到
# 任何东西，probe::ufw_active 一律给 no —— 照着它打「未启用」，用户会去按
# 「启用防火墙」，然后收到一句找不到命令
action_status() {
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::section 'UFW 防火墙'
        os::kv '运行状态' '未安装' '数据来源' "$(probe::describe)"
        os::info '本机没有 ufw。选「安装 ufw」装上，装完再选「启用防火墙」才开始拦截'
        os::output 0 installed=no active=no
        return 0
    fi

    probe::ufw_active
    local active=${OS_PROBE_VALUE}

    # 规则表分两种状态取：启用时 `ufw status numbered` 带序号，删除要靠它；
    # 停用时那条命令只打一行 `Status: inactive`，规则得从 `ufw show added` 读。
    # 从前两种状态都用前者，于是停用之后这一屏是空的 —— 而停用时刚打过一句
    # 「规则仍保留在 /etc/ufw」，两屏当场矛盾
    local rules=''
    if [[ ${active} == yes ]]; then
        probe::ufw_rules
        rules=${OS_PROBE_VALUE}
    else
        probe::ufw_added_rules
        rules=${OS_PROBE_VALUE}
    fi

    os::section 'UFW 防火墙'
    os::kv '运行状态' "$([[ ${active} == yes ]] && printf '已启用' || printf '未启用')" \
        '数据来源' "$(probe::describe)"
    warn_docker_bypass
    if [[ ${OS_OUTPUT} == json ]]; then
        os::output 0 installed=yes active="${active}"
        return 0
    fi
    printf '%s\n' "${rules}"
    if [[ ${active} != yes ]]; then
        os::info '防火墙未启用，以上规则一条都不生效 —— 选「启用防火墙」它们才开始拦截'
    fi
    UFW_RULES_SHOWN=1
    return 0
}

# 重载。**未启用时 `ufw reload` 是一次空操作**：实测它打的是
# `Firewall not enabled (skipping reload)`，退出码仍然是 0。不先判一下状态的话，
# 这里会照打一句「✓ UFW 配置已重载」—— 一个什么都没发生的动作报了成功，
# 而用户正想靠它让刚改的规则生效
action_reload() {
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::warn '防火墙未启用，重载是空操作 —— 规则已经在盘上，要它们生效请选「启用防火墙」'
        os::output 0 active=no changed=no
        return 0
    fi

    os::record_change '重载了 UFW 规则'
    os::run --env "${UFW_ENV}" '重载 UFW 配置' -- ufw reload
    os::ok 'UFW 配置已重载'
    os::output 0 active=yes changed=yes
    return 0
}

# 停用。**这是降低安全性的操作**（§15），所以默认答案是否，并且把后果说成
# 用户看得懂的话 —— 「ufw disable」四个字不会让任何人意识到机器随即全裸
action_disable() {
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::ok 'UFW 本来就没在跑，无需变更'
        os::output 0 active=no changed=no
        return 0
    fi

    # 只列**对外监听**的那些。从前用 probe::listening_ports 打全量，
    # 里面混着一堆只听 127.0.0.1 的服务 —— 停用防火墙并不会让它们对公网开放，
    # 那句警告对它们是假话，而假话混在真话里会把真正该看的那几个淹掉
    probe::listening_scoped
    local scoped=${OS_PROBE_VALUE} pub='' loc=''
    ufw_split_scoped "${scoped}" pub loc
    # 三种情形要分开说。**「探不到」与「一个对外端口都没有」不是一回事** ——
    # 从前一个 `${pub:-（探测不到）}` 把它们混成同一句，而后者恰恰是这台机器
    # 全部服务都只听 127.0.0.1 的正常形态，报成「探测不到」等于在说探测坏了
    if [[ -z ${scoped} ]]; then
        os::warn '停用之后所有对外监听的端口会立刻对公网开放 —— 这次没能探到监听端口清单，无法列出是哪些'
    elif [[ -n ${pub} ]]; then
        os::warn "停用之后这些端口会立刻对公网开放：${pub}"
    else
        os::warn '眼下没有端口对外监听，但停用之后防火墙不再拦任何入站连接 —— 此后新起的服务会直接暴露'
    fi
    [[ -n ${loc} ]] && os::info "另有这些端口只监听本地，不受影响：${loc}"
    os::confirm --arg disable-firewall '确认停用防火墙？' n \
        || os::die 130 '已取消，防火墙仍在运行'

    # 「禁止自动回滚」类：回滚 = 再把防火墙打开。规则还在 /etc/ufw 里，
    # 重新启用即恢复，所以停用本身不需要先备份什么
    os::record_change '停用了 UFW 防火墙'
    os::run --env "${UFW_ENV}" '停用 UFW' -- ufw disable
    os::ok 'UFW 已停用，规则仍保留在 /etc/ufw，重新启用即生效'
    os::output 0 active=no changed=yes
    return 0
}

# 重启。走 systemd 而不是 `ufw disable && ufw enable`：后者中间有一个真空窗口，
# 而且一旦第二条失败就把机器留在无防火墙状态
action_restart() {
    probe::unit_exists "${UFW_UNIT}"
    [[ ${OS_PROBE_VALUE} == yes ]] || os::die 3 "找不到 ${UFW_UNIT}，ufw 可能没装"

    os::systemd_restart "${UFW_UNIT}"

    probe::ufw_active
    local active=${OS_PROBE_VALUE}
    if [[ ${active} == yes ]]; then
        os::ok "${UFW_UNIT} 已重启，防火墙在运行"
    else
        # 重启一个 disabled 的 ufw 是合法操作，unit 会起来但规则不生效。
        # 报成功而不说这句，用户会以为防火墙已经在保护机器了
        os::warn "${UFW_UNIT} 已重启，但 ufw 仍是未启用状态 —— 规则一条都不生效，选「启用防火墙」才会真的挡"
    fi
    os::output 0 active="${active}" changed=yes
    return 0
}

# 安装。**装 ufw 是一次用户点头才发生的系统变更，不是进这个界面的门票** ——
# 从前它在 main() 里，点开「防火墙」想看一眼状态就先被装了个包、还顺带
# enable 了 ufw.service，没有任何人同意过。它现在跟启用、卸载排在一起。
#
# **装上了就登记**：uninstall 只认 state 里的资源清单，这一步不记账，
# 本工具替用户装的这个包就再也卸不掉（§12）。
# **本来就装着的不登记**：那是用户自己的东西，记一笔等于日后去 purge
# 一个不属于自己的包 —— state 记的是「本工具装过什么」，不是「机器上有什么」。
action_install() {
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        probe::package_version ufw
        os::ok "ufw ${OS_PROBE_VALUE} 已安装，无需变更"
        os::output 0 installed=yes changed=no
        return 0
    fi

    # 走 os::pkg_install 而不是裸 apt-get：needrestart 静默、universe 源探测、
    # 幂等与临界区都在里面，装上的包也才会进 OS_PKG__INSTALLED。
    # 变更清单由它自己按事后探测记，这里不重复记一笔
    os::pkg_install ufw

    probe::package_version ufw
    os::state_set "${FIREWALL_ID}" version="${OS_PROBE_VALUE}" method=apt
    local pkg
    while IFS= read -r pkg; do
        [[ -n ${pkg} ]] || continue
        os::state_resource_add "${FIREWALL_ID}" pkg "${pkg}"
    done < <(os::pkg_installed_names)

    os::ok "ufw ${OS_PROBE_VALUE} 已安装 —— 此刻一条规则都不生效，选「启用防火墙」才开始拦截"
    os::output 0 installed=yes changed=yes
    return 0
}

# 卸载。**purge 会连 /etc/ufw 下的规则一起删掉**，那是用户自己攒的资产、
# 不可重建，所以走 os::destroy_confirm（打全名 + --force-destroy，`--yes` 无效）
# 而不是普通确认。停用排在 purge 之前：先把链撤干净，再删包。
action_uninstall() {
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::ok 'ufw 没有安装，无需变更'
        os::output 0 installed=no changed=no
        return 0
    fi

    probe::ufw_active
    local active=${OS_PROBE_VALUE}

    os::destroy_confirm --arg confirm-uninstall-firewall 'ufw' -- \
        '卸载 ufw 软件包（apt purge）' \
        '删除 /etc/ufw 下的全部规则与配置（purge 的一部分，不可恢复）' \
        '/etc/default/ufw 一并删除 —— 网络定位的转发策略那一半随之作废，重装后要重跑 oneserver network 才恢复' \
        "$([[ ${active} == yes ]] && printf '先停用防火墙，此后所有监听端口对公网开放' || printf '防火墙当前未启用，卸载不改变暴露面')"

    if [[ ${active} == yes ]]; then
        os::record_change '停用了 UFW 防火墙'
        os::run --env "${UFW_ENV}" '停用 UFW' -- ufw disable
    fi

    # 「禁止自动回滚」类：ufw 可能是用户自己装的，装回去也补不回被 purge 的规则
    os::record_change '卸载了 ufw 软件包'
    os::pkg_purge ufw || os::die 1 '卸载 ufw 失败'

    # state 记录的是系统事实（D125）：包没了，登记也就不再成立
    os::state_del "${FIREWALL_ID}"
    os::ok 'ufw 已卸载，规则与配置一并删除'
    os::output 0 installed=no changed=yes
    return 0
}

# 组装一次 ufw 调用的参数。--from 给了就走 proto/from/to 的完整写法，
# 那是原来「专家模式」唯一比标准写法多出来的能力（限制来源）。
ufw_args() {
    local verb=${1} port=${2} proto=${3} from=${4-}
    if [[ -n ${from} ]]; then
        printf '%s\n' "${verb}" proto "${proto}" from "${from}" to any port "${port}"
    else
        printf '%s\n' "${verb}" "${port}/${proto}"
    fi
    return 0
}

# 这一串端口里命中了哪些敏感端口，一行一个 `端口（名字）`。
#
# 两个调用点（放行前的提醒、启用前的暴露面提示）从前各写了一份同样的双重
# 循环，而两份已经跑偏了：一处用 port_covers 认得出 `3300:3310` 覆盖 3306，
# 另一处只做字面比较、认不出。同一个判断两份实现就是两种结果。
sensitive_hits() {
    local p item q
    for p in "$@"; do
        for item in "${UFW_SENSITIVE_PORTS[@]}"; do
            q=${item%%=*}
            port_covers "${p}" "${q}" && printf '%s（%s）\n' "${q}" "${item#*=}"
        done
    done
    return 0
}

# 这个端口是不是敏感端口，只给返回码
is_sensitive_port() {
    local item q
    for item in "${UFW_SENSITIVE_PORTS[@]}"; do
        q=${item%%=*}
        port_covers "${1}" "${q}" && return 0
    done
    return 1
}

# 即将放行的端口里有没有那种「一对外就等于裸奔」的。限了来源就不算 ——
# 那时放行的是一条定向通道，不是把服务挂到公网上。
#
# **命中时返回 1**，让调用方决定要不要再问一句。返回码而不是在这里直接问：
# 问句要配 `--arg`，而参数名属于那条命令（§9），不属于这个判断
warn_sensitive_ports() {
    local from=${1}
    shift
    # **`0.0.0.0/0` 与 `::/0` 写着「限制来源」，实际就是全网。** 只看 from
    # 空不空的话，拿它们放行 3306 会一声不吭地过去 —— 而这正是这个提醒
    # 唯一要拦的那件事
    case ${from} in
        '0.0.0.0/0' | '::/0' | 'any') from='' ;;
    esac
    [[ -z ${from} ]] || return 0

    local p
    local -a hit=()
    # 去重后按端口号排。只 `sort -u` 的话是字典序，屏幕上会排成
    # 11211、2019、27017、3306 这种看着像乱序的样子
    mapfile -t hit < <(sensitive_hits "$@" | sort -u | sort -n)
    [[ ${#hit[@]} -gt 0 ]] || return 0

    os::warn '这些端口将对任何来源开放，而它们通常只该本机或内网访问：'
    for p in "${hit[@]}"; do
        os::warn "    ${p}"
    done
    os::info '只给固定 IP 用的话，回到上一步在「限制来源」里填 IP 或网段，比放行给所有人安全得多'
    return 1
}

# 对外监听、又没被放行的敏感端口。上面那句「要放行就填这些」已经把这一类
# 剔掉了，这里补上剔掉的理由 —— 否则用户会觉得建议清单漏了几个。
# 对这一类，填进放行清单恰恰是**降低**安全性：正确做法是让服务只听本地
warn_exposed_sensitive() {
    local p
    local -a hit=()
    # 去重后按端口号排。只 `sort -u` 的话是字典序，屏幕上会排成
    # 11211、2019、27017、3306 这种看着像乱序的样子
    mapfile -t hit < <(sensitive_hits "$@" | sort -u | sort -n)
    [[ ${#hit[@]} -gt 0 ]] || return 0

    os::warn '其中这几个正在对外监听，而它们通常只该本机访问 —— 建议让服务改听 127.0.0.1，而不是放行它们：'
    for p in "${hit[@]}"; do
        os::warn "    ${p}"
    done
    return 0
}

action_allow() {
    local ports_input='' proto='' from=''
    os::ask --arg ports '要放行的端口（多个用空格或逗号隔开，支持 6000:6010 这样的范围）' ports_input
    os::select --arg proto '协议' proto 'both=TCP 与 UDP' 'tcp=仅 TCP' 'udp=仅 UDP'
    os::ask --arg from '限制来源 IP/CIDR（留空表示不限制）' from ''

    local -a ports=()
    mapfile -t ports < <(parse_ports "${ports_input}")

    # 命中敏感端口且不限来源时补一次确认（§15：放宽访问来源默认必须为否）。
    # **放行是这个界面里唯一提高暴露面的动作**，从前却是唯一没有确认的那个 ——
    # 停用、删规则各有一道默认否的确认，启用也要点头，只有它警告完就直接放
    if ! warn_sensitive_ports "${from}" "${ports[@]}"; then
        os::confirm --arg confirm-sensitive '仍然把这些端口放行给所有来源？' n \
            || os::die 130 '已取消，一条规则都没加'
    fi

    local -a protos=()
    case ${proto} in
        tcp) protos=(tcp) ;;
        udp) protos=(udp) ;;
        *) protos=(tcp udp) ;;
    esac

    local port pr
    local -a args=()
    local -i any_changed=0
    for port in "${ports[@]}"; do
        for pr in "${protos[@]}"; do
            mapfile -t args < <(ufw_args allow "${port}" "${pr}" "${from}")
            ufw_apply "放行 ${port}/${pr}" allow "${args[@]}"
            # 加规则属「必须回滚」类，但仅限**本次真的新增**的那一条：
            # ufw_apply 已经能区分「新增」与「Skipping（已存在）」，命中后者
            # 说明这条规则是用户早就有的，回滚会把它删掉
            if [[ ${OS_UFW_APPLY_CHANGED} -eq 1 ]]; then
                # **真的新增了就记一笔。** 从前删规则记账、加规则不记 ——
                # 而变更清单正是用户事后排查「这台机器上多了个口子是谁开的」
                # 的依据，放行恰恰是唯一提高暴露面的动作，漏掉的是最该记的那条。
                # 只在 CHANGED 时记：命中 Skipping 说明规则本来就在，记了是假账
                os::record_change "在 UFW 里放行了 ${port}/${pr}（来源：${from:-不限}）"
                # 经 os::run 而不是裸命令：回滚动作本身也是副作用，
                # 不该绕开审计日志与脱敏（§10）
                #
                # **删的必须是刚加的那条 tuple，不能一律写 `allow <口>/<协议>`**：
                # 带 --from 时加进去的是 `allow proto tcp from X to any port Y`，
                # 跟 `allow 80/tcp` 是两条不同的规则。从前不分情况都按后者删，
                # 于是限来源的规则回滚不掉（暴露面没收回），而机器上恰好存在
                # 一条通用 80/tcp 规则时，反倒把用户自己的那条删了
                os::defer os::run --allow-fail '回滚：撤销本次新放行的规则' -- \
                    ufw delete "${args[@]}"
                any_changed=1
            fi
        done
    done

    if ((any_changed == 1)); then
        ufw_reload_if_active
    else
        os::info '全部规则已存在，跳过 reload：没有变化就不必重建 netfilter 规则'
    fi
    os::ok "已处理 ${#ports[@]} 个端口"
    # changed 这一列不能省：JSON 是给程序读的，而 install / uninstall /
    # disable / restart 都报了它，偏偏最常被调用的放行与删除没有 ——
    # 调用方于是无从判断这次到底动没动这台机器
    # 写成 `[[ ]]` 而不是 `$(((…))`：`$((` 会被当成算术展开的开头
    os::output 0 ports="$(ufw_join "${ports[@]}")" proto="${proto}" \
        changed="$([[ ${any_changed} -eq 1 ]] && printf 'yes' || printf 'no')"
    return 0
}

# 规则列表里最大的序号。列表形如 `[ 6] Anywhere  ALLOW FWD  10.88.0.0/16`
rules_max_index() {
    local line n max=0
    while IFS= read -r line; do
        [[ ${line} =~ ^\[[[:space:]]*([0-9]+)\] ]] || continue
        n=${BASH_REMATCH[1]}
        ((n > max)) && max=${n}
    done <<<"${1}"
    printf '%d' "${max}"
}

# 一条规则行的目标端口。行形如 `[ 3] 22/tcp   ALLOW IN   Anywhere`，
# 取的是「To」那一列，剥掉协议与 (v6) 标记；取不出数字就是空（比如
# `Anywhere ALLOW FWD 10.88.0.0/16` 这种没有端口的转发规则）。
#
# **给 SSH 端口保护用**。从前那里拿整行做子串匹配（`${line} == *${ssh_port}*`），
# SSH 端口是默认的 22 时，`2222/tcp`、`8022/tcp`、乃至序号恰好是 `[22]` 的
# 任意一行都会被判成「SSH 规则」而拒绝删除，报错内容还跟事实对不上。
rule_port() {
    local line=${1}
    line=${line#*]}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%% *}
    line=${line%%/*}
    # **范围写法也要认**：只收纯数字的话，一条 `20:30/tcp` 取出来是空值，
    # 调用方的 SSH 保护就放它过去了 —— 而那条规则恰恰覆盖着 22
    [[ ${line} =~ ^[0-9]+(:[0-9]+)?$ ]] || return 0
    printf '%s' "${line}"
    return 0
}

# 某个序号那一行的原文，没有就是空
rule_line() {
    local want=${1} line n
    while IFS= read -r line; do
        [[ ${line} =~ ^\[[[:space:]]*([0-9]+)\] ]] || continue
        n=${BASH_REMATCH[1]}
        [[ ${n} -eq ${want} ]] && {
            printf '%s' "${line}"
            return 0
        }
    done <<<"${2}"
    return 1
}

# 把用户输入拆成「序号」与「端口」两拨，结果写进调用方的 nums / ports。
#
# 判据是**落不落在当前列表的序号范围内**。两者都可能命中时（比如列表有 22 条，
# 而 22 又是个常见端口）**当场问，不猜** —— 猜错的两个方向都很糟：
# 当成端口会删掉一组本不该动的规则，当成序号会删掉列表里完全不相干的一行。
split_nums_and_ports() {
    local raw=${1//,/ } rules=${2}
    local -i max
    max=$(rules_max_index "${rules}")

    local p
    local -a maybe=()
    local IFS=' '
    for p in ${raw}; do
        p=${p%%/*}
        # 范围写法只可能是端口，不可能是序号 —— 不必进两可那条路
        if [[ ${p} =~ ^[0-9]+:[0-9]+$ ]]; then
            mapfile -t -O "${#ports[@]}" ports < <(parse_ports "${p}")
            continue
        fi
        [[ ${p} =~ ^[0-9]+$ ]] || os::die 2 "「${p}」既不是端口也不是序号"
        if ((p >= 1 && p <= max)); then
            maybe+=("${p}")
            continue
        fi
        ((p >= 1 && p <= 65535)) || os::die 2 "端口 ${p} 超出范围"
        ports+=("${p}")
    done

    # 两可的值**一次问清，不逐个问**：逐个问就得给每个值一个参数名，
    # 而参数名是动态的话 @args 里声明不了，非交互下根本传不进来。
    if [[ ${#maybe[@]} -gt 0 ]]; then
        local answer=''
        for p in "${maybe[@]}"; do
            os::info "第 ${p} 条是：$(rule_line "${p}" "${rules}")"
        done
        # **必须 --required**：不加的话非交互下会默默取第一项，
        # 于是 `--ports=22` 在规则够多的机器上删掉的是第 22 条而不是端口 22，
        # 而且不会有任何提示。两可的值没有安全的默认答案。
        # `--keep-screen`：上面逐条打出的「第 N 条是：<规则原文>」就是判断依据，
        # 清屏之后用户面对的是一个没有任何线索的二选一
        os::select --keep-screen --required --arg ambiguous "「${maybe[*]}」按哪种理解？" answer \
            'num=规则序号' 'port=端口号'
        for p in "${maybe[@]}"; do
            [[ ${answer} == num ]] && nums+=("${p}") || ports+=("${p}")
        done
    fi

    [[ ${#nums[@]} -gt 0 || ${#ports[@]} -gt 0 ]] || os::die 2 '没有给出任何端口或序号'
    return 0
}

# 按序号删。**必须从大到小** —— ufw 删掉一条之后，它后面的规则编号全部前移，
# 按输入顺序删的话第二条起就落到别的规则上了，而且删错了不会有任何提示。
delete_by_number() {
    local rules=${1}
    shift
    local -a sorted=()
    mapfile -t sorted < <(printf '%s\n' "$@" | sort -rn -u)

    probe::ssh_port
    local ssh_port=${OS_PROBE_VALUE}

    local n line port
    local -a lines=()
    for n in "${sorted[@]}"; do
        line=$(rule_line "${n}" "${rules}") || os::die 2 "规则列表里没有第 ${n} 条"
        # 序号选中 SSH 那一行同样拒绝 —— 换条路进来不该换个结果。
        # 比的是解析出来的目标端口，不是整行子串（理由见 rule_port）；
        # 经 port_covers 而不是字符串相等，好让 `20:30/tcp` 这种覆盖了
        # SSH 端口的范围规则同样拦得住
        port=$(rule_port "${line}")
        if [[ -n ${ssh_port} && -n ${port} ]] && port_covers "${port}" "${ssh_port}"; then
            # 精确命中与范围覆盖分开说，同 action_delete 里的那处
            [[ ${port} == "${ssh_port}" ]] \
                && os::die 2 "第 ${n} 条就是当前 SSH 管理端口（${ssh_port}）的规则，拒绝删除"
            os::die 2 "第 ${n} 条（${port}）覆盖了当前的 SSH 管理端口 ${ssh_port}，拒绝删除"
        fi
        lines+=("${line}")
    done

    # 确认时显示整行原文。用户输的是数字，脑子里想的是规则 ——
    # 只回显数字的话，他核对不了自己有没有输错
    os::section '将删除这几条'
    for line in "${lines[@]}"; do
        os::info "    ${line}"
    done
    os::confirm --arg confirm-delete-rules '确认删除？' n || os::die 130 '已取消'

    for n in "${sorted[@]}"; do
        # 删规则属「禁止自动回滚」类：那条规则是不是本次会话加的、原来长什么样，
        # 框架都不知道，猜着加回去比不加更危险
        os::record_change "删除了 UFW 规则第 ${n} 条"
        os::run --env "${UFW_ENV}" '按序号删除 UFW 规则' -- ufw --force delete "${n}"
    done
    os::ok "已删除 ${#sorted[@]} 条规则"
    return 0
}

action_delete() {
    local ports_input='' proto='' from=''

    probe::ufw_active
    local active=${OS_PROBE_VALUE}

    # 规则表分两种状态取，理由同 action_status
    local rules=''
    if [[ ${active} == yes ]]; then
        probe::ufw_rules
        rules=${OS_PROBE_VALUE}
    else
        probe::ufw_added_rules
        rules=${OS_PROBE_VALUE}
    fi
    # 规则表在动作清单的总览里刚打过，不再打第二遍。
    # **只有从命令行直接跑时才打**：那时总览不会显示（它只在交互的动作清单里
    # 跑），而这一步要用户对着真实清单输端口或序号
    if [[ ${OS_OUTPUT} != json && ${UFW_RULES_SHOWN} -ne 1 ]]; then
        os::section '当前规则'
        printf '%s\n' "${rules}"
    fi

    # **停用状态下没有序号可用**：`ufw status numbered` 那时只打一行
    # `Status: inactive`，规则得从 `ufw show added` 读，而后者不带序号，
    # 行序也跟启用后的序号对不上（实测：show added 4 行，status numbered 6 条 ——
    # v4/v6 在后者里是分开编号的两条）。
    #
    # 从前这里不分状态、一律拿 status 当规则表，于是停用时 max 序号算出来是 0，
    # split_nums_and_ports 的序号分支永不成立，**所有输入一律被当成端口号**：
    # 用户想删第 3 条，脚本去删「3/tcp」，ufw 回「规则不存在」，屏幕上却是
    # 一句「已是目标状态」—— 什么都没删，看起来却像删成功了。
    local -a nums=() ports=()
    if [[ ${active} == yes ]]; then
        os::ask --arg ports '要删除的端口，或规则序号（多个用空格或逗号隔开）' ports_input
        # 输入里的序号先摘出来单独走一条路。**按端口删对没有端口的规则无能为力**：
        # `Anywhere ALLOW FWD 10.88.0.0/16` 这种转发规则压根没有端口可输，
        # route 规则的 tuple 也跟 `delete allow <口>/<协议>` 对不上 —— 列表里
        # 看得见却删不掉，是这个界面最没道理的地方。
        split_nums_and_ports "${ports_input}" "${rules}"
    else
        os::info '防火墙未启用，上面这份清单没有序号 —— 现在只能按端口删除'
        os::ask --arg ports '要删除的端口（多个用空格或逗号隔开）' ports_input
        mapfile -t ports < <(parse_ports "${ports_input}")
    fi

    # SSH 端口保护。删掉它就等于把自己锁在门外，而且是**在远程操作时**——
    # 这不是「危险」，是不可恢复。所以不给确认选项，直接拒绝。
    #
    # **这一关必须排在任何删除动作之前。** 从前它排在 delete_by_number 之后：
    # 输入 `3 22`（3 是序号、22 是 SSH 端口）时，第 3 条已经被删掉了，才轮到
    # 这里拒绝，而屏幕上只有一句「拒绝删除」—— 用户完全看不出前面已经动过手。
    probe::ssh_port
    local ssh_port=${OS_PROBE_VALUE}
    local port
    for port in ${ports[@]+"${ports[@]}"}; do
        # 范围写法要展开比（见 port_covers）：删「20:30」同样会带走 22 上的规则。
        # 两种命中分开说 —— 精确命中时写成「22 覆盖了 22」是句绕口的废话
        if [[ -n ${ssh_port} ]] && port_covers "${port}" "${ssh_port}"; then
            [[ ${port} == "${ssh_port}" ]] \
                && os::die 2 "端口 ${port} 是当前的 SSH 管理端口，拒绝删除（改端口用 oneserver safe ssh）"
            os::die 2 "端口范围 ${port} 覆盖了当前的 SSH 管理端口 ${ssh_port}，拒绝删除（改端口用 oneserver safe ssh）"
        fi
    done

    # 序号那一半：按序号删，**从大到小**。删掉一条之后它后面的编号会全部
    # 前移，按输入顺序删的话第二条起就删到别的规则上了。
    if [[ ${#nums[@]} -gt 0 ]]; then
        delete_by_number "${rules}" "${nums[@]}"
    fi
    # 只输了序号那条路：走到这里说明 delete_by_number 已经删过，changed 恒为 yes
    [[ ${#ports[@]} -gt 0 ]] || {
        ufw_reload_if_active
        os::output 0 rules="$(ufw_join "${nums[@]}")" changed=yes
        return 0
    }

    os::select --arg proto '协议' proto 'both=TCP 与 UDP' 'tcp=仅 TCP' 'udp=仅 UDP'
    os::ask --arg from '当初限制的来源 IP/CIDR（留空表示未限制）' from ''

    # 用 ufw_join 而不是 ${ports[*]}：文件头把 IFS 设成了 $'\n\t'，
    # 后者在这个脚本里是用换行连的，确认框里会折成好几行（D91）
    os::confirm --arg confirm-delete "确认删除端口 $(ufw_join "${ports[@]}") 的规则？" n \
        || os::die 130 '已取消'

    local -a protos=()
    case ${proto} in
        tcp) protos=(tcp) ;;
        udp) protos=(udp) ;;
        *) protos=(tcp udp) ;;
    esac

    local pr
    local -a args=()
    local -i any_changed=0
    for port in "${ports[@]}"; do
        for pr in "${protos[@]}"; do
            mapfile -t args < <(ufw_args allow "${port}" "${pr}" "${from}")
            # 删规则属「禁止自动回滚」类：那条规则是不是本次会话加的、
            # 原来长什么样，框架都不知道，猜着加回去比不加更危险
            ufw_apply "删除 ${port}/${pr}" delete delete "${args[@]}"
            # **记在动作之后，且只在 ufw 确实动过时记。** 从前是无条件先记
            # 一笔，而 ufw_apply 下一行打的可能是「规则不存在，已是目标状态」——
            # 什么都没删，清单里却写着删了。那份清单是用户事后排查的依据，
            # 一条假账比少一条记录更能把人带偏。
            # （dry-run 下 ufw_apply 按「会改变」置位，预演清单里因此也有这条，
            # 那正是预演该显示的东西）
            if [[ ${OS_UFW_APPLY_CHANGED} -eq 1 ]]; then
                os::record_change "删除了 UFW 规则 ${port}/${pr}"
                any_changed=1
            fi
        done
        # 旧版本可能加过不带协议的通用规则，一并清掉
        os::run_out --allow-fail --env "${UFW_ENV}" '清理端口的通用规则' \
            -- ufw delete allow "${port}" || true
        if [[ ${OS_RUN_SKIPPED} -ne 1 && ${OS_RUN_OUTPUT} == *'Rule deleted'* ]]; then
            # 这一步真删掉过东西，同样要记 —— 从前它一声不响地删，
            # 清单里连痕迹都没有
            os::record_change "删除了 UFW 里 ${port} 的通用规则（不带协议的那条）"
            any_changed=1
        fi
    done

    if ((any_changed == 1)); then
        ufw_reload_if_active
    else
        os::info '没有规则被真的删掉，跳过 reload'
    fi
    os::ok "已处理 ${#ports[@]} 个端口"
    os::output 0 ports="$(ufw_join "${ports[@]}")" proto="${proto}" \
        changed="$([[ ${any_changed} -eq 1 ]] && printf 'yes' || printf 'no')"
    return 0
}

# 启用防火墙。规则加在一个没启用的 ufw 上一条都不生效，所以「把它打开」
# 必须是这个界面里的一个动作。防火墙整体归本命令，`oneserver safe status`
# 那边只报一句开没开。
#
# 四条硬要求：
#   1. **SSH 端口自动进放行清单**，不问 —— 启用一个不放行 SSH 的防火墙，
#      等于在远程操作时按下自毁按钮
#   2. **启用前把「正在对外听、又没有任何放行规则」的端口指名道姓列出来**。
#      不列的话这就是一次盲操作，用户要等到某个服务连不上才知道关掉了什么
#   3. 先放行、再启用。顺序反了中间有一个窗口期是「全拒绝」
#   4. **确认排在所有系统变更之前**：选「否」必须意味着这台机器一个字节都没动
action_enable() {
    probe::ufw_active
    local active=${OS_PROBE_VALUE}

    probe::ssh_port
    local ssh_port=${OS_PROBE_VALUE}

    # 已经在盘上的规则。**必须从 show added 读**：未启用时 `ufw status` 一条
    # 规则都读不出来，拿它算的话，之前放行过的端口会被当成「没放行」再报一遍 ——
    # 用户真机上 12 个警告端口里有一半是这么来的
    probe::ufw_added_rules
    local added=''
    added=$(ufw_added_ports "${OS_PROBE_VALUE}")

    local ports_input=''
    os::ask --arg ports "除 SSH（${ssh_port}）外还要放行哪些 TCP 端口（回车跳过）" ports_input ''

    local -a ports=("${ssh_port}")
    if [[ -n ${ports_input//[[:space:]]/} ]]; then
        local -a extra=()
        mapfile -t extra < <(parse_ports "${ports_input}")
        ports+=("${extra[@]}")
    fi

    # 监听端口分对外与仅本地两拨。**从前用不分地址的 probe::listening_ports**，
    # 于是只听 127.0.0.1 的服务也被列进「启用后将无法从外部访问」——
    # 防火墙根本碰不到它们，这句话对它们是假的。真机实测 12 个里 7 个是这种，
    # 噪音把真正该看的那几个淹了
    probe::listening_scoped
    local pub='' loc=''
    ufw_split_scoped "${OS_PROBE_VALUE}" pub loc

    local -a pub_arr=() loc_arr=()
    IFS=' ' read -ra pub_arr <<<"${pub}" || true
    IFS=' ' read -ra loc_arr <<<"${loc}" || true

    # 对外在听的端口分三种去向，各回答一个不同的问题：
    #   blocked —— 没有任何规则，也不在本次清单里，启用后就断
    #   limited —— 规则带着条件（限来源或限网卡），条件内通、条件外不通。
    #              归进 blocked 会说成「无法从外部访问」，那不对
    #   其余    —— 已经无条件放行过，或本次会放行，不必提
    local p q hit
    local -a blocked=() limited=()
    # `${arr[@]+…}` 而不是裸 `"${arr[@]}"`：全是 loopback 的机器上 pub_arr
    # 就是个空数组，而这份代码要在 set -u 下跑（同 all_ports 那处的写法）
    for p in ${pub_arr[@]+"${pub_arr[@]}"}; do
        [[ -n ${p} ]] || continue
        hit=''
        for q in "${ports[@]}"; do
            port_covers "${q}" "${p}" && {
                hit=1
                break
            }
        done
        [[ -n ${hit} ]] && continue
        # 一律带上 tcp：这一屏放行的是 tcp，拿一条 udp 规则当「已放行」
        # 会把真会被挡的端口从警告清单里抹掉
        ufw_port_in "${p}" 'any' "${added}" 'tcp' && continue
        if ufw_port_in "${p}" '' "${added}" 'tcp'; then
            limited+=("${p}")
        else
            blocked+=("${p}")
        fi
    done

    # 本次真正会新增的规则：已经有 any 规则的不算新增，说成「新增」会让人
    # 以为这次动了什么
    local -a adding=()
    for p in "${ports[@]}"; do
        ufw_port_in "${p}" 'any' "${added}" 'tcp' && continue
        adding+=("${p}")
    done
    # 用户把同一个端口输两遍时不必在清单里显示两遍（放行本身是幂等的）
    [[ ${#adding[@]} -gt 0 ]] && mapfile -t adding < <(printf '%s\n' "${adding[@]}" | sort -u | sort -n)

    # 已放行的端口，去重后按数值排序。**限了来源的要标出来** —— 只写个端口号
    # 的话，一条 `allow from 10.0.0.0/8 to any port 5432` 会被读成「5432 对谁
    # 都开着」，那跟事实差了一整个网段
    #
    # **去重与排序必须分两步**：`sort -nu` 的 -u 比的是**数值键**而不是整行，
    # 于是 `22` 会把 `22:30` 吃掉、`6000` 会把 `6000:6010` 吃掉（两者的数值键
    # 都一样），机器上同时有这两条规则时清单里只剩一条。先按字面去重，
    # 再按数值排序，两个范围端口才都留得住
    # 只收 tcp 与不写协议的那些：这一屏谈的是 tcp 放行，把一条 `53/udp`
    # 列进「已有规则」，用户会以为 53 的 tcp 也通着
    local -a already=() all_ports=()
    mapfile -t all_ports < <(printf '%s\n' "${added}" | while IFS=$'\t' read -r p q pr; do
        [[ -n ${p} ]] || continue
        [[ -z ${pr} || ${pr} == 'tcp' ]] || continue
        printf '%s\n' "${p}"
    done | sort -u | sort -n)
    for p in ${all_ports[@]+"${all_ports[@]}"}; do
        case $(ufw_scope_of "${p}" "${added}" 'tcp') in
            any) already+=("${p}") ;;
            iface) already+=("${p}(限网卡)") ;;
            *) already+=("${p}(限来源)") ;;
        esac
    done

    os::section '防火墙启用'
    # 「本次新增」那一行不写成 `22 80/tcp`：那个后缀只黏在最后一个端口上，
    # 读起来像「22 是别的协议、只有 80 是 tcp」。协议对这一屏是统一的，
    # 放进括号里说一次
    os::kv '当前状态' "$([[ ${active} == yes ]] && printf '已启用' || printf '未启用')" \
        'SSH 端口' "${ssh_port}" \
        '默认策略' '入站拒绝 · 出站允许' \
        '已有 TCP 规则' "$([[ ${#already[@]} -gt 0 ]] && ufw_join "${already[@]}" || printf '（无）')" \
        '本次新增' "$([[ ${#adding[@]} -gt 0 ]] && printf '%s（TCP）' "$(ufw_join "${adding[@]}")" || printf '（无）')"

    if [[ ${#blocked[@]} -gt 0 ]]; then
        os::warn "以下端口正在对外监听，又没有任何放行规则 —— 启用后将无法从外部访问："
        for p in "${blocked[@]}"; do
            os::warn "    ${p}"
        done
        # 提示回到上一步，而不是让人去背 CLI 参数：这一屏是交互菜单，
        # 刚才那个提问就在几行之上。
        #
        # **建议里必须剔掉敏感端口。** 从前这句列的是 blocked 全集，而紧跟着
        # 的下一句又说「其中 3306 建议别放行」—— 前后两句直接打架，照上一句
        # 做就是把数据库开到公网。这句只留真正该放行的，那一类交给下面单说
        local -a suggest=()
        for p in "${blocked[@]}"; do
            is_sensitive_port "${p}" || suggest+=("${p}")
        done
        [[ ${#suggest[@]} -gt 0 ]] \
            && os::info "要放行就重来一次，在「还要放行哪些 TCP 端口」那一问里填：$(ufw_join "${suggest[@]}")"
        warn_exposed_sensitive "${blocked[@]}"
    fi
    if [[ ${#limited[@]} -gt 0 ]]; then
        os::info "以下端口的放行带着条件（限来源或限网卡），条件之外的连接启用后会被挡：$(ufw_join "${limited[@]}")"
    fi
    if [[ ${#loc_arr[@]} -gt 0 ]]; then
        os::info "另有 ${#loc_arr[@]} 个端口只监听本地，防火墙管不到、也不受影响：${loc}"
    fi

    # 用户自己填进放行清单的敏感端口也要说一句。**warn_exposed_sensitive 只看
    # 没放行的那批**，于是「在提问里输入 3306」这条路从前一句警告都没有 ——
    # 而它跟在 allow 里放行 3306 是同一件事。这里只提醒，决定权交给下面那次
    # 确认（enable 本来就要点头，不必再叠一次问句）
    warn_sensitive_ports '' "${ports[@]}" || true

    # **确认在前，系统变更在后。** 从前两条 `ufw default` 排在确认框之前就执行了，
    # 用户在「现在启用防火墙？」那一步选 n，得到一句「已取消」，而默认入站策略
    # 其实已经被改成 deny 了 —— 取消掉的只是最后那下 enable
    if [[ ${active} != yes ]]; then
        os::confirm --arg confirm-enable '现在启用防火墙？清单之外的入站连接将被拒绝' y \
            || os::die 130 '已取消，未做任何变更'
    fi

    # 默认策略属「禁止自动回滚」类，同下面的启用：回滚 = 把入站策略改回允许，
    # 是在失败路径上降低安全性。之前这一步既不 defer 也不 record_change，
    # 出问题时变更清单里看不出策略已经改了
    os::record_change '设置了 UFW 默认入站策略为拒绝'
    os::run --env "${UFW_ENV}" '设置默认入站策略为拒绝' -- ufw default deny incoming
    os::run --env "${UFW_ENV}" '设置默认出站策略为允许' -- ufw default allow outgoing

    local -a args=()
    local -i any_changed=0
    for p in "${ports[@]}"; do
        mapfile -t args < <(ufw_args allow "${p}" tcp '')
        ufw_apply "放行 ${p}/tcp" allow "${args[@]}"
        if [[ ${OS_UFW_APPLY_CHANGED} -eq 1 ]]; then
            any_changed=1
            # 同 action_allow：真的新增了才记，命中 Skipping 记了就是假账
            os::record_change "在 UFW 里放行了 ${p}/tcp（来源：不限）"
            # SSH 端口永不注册回滚：即使这次是新增的，一旦后续步骤失败
            # （典型是 `ufw reload` 语法错误），回滚会当场删掉刚放行的 SSH
            # 规则——默认策略这时已经是 deny，当前 SSH 会话是已建立连接
            # 所以不断，但下一次连接就进不来了。这条底线比「回滚要精确」更高优先。
            if [[ ${p} != "${ssh_port}" ]]; then
                # 经 os::run 而不是裸命令：回滚动作本身也是副作用，
                # 不该绕开审计日志与脱敏（§10）。删的是刚加的那条 tuple，
                # 理由同 action_allow 里的回滚
                os::defer os::run --allow-fail '回滚：撤销本次新放行的规则' -- \
                    ufw delete "${args[@]}"
            fi
        fi
    done

    if [[ ${active} == yes ]]; then
        if ((any_changed == 1)); then
            os::run --env "${UFW_ENV}" '重载 UFW 使规则生效' -- ufw reload
            os::ok 'UFW 本来就是启用状态，规则已更新'
        else
            os::ok 'UFW 本来就是启用状态，规则已是目标状态，无需重载'
        fi
    else
        # 启用防火墙属「禁止自动回滚」类：回滚 = 关掉防火墙，
        # 那是在失败路径上降低安全性。确认已经在动手之前问过了
        os::record_change '启用了 UFW 防火墙'
        os::run --env "${UFW_ENV}" '启用 UFW' -- ufw --force enable
        os::ok 'UFW 已启用，并已设置为开机自启'
        warn_docker_bypass
    fi

    # active 不硬编码 yes：dry-run 下上面那条 enable 根本没跑，报 active=yes
    # 会让预演的输出与事实不符（D15）。
    # changed 要把两件事都算进去 —— 规则有没有新增，以及防火墙是不是本次才开的
    local changed='no'
    ((any_changed == 1)) && changed='yes'
    [[ ${active} != yes ]] && changed='yes'
    probe::ufw_active
    os::output 0 ports="$(ufw_join "${ports[@]}")" ssh_port="${ssh_port}" \
        active="${OS_PROBE_VALUE}" changed="${changed}"
    return 0
}

# ------------------------------------------------------------------

# 真要调 ufw 命令的动作在这里挡一次。装不装现在由用户在菜单里决定，
# 所以「ufw 在不在」不再是进入这个脚本时就成立的前提。
# 退出码 3 而不是 1：缺的是依赖，不是执行失败（§8）
require_ufw() {
    probe::package_installed ufw
    [[ ${OS_PROBE_VALUE} == yes ]] || os::die 3 'ufw 未安装，先选「安装 ufw」（或 oneserver firewall install）'
    return 0
}

main() {
    # 位置参数优先；没给才走交互（--action=... 由 os::select 自己从命令行取）。
    # 不去碰 OS_ARG_MAP —— 那是框架内部的东西，脚本伸手进去就是越层了。
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    # 日常动作在前，生命周期动作在后：放行端口每周都可能按，装卸 ufw 一辈子按一次。
    # 两类混排的话，最常用的那条每次都要在一串危险选项里找。
    # 「安装」始终列着而不是按装没装隐藏：菜单项跟着系统状态变的话，用户既记不住
    # 编号，也没法从这一屏看出「这台机器还没装」——那件事由总览负责说
    os::action_menu --overview action_status --arg action '操作' dispatch \
        'allow=放行端口' 'delete=删除规则' 'reload=重载配置' \
        'enable=启用防火墙' 'disable=停用防火墙' 'restart=重启防火墙' \
        'install=安装 ufw' 'uninstall=卸载 ufw'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        install) action_install ;;
        uninstall) action_uninstall ;;
        allow)
            require_ufw
            action_allow
            ;;
        delete)
            require_ufw
            action_delete
            ;;
        reload)
            require_ufw
            action_reload
            ;;
        enable)
            require_ufw
            action_enable
            ;;
        disable)
            require_ufw
            action_disable
            ;;
        restart)
            require_ufw
            action_restart
            ;;
        *) os::die 2 "未知操作「${1}」，可用：status install allow delete reload enable disable restart uninstall" ;;
    esac
}

main "$@"
