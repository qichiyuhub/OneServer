#!/bin/bash
#
# Caddy 管理
#
# @command      caddy
# @name         Caddy 管理
# @group        web
# @order        20
# @requires     caddy
# @privilege    root
# @requires_lib >= 4.0
# @provides_unit ext:caddy.service
# @args         [--action=<status|show|validate|apply|edit|rollback|reload|restart|logs|certs|cert-rm|token>] [--source=<url|file>] [--url=<地址>] [--file=<路径>] [--provider=<cloudflare|alidns|tencentcloud>] [--token-anyway=<y|n>] [--restart-now=<y|n>] [--lines=<行数>] [--cert=<all|域名>] [--confirm-cert-rm=<all|域名>] [--wait-file=<y|n>] [--edit-open=<y|n>] [--apply-edited=<y|n>]
# @description  校验与更新 Caddyfile、控制服务、管理证书
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 从 628 行的交互菜单变成一条命令 + 一个动作（D73）
#
# 旧脚本是个常驻的 while 循环菜单，里面套着二级菜单、`clear`、
# 「按 Enter 返回」。而 D79 已经定过：**菜单是一次性的** —— 选中即 exec，
# 命令跑完回到 shell。所以这里的形态是 `oneserver caddy <动作>`，
# 菜单条目由注册表自动生成，脚本里零 case 排版。
#
# ## 砍掉了什么，为什么
#
#   `tail -f` 实时跟踪   跟命令式工具不搭，而且旧实现为了「Ctrl+C 只退出跟踪」
#                        用了 `eval "$orig_trap"`（规范只允许 trap 恢复这一处
#                        例外，但那是框架的事，不是脚本的）。改成打最后 N 行，
#                        并把「要实时跟就敲这条」的命令原样打给用户
#   `Caddyfile.bak.*`    自己一套备份命名。框架的 os::backup_file 已经在做同一件
#                        事且更严格（0700 目录、每次执行只备一份）。rollback
#                        改从框架的备份目录取
#   `bat` 高亮提示       「装个 bat 体验更好」是作者的偏好，不该由一个服务器
#                        管理工具来推荐
#   二级菜单             备份的列出/清理并进 `caddy certs` 与 rollback
#
# ## K12 · source secure.conf
#
# 旧脚本 `_source_token()` 直接 `source "$SECURE_CONF"` 取 Cloudflare 令牌 ——
# source 一个配置文件等于执行它。这里走 `os::secure_load`（严格解析、不执行），
# key 是 `caddy.dns_token`。
#
# ## 令牌不再写死成 Cloudflare
#
# 旧脚本把 `CLOUDFLARE_API_TOKEN` 写死在三处。而插件清单里有三个 DNS 提供商
# （cloudflare / alidns / tencentcloud），每家的环境变量名都不一样 ——
# 写死一个等于「这个功能只服务用 Cloudflare 的人」。
#
# 令牌也**不再直接写进 systemd drop-in**：drop-in 默认 0644，把令牌摊给了
# 机器上的每一个用户。改成 drop-in 只写一行 `EnvironmentFile=`，令牌落在
# 一个 0600 的文件里，由 systemd 以 root 读。

readonly CADDY_UNIT='caddy.service'
readonly CADDYFILE='/etc/caddy/Caddyfile'
readonly CADDY_ENV_FILE='/etc/caddy/oneserver.env'
readonly CADDY_DROPIN_DIR='/etc/systemd/system/caddy.service.d'
readonly CADDY_DROPIN='/etc/systemd/system/caddy.service.d/oneserver-env.conf'
readonly CADDY_CERT_DIR='/var/lib/caddy/.local/share/caddy/certificates'
readonly CADDY_LOG_DIR='/var/log/caddy'

# 配置投放目录。**固定一个位置，胜过每次问一遍路径**：交互里要人敲完整路径，
# 等于把「文件放哪」这个只有工具知道的答案推给用户去猜。
#
# **不能用 /etc/caddy/incoming/**：那个目录归 `oneserver web`，里面的
# `oneserver-web.caddy` 是主 Caddyfile 用 `import incoming/*.caddy` 引着的
# **正在生效的片段**，不是待处理的投稿。扫它的后果是本命令把面板片段列成候选
# ——目录里只有这一个文件时还会自动选中、连问都不问——然后拿一个只有面板
# vhost 的片段整份替换掉 /etc/caddy/Caddyfile，机器上其余站点全部消失。
# 一个目录不能既是「常驻片段的家」又是「待替换的投稿箱」。
#
# 换到 /root：scp 上来默认就落在这儿，不必先建目录、不必记路径。
readonly CADDY_DROP_DIR='/root'

# 常驻片段目录，归 `oneserver web`。本命令只读它，用来判断整份替换 Caddyfile 时
# 要不要把 import 那行补回去。措辞与正则跟 web.sh 里的那份逐字相同 —— 两处，
# 不提取（第三处再说）
readonly CADDY_SNIPPET_DIR='/etc/caddy/incoming'
readonly CADDY_IMPORT_LINE='import incoming/*.caddy'
readonly CADDY_IMPORT_RE='^[[:space:]]*import[[:space:]]+incoming/\*\.caddy[[:space:]]*(#.*)?$'

# ------------------------------------------------------------------

# 校验一份 Caddyfile。**带上环境文件里的令牌**：Caddyfile 里写
# `dns cloudflare {env.CLOUDFLARE_API_TOKEN}` 时，不注入变量的话
# `caddy validate` 会因为「变量为空」而失败 —— 而那不是配置的错。
caddy_validate() {
    local file=${1}
    local -a env_args=()
    local line
    if [[ -r ${CADDY_ENV_FILE} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ ${line} == *=* && ${line} != '#'* ]] || continue
            env_args+=(--env "${line}")
        done <"${CADDY_ENV_FILE}"
    fi

    # --want-stderr：caddy 把整份诊断写在 stderr，stdout 是空的。不要来的话
    # 「校验未通过」后面跟的是一个空行，用户与日志都拿不到任何线索。
    os::query --timeout 60 --want-stderr ${env_args[@]+"${env_args[@]}"} \
        -- caddy validate --config "${file}" --adapter caddyfile
}

# 校验失败时，把 caddy 的原话打出来，并在认得出的失败上补一句出口。
#
# 「令牌为空」值得单独认：Caddyfile 里的 `{env.XXX}` 展开不出东西时，caddy 报的是
# `API token '' appears invalid`，而那不是配置的错 —— 配置一个字都不用改，
# 该做的是 `oneserver caddy token`。没有这一句，用户会照着报错去翻 Caddyfile。
caddy_report_invalid() {
    os::info "${OS_RUN_OUTPUT:-（caddy 没有输出任何诊断信息）}"
    if [[ ${OS_RUN_OUTPUT} == *"token ''"* || ${OS_RUN_OUTPUT} == *'token "" '* ]]; then
        os::warn 'DNS 令牌是空的 —— 配置本身没问题，是 Caddy 读不到令牌'
        os::info '配上它：oneserver caddy token（配完按提示重启，reload 不会重读环境变量）'
    fi
    return 0
}

# 重载前把日志目录交还给 caddy 用户。**这一步没有就等于 reload 会随机失败。**
#
# `caddy validate` 不只是解析：它会 provision 各个模块，也就是**真的把配置里
# 写的日志文件建出来**。而校验必须以 root 跑（要读 0600 的环境文件），于是
# /var/log/caddy 下留下 root:root 0600 的文件 —— 服务是 caddy 用户，紧接着的
# reload 就是 `open /var/log/caddy/…: permission denied`，HTTP 400。
# 人手工敲一次 `caddy validate` 也是同样的结果，排查时最容易发生。
#
# 而 systemd 对 **reload 失败不动正在跑的进程**：is-active 仍是 active，旧配置
# 继续服务。现场表现是「状态正常、改的东西没生效、证书也签不下来」，三样都不
# 指向权限，这正是它值得一个专门函数的理由。
#
# **drop-in 的 LogsDirectory= 兜不住这件事**：systemd 只在目录属主与配置不符时
# 才递归修正，目录已经是 caddy:caddy 时，里面的 root 属主文件它看都不看。
# 所以 install_caddy 起服务前也有同样一段（fix_log_owner）。
#
# 先探再改：目录本来就对的时候不留审计记录，第二次执行才是真的零变更。
caddy_fix_log_owner() {
    [[ -d ${CADDY_LOG_DIR} ]] || return 0
    os::query -- find "${CADDY_LOG_DIR}" ! -user caddy -print -quit || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0
    os::record_change "把 ${CADDY_LOG_DIR} 的属主改回 caddy"
    os::run '把日志目录交还给 caddy 用户' -- chown -R caddy:caddy "${CADDY_LOG_DIR}"
}

# 重载，并在失败时把**后果**说清楚。
#
# 只报「重载失败」是不够的：失败之后旧进程带着旧配置继续跑，而所有常规检查
# （systemctl status、oneserver caddy status）都显示正常。不明说这一点，
# 人会以为新配置已经生效，然后去查一个根本不存在的问题。
# 重启并确认真的起来了。**重启前同样要交还日志目录属主**：理由与 caddy_reload
# 一样，只是后果更响 —— reload 是不生效，restart 是根本起不来。
caddy_restart() {
    caddy_fix_log_owner
    os::systemd_restart "${CADDY_UNIT}"
    probe::service_active "${CADDY_UNIT}"
    if [[ ${OS_PROBE_VALUE} != active && ${OS_DRYRUN} -ne 1 ]]; then
        os::query --timeout 10 --want-stderr -- journalctl -u "${CADDY_UNIT}" --no-pager -n 20
        os::debug "journalctl 尾部：${OS_RUN_OUTPUT}"
        os::die 1 'Caddy 重启后未能进入 active，日志里有 journalctl 的尾部输出'
    fi
    return 0
}

caddy_reload() {
    caddy_fix_log_owner
    os::systemd_reload "${CADDY_UNIT}" || {
        os::err '重载失败 —— systemd 不会动正在跑的进程，此刻服务里跑的仍是上一份配置'
        os::info "服务状态会显示 active，但那是旧进程。失败原因看：journalctl -u ${CADDY_UNIT} -n 30"
        # 环境文件在，就得提这一句：**reload 不重读 EnvironmentFile**。
        # 令牌刚变过的话，校验会通过（新进程读得到文件）而 reload 必然失败，
        # 两者的差别只在「谁读了那个文件」，从报错里一个字都看不出来。
        if [[ -f ${CADDY_ENV_FILE} ]]; then
            os::info "配置里用到 {env.*} 而令牌刚改过的话，要的是重启不是重载：oneserver caddy restart"
        fi
        return 1
    }
    return 0
}

# 应用一份新的 Caddyfile：校验 → 备份 → 换 inode → 重载。
#
# **校验在替换之前**（同 install_caddy 的 verify → switch）：一份跑不起来的
# Caddyfile 换上去再重载，等于把正在服务的站点全部打掉，而错误信息在
# journal 里、用户看到的是「网站打不开了」。
apply_caddyfile() {
    local src=${1}

    if ! os::query --timeout 10 -- test -s "${src}"; then
        os::die 2 '新配置是空的，拒绝应用'
    fi

    # 片段在、新配置里没有 import —— **自动补上，不是问一句**。
    #
    # 主 Caddyfile 里的那一行是面板 vhost 唯一的入口。整份替换会把它一起换掉，
    # 而 caddy validate 一个字都不会说（少一个 import 的配置完全合法），面板只是
    # 从此 404 —— 没有人会从「我换了份 Caddy 配置」联想到「面板没了」。
    # 面板是用户已经配好、正在用的东西，改配置不该顺手把它拆了；反过来「就是
    # 想关掉面板」有专门的出口（oneserver web disable 会问要不要连这行一起去掉），
    # 所以补进去不会把人锁在一个撤不掉的状态里。
    #
    # 补在校验之前：补完的这份才是真正要装上去的东西，让它整份过一遍 fmt 与
    # validate，而不是校验一份、装上另一份。
    if [[ -d ${CADDY_SNIPPET_DIR} ]] \
        && os::query --timeout 5 -- find "${CADDY_SNIPPET_DIR}" -maxdepth 1 -name '*.caddy' -print -quit \
        && [[ -n ${OS_RUN_OUTPUT} ]] \
        && ! os::query --timeout 5 -- grep -qE "${CADDY_IMPORT_RE}" "${src}"; then
        os::replace_line --append-if-missing "${src}" \
            "${CADDY_IMPORT_RE}" "${CADDY_IMPORT_LINE}" \
            || os::die 1 '给新配置补 import 行失败'
        os::info "新配置里没有 ${CADDY_IMPORT_LINE}，已自动补上一行 —— ${CADDY_SNIPPET_DIR}/ 下的片段（Web面板的 vhost 在那儿）才不会失效"
        os::info '不要面板了就关掉它：oneserver web disable —— 那里会问要不要把这一行也去掉'
    fi

    os::run --allow-fail '格式化 Caddyfile' -- caddy fmt --overwrite "${src}" || true

    if ! caddy_validate "${src}"; then
        os::err '新配置未通过 caddy validate，未做任何替换'
        caddy_report_invalid
        return 1
    fi
    os::ok '新配置校验通过'

    os::record_change "替换了 ${CADDYFILE}"
    os::backup_file "${CADDYFILE}" || os::die 1 "备份 ${CADDYFILE} 失败"
    os::install_file --mode 0640 "${src}" "${CADDYFILE}" \
        || os::die 1 "写入 ${CADDYFILE} 失败"

    if [[ ${OS_TEMPLATE_CHANGED} -eq 0 ]]; then
        os::ok 'Caddyfile 已是目标状态，无需重载'
        return 0
    fi

    os::run '设置 Caddyfile 属主' -- chown root:caddy "${CADDYFILE}"
    # reload 而不是 restart：Caddy 的 reload 是零停机的配置热替换，
    # 而 restart 会掐断正在进行的连接。这是 Caddy 相对其他 web 服务器的
    # 主要优势之一，没有理由不用
    caddy_reload || os::die 1 "新配置已写入 ${CADDYFILE}，但没能重载生效（回滚用 oneserver caddy rollback）"
    return 0
}

# ------------------------------------------------------------------

action_status() {
    probe::service_active "${CADDY_UNIT}"
    local active=${OS_PROBE_VALUE}
    probe::service_enabled "${CADDY_UNIT}"
    local enabled=${OS_PROBE_VALUE}
    probe::component_version caddy
    local ver=${OS_PROBE_VALUE%%$'\n'*}

    local conf='不存在'
    [[ -f ${CADDYFILE} ]] && conf=${CADDYFILE}

    os::section 'Caddy'
    os::kv '版本' "${ver:-未知}" \
        '运行状态' "${active}" \
        '开机自启' "${enabled}" \
        '配置文件' "${conf}" \
        '数据来源' "$(probe::describe)"
    os::output 0 version="${ver}" active="${active}" enabled="${enabled}"
    return 0
}

action_validate() {
    [[ -f ${CADDYFILE} ]] || os::die 2 "配置文件不存在：${CADDYFILE}"
    if caddy_validate "${CADDYFILE}"; then
        os::ok "${CADDYFILE} 校验通过"
        os::output 0 valid=yes
        return 0
    fi
    os::err '校验未通过'
    caddy_report_invalid
    os::die 1 "${CADDYFILE} 校验未通过"
}

# 从 URL、本地文件或 stdin 取一份新配置并应用。
#
# **先选来源，再只问那一个。** 原来是接连问 URL 和路径两遍，其中一遍必然是
# 空回车；而「本地文件」那一问既没说文件该放哪，也没给一条能照抄的路子。
#
# 管道喂配置（`cat new.caddy | oneserver caddy apply`）时**不能弹选单**：
# 那时 stdin 是配置本身，问一句就把配置的第一行吃掉了。
CADDY_DROP_FILES=()

# 投放目录里认得出的配置文件（只取一层，只要普通文件）。
#
# **按文件名筛，不是挑剔而是为了列表还能看**：/root 下本来就躺着 `.bashrc`、
# `.ssh`、各种下载来的杂物，全列出来等于没有列表。三种写法覆盖了绝大多数习惯
# （Caddyfile · Caddyfile.new · site.caddy · site.caddyfile），名字实在对不上的
# 仍可走 `--file=<完整路径>`——那条路不筛任何东西。
load_drop_dir() {
    CADDY_DROP_FILES=()
    [[ -d ${CADDY_DROP_DIR} ]] || return 0
    # 顺序不能是随机的，否则「只有一个文件就自动选中」与「多个文件让人挑」
    # 两条路给出的编号会来回变。排序经 `os::query --stdin` 把 find 的结果从
    # stdin 送进 sort —— 不起内层 shell，目录名也就不进任何脚本文本
    os::query --timeout 10 -- \
        find "${CADDY_DROP_DIR}" -maxdepth 1 -type f \
        \( -name 'Caddyfile*' -o -name '*.caddy' -o -name '*.caddyfile' \) -printf '%f\n' \
        || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0
    os::query --timeout 10 --stdin "${OS_RUN_OUTPUT}" -- sort || return 0
    local one
    local IFS=$'\n'
    for one in ${OS_RUN_OUTPUT}; do
        [[ -n ${one} ]] || continue
        CADDY_DROP_FILES+=("${one}")
    done
    return 0
}

action_apply() {
    local url='' file='' src_kind=''
    local -i given=0
    if os::flag --arg url; then
        src_kind=url
        given=1
    fi
    if os::flag --arg file; then
        src_kind='file'
        given=1
    fi

    if ((given == 0)); then
        if [[ ! -t 0 ]]; then
            src_kind=stdin
        else
            os::select --arg source '新配置从哪里来' src_kind \
                'file=本地文件' 'url=从 URL 下载'
        fi
    fi

    case ${src_kind} in
        url)
            os::ask --arg url '配置文件的 URL' url
            ;;
        file)
            if ((given == 1)); then
                # 命令行直接给了路径（脚本化用法），照它办，不碰投放目录
                os::ask --arg file '本地配置文件的完整路径' file
            else
                # 不建目录、不改权限：/root 一定在，而且它的权限不归本命令管。
                # 从前那三步是给 /etc/caddy/incoming/ 建家用的，那个目录已经不是
                # 投放箱了（见 CADDY_DROP_DIR 处的说明）
                load_drop_dir

                # **目录里没有不是失败，是「还没放」。** 此刻用户要的正是这个目录名，
                # 而不是一个退出码 —— 报错退出会把他弹回菜单，再进来还得重选一遍。
                # 这里等着他放好，回车再扫一遍。
                local -i waits=0
                while [[ ${#CADDY_DROP_FILES[@]} -eq 0 ]]; do
                    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
                        os::die 2 "${CADDY_DROP_DIR}/ 里没有认得出的配置文件，非交互下无从等待（改用 --file=<路径>）"
                    fi
                    waits=$((waits + 1))
                    if ((waits > 5)); then
                        os::die 2 "${CADDY_DROP_DIR}/ 里一直没有配置文件，已放弃"
                    fi
                    os::info "把改好的配置放进 ${CADDY_DROP_DIR}/，名字叫 Caddyfile，或以 .caddy / .caddyfile 结尾"
                    os::info "从你自己的机器传：scp Caddyfile root@这台机器:${CADDY_DROP_DIR}/"
                    # 用 confirm 不用 ask：这里要的是「放好了吗」，而 ask 得编一个
                    # 默认值，那个值会被原样打成「回车用 xxx」——一个只有代码看得懂的词
                    os::confirm --arg wait-file '放好了吗？回车继续，选否放弃' y \
                        || os::die 130 '已放弃，未做任何改动'
                    load_drop_dir
                done

                local -i nf=${#CADDY_DROP_FILES[@]}
                if ((nf == 1)); then
                    file="${CADDY_DROP_DIR}/${CADDY_DROP_FILES[0]}"
                    os::info "用 ${file}"
                else
                    local pick=''
                    os::select --required --arg file '用哪一份配置' pick "${CADDY_DROP_FILES[@]}"
                    file="${CADDY_DROP_DIR}/${pick}"
                fi
            fi
            ;;
        stdin) ;;
        *) os::die 2 "未知的配置来源「${src_kind}」" ;;
    esac

    local dir src
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    src="${dir}/Caddyfile.new"

    if [[ -n ${url} ]]; then
        os::info "从 ${url} 下载"
        os::run_out '下载 Caddyfile' -- \
            curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
            -o "${src}" "${url}" \
            || os::die 1 "下载失败：${url}"
    elif [[ -n ${file} ]]; then
        [[ -f ${file} ]] || os::die 2 "文件不存在：${file}"
        os::run '读取本地配置' -- cp -- "${file}" "${src}"
    else
        os::info '从标准输入读取配置'
        cat >"${src}"
    fi

    apply_caddyfile "${src}" || os::die 1 '应用新配置失败'
    os::ok 'Caddyfile 已更新'
    os::output 0 changed=yes
    return 0
}

action_edit() {
    if [[ ! -t 0 ]]; then
        os::die 2 'edit 需要一个交互式终端。非交互场景请用 apply'
    fi
    [[ -f ${CADDYFILE} ]] || os::die 2 "配置文件不存在：${CADDYFILE}"

    local dir src
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    src="${dir}/Caddyfile.edit"
    os::run '取出当前配置供编辑' -- cp -- "${CADDYFILE}" "${src}"

    os::section '编辑 Caddyfile'
    os::info "改的是 ${CADDYFILE} 的一份副本，存盘退出后先校验，通过了才替换并热重载"
    os::info 'nano：Ctrl+O 存盘、Ctrl+X 退出'

    # **必须在这里停一下。** 上面几行打完就直接开编辑器的话，nano/vim 一启动
    # 就清屏，那几行还没来得及被读到就被冲掉了 —— 现场表现是「什么提示都没有，
    # 直接跳进了编辑器」。
    os::confirm --arg edit-open '现在打开编辑器？' y \
        || os::die 130 '已取消，配置未改动'

    # 编辑器直接跑，不经 os::run：它要接管终端，而 os::run 会把 stdout
    # 收进日志管道（D64）—— 那会让 nano/vim 的界面完全乱掉
    "${EDITOR:-nano}" "${src}"

    # 编辑完不立刻替换：给「我只是想看看」和「改错了想重来」留个出口。
    # 此刻 /etc/caddy/Caddyfile 一个字节都还没动
    os::confirm --arg apply-edited '编辑完成，现在校验并应用？' y \
        || os::die 130 '已取消，配置未改动'

    apply_caddyfile "${src}" || os::die 1 '编辑后的配置未能应用'
    os::ok 'Caddyfile 已更新'
    os::output 0 changed=yes
    return 0
}

# 从框架的备份目录回滚。
#
# 旧脚本自己在 /etc/caddy 里堆 `Caddyfile.bak.<时间>` —— 与配置文件同目录，
# Caddy 扫目录时看得见，而且没人清理。框架的 os::backup_file 落在
# /var/backups/oneserver/files 且目录是 0700，直接用它。
action_rollback() {
    local dir="${OS_BACKUP_DIR}/files"
    [[ -d ${dir} ]] || os::die 2 "没有备份目录 ${dir}"

    # 「最新的那一份」= 按 mtime 倒序的第一条。用 find 带出时间戳再排序，
    # 不起内层 shell —— 目录名不进任何脚本文本（同 restore.sh 的列举函数）。
    # `%T@` 是纪元秒，数值排序，跨时区与跨年都不会像文件名那样排错
    os::query --timeout 10 -- \
        find "${dir}" -maxdepth 1 -type f -name '*_etc_caddy_Caddyfile*' -printf '%T@ %f\n' \
        || true
    local newest=''
    if [[ -n ${OS_RUN_OUTPUT} ]] \
        && os::query --timeout 10 --stdin "${OS_RUN_OUTPUT}" -- sort -rn; then
        newest=${OS_RUN_OUTPUT%%$'\n'*}
        newest=${newest#* }
    fi
    [[ -n ${newest} ]] || os::die 2 "在 ${dir} 里没找到 Caddyfile 的备份"

    local src="${dir}/${newest}"
    os::info "最新备份：${src}"
    apply_caddyfile "${src}" || os::die 1 '回滚失败（备份本身没通过校验，未做替换）'
    os::ok "已回滚到 ${newest}"
    os::output 0 backup="${newest}" changed=yes
    return 0
}

action_reload() {
    [[ -f ${CADDYFILE} ]] || os::die 2 "配置文件不存在：${CADDYFILE}"
    caddy_validate "${CADDYFILE}" || {
        os::info "${OS_RUN_OUTPUT}"
        os::die 1 '当前配置没通过校验，拒绝重载（重载一份坏配置会把站点打掉）'
    }
    caddy_reload || os::die 1 '重载未生效'
    os::ok 'Caddy 已重载配置'
    os::output 0 changed=yes
    return 0
}

action_restart() {
    caddy_restart
    os::ok 'Caddy 已重启'
    os::output 0 changed=yes
    return 0
}

# 日志：打最后 N 行，**不做 tail -f**。
#
# 实时跟踪跟命令式工具不搭（跑起来就不返回了），而旧脚本为了让 Ctrl+C
# 只退出跟踪不退出脚本，用了 `eval "$orig_trap"` ——规范给 trap 恢复留的
# 那处例外是给框架的，不是给脚本的。要实时跟就把命令打给用户自己敲。
# 看一眼当前配置。**与 edit 是两件事**：edit 会拉起编辑器、改完还要问应不应用，
# 而绝大多数时候人只是想确认「现在到底跑的是什么」——为这件事进一趟编辑器，
# 顺手改错一个字符的风险是白担的。
#
# 打的是**磁盘上**的 Caddyfile，不是 Caddy 内存里那份。改了没重载时两者会不
# 一致，这一点在下面写明，免得看着文件对、服务却是另一套行为时无从下手。
action_show() {
    [[ -f ${CADDYFILE} ]] || os::die 3 "${CADDYFILE} 不存在"

    os::query --timeout 10 -- cat -- "${CADDYFILE}" \
        || os::die 1 "读取 ${CADDYFILE} 失败"
    local body=${OS_RUN_OUTPUT}

    # 纯 bash 数行，不 fork wc：只读查询本该走 os::query，而为了一个行数
    # 再起一个进程、再包一层接口，不如根本不离开 bash
    local -i lines=0
    local -a rows=()
    if [[ -n ${body} ]]; then
        mapfile -t rows <<<"${body}"
        lines=${#rows[@]}
    fi

    if [[ ${OS_OUTPUT} == json ]]; then
        os::output 0 file="${CADDYFILE}" lines="${lines}"
        return 0
    fi

    os::section "${CADDYFILE}"
    # 原样打印，不走 os::info：配置是要照着抄、照着改的文本，
    # 每行前面加一个 `·` 就不再是它本身了（同 status 打 ufw 规则）
    printf '%s\n' "${body}"
    os::spacer
    os::kv '文件' "${CADDYFILE}" '行数' "${lines}"
    os::info '这是磁盘上的内容；改过而没重载的话，服务里跑的仍是上一份'
    os::info '改它：oneserver caddy edit（或 oneserver caddy apply 整份替换）'
    os::output 0 file="${CADDYFILE}" lines="${lines}"
    return 0
}

action_logs() {
    local lines=''
    os::ask --match '^[1-9][0-9]*$' --hint '要正整数' --arg lines '显示最近多少行' lines '50'

    os::query --timeout 20 -- journalctl -u "${CADDY_UNIT}" --no-pager -n "${lines}"
    os::section "Caddy 最近 ${lines} 行日志"
    os::info "${OS_RUN_OUTPUT}"
    os::info "要实时跟踪：journalctl -u ${CADDY_UNIT} -f"
    os::output 0 lines="${lines}"
    return 0
}

# 证书列表。**不解析 openssl 的日期做倒计时**（旧脚本那套 `date -d` 依赖
# locale 与 GNU date），只列出域名与文件时间 —— 到期时间 Caddy 自己会续，
# 真要看细节 openssl 一条命令的事，把它打给用户。
# 证书清单 → 两个平行数组：展示用的域名，以及它所在的目录（删单个时要用）
CADDY_CERT_NAMES=()
CADDY_CERT_DIRS=()

load_certs() {
    CADDY_CERT_NAMES=()
    CADDY_CERT_DIRS=()
    [[ -d ${CADDY_CERT_DIR} ]] || return 0
    os::query --timeout 20 -- find "${CADDY_CERT_DIR}" -type f -name '*.crt' || return 0
    local f domain
    local IFS=$'\n'
    for f in ${OS_RUN_OUTPUT}; do
        [[ -n ${f} ]] || continue
        domain=${f##*/}
        domain=${domain%.crt}
        domain=${domain/#wildcard_./*.}
        CADDY_CERT_NAMES+=("${domain}")
        # 一份证书的 .crt / .key / .json 同在一个目录里，删单个删的是这个目录
        CADDY_CERT_DIRS+=("${f%/*}")
    done
    return 0
}

# **只列出，不删。** 删除独立成 cert-rm ——
# 把「看一眼证书」和「删证书」放在同一个动作里，等于每次查看都要先回答一遍
# 「要不要清空全部」，而那是这个脚本里最疼的操作。
action_certs() {
    if [[ ! -d ${CADDY_CERT_DIR} ]]; then
        os::info "证书目录还不存在（${CADDY_CERT_DIR}）—— Caddy 第一次签发成功后才会建"
        os::output 0 count=0
        return 0
    fi

    load_certs
    local -i n=${#CADDY_CERT_NAMES[@]}
    if ((n == 0)); then
        os::info '证书目录存在但还没有证书'
        os::output 0 count=0
        return 0
    fi

    os::section 'TLS 证书'
    local -i i
    for ((i = 0; i < n; i++)); do
        os::kv "${CADDY_CERT_NAMES[i]}" "${CADDY_CERT_DIRS[i]}"
        os::output_item domain="${CADDY_CERT_NAMES[i]}" path="${CADDY_CERT_DIRS[i]}"
    done
    os::info "看有效期：openssl x509 -in <证书目录>/<域名>.crt -noout -dates"
    os::info '要删除：oneserver caddy cert-rm'
    os::output 0 count="${n}"
    return 0
}

# 删证书是**真正会疼**的操作：删完要重新签发，而 Let's Encrypt 对同一组域名
# 有每周签发次数上限 —— 撞上就是几天签不出来，站点一直没有证书。
# 所以：独立动作 · 列表里挑 · 走 os::destroy_confirm（打全名，--yes 不生效）。
action_cert_rm() {
    load_certs
    local -i n=${#CADDY_CERT_NAMES[@]}
    if ((n == 0)); then
        os::info "没有可删的证书（${CADDY_CERT_DIR}）"
        os::output 0 removed=0
        return 0
    fi

    local -a opts=("all=全部 ${n} 份")
    local -i i
    for ((i = 0; i < n; i++)); do
        opts+=("${CADDY_CERT_NAMES[i]}=${CADDY_CERT_DIRS[i]}")
    done

    # --required：非交互下没给 --cert 就停，不替人挑一个来删；编号打错也不落回第一项
    local target=''
    os::select --required --arg cert '要删除哪个证书' target "${opts[@]}"

    if [[ ${target} == all ]]; then
        if ! os::destroy_confirm --arg confirm-cert-rm 'all' -- \
            "${CADDY_CERT_DIR} 下的 ${n} 份证书与私钥" \
            '删除后 Caddy 会重新向 CA 申请' \
            "**Let's Encrypt 对同一组域名有每周签发上限，撞上就是几天签不出来**"; then
            os::info '已取消，证书未动'
            os::output 0 removed=0
            return 0
        fi
        os::record_change "清空了 ${CADDY_CERT_DIR}"
        os::run '清空证书目录' -- find "${CADDY_CERT_DIR}" -type f -delete
        os::ok "已删除 ${n} 份证书，重启 Caddy 后会重新签发"
        os::output 0 removed="${n}"
        return 0
    fi

    local dir=''
    for ((i = 0; i < n; i++)); do
        [[ ${CADDY_CERT_NAMES[i]} == "${target}" ]] || continue
        dir=${CADDY_CERT_DIRS[i]}
        break
    done
    [[ -n ${dir} ]] || os::die 2 "没有这个证书：${target}"
    # 双保险：`--cert=` 是用户给的，绝不让它把删除动作带出证书目录
    [[ ${dir} == "${CADDY_CERT_DIR}"/* ]] \
        || os::die 1 "拒绝删除证书目录之外的路径：${dir}"

    if ! os::destroy_confirm --arg confirm-cert-rm "${target}" -- \
        "${target} 的证书、私钥与元数据" \
        "目录 ${dir}" \
        '删除后 Caddy 会为这个域名重新申请' \
        "**Let's Encrypt 对同一组域名有每周签发上限**"; then
        os::info '已取消，证书未动'
        os::output 0 removed=0
        return 0
    fi

    os::record_change "删除了 ${target} 的证书"
    os::run '删除证书目录' -- rm -rf -- "${dir}"
    os::ok "已删除 ${target} 的证书，重启 Caddy 后会重新签发"
    os::output 0 removed=1 domain="${target}"
    return 0
}

# DNS 提供商的令牌。
#
# 三件事与旧脚本不同：
#   1. **不写死 Cloudflare** —— 插件清单里有三家，各自的环境变量名不同
#   2. **不 source secure.conf**（K12）—— 走 os::secure_load / os::secure_set
#   3. **令牌不写进 systemd drop-in** —— drop-in 默认 0644，等于把令牌摊给
#      机器上每一个用户。改成 drop-in 只写 EnvironmentFile=，令牌落在 0600 的
#      文件里由 systemd 以 root 读
action_token() {
    local provider=''
    os::select --arg provider 'DNS 提供商' provider \
        'cloudflare=Cloudflare' 'alidns=阿里云 DNS' 'tencentcloud=腾讯云 DNS'

    local env_name='' plugin=''
    case ${provider} in
        cloudflare)
            env_name='CLOUDFLARE_API_TOKEN'
            plugin='github.com/caddy-dns/cloudflare'
            ;;
        alidns)
            env_name='ALIDNS_ACCESS_KEY_SECRET'
            plugin='github.com/caddy-dns/alidns'
            ;;
        tencentcloud)
            env_name='TENCENTCLOUD_SECRET_KEY'
            plugin='github.com/caddy-dns/tencentcloud'
            ;;
        *) os::die 2 "不认识的提供商「${provider}」" ;;
    esac

    # **先看插件在不在，再问令牌。** 令牌只是喂给插件的一个环境变量：插件没编进
    # 二进制时，令牌存了、环境文件写了、服务也重启了，屏幕上一路是 ✓，而
    # `dns ${provider}` 这个指令根本不存在，Caddyfile 校验直接失败或证书永远签不下来。
    # 新手不会把这两件事联系起来，所以这里必须先说。
    #
    # 是告警而不是拒绝：先配令牌再装插件是合理顺序，用户也可能跑的是自己编的
    # 二进制。默认答否，因为「不知道要装插件」的人按回车才是对他有利的那一边
    probe::caddy_plugins
    if [[ " ${OS_PROBE_VALUE} " != *" ${plugin} "* ]]; then
        os::warn "当前的 Caddy 没有编进 ${plugin} —— 令牌配好了也不会生效：Caddyfile 里的 dns ${provider} 是这个插件提供的指令，缺了它配置校验就过不去"
        os::info "先装插件：oneserver install caddy --plugins=+${plugin}"
        os::confirm --arg token-anyway '仍然继续配置令牌？（打算稍后再装插件就选是）' n \
            || os::die 130 '已取消，未写入任何东西'
    fi

    local token=''
    if ! os::secure_load "caddy.dns_token" token; then
        os::ask_secret '请输入 DNS 提供商的 API 令牌' token
        os::secure_set 'caddy.dns_token' "${token}" || os::die 1 '保存令牌失败'
        # 凭据是本次新建的；后续文件落地失败时一起撤销。已有凭据不会走这里。
        os::defer os::secure_del 'caddy.dns_token'
    else
        os::info '沿用凭据库里已有的令牌（要换先 oneserver secure del caddy.dns_token）'
    fi

    local dir tmp
    local -i env_created=0 dropin_created=0 dropin_dir_created=0
    local -i state_created=0 state_cleanup_registered=0
    os::state_has caddy || state_created=1
    os::tmpdir dir || os::die 1 '无法创建临时目录'

    # 环境文件：0600，只有 systemd（root）读得到
    tmp="${dir}/oneserver.env"
    printf '%s=%s\n' "${env_name}" "${token}" >"${tmp}"
    [[ -e ${CADDY_ENV_FILE} ]] || env_created=1
    os::install_file --backup --mode 0600 "${tmp}" "${CADDY_ENV_FILE}" \
        || os::die 1 "写入 ${CADDY_ENV_FILE} 失败"
    # 只登记本次从无到有建的文件；覆盖用户原有同名文件时已经先备份，
    # 但它仍是用户资产，卸载不能据此把它删除。
    if ((env_created == 1)); then
        os::defer rm -f -- "${CADDY_ENV_FILE}"
        os::state_resource_add caddy file "${CADDY_ENV_FILE}" \
            || os::die 1 "登记 ${CADDY_ENV_FILE} 失败"
        # 手工安装的 Caddy 可能此前完全不在 state；失败回滚时不能留下只有
        # installed_at 的幽灵组件。state 原本存在则绝不整份删除。
        if ((state_created == 1)); then
            os::defer os::state_del caddy
            state_cleanup_registered=1
        fi
        os::defer os::state_resource_del caddy file "${CADDY_ENV_FILE}"
    fi

    # drop-in：只有一行引用，**里面没有秘密**
    tmp="${dir}/oneserver-env.conf"
    {
        printf '[Service]\n'
        printf 'EnvironmentFile=-%s\n' "${CADDY_ENV_FILE}"
    } >"${tmp}"
    [[ -d ${CADDY_DROPIN_DIR} ]] || dropin_dir_created=1
    os::run '创建 systemd drop-in 目录' -- mkdir -p "${CADDY_DROPIN_DIR}"
    ((dropin_dir_created == 1)) && os::defer rmdir -- "${CADDY_DROPIN_DIR}"
    [[ -e ${CADDY_DROPIN} ]] || dropin_created=1
    os::install_file --backup --mode 0644 "${tmp}" "${CADDY_DROPIN}" \
        || os::die 1 "写入 ${CADDY_DROPIN} 失败"
    if ((dropin_created == 1)); then
        os::defer rm -f -- "${CADDY_DROPIN}"
        os::state_resource_add caddy file "${CADDY_DROPIN}" \
            || os::die 1 "登记 ${CADDY_DROPIN} 失败"
        if ((state_created == 1 && state_cleanup_registered == 0)); then
            os::defer os::state_del caddy
            state_cleanup_registered=1
        fi
        os::defer os::state_resource_del caddy file "${CADDY_DROPIN}"
    fi

    os::systemd_daemon_reload

    # 文件、state、凭据都已落地，这件事到此做成了 —— 后面那步重启是「让它生效」，
    # 失败了也不该把令牌撤回去。不提交的话，重启失败会连坐删掉刚写好的环境文件，
    # 用户重输一遍令牌、再失败一次、再被删一次（K18 就是这么发生的）。
    os::commit

    # **在这里问，而不是丢一句「记得重启」。** reload 不重读 EnvironmentFile，
    # 只有重启才会 —— 而这件事的后果要等到下一次换配置时才显形：校验通过
    # （校验是新进程，读得到文件），reload 却失败，现场是「配置明明是对的却装不上」，
    # 没人会回想到几步之前那句黄字。默认答是：不重启的话这次配置等于没做完。
    if os::confirm --arg restart-now '现在重启 Caddy 让令牌生效？' y; then
        caddy_restart
        os::ok 'Caddy 已重启，令牌已生效'
    else
        os::warn '令牌写下了但还没生效 —— 记得 oneserver caddy restart（reload 不算，它不重读环境变量）'
    fi

    os::kv '提供商' "${provider}" \
        '环境变量' "${env_name}" \
        '环境文件' "${CADDY_ENV_FILE}（0600）" \
        '凭据键名' 'caddy.dns_token'
    os::output 0 provider="${provider}" env="${env_name}" changed=yes
    return 0
}

# ------------------------------------------------------------------

main() {
    # 装没装以 probe 为准，不用 @requires（D93 / D138）——
    # 手工 apt 装的 Caddy 不在 state 里
    probe::component_version caddy
    if [[ -z ${OS_PROBE_VALUE} ]]; then
        os::die 3 '没有检测到 Caddy。先 oneserver install caddy'
    fi
    os::require_cmd caddy systemctl

    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_status --arg action '操作' dispatch \
        'show=查看配置' 'validate=校验配置' 'apply=更新配置' 'edit=编辑配置' \
        'rollback=回滚到上一版配置' 'reload=热重载配置' 'restart=重启服务' \
        'logs=查看日志' 'certs=查看证书' 'cert-rm=删除证书' 'token=配置 DNS 令牌'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        show) action_show ;;
        validate) action_validate ;;
        apply) action_apply ;;
        edit) action_edit ;;
        rollback) action_rollback ;;
        reload) action_reload ;;
        restart) action_restart ;;
        logs) action_logs ;;
        certs) action_certs ;;
        cert-rm) action_cert_rm ;;
        token) action_token ;;
        *) os::die 2 "未知操作「${1}」，可用：status show validate apply edit rollback reload restart logs certs cert-rm token" ;;
    esac
}

main "$@"
