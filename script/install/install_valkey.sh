#!/bin/bash
#
# 安装并配置 Valkey
#
# @command      install valkey
# @name         Valkey（Redis）
# @group        app
# @order        120
# @privilege    root
# @requires_lib >= 4.4
# @provides     valkey
# @provides_unit ext:valkey-server.service
# @args         [--purpose=<cache|store>] [--maxmemory=<MB|auto|0>] [--bind=<地址列表>] [--bind-public=<y|n>] [--regen-password] [--auto-password=<y|n>]
# @description  装发行版源的 Valkey，配内存上限与访问密码
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 为什么是 Valkey
#
# Redis 7.4 起换成 RSALv2/SSPL，不再是开源许可证。Valkey 是 Linux 基金会
# 接手的 BSD 分支，两大发行版都收进了自家源，而 Redis 在发行版源里的版本
# 只会越来越滞后。协议、配置文件语法、客户端库全部兼容 —— 连 valkey-cli
# 认的环境变量都还是 `REDISCLI_AUTH`（7.2 与 8.1 上都实测过）。
#
# 于是「只走发行版源」这条（D99：只有 Caddy 一家加第三方源）不但保住了，
# 拿到的版本还更新：Ubuntu 24.04 上是 Valkey 7.2 对 Redis 7.0。
#
# 直接后果是**版本升级不归这个脚本管** —— 发行版源的升级是 `apt upgrade`
# 的事。这里只负责「装上并配到目标状态」，检测到有更新的候选版本时说一句，
# 不代劳。「比较版本号再问要不要升级」在发行版源上等于把 apt 已经做好的事
# 重写一遍，还多一种出错方式。
#
# 为什么改主配置而不是建 conf.d + include
#
# 看着 include 更干净，但它对「include 一个不存在的文件」的反应是**启动失败**。
# 于是「卸载时删掉我们自己那份文件」这个最正常不过的动作会把服务打死，
# 而且是在下一次重启时才发作。逐行改主配置的最坏情况只是配置留在原地，
# purge 时随 conffile 一起走。

readonly VALKEY_CONF='/etc/valkey/valkey.conf'
readonly VALKEY_UNIT='valkey-server.service'
readonly VALKEY_SECRET_KEY='valkey.password'

# 函数之间的返回通道。**不用 $( ) 取返回值**：那是子 shell，里面的
# os::record_change / os::defer / 脱敏登记一条都传不出来（D74）。
VALKEY_PASS=''
VALKEY_MAXMEMORY_MB=0
VALKEY_POLICY=''
VALKEY_CHANGED=0

# 本次要不要开 AOF：`yes` = 开，空 = **不碰这一行**（见 apply_config）
VALKEY_AOF=''
# 配置文件里 AOF 现在的实际状态，yes / no
VALKEY_AOF_NOW='no'

# ------------------------------------------------------------------

# `auto` 要算的那个数：物理内存的百分之几，但不低于下限。
#
# 下限存在的理由：512MB 的小 VPS 上 25% 只有 128MB，再小的机器就只剩几十 MB，
# 那点空间连 WordPress 的对象缓存都装不下 —— 设一个装不下东西的上限，
# 比不设更糟，因为它会一直在淘汰。
resolve_maxmemory() {
    local spec=${1}

    if [[ ${spec} == '0' ]]; then
        VALKEY_MAXMEMORY_MB=0
        return 0
    fi

    if [[ ${spec} =~ ^[1-9][0-9]*$ ]]; then
        VALKEY_MAXMEMORY_MB=${spec}
        return 0
    fi

    if [[ ${spec} != 'auto' ]]; then
        os::die 2 "--maxmemory 只接受 auto、0 或正整数 MB，收到「${spec}」"
    fi

    probe::mem_total_kb
    local total_kb=${OS_PROBE_VALUE}
    if [[ ! ${total_kb} =~ ^[0-9]+$ || ${total_kb} -eq 0 ]]; then
        os::warn "读不到物理内存，maxmemory 取下限 ${OS_DEFAULT_VALKEY_MAXMEMORY_MIN_MB}MB"
        VALKEY_MAXMEMORY_MB=${OS_DEFAULT_VALKEY_MAXMEMORY_MIN_MB}
        return 0
    fi

    VALKEY_MAXMEMORY_MB=$((total_kb * OS_DEFAULT_VALKEY_MAXMEMORY_PCT / 100 / 1024))
    if ((VALKEY_MAXMEMORY_MB < OS_DEFAULT_VALKEY_MAXMEMORY_MIN_MB)); then
        VALKEY_MAXMEMORY_MB=${OS_DEFAULT_VALKEY_MAXMEMORY_MIN_MB}
    fi
    return 0
}

# 密码：默认自动生成，用户可以自己输。
#
# **没有 `--password=<值>` 这种参数，而且这是特意的** —— 凭据进 argv 就是
# 同机任何用户 `ps` 可见。手输走 os::ask_secret，
# 它不查 OS_ARG_MAP，也就没有从命令行取值的可能。
#
# 生成用 os::query 而不是 os::run_out：这是只读取值，不该产生审计记录，
# 而且 os::query 不把输出写进任何日志 —— 值在登记脱敏之前是裸的，
# 少经过一个环节就少一处泄漏点。
resolve_password() {
    local -i regen=${1}

    if [[ ${regen} -eq 0 ]] && os::secure_load "${VALKEY_SECRET_KEY}" VALKEY_PASS; then
        os::info '沿用已保存的 Valkey 密码（要换用 --regen-password）'
        return 0
    fi

    if os::confirm --arg auto-password '自动生成 Valkey 密码？（选否则手动输入）' y; then
        os::query --timeout 10 -- openssl rand -hex $((OS_DEFAULT_VALKEY_PASS_LEN / 2)) \
            || os::die 1 '生成密码失败'
        VALKEY_PASS=${OS_RUN_OUTPUT}
        if [[ ${#VALKEY_PASS} -lt 16 ]]; then
            os::die 1 '生成的密码长度异常，拒绝继续'
        fi
    else
        os::ask_secret --confirm '请输入 Valkey 密码' VALKEY_PASS
    fi

    os::secure_set "${VALKEY_SECRET_KEY}" "${VALKEY_PASS}" || os::die 1 '保存 Valkey 密码失败'
    return 0
}

# 监听地址：不给就一个字节都不改。
#
# 发行版默认是 `bind 127.0.0.1 -::1`，这是对的默认值，没有任何理由去动它。
# 用户给了非回环地址就是**降低安全性的选项**：默认必须为 n，
# 且要说清补偿控制。Valkey 没有传输加密、没有用户体系，暴露到公网基本等同
# 于把这台机器交出去 —— 这不是危言耸听，是 Redis 未授权访问那一整类事件。
# 实际生效的端口。**不写死 6379**：本脚本不管端口，用户改过 valkey.conf 的
# 话，防火墙判据必须跟着那个值走，否则查的是一个根本没人听的端口。
valkey_port() {
    local line port=''
    if [[ -r ${VALKEY_CONF} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ ${line} =~ ^port[[:space:]]+([0-9]+) ]] || continue
            port=${BASH_REMATCH[1]}
            break
        done <"${VALKEY_CONF}"
    fi
    printf '%s' "${port:-6379}"
}

apply_bind() {
    local addr=${1}
    [[ -n ${addr} ]] || return 0

    local -i public=0
    local one
    # 脚本层的 IFS 是 $'\n\t'，不含空格（D91）—— 不显式改的话，
    # `bind 0.0.0.0 ::1` 会被当成**一个**词，判不出里面有非回环地址
    local IFS=' '
    for one in ${addr}; do
        case ${one} in
            127.* | ::1 | -::1 | localhost) ;;
            *) public=1 ;;
        esac
    done

    if [[ ${public} -eq 1 ]]; then
        if ! os::confirm --arg bind-public \
            'Valkey 没有传输加密，监听非回环地址等于把它暴露给能到达这台机器的任何人。确定？' n; then
            os::die 2 '已取消：未修改监听地址'
        fi

        # §15：放宽必须**在同一步骤内**落实补偿控制，落实不了就拒绝执行。
        # 从前这里只打一句「请务必用 oneserver firewall 只放行可信来源」——
        # 那正是 §15 逐字禁止的「先开放，稍后提示用户自行加固」，而同一份规范
        # 在 install_mariadb 里是有硬门槛的。判据统一收在 probe::ufw_port_guarded：
        # active + 默认入站 deny/reject + 该端口没有无条件放行给 Anywhere。
        local vport
        vport=$(valkey_port)
        probe::ufw_port_guarded "${vport}"
        [[ ${OS_PROBE_VALUE} == yes ]] || os::die 2 \
            "Valkey 监听非回环地址前必须先有真正挡得住的防火墙：要求 UFW 已启用、默认入站为 deny/reject、且 ${vport} 没有无条件放行给 Anywhere。先执行 oneserver firewall enable 并只放行可信来源，未修改监听地址"

        os::warn "已核实：UFW 生效且 ${vport} 未被无条件放行；另有访问密码与 protected-mode 兜底。远程访问请只放行可信网段"
    fi

    os::replace_line --backup "${VALKEY_CONF}" '^bind ' "bind ${addr}" \
        || os::die 1 "${VALKEY_CONF} 里找不到 bind 行，配置文件可能已被大改"
    [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && VALKEY_CHANGED=1
    return 0
}

# AOF 现在到底开没开。**记进 state 的必须是系统事实，不是本次意图**（D125）：
# cache 用途下这个脚本根本不碰 appendonly，那时 state 若照着「本次要开吗」去写，
# 记的就是一个与配置文件矛盾的值。
valkey_aof_state() {
    VALKEY_AOF_NOW='no'
    if os::query --timeout 5 -- grep -qE '^appendonly[[:space:]]+yes' "${VALKEY_CONF}"; then
        VALKEY_AOF_NOW='yes'
    fi
    return 0
}

# 三行配置。全部用 --append-if-missing：发行版的 valkey.conf 里这三项都是
# **注释掉的示例行**（`# maxmemory <bytes>`），正则匹配不到，追加到末尾。
#
# 追加到末尾正是对的 —— 配置语义是**后面的覆盖前面的**，而
# os::replace_line 匹配到多行时全部替换，第二次执行会命中我们自己追加的
# 那一行并发现值没变，于是不写。幂等成立。
#
# 正则里的空格不能省：`^maxmemory ` 才不会连 `maxmemory-policy` 一起匹配。
apply_config() {
    # 「先备份再改」类：valkey.conf 是 dpkg 的 conffile，也可能有用户
    # 自己加的东西，不可重建。`--backup` 只在真要写时才落副本，回滚动作
    # 由 os::backup_file 自己压进回滚栈（同 apply_bind，不用再手动
    # record_change 一遍——那样无条件记录，三行配置一个字都没变时也照记）。
    local mem_line='maxmemory 0'
    [[ ${VALKEY_MAXMEMORY_MB} -gt 0 ]] && mem_line="maxmemory ${VALKEY_MAXMEMORY_MB}mb"

    os::replace_line --append-if-missing --backup "${VALKEY_CONF}" '^maxmemory ' "${mem_line}"
    [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && VALKEY_CHANGED=1

    os::replace_line --append-if-missing --backup "${VALKEY_CONF}" \
        '^maxmemory-policy ' "maxmemory-policy ${VALKEY_POLICY}"
    [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && VALKEY_CHANGED=1

    os::replace_line --append-if-missing --backup "${VALKEY_CONF}" \
        '^requirepass ' "requirepass ${VALKEY_PASS}"
    [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && VALKEY_CHANGED=1

    # 持久化。**发行版默认只有 RDB 快照**（实测：`save 3600 1 300 100 60 10000`、
    # `appendonly no`），也就是崩溃／断电最多丢一小时的写入 —— 那不叫「持久化
    # 数据库」。所以 store 用途必须把 AOF 打开，`appendfsync` 保持发行版的
    # `everysec`（崩溃最多丢 1 秒；`always` 每写必 fsync，延迟高一个量级，
    # 不该由脚本替人选）。
    #
    # **cache 用途一个字都不改这一行。** 不是忘了对称：把 AOF 关掉是在撤销一份
    # 已经生效的持久化保证，属于降低数据安全性，必须由人来做（同「永不自动
    # 删除数据」那条）。上一次按 store 装过、这次改成 cache 的机器，AOF 会留着，
    # 只提示一句。
    if [[ -n ${VALKEY_AOF} ]]; then
        os::replace_line --append-if-missing --backup "${VALKEY_CONF}" \
            '^appendonly ' "appendonly ${VALKEY_AOF}"
        [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && VALKEY_CHANGED=1
    elif [[ ${VALKEY_AOF_NOW} == yes ]]; then
        os::warn "AOF 持久化当前开着（上次按持久化数据库装的）。本命令不会替你关掉 —— 要关请自己把 ${VALKEY_CONF} 的 appendonly 改成 no"
    fi

    return 0
}

# 连通性验证。密码走 --env 不进 argv（D63：子 shell 里 export 后 exec），
# 这也是 REDISCLI_AUTH 存在的理由 —— `valkey-cli -a` 会把密码摆进 ps。
# 变量名沿用 Redis 的拼写不是笔误，valkey-cli 认的就是它。
verify_valkey() {
    os::query --timeout 10 --env "REDISCLI_AUTH=${VALKEY_PASS}" -- valkey-cli PING || return 1
    [[ ${OS_RUN_OUTPUT} == 'PONG' ]] || return 1
    return 0
}

# `Valkey server v=8.1.4 sha=...` → `8.1.4`；解析不出来返回空
parse_version() {
    local raw=${1}
    raw=${raw#*v=}
    raw=${raw%% *}
    [[ ${raw} == *'Valkey'* ]] && raw=''
    printf '%s' "${raw}"
}

# 发行版源里有没有更新的版本。说一句就完了，**不代劳升级**：
# 那是 apt upgrade 的事，替用户做等于在他没要求的时候动他的系统。
hint_upgrade() {
    local current=${1}
    probe::package_candidate valkey-server
    local candidate=${OS_PROBE_VALUE}
    [[ -n ${candidate} ]] || return 0
    # 8.1.4+dfsg1-2 → 8.1.4
    candidate=${candidate#*:}
    candidate=${candidate%%-*}
    candidate=${candidate%%+*}
    [[ -n ${current} && ${candidate} != "${current}" ]] || return 0
    os::info "发行版源里有 ${candidate}（当前 ${current}），用 apt upgrade valkey-server 升级"
    return 0
}

# ------------------------------------------------------------------

main() {
    # 1) 用途。它决定三件事：内存上限的默认值、淘汰策略、要不要开 AOF。
    #    RDB 快照两种用途都不动 —— 关掉它是降低数据安全性，而用户很可能往
    #    「缓存」里塞了不该丢的东西（规范：降低安全性的选项默认为否）。
    local purpose=''
    os::select --arg purpose 'Valkey用途？' purpose \
        'cache=缓存' 'store=持久化数据库'
    case ${purpose} in
        cache | store) ;;
        *) os::die 2 "--purpose 只接受 cache 或 store，收到「${purpose}」" ;;
    esac

    local mem_default='auto'
    VALKEY_POLICY=${OS_DEFAULT_VALKEY_CACHE_POLICY}
    if [[ ${purpose} == 'store' ]]; then
        # 数据是主本时，「内存满了就淘汰几个键」是静默丢数据，
        # 而写失败至少调用方看得见；AOF 则把「进程挂了」那一半也补上。
        # 两者缺一，`store` 这个词就是空头承诺。
        mem_default='0'
        VALKEY_POLICY='noeviction'
        VALKEY_AOF='yes'
    fi

    local mem_spec=''
    os::ask --arg maxmemory \
        '最大内存（MB）；auto = 物理内存的一部分，0 = 不限制' mem_spec "${mem_default}"
    resolve_maxmemory "${mem_spec}"

    local bind_addr=''
    os::ask --arg bind '监听地址（回车保持系统默认的仅本机）' bind_addr ''

    local -i regen=0
    os::flag --arg regen-password && regen=1

    # 2) 装。openssl 与 ca-certificates 是通用依赖，**不登记进 valkey 名下**
    #    （D103）—— 卸载 Valkey 时把 openssl 一起 purge 掉，后果比留下一个包
    #    严重得多。valkey-tools 由 valkey-server 依赖带上，同理不登记。
    os::pkg_install valkey-server openssl ca-certificates

    probe::component_version valkey
    local current
    current=$(parse_version "${OS_PROBE_VALUE}")
    [[ -n ${current} ]] && os::info "当前已安装：${current}"

    # **这一段必须排在 os::require_cmd 前面。**
    # dry-run 下 os::pkg_install 什么都没装，紧接着去 require_cmd 一个本该由
    # 它装上的命令，必然以退出码 3 停在「缺少 valkey-server」上 —— 而那是
    # 预演在报告一件它自己造成的事。规范管这叫「依赖断裂」：
    # 诚实声明无法预演，然后正常结束。
    # 反过来，Valkey 已经装着的时候 dry-run 能一路预演到配置改动，
    # 那才是这个开关真正有用的场景。
    if [[ ! -f ${VALKEY_CONF} ]]; then
        if [[ ${OS_DRYRUN} -eq 1 ]]; then
            os::info "[dry-run] 后续步骤无法预演：${VALKEY_CONF} 尚不存在（包还没真装）"
            os::output 0 purpose="${purpose}" maxmemory_mb="${VALKEY_MAXMEMORY_MB}" \
                policy="${VALKEY_POLICY}" changed=dry-run
            return 0
        fi
        os::die 1 "装完 valkey-server 之后仍然没有 ${VALKEY_CONF}"
    fi

    os::require_cmd valkey-server valkey-cli openssl

    # 3) 配。密码先落 secure 再进配置文件：secure_set 会登记脱敏，
    #    此后 replace_line 的 dry-run 预览与日志里都不会有明文。
    #    顺序反过来就漏了 —— 那正是「验收测单个函数、bug 出在调用组合」的形态。
    resolve_password "${regen}"
    valkey_aof_state
    apply_config
    apply_bind "${bind_addr}"
    valkey_aof_state

    # 4) 起服务。**配置没变就不重启** —— 重启一个正在服务的 Valkey 会掐断
    #    全部连接、清空非持久化的数据，那是实打实的变更，而规范要求第二次
    #    执行零变更。服务本来就没跑的话仍然要拉起来，那不是变更，是达到目标状态。
    probe::service_active "${VALKEY_UNIT}"
    if [[ ${VALKEY_CHANGED} -eq 1 || ${OS_PROBE_VALUE} != active ]]; then
        os::systemd_restart "${VALKEY_UNIT}"
    fi
    os::systemd_enable "${VALKEY_UNIT}"

    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        probe::service_active "${VALKEY_UNIT}"
        if [[ ${OS_PROBE_VALUE} != active ]]; then
            os::query --timeout 10 -- journalctl -u "${VALKEY_UNIT}" --no-pager -n 20
            os::debug "journalctl 尾部：${OS_RUN_OUTPUT}"
            os::die 1 'Valkey 服务启动失败，日志里有 journalctl 的尾部输出'
        fi
        verify_valkey || os::die 1 '装好了但连不上：用保存的密码 PING 不通'
    fi

    # 5) 状态与资源清单。
    #    没有这一段，F6 的 uninstall 就只能靠猜。
    probe::component_version valkey
    local ver
    ver=$(parse_version "${OS_PROBE_VALUE}")
    [[ -n ${ver} ]] || ver='unknown'

    os::state_set valkey version="${ver}" purpose="${purpose}" \
        maxmemory_mb="${VALKEY_MAXMEMORY_MB}" policy="${VALKEY_POLICY}" aof="${VALKEY_AOF_NOW}"

    # 只登记本组件自己的包，且只在本次真装上时登记（D103 的两层过滤）。
    # `valkey.conf` **不登记 file**：那是 dpkg 的 conffile，不是本项目创建的
    # 文件，purge 时随包一起走 —— 登记它等于让 uninstall 去删 apt 管的东西。
    local pkg
    while IFS= read -r pkg; do
        [[ ${pkg} == 'valkey-server' ]] || continue
        os::state_resource_add valkey pkg "${pkg}"
    done < <(os::pkg_installed_names)

    hint_upgrade "${ver}"

    local mem_text='不限制'
    [[ ${VALKEY_MAXMEMORY_MB} -gt 0 ]] && mem_text="${VALKEY_MAXMEMORY_MB} MB"
    local persist_text='仅 RDB 快照（崩溃最多丢一小时的写入）'
    [[ ${VALKEY_AOF_NOW} == yes ]] && persist_text='RDB 快照 + AOF（崩溃最多丢 1 秒）'
    os::kv '版本' "${ver}" \
        '用途' "${purpose}" \
        '最大内存' "${mem_text}" \
        '淘汰策略' "${VALKEY_POLICY}" \
        '持久化' "${persist_text}" \
        '配置文件' "${VALKEY_CONF}" \
        '密码' "已保存在凭据库，键名 ${VALKEY_SECRET_KEY}"

    local changed_text='no'
    if [[ ${VALKEY_CHANGED} -eq 1 ]]; then
        changed_text='yes'
        os::ok "Valkey 已安装并配置完成：${ver}"
    else
        os::ok "Valkey ${ver} 已是目标状态"
    fi
    os::output 0 version="${ver}" purpose="${purpose}" \
        maxmemory_mb="${VALKEY_MAXMEMORY_MB}" policy="${VALKEY_POLICY}" \
        changed="${changed_text}"
    return 0
}

main "$@"
