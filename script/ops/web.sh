#!/bin/bash
#
# 只读 Web面板
#
# @command      web
# @name         Web 面板
# @group        monitor
# @order        5
# @privilege    root
# @requires_lib >= 4.8
# @provides     web
# @provides_unit own:oneserver-web-live.service
# @provides_unit own:oneserver-web-live.timer
# @provides_unit own:oneserver-web-fast.service
# @provides_unit own:oneserver-web-fast.timer
# @provides_unit own:oneserver-web-slow.service
# @provides_unit own:oneserver-web-slow.timer
# @args         [--action=<enable|disable|status|report|telegram|refresh>] [--basic-auth=<y|n>] [--allow-from=<CIDR>] [--telegram-chat-id=<chat_id>] [--caddy-import=<y|n>] [--caddy-unimport=<y|n>] [--firewall-allow=<y|n>] [--firewall-revoke=<y|n>]
# @description  开关只读面板，异常时 Telegram 通知
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 为什么这个面板只读、但监听所有网卡
# ==================================================================
#
# 规范 §1 明确「不做操作型 Web 面板」。这里做的是它的补集：**只显示**，
# 页面上没有任何按钮能改服务器状态，连刷新按钮也只是重新拉取已落盘的
# 数据，不触发服务端探测。
#
# 只读不等于不用门——那是两件独立的事（§1）。但**门有两种形态**，二选一：
#
#   密码（默认）  监听所有网卡，basic_auth 挡，密码进凭据库（键名 web.basic_auth）。
#                 公网服务器上你和它不在一个局域网，密码是唯一不逼人开隧道的门。
#   来源限制      内网机器上密码只是负担。选否时监听收窄到 127.0.0.1，或只对
#                 指定网段应答、其余 403。
#
# **关掉密码时那句来源限制必须当场落实**，不能只打一行警告 —— §15 点名禁止
# 「先开放，稍后提示用户自行加固」。所以这两个问题是同一步里的一问一答，
# 而不是「关掉密码」加「记得自己去限制来源」。
#
# 要不要再套 HTTPS/域名/反代，跟这台机器上其他任何站点一样走 oneserver caddy
# 自己决定，面板不替你做这个选择。
#
# 不去改用户的 Caddyfile：那是他的主配置，§11 也禁止就地修改。片段落在
# incoming/，最后那行 import 由人自己决定 —— enable 时问一句加不加，disable
# 时（且 incoming/ 已经空了）问一句去不去掉，两处都默认否。
#
# 唯一不问就动手的地方在 `oneserver caddy apply`：那条路是整份替换 Caddyfile，
# 不把 import 带过去的话，面板会因为一次无关的配置更新而静默 404。

readonly CADDY_INBOX='/etc/caddy/incoming'
readonly CADDY_SNIPPET="${CADDY_INBOX}/oneserver-web.caddy"
readonly CADDYFILE='/etc/caddy/Caddyfile'
readonly CADDY_ENV_FILE='/etc/caddy/oneserver.env'
readonly CADDY_UNIT='caddy.service'
readonly CADDY_LOG_DIR='/var/log/caddy'
readonly CADDY_IMPORT_LINE='import incoming/*.caddy'
# 认这一行的正则。容许行首缩进与行尾注释 —— 用户自己加过的那行未必长成
# CADDY_IMPORT_LINE 的样子，认不出来就会被当成「没有」而重复追加一行
readonly CADDY_IMPORT_RE='^[[:space:]]*import[[:space:]]+incoming/\*\.caddy[[:space:]]*(#.*)?$'
readonly WEB_PORT='8730'
readonly WEB_AUTH_KEY='web.basic_auth'
readonly COMPONENT='web'
# ufw 的措辞随 locale 变，而下面收回放行时要按文本判定删没删掉。
#
# **不派发 oneserver firewall 去做这件事**：本命令持着全局锁，子进程 flock
# 同一个文件只能等到超时 —— 所以 ufw 只能在本进程里直接发。放行走
# lib/firewall.sh，只有删规则留在这里（§11 防火墙那行的例外说明）。
readonly UFW_ENV='LC_ALL=C'

# 面板的门。二选一，不能都没有。
GUARD_AUTH='yes' # 用密码挡
GUARD_FROM=''    # 不用密码时允许的来源网段；空＝只允许本机

readonly -a WEB_UNITS=(
    'oneserver-web-live.timer'
    'oneserver-web-fast.timer'
    'oneserver-web-slow.timer'
)
# 采集产物。disable 时要清掉：留着的话，页面没了数据还在，而那份数据
# 会永远停在被关掉的那一刻——比没有更容易误导人
readonly -a WEB_FILES=(
    'probe-live.tsv'
    'probe-fast.tsv'
    'probe-slow.tsv'
    'history.tsv'
    'alerts.tsv'
    'components.tsv'
    'containers.tsv'
    'volumes.tsv'
    'container-updates.tsv'
    'firewall.tsv'
    'backups.tsv'
    'oneserver.jsonl'
    'report.html'
)

# ------------------------------------------------------------------
# 面板页面**由 Caddy 直接从模板目录读**，数据目录里既没有副本也没有链接。
#
# 副本会过期：`oneserver update` 整目录换掉 templates/，而副本停在拷过去
# 那一刻 —— 升级完面板还是旧版，用户没有任何迹象能看出来。
# 链接解决了过期，但数据目录搬到 tmpfs 之后它每次重启都会消失，于是又要再找
# 一个东西在开机时把它补回来。
#
# 直接让 Caddy 指过去，两个问题一起没有：升级换掉模板即刻生效，重启不需要
# 谁来补。模板是 0644、templates/ 是 0755，跑 Caddy 的用户读得到。
page_source() {
    # 走 os::template_source：/etc 下的同名文件优先，属主/权限不合格就**拒绝
    # 采用它**（它会把拒绝的理由打在 stderr 上，不是静默）。此处随后退回分发
    # 自带的那一份 —— 对这个页面来说「不采用可疑的覆盖」就是安全的那一侧，
    # 而整条命令失败只会让面板连页面都没有。写配置那条路（os::install_template）
    # 的安全侧不同，它是直接中止。
    # 这个页面由 Caddy 直接对外提供，一个组可写的覆盖文件等于让别人改面板内容。
    local resolved=''
    if os::template_source 'dashboard.html' resolved; then
        printf '%s' "${resolved}"
    else
        printf '%s' "${OS_TEMPLATE_DIR}/dashboard.html"
    fi
}

# 页面所在的目录，给 Caddy 的第二个 root 用。页面文件名固定是 dashboard.html，
# 变的只有它在 /etc 覆盖还是在 templates/ 下
page_dir() {
    local src
    src=$(page_source)
    printf '%s' "${src%/*}"
}

ensure_public_dir() {
    [[ -d ${OS_PUBLIC_DIR} ]] && return 0
    os::run '创建面板数据目录' -- \
        mkdir -m "${OS_PUBLIC_DIR_MODE}" "${OS_PUBLIC_DIR}"
}

# Caddy 直接从当前版本的 templates/ 读页面。更新归档在 umask 027 下解包时，
# 旧版本可能把目录落成 0750；文件本身即使是 0644，Caddy 也穿不过父目录。
# enable 在生成片段之前校正分发模板路径并以真实 caddy 身份验读，不能再把
# 「文件存在」当成「HTTP 服务读得到」。/etc 下的用户覆盖不擅自放宽父目录；
# 它若不可读就明确失败，让用户决定那棵配置树的暴露范围。
ensure_caddy_page_access() {
    local src
    src=$(page_source)
    [[ -f ${src} ]] || {
        os::err "面板页面模板不存在：${src}"
        return 1
    }

    if [[ ${src} == "${OS_TEMPLATE_DIR}/dashboard.html" ]]; then
        local path want got
        for path in "${OS_ROOT}" "${OS_TEMPLATE_DIR}"; do
            want=755
            os::query -- stat -c %a -- "${path}" || return 1
            got=${OS_RUN_OUTPUT}
            [[ ${got} == "${want}" ]] \
                || os::run '校正面板模板目录权限' -- chmod 0755 -- "${path}" || return 1
        done
        os::query -- stat -c %a -- "${src}" || return 1
        [[ ${OS_RUN_OUTPUT} == 644 ]] \
            || os::run '校正面板页面权限' -- chmod 0644 -- "${src}" || return 1
    fi

    os::require_cmd runuser
    os::query -- runuser -u caddy -- test -r "${src}" || {
        os::err "Caddy 用户读不到面板页面：${src}"
        os::info '不会自动放宽 /etc 下的用户覆盖目录；请检查 namei -l 输出后自行决定权限'
        return 1
    }
    return 0
}

web_enabled() {
    probe::service_enabled 'oneserver-web-fast.timer'
    [[ ${OS_PROBE_VALUE} == enabled ]]
}

# 问一次「要不要密码」，答案连同来源限制一起进 state。
#
# **默认 y**：关掉密码是降低安全性的选项，§15 要求这类默认必须为否。
# 关掉的那一步里当场把来源限制问出来（留空＝只听 127.0.0.1），补偿控制与
# 放宽写进同一份片段 —— 而不是打一行「记得自己去限制来源」。
#
# 已经启用过的机器拿 state 当默认值：重复 enable 是 update 之后的例行动作，
# 不该每次把人问一遍，更不该悄悄把他关掉的密码打开。
resolve_guard() {
    # os::state_get 取不到时返回默认值且退出码 0，不必再兜一次
    local def='y'
    [[ $(os::state_get "${COMPONENT}" auth 'yes') == no ]] && def='n'

    if os::confirm --arg basic-auth \
        '面板用密码保护？选否就改用来源限制（只有本机或你指定的网段能打开）' "${def}"; then
        GUARD_AUTH='yes'
        GUARD_FROM=''
        return 0
    fi

    GUARD_AUTH='no'
    local cur
    cur=$(os::state_get "${COMPONENT}" from '')
    # 空串是合法答案（「只允许本机」），所以正则里带一个空分支，而默认值
    # 必须显式给出 —— 否则非交互下这条调用会被当成「没给默认值」而以 2 停下
    os::ask --match '^([0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2})?$' \
        --hint '例 192.168.1.0/24；留空＝只允许本机 127.0.0.1' --arg allow-from \
        '允许哪个网段访问面板？' GUARD_FROM "${cur}"
    if [[ -n ${GUARD_FROM} ]]; then
        os::warn "面板不设密码，只有来源限制挡着：${GUARD_FROM} 之外的请求一律 403"
    else
        os::warn "面板不设密码，监听收窄到 127.0.0.1 —— 只能从这台机器上打开（或经 SSH 隧道）"
    fi
    return 0
}

# UFW 里放行过面板端口的 TCP 没有。规则匹配在 lib/firewall.sh（§11）——
# 那条正则真机上栽过一次（少一个结尾锚点，`8730/udp` 被读成「TCP 已放行」，
# 于是放行提示再也不出现而面板打不开），四个调用点各写一份就要各栽一次。
web_port_allowed() {
    probe::ufw_rules
    os::ufw_allowed "${OS_PROBE_VALUE}" "${WEB_PORT}" tcp
}

# 放行范围跟着门走。给了网段就只放行那个网段 —— 放成 Anywhere 的话，挡在
# 外面的就只剩 Caddy 那条 remote_ip，少一层。
#
# **FW_RULE 只剩 revoke 用**：删一条规则要拿规则全文，而删不在 firewall.sh 里
# （§11 防火墙那行的例外说明）。放行走 os::ufw_allow，它自己拼规则。
# FW_SCOPE 两条路都用，措辞集中在这里。
FW_RULE=()
FW_SCOPE=''

firewall_rule_for() {
    local from=${1}
    if [[ -n ${from} ]]; then
        FW_RULE=(from "${from}" to any port "${WEB_PORT}" proto tcp)
        FW_SCOPE=${from}
    else
        FW_RULE=("${WEB_PORT}/tcp")
        FW_SCOPE='所有来源'
    fi
    return 0
}

# enable 收尾：UFW 开着但没放行面板端口时问一句。
#
# **默认否**（§15：放宽访问来源默认必须为否）。问一句而不是只丢一行提示，
# 是因为 8730 是本命令自己开出来的端口 —— 不放行它就等于这条命令做了一半。
#
# **只听回环时压根不问**：Caddy 绑在 127.0.0.1 上，包到不了网卡，一条 ufw
# 规则不会让任何人多打开一个页面，问了只是噪声。
#
# 无密码但限了网段则照问不误，而且**只放行那个网段**。曾经在这里一刀切成
# 「没密码就拒绝放行」，把「无密码 + 仅本机」和「无密码 + 限网段」当成了
# 同一件事 —— 后者的门（remote_ip）根本没被防火墙动到，而放行恰恰是它能用
# 的前提，于是那台机器上永远等不到提示，面板也永远打不开。
offer_firewall_allow() {
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] || return 0
    [[ ${GUARD_AUTH} == no && -z ${GUARD_FROM} ]] && return 0
    web_port_allowed && return 0

    firewall_rule_for "${GUARD_FROM}"
    os::confirm --arg firewall-allow \
        "UFW 已启用，但没放行面板端口 ${WEB_PORT}/tcp，外面现在打不开。放行给 ${FW_SCOPE}？" n || {
        os::info "留着了。自己放行：oneserver firewall allow --ports=${WEB_PORT}"
        return 0
    }

    os::ufw_allow "${WEB_PORT}" tcp "${GUARD_FROM}" || return 1
    os::ufw_reload || return 1
    os::ok "已放行 ${WEB_PORT}/tcp（来源 ${FW_SCOPE}）"
    return 0
}

# disable 收尾：面板都关了，那条放行就是个没人守的洞。
#
# **默认是**，与 drop_caddy_import 的「默认否」相反：那一行 import 管的是整个
# incoming/ 目录，可能还有别的片段在用；而 8730 只有面板用，收回它不会影响
# 任何别的东西。方向也不同 —— 收紧不受 §15 约束，留着开口才是。
revoke_firewall() {
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] || return 0
    web_port_allowed || return 0

    os::confirm --arg firewall-revoke \
        "UFW 里还留着 ${WEB_PORT}/tcp 的放行，而面板已经关了。收回？" y || {
        os::info "留着了。要自己收回：oneserver firewall delete --ports=${WEB_PORT}"
        return 0
    }

    # 按当初放行的那个范围删。ufw 认的是规则全文，拿 `8730/tcp` 去删一条
    # `from <网段> to any port 8730` 是删不掉的 —— 这一步排在 state_del 之前
    # 就是为了还能读到 from
    firewall_rule_for "$(os::state_get "${COMPONENT}" from '')"
    os::record_change "从 UFW 收回 ${WEB_PORT}/tcp 的放行"
    os::run_out --allow-fail --env "${UFW_ENV}" '收回面板端口的放行' \
        -- ufw delete allow "${FW_RULE[@]}" || true
    # 删不掉不能报成功：规则可能是手工加的，范围和我们记的对不上，
    # 而一句「已收回」会让人以为端口关了
    if ((OS_RUN_STATUS != 0)); then
        os::warn "没能自动收回 ${WEB_PORT}/tcp —— 规则范围与记录的不一致，自己看一眼 oneserver firewall status"
        return 0
    fi
    os::run --env "${UFW_ENV}" '重载 UFW 使变更生效' -- ufw reload || return 1
    os::ok "已收回 ${WEB_PORT}/tcp（来源 ${FW_SCOPE}）"
    return 0
}

install_units() {
    local u
    for u in oneserver-web-live.service oneserver-web-live.timer \
        oneserver-web-fast.service oneserver-web-fast.timer \
        oneserver-web-slow.service oneserver-web-slow.timer; do
        os::systemd_install "${OS_UNIT_SRC_DIR}/${u}" own || return 1
    done
    os::systemd_daemon_reload || return 1
    return 0
}

write_caddy_snippet() {
    # 不能拿 incoming/ 是否存在当成 Caddy 是否安装：这是 caddy apply 的投放
    # 目录，不是包安装时必有的目录。此前 Caddy 明明已装、面板却被报成「未装
    # HTTP 服务」，片段、HTTP 风险警告与 import 指引一起消失。
    probe::component_version caddy
    [[ -n ${OS_PROBE_VALUE} ]] || return 0
    os::require_cmd caddy
    ensure_caddy_page_access || return 1

    if [[ ! -d ${CADDY_INBOX} ]]; then
        # Caddy 进程以 caddy 用户运行，父目录没有执行权限时 import 会静默匹配
        # 0 个文件。目录只在本次新建时设权限，重复 enable 不产生变更。
        os::run '创建 Caddy 配置投放目录' -- mkdir -p "${CADDY_INBOX}"
        os::run '让 Caddy 用户能读投放目录' -- chown root:caddy "${CADDY_INBOX}"
        os::run '收紧 Caddy 投放目录权限' -- chmod 0750 "${CADDY_INBOX}"
    fi

    # --- 不设密码：门是来源限制，那条路上一个密码都不用生成 ---
    #
    # 站点地址与 guard 两处配合：给了网段就仍监听所有网卡、由 remote_ip 拒掉
    # 其余来源；没给就把监听本身收窄到 127.0.0.1，一行 Caddy 指令都不用。
    if [[ ${GUARD_AUTH} == no ]]; then
        local addr=":${WEB_PORT}" guard=''
        if [[ -n ${GUARD_FROM} ]]; then
            guard=$'\t@blocked not remote_ip '"${GUARD_FROM}"$'\n\trespond @blocked 403'
        else
            addr="127.0.0.1:${WEB_PORT}"
        fi
        os::install_template --mode 0644 \
            "${OS_TEMPLATE_DIR}/caddy-dashboard.conf" "${CADDY_SNIPPET}" \
            "SITE_ADDR=${addr}" "PUBLIC_DIR=${OS_PUBLIC_DIR}" \
            "PAGE_DIR=$(page_dir)" "GUARD=${guard}" || return 1
        os::state_resource_add "${COMPONENT}" file "${CADDY_SNIPPET}" || true
        return 0
    fi

    # 面板登录密码。**复用已有的**：反复走这条路径（比如 update 后重装
    # unit）不该每次都换一次密码，把已经记住密码的人全部踢出去。
    # 要换新密码：oneserver secure del web.basic_auth，再 disable/enable 一遍
    local pass='' hash=''
    if os::secure_load "${WEB_AUTH_KEY}" pass; then
        # 密码没换就沿用片段里已有的哈希。**bcrypt 每次加盐**，同一个密码
        # 每次算出的哈希都不一样 —— 照算的话片段内容每次都「变了」，
        # os::install_template 的幂等性被绕过，每次 enable 都要白重载一次
        # Caddy，而 enable 是 update 之后的例行动作。
        # 片段里有哈希 ⇒ 它就是这个密码的：哈希只在这里写，而密码只在
        # 凭据库里没有时才重新生成（那条路走下面的分支）。
        if [[ -r ${CADDY_SNIPPET} ]]; then
            # 用 `[$]` 而不是 `\$`：bcrypt 哈希以 `$2a$` 开头，写成 `\$`
            # 会被 shellcheck 当成一个没能展开的变量（字符类里没有这个歧义）。
            # 注意别让注释以 shellcheck 这个词开头 —— 那是它的指令前缀
            os::query -- sed -n \
                's/^[[:space:]]*admin[[:space:]]\{1,\}\([$]2[aby][$][^[:space:]]\{1,\}\).*/\1/p' \
                "${CADDY_SNIPPET}" || true
            hash=${OS_RUN_OUTPUT}
        fi
    else
        os::query --timeout 10 -- openssl rand -hex 16 || os::die 1 '生成面板密码失败'
        pass=${OS_RUN_OUTPUT}
        [[ ${#pass} -ge 16 ]] || os::die 1 '生成的密码长度异常，拒绝继续'
        os::secure_set "${WEB_AUTH_KEY}" "${pass}" || os::die 1 '保存面板密码失败'
    fi

    # Caddyfile 的 basic_auth 只认哈希，不认明文；密码经 stdin 送进 caddy，
    # 不进 argv（ps 对同机所有用户可见，同 D63）
    if [[ -z ${hash} ]]; then
        os::run_out --stdin-secret "${pass}" '生成面板密码哈希' -- caddy hash-password \
            || os::die 1 '生成密码哈希失败'
        hash=${OS_RUN_OUTPUT}
        # dry-run 下这条根本没跑，**拿不到哈希是必然的，不是故障**。此前这里
        # 一路走到下面那句 `os::die 1 密码哈希为空` —— 干净机器上（Caddy 已装、
        # 片段还没生成）敲一次 `web enable --dry-run` 就是「预演直接报错」。
        # §10：跳过副作用之后真实状态与推演状态已分叉，遇到依赖未满足**禁止**
        # 报错退出，必须声明预演到哪一步并以 0 结束。
        if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
            os::info '[dry-run] 预演到此为止：密码哈希要由 caddy hash-password 现算，它已被跳过，后面的片段内容推演不出来'
            return 0
        fi
    fi
    [[ -n ${hash} ]] || os::die 1 '密码哈希为空，拒绝写入配置'

    os::install_template --mode 0644 \
        "${OS_TEMPLATE_DIR}/caddy-dashboard.conf" "${CADDY_SNIPPET}" \
        "SITE_ADDR=:${WEB_PORT}" "PUBLIC_DIR=${OS_PUBLIC_DIR}" \
        "PAGE_DIR=$(page_dir)" \
        "GUARD=$(printf '\tbasic_auth {\n\t\tadmin %s\n\t}' "${hash}")" || return 1
    os::state_resource_add "${COMPONENT}" file "${CADDY_SNIPPET}" || true
    return 0
}

validate_caddyfile() {
    local -a env_args=()
    local line
    if [[ -r ${CADDY_ENV_FILE} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ ${line} == *=* && ${line} != '#'* ]] || continue
            env_args+=(--env "${line}")
        done <"${CADDY_ENV_FILE}"
    fi
    os::query --timeout 60 ${env_args[@]+"${env_args[@]}"} \
        -- caddy validate --config "${1}" --adapter caddyfile
}

fix_caddy_log_owner() {
    [[ -d ${CADDY_LOG_DIR} ]] || return 0
    os::query -- find "${CADDY_LOG_DIR}" ! -user caddy -print -quit || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0
    os::run '把 Caddy 日志目录交还给服务用户' -- chown -R caddy:caddy "${CADDY_LOG_DIR}"
}

# offer_caddy_import <片段是否有变动>
#
# 已经 import 过的机器上，这个片段就是 Caddy 正在跑的配置的一部分 —— 改了它
# 而不热重载，Caddy 继续用内存里的旧配置，而命令已经报了「面板已启用」。
# 换密码时这一点最要命：`enable` 说完成了，实际拦人的还是上一个密码；
# 首次启用时更糟，片段刚生成、还没被读进去，8730 是**不带认证**开着的。
offer_caddy_import() {
    local snippet_changed=${1:-0}
    [[ -f ${CADDY_SNIPPET} && -f ${CADDYFILE} ]] || return 0
    if os::query --timeout 5 -- grep -qE "${CADDY_IMPORT_RE}" "${CADDYFILE}"; then
        if ((snippet_changed == 1)); then
            os::systemd_reload "${CADDY_UNIT}" \
                || os::die 1 '面板片段已更新，但 Caddy 热重载失败 —— 它仍在运行旧配置'
            os::ok 'Caddy 已热重载，面板配置生效'
        fi
        return 0
    fi

    os::confirm --arg caddy-import \
        '将面板片段加入 Caddyfile 并热重载 Caddy？' n || return 0

    # 先在同目录副本上加入 import 并校验。主配置只在候选文件通过校验后才
    # 替换；否则现有站点继续使用原配置。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::replace_line --append-if-missing --backup "${CADDYFILE}" \
            "${CADDY_IMPORT_RE}" \
            "${CADDY_IMPORT_LINE}"
        ((OS_REPLACE_CHANGED == 1)) && os::systemd_reload "${CADDY_UNIT}"
        return 0
    fi

    # 临时名走 mktemp，不拼 `$$`（同 template::_place 与 os::replace_line）：
    # PID 只有三万多个取值、可以喷洒预置，而 /etc/caddy 是 root:caddy ——
    # 一个能以 caddy 身份写那个目录的进程可以事先把这个名字建成指向别处的
    # 符号链接，`cp` 就跟过去以 root 覆写它。mktemp 走 O_EXCL，路径已存在就失败
    local candidate=''
    candidate=$(mktemp "${CADDYFILE}.oneserver-web-import.XXXXXXXX") \
        || os::die 1 "无法在 ${CADDYFILE%/*} 下创建临时文件"
    os::run '准备 Caddyfile 校验副本' -- cp -- "${CADDYFILE}" "${candidate}"
    os::defer rm -f -- "${candidate}"
    os::replace_line --append-if-missing "${candidate}" \
        "${CADDY_IMPORT_RE}" \
        "${CADDY_IMPORT_LINE}" || os::die 1 '生成 Caddyfile 候选配置失败'
    validate_caddyfile "${candidate}" || {
        os::err '加入面板片段后的 Caddyfile 未通过校验，原配置未改动'
        os::info "${OS_RUN_OUTPUT}"
        os::die 1 'Caddyfile 校验失败'
    }

    os::record_change "在 ${CADDYFILE} 中加入面板片段 import"
    os::install_file --backup --mode 0640 "${candidate}" "${CADDYFILE}" \
        || os::die 1 '写入 Caddyfile 失败'
    os::run '设置 Caddyfile 属主' -- chown root:caddy "${CADDYFILE}"
    fix_caddy_log_owner
    os::systemd_reload "${CADDY_UNIT}" \
        || os::die 1 'Caddyfile 已写入，但热重载失败；服务仍在运行旧配置'
    os::run '清理 Caddyfile 校验副本' -- rm -f -- "${candidate}"
    os::ok 'Caddy 已纳入面板配置并热重载'
    return 0
}

do_enable() {
    resolve_guard

    if web_enabled; then
        install_units || return 1
        ensure_public_dir || return 1
        # **已启用的机器也要把每个 timer 过一遍**，不能因为「面板已经开着」
        # 就跳过。判据 web_enabled 只看快档那一个 timer —— 新增一档时，
        # 老机器上 unit 文件装进去了却从来没人 enable 它，现场表现是升级完
        # 少了一档数据而面板报「已启用，无需变更」。真机上第一次就撞到了。
        # os::systemd_enable 对已启用的 unit 是幂等的，多跑一遍没有代价。
        local u
        for u in "${WEB_UNITS[@]}"; do
            os::systemd_enable "${u}" --now own || return 1
        done
        write_caddy_snippet || return 1
        local snippet_changed=${OS_TEMPLATE_CHANGED}
        save_guard
        if ((snippet_changed == 1)); then
            os::ok '面板片段已更新'
        else
            os::ok '面板已启用，无需变更'
        fi
        offer_caddy_import "${snippet_changed}"
        offer_firewall_allow
        return 0
    fi

    install_units || return 1

    ensure_public_dir || return 1

    local u
    for u in "${WEB_UNITS[@]}"; do
        os::systemd_enable "${u}" --now own || return 1
    done

    write_caddy_snippet
    local snippet_changed=${OS_TEMPLATE_CHANGED}

    # 显式登记 unit，**不等框架在退出时自动登记**：首轮采集就在下面几行，
    # 而自动登记发生在命令退出的 EXIT 钩子里 —— 那时首轮早跑完了，采到的
    # 组件资源清单是空的，面板要等下一轮慢档（最长 5 分钟）才自愈。
    # os::state_unit_add 对重复项是幂等的，退出时再登记一次没有代价。
    local unit
    for unit in oneserver-web-live.service oneserver-web-live.timer \
        oneserver-web-fast.service oneserver-web-fast.timer \
        oneserver-web-slow.service oneserver-web-slow.timer; do
        os::state_unit_add "${COMPONENT}" "own:${unit}" || true
    done

    # 立刻采一轮：否则页面开出来是空的，而用户没法区分「还没采」和「坏了」
    os::run '采集首轮面板数据' -- \
        "${OS_SCRIPT_DIR}/ops/web_collect.sh" --tier=all --non-interactive || true

    os::state_set "${COMPONENT}" "port=${WEB_PORT}" || true
    save_guard
    os::ok '面板已启用'
    print_access
    offer_caddy_import "${snippet_changed}"
    offer_firewall_allow
    return 0
}

# 门的选择进 state：下次 enable 拿它当默认值，而 do_status 拿它决定
# 概览上那几行访问信息怎么写（有没有密码、从哪儿能打开）
save_guard() {
    os::state_set "${COMPONENT}" "auth=${GUARD_AUTH}" || true
    os::state_set "${COMPONENT}" "from=${GUARD_FROM}" || true
    return 0
}

# 关掉面板之后，主 Caddyfile 里那行 import 就指向一个空目录了。问一句要不要
# 一并去掉，**默认否**：那是用户的主配置，而 §12「永不自动删除用户配置」；
# 何况他可能只是想临时停掉面板，过两天再 enable 回来。
#
# **incoming/ 里还有别的片段就不问。** 那一行 import 管的是整个目录，不是面板
# 专属；用户自己往里放过东西的话，去掉它会连那些一起打掉 —— 那就成了「关个面板
# 顺手废了别的站点」。这一步排在片段删除之后，所以「还剩几个」是真实剩余数。
drop_caddy_import() {
    [[ -f ${CADDYFILE} ]] || return 0
    os::query --timeout 5 -- grep -qE "${CADDY_IMPORT_RE}" "${CADDYFILE}" || return 0

    os::query --timeout 5 -- find "${CADDY_INBOX}" -maxdepth 1 -name '*.caddy' -print -quit || true
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        os::info "${CADDYFILE} 里的 import 留着没动 —— ${CADDY_INBOX}/ 下还有别的片段在用它"
        return 0
    fi

    os::warn "${CADDY_INBOX}/ 已经空了，而 ${CADDYFILE} 里还留着一行 ${CADDY_IMPORT_LINE}"
    os::confirm --arg caddy-unimport '把这一行也从 Caddyfile 去掉？' n || {
        os::info "留着了。要自己去掉就删 ${CADDYFILE} 里的这一行，然后 oneserver caddy reload"
        return 0
    }

    # 先在临时副本上删，校验过了才换主配置 —— 同 offer_caddy_import 的方向，
    # 只是反着来。框架的替换接口只会替换或追加，删一行得自己滤
    local dir candidate line
    local -a keep=()
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    candidate="${dir}/Caddyfile.no-import"
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} =~ ${CADDY_IMPORT_RE} ]] && continue
        keep+=("${line}")
    done <"${CADDYFILE}"
    printf '%s\n' ${keep[@]+"${keep[@]}"} >"${candidate}"

    validate_caddyfile "${candidate}" || {
        os::err '去掉 import 之后的 Caddyfile 没通过校验，主配置一个字都没动'
        os::info "${OS_RUN_OUTPUT}"
        return 1
    }

    os::record_change "从 ${CADDYFILE} 去掉了面板片段的 import"
    os::install_file --backup --mode 0640 "${candidate}" "${CADDYFILE}" \
        || os::die 1 "写入 ${CADDYFILE} 失败"
    os::run '设置 Caddyfile 属主' -- chown root:caddy "${CADDYFILE}"
    fix_caddy_log_owner
    os::systemd_reload "${CADDY_UNIT}" \
        || os::die 1 "${CADDYFILE} 已更新，但热重载失败；服务仍在运行旧配置"
    os::ok "已从 ${CADDYFILE} 去掉 import 并热重载"
    return 0
}

do_disable() {
    local u
    for u in "${WEB_UNITS[@]}"; do
        os::systemd_remove "own:${u}" || true
    done
    os::systemd_remove 'own:oneserver-web-live.service' || true
    os::systemd_remove 'own:oneserver-web-fast.service' || true
    os::systemd_remove 'own:oneserver-web-slow.service' || true

    local f
    for f in "${WEB_FILES[@]}"; do
        [[ -e "${OS_PUBLIC_DIR}/${f}" ]] || continue
        os::run '移除面板数据文件' -- rm -f -- "${OS_PUBLIC_DIR}/${f}" || true
    done
    if [[ -e ${CADDY_SNIPPET} ]]; then
        os::run '移除 Caddy 片段' -- rm -f -- "${CADDY_SNIPPET}" || true
    fi
    drop_caddy_import
    revoke_firewall

    os::secure_del "${WEB_AUTH_KEY}" || true
    os::secure_del 'web.telegram_token' || true
    os::secure_del 'web.telegram_chat_id' || true
    os::state_del "${COMPONENT}" || true
    os::ok '面板已关闭'
    return 0
}

# 怎么打开面板 —— **概览里也要有**，不只在 enable 的输出里。
#
# 从前这几行只在 enable 那一次打出来，随后被菜单刷掉。真正需要它的时刻是
# 「下次想登录」，那时它早已不在屏幕上，而没人会为了看一眼地址再 enable 一遍。
#
# 门的形态从 state 读，不从片段里猜：概览每进一次菜单就跑一遍，去 grep
# 一份 Caddy 配置来反推「有没有密码」既慢又脆。
print_access() {
    if [[ ! -f ${CADDY_SNIPPET} ]]; then
        os::kv '数据目录' "${OS_PUBLIC_DIR}"
        os::box '如何查看（未装 Caddy）' -- \
            '页面与数据已就位，但这台机器上没有 HTTP 服务' \
            "取回：scp -r <这台机器>:${OS_PUBLIC_DIR} ./os-panel" \
            '本地起任意静态服务再打开 dashboard.html' \
            '直接双击打不开：浏览器不允许 file:// 页面读同目录的数据文件'
        return 0
    fi

    local auth from
    auth=$(os::state_get "${COMPONENT}" auth 'yes')
    from=$(os::state_get "${COMPONENT}" from '')

    if [[ ${auth} == no && -z ${from} ]]; then
        os::kv '访问地址' "http://127.0.0.1:${WEB_PORT}"
        os::kv '登录' '不设密码 · 监听收窄到本机，外面打不开（要远程就开 SSH 隧道）'
        # 只走回环，明文那句在这里不成立，说了反而是噪声
        return 0
    fi

    os::kv '访问地址' "http://<这台机器的地址>:${WEB_PORT}"
    if [[ ${auth} == no ]]; then
        os::kv '登录' "不设密码 · 只有 ${from} 能打开，其余来源一律 403"
    else
        os::kv '登录' '用户名 admin · 取密码：oneserver secure get web.basic_auth'
    fi
    # **不用 warn 样式**：它消不掉，而概览里一条永远亮着的黄色叹号会把真正
    # 需要处理的那些一起拉低成背景噪声
    os::info "面板走 HTTP 明文，密码与页面内容在链路上可见 —— 经 HTTPS 反代访问，别直接把 ${WEB_PORT} 暴露到公网"
    return 0
}

# 离线报告 —— 把当前数据内嵌进页面，生成一个自包含的 HTML
#
# 用途：没装 Caddy（或不想开 HTTP）的机器上，scp 走这**一个文件**双击就能看。
# 在线模式下页面 fetch 同目录的数据文件，而浏览器不允许 file:// 页面读同目录
# 文件 —— 所以直接把数据目录拷回本地双击页面是打不开的，必须内嵌。
#
# 转义只做两步、且顺序不能反：先 `&` 后 `<`。反过来的话第一步产生的
# `&lt;` 会被第二步的 `&` 替换二次编码成 `&amp;lt;`，页面上就会显示出实体源码。
do_report() {
    local out="${OS_PUBLIC_DIR}/report.html"
    local html src
    # 走 page_source：在线页面认 /etc 覆盖而报告不认的话，同一台机器上两份
    # 页面长得不一样
    src=$(page_source)
    html=$(<"${src}") || os::die 1 "读不到面板模板：${src}"

    local blocks='' f body
    for f in "${WEB_FILES[@]}"; do
        [[ ${f} == report.html ]] && continue
        [[ -r "${OS_PUBLIC_DIR}/${f}" ]] || continue
        body=$(<"${OS_PUBLIC_DIR}/${f}") || body=''
        body=${body//&/&amp;}
        body=${body//</&lt;}
        blocks+="<script type=\"text/plain\" data-file=\"${f}\">${body}</script>"$'\n'
    done

    if [[ -z ${blocks} ]]; then
        os::die 1 '还没有采集数据，先运行 oneserver web --action=refresh'
    fi

    # **插在主脚本之前，不是 </body> 之前**：HTML 是流式解析的，主脚本执行时
    # 排在它后面的 <script type="text/plain"> 还没进 DOM，querySelectorAll
    # 一个都找不到 —— 现场表现是报告页悄悄回退成在线模式，双击打开时
    # 因为 fetch 不到同目录文件而整页空白。
    os::write_public 'report.html' "${html/<script>/${blocks}<script>}" || return 1
    os::ok '离线报告已生成'
    os::kv '文件' "${out}"
    os::box '怎么看' -- \
        "取回：scp <这台机器>:${out} ." \
        '双击打开即可，不需要任何服务' \
        '注意：里面的数据是生成那一刻的快照，不会自动更新'
    return 0
}

do_status() {
    # **先答「这功能开没开」，再谈别的。** 采集产物（那十几份 .tsv）是面板的
    # 内部数据，没启用时全部缺失是必然结果 —— 把它们逐个当告警摊在屏幕上，
    # 用户读到的是「一堆看不懂的东西坏了」，而真相只有一句「面板还没开」。
    local -i enabled=0
    probe::unit_exists "${WEB_UNITS[0]}"
    [[ ${OS_PROBE_VALUE} == yes ]] && enabled=1

    if ((enabled == 0)); then
        os::kv '面板' '未启用'
        os::info "启用后在本机 ${WEB_PORT} 端口提供一个只读页面：组件、服务、端口、防火墙、日志一屏看完，页面不做任何变更"
        return 0
    fi

    # 访问信息排在最前：这一屏里被读得最多的就是它，而下面那些 timer / 采集
    # 状态是「出事时才看」的东西
    print_access

    local u
    for u in "${WEB_UNITS[@]}"; do
        probe::service_enabled "${u}"
        local en=${OS_PROBE_VALUE}
        probe::service_active "${u}"
        local act=${OS_PROBE_VALUE}
        probe::timer_next "${u}"
        os::kv "${u}" "${en} / ${act}${OS_PROBE_VALUE:+ · 下次 ${OS_PROBE_VALUE}}"
    done

    # 页面由 Caddy 直接从模板目录读。存在不等于 Caddy 读得到：更新曾把
    # templates/ 落成 0750，页面在、HTTP 却只回空 403。状态页必须以服务身份
    # 验读，不能继续报一个与真实访问相反的「已就位」。
    local page
    page=$(page_source)
    if [[ ! -f ${page} ]]; then
        os::warn '面板页面模板缺失，跑 oneserver web --action=enable 重建'
    elif command -v runuser >/dev/null 2>&1 && id caddy >/dev/null 2>&1 \
        && ! os::query -- runuser -u caddy -- test -r "${page}"; then
        os::warn "面板页面存在，但 Caddy 用户读不到：${page}"
        os::info '运行 oneserver web enable 会校正分发模板权限；用户覆盖目录不会被自动放宽'
    else
        os::kv '面板页面' '已就位 · Caddy 可读'
    fi

    # 采集产物分两问：**齐不齐**查全部，**新不新鲜**只看两份档位快照。
    #
    # `os::write_public` 内容没变就不重写（避免换 inode 让正在读的客户端拿到
    # 半截），所以别的产物 mtime 停在「内容上次变化」那一刻 —— 防火墙规则、
    # 告警、组件清单在一台稳定运行的机器上可以几天不动，拿 mtime 判它们就是
    # 天天误报「采集器没在跑」，而且刷新多少遍也消不掉。两份快照首行是
    # `#ts <epoch>`，每轮必变，才是「采集器还活着」的唯一可信信号。
    #
    local f
    local -i total=0
    local -a missing=()
    for f in "${WEB_FILES[@]}"; do
        case ${f} in
            report.html) continue ;;
        esac
        total+=1
        [[ -f "${OS_PUBLIC_DIR}/${f}" ]] || missing+=("${f}")
    done

    # 阈值取采集周期的 3 倍：偶尔错过一轮是正常的，连着错过三轮才说明 timer
    # 或采集本身出了问题
    local spec name limit label mtime now age fresh='' lag=''
    printf -v now '%(%s)T' -1
    for spec in 'probe-live.tsv 30 实时档' 'probe-fast.tsv 90 快档' 'probe-slow.tsv 900 慢档'; do
        IFS=' ' read -r name limit label <<<"${spec}"
        [[ -f "${OS_PUBLIC_DIR}/${name}" ]] || continue
        # 走 os::query 而不是裸 stat：规范要求只读查询经带超时的通道。
        # 这几个文件都在 tmpfs 上，默认的 probe 超时绰绰有余
        mtime=0
        os::query -- stat -c %Y -- "${OS_PUBLIC_DIR}/${name}" && mtime=${OS_RUN_OUTPUT}
        [[ ${mtime} =~ ^[0-9]+$ ]] || mtime=0
        age=$((now - mtime))
        if ((age > limit)); then
            lag+="${lag:+，}${label} ${age} 秒前（上限 ${limit} 秒）"
        else
            fresh+="${fresh:+ · }${label} ${age} 秒前"
        fi
    done

    if ((${#missing[@]} > 0)); then
        os::warn "${total} 份采集数据缺了 ${#missing[@]} 份，跑「刷新面板数据」补齐"
        for f in "${missing[@]}"; do
            os::info "    ${f}"
        done
    fi
    if [[ -n ${lag} ]]; then
        os::warn "采集器可能没在跑：${lag}"
    elif ((${#missing[@]} == 0)); then
        os::kv '采集数据' "${total} 份都在 · ${fresh}"
    fi

    if [[ -f ${CADDY_SNIPPET} ]]; then
        os::kv 'Caddy 片段' "${CADDY_SNIPPET}"
    fi
    return 0
}

# 告警**由面板的定时采集驱动**：web_notify.sh 挂在 oneserver-web-fast.service
# 的 ExecStartPost 上，读的是 web_collect 生成的 alerts.tsv。面板没启用时这条
# 链一次都不会跑 —— 配好令牌却收不到任何消息，而屏幕上刚打过一个 ✓。
# 所以这里必须当场把话说清，不能等用户过几天来问「为什么没告警」
do_telegram() {
    local token='' chat=''
    os::require_cmd curl
    os::ask_secret '请输入 Telegram Bot Token' token
    os::ask --match '^-?[0-9]+$' --hint 'Telegram 数字 chat ID' --arg telegram-chat-id \
        '请输入 Telegram chat ID' chat
    os::secure_set 'web.telegram_token' "${token}" || os::die 1 '保存 Telegram Token 失败'
    # chat ID 是个数字标识，不是秘密。放凭据库只为跟 token 共用命名空间与 0600，
    # 所以显式声明 --not-secret：既不受最短长度门槛约束，也不进脱敏表
    # （纯数字进脱敏表会把日志里凑巧相同的数字一起打成 ***）
    os::secure_set --not-secret 'web.telegram_chat_id' "${chat}" || os::die 1 '保存 Telegram chat ID 失败'
    os::ok 'Telegram 通知已配置；首次采集只建立基线，之后新增告警与恢复才会发送'

    # 判据是 fast 那个 timer：web_notify 挂在它的 service 上，slow 那条不发通知
    probe::service_active "${WEB_UNITS[0]}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::warn "${WEB_UNITS[0]} 没在跑，告警不会被触发 —— 先选「启用面板」"
    fi
    return 0
}

do_refresh() {
    os::run '刷新面板数据' -- \
        "${OS_SCRIPT_DIR}/ops/web_collect.sh" --tier=all --non-interactive \
        || os::die 1 '刷新面板数据失败'
    os::ok '面板数据已刷新'
}

dispatch() {
    case ${1} in
        status) do_status ;;
        enable) do_enable ;;
        disable) do_disable ;;
        report) do_report ;;
        telegram) do_telegram ;;
        refresh) do_refresh ;;
        *) os::die 2 "未知操作「${1}」，可用：status enable disable report telegram refresh" ;;
    esac
}

main() {
    # 告警排在启停之后、离线报告之前：它是这一屏里第二常用的东西（配一次，
    # 之后出事全靠它），从前排在第四位，用户得先扫过两个不相干的选项才看到
    os::action_menu --overview do_status --arg action '操作' dispatch \
        'enable=启用面板' 'disable=关闭面板' \
        'telegram=配置 Telegram 告警通知' \
        'refresh=刷新面板数据' 'report=生成离线报告'
}

main "$@"
