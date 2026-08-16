# lib/firewall.sh —— L3 能力层：UFW 放行规则的判定与落地
#
# 只依赖 L0–L2（用 exec.sh 的 os::run 执行 ufw）。**不依赖同层的 probe.sh**：
# 规则文本由调用方先 `probe::ufw_rules` 取好再传进来（§11 里系统事实的唯一
# 入口仍是 probe），这个文件只负责「这条规则在不在里面」与「把它加进去」。
#
# --- 这个文件存在的理由 ---
#
# 「UFW 开着但端口没放行」这件事有四个现场：面板端口（web.sh）、Valkey 与
# MariaDB 的容器网段（valkey_manager.sh / db_manager.sh）各写了一份完整的
# 判定 + 放行 + reload，形状逐行相同；Caddy 的 80/443 则只有一句提示。
#
# **判定那一步的正则最容易写错，而且错了不报错**：web.sh 真机上撞到过一次，
# 正则少一个结尾锚点，一条 `8730/udp` 被读成「TCP 已放行」，于是放行提示再也
# 不出现而面板永远打不开；Caddy 那句提示更松，用的是 `*'443'*` 子串匹配，
# 规则里任何一处 443（`18443`、`4430`）都能让它以为放行过了。
# 一份判定四种写法，就有四种错法。
#
# **交互与措辞不在这里**：问不问、怎么问、拒绝之后说什么，是脚本层的事
# （§9 的交互完备性要求每个问句配一个 `--arg`，而参数名属于那条命令）。
# 这个文件只到「判定 + 执行」为止，不打印任何面向用户的消息。

# ufw 的输出措辞随 locale 变，而放行判定是**按文本认**的：中文 locale 下
# `ALLOW IN` 会变成别的字，正则当场失配 —— 表现是每次都以为没放行过，
# 于是重复 allow（幂等还在，只是白跑一趟并多记一条变更）。
OS_FIREWALL__ENV='LC_ALL=C'

firewall::_check_proto() {
    case ${1-} in
        tcp | udp) return 0 ;;
        *)
            ui::line error "放行协议只能是 tcp 或 udp，收到「${1-}」"
            return 2
            ;;
    esac
}

# 端口要能安全地进正则，也要能原样交给 ufw。**误传 `80/tcp` 这种带协议的写法
# 必须当场拒绝**：它进了正则不会报错，只会让判定永远匹配不上 —— 而这个模块
# 的全部风险就是「判错了不报错」。范围写法（`8000:9000`）ufw 认，一并放行。
firewall::_check_port() {
    [[ ${1-} =~ ^[0-9]+(:[0-9]+)?$ ]] && return 0
    ui::line error "端口只能是数字或 a:b 形式的范围，收到「${1-}」"
    return 2
}

# os::ufw_allowed <规则文本> <端口> <协议> [来源]   这条放行在不在规则里
#
# 规则文本取自 `probe::ufw_rules`，每行形如 `[ 1] 8730/tcp   ALLOW IN  Anywhere`。
#
# **调用方必须先确认防火墙是启用的。** `ufw status` 在未启用时只打一行
# `Status: inactive` —— 规则一条都读不出来，而它们全都还在 /etc/ufw 里。
# 拿那份空文本进来，这里会把**每一条**都判成「没放行」，且没有任何迹象表明
# 判定依据是空的。四个调用点里有两处的预览表曾经排在状态门控之前，于是
# 停用态下整张表把已放行的网段全标成「本次新增」。
#
# 判定本身不接管这个前提：它不依赖 probe（见文件头的分层约束），也就无从
# 知道传进来的文本为什么是空的。要在两种状态下都读得到规则，
# 用 `probe::ufw_added_rules`（`ufw show added`）—— 但那份文本没有序号、
# 格式也不同，这里的正则不认，需要另写判定。
#
# **按序号加端口认，不做子串匹配**：`*8730*` 会被 18730 或某条注释蒙混过去。
#
# **协议后面那个锚点不能省。** 少了它 `(/tcp)?` 匹配空串也算数，于是一条
# `8730/udp` 的规则会被读成「TCP 已放行」。反过来，`ufw allow 443`（不带协议）
# 生成的规则行就是 `443`，它同时覆盖 tcp 与 udp —— 所以协议那一段是可选的，
# 判 udp 时 `443` 与 `443/udp` 都算放行过，`443/tcp` 不算。
#
# **来源为空时只认端口与动作**，不看 `ALLOW IN` 再后面那一列是什么：调用方问的是
# 「这个端口通不通」，一条限了网段的规则也让它通（只是通的范围窄），再放行一条
# Anywhere 才是真正的放宽，那必须由调用方自己决定，不能被这里判成「已放行」。
#
# **动作那一段不能省。** 从前来源为空的分支匹配到端口后面的空白就收尾了，
# 于是 `DENY IN`、`REJECT IN`、`ALLOW OUT`、`ALLOW FWD` 一律被读成「已放行」——
# 方向正好反了：一条明确拦截的规则会让调用方以为端口通着，于是跳过放行、
# 也不提示，而这个模块的全部风险就是「判错了不报错」。web.sh 与 install_caddy
# 传的正是空来源，撞上一条 DENY 就是「面板打不开、屏幕上一句话都没有」。
#
# `LIMIT` 与 `ALLOW` 一并认：`ufw limit 22/tcp` 是放行加限速，规则行里写作
# `LIMIT IN`，把它判成没放行会让调用方重复放行一条 Anywhere，反倒把限速绕开。
os::ufw_allowed() {
    local rules=${1-} port=${2-} proto=${3-} from=${4-}
    firewall::_check_proto "${proto}" || return 2
    firewall::_check_port "${port}" || return 2

    # 来源里的 `.` 在正则里是通配符：`10.88.0.0/16` 不转义的话，
    # `10x88y0z0/16` 这种不存在的来源也会被判成匹配
    local want=${from//./\\.}
    local line
    while IFS= read -r line; do
        if [[ -z ${from} ]]; then
            [[ ${line} =~ ^\[[[:space:]]*[0-9]+\][[:space:]]+${port}(/${proto})?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN([[:space:]]|$) ]] \
                && return 0
        else
            [[ ${line} =~ ^\[[[:space:]]*[0-9]+\][[:space:]]+${port}(/${proto})?[[:space:]]+(ALLOW|LIMIT)[[:space:]]+IN[[:space:]]+${want}([[:space:]]|$) ]] \
                && return 0
        fi
    done <<<"${rules}"
    return 1
}

# os::ufw_allow <端口> <协议> [来源]   放行一条规则
#
# **不 reload**：调用方通常要放行一批（几个网段、80 与 443），reload 一次就够，
# 每条都 reload 是把一次重载放大成 N 次。放完调用 os::ufw_reload。
#
# **不判幂等**：判定要规则文本，取文本是 probe 的事（见文件头）。调用方先用
# os::ufw_allowed 过一遍，跳过已经在里面的 —— 重复 allow 对 ufw 无害，但会
# 在变更清单里多记一条「放行了 X」，而那条清单是用户排查时的依据。
#
# **不注册回滚**：撤销一条放行是在失败路径上收紧，本身不危险；但这个文件不
# 知道那条规则是不是本次新增的（判幂等在调用方那边），删掉一条用户早就有的
# 规则比留下一条多余的放行严重得多。要回滚的调用方自己 os::defer。
os::ufw_allow() {
    local port=${1-} proto=${2-} from=${3-}
    firewall::_check_proto "${proto}" || return 2
    firewall::_check_port "${port}" || return 2

    local -a args=()
    local scope
    if [[ -n ${from} ]]; then
        args=(from "${from}" to any port "${port}" proto "${proto}")
        scope=${from}
    else
        args=("${port}/${proto}")
        scope='所有来源'
    fi

    os::record_change "在 UFW 里放行 ${port}/${proto}，来源 ${scope}"
    os::run --env "${OS_FIREWALL__ENV}" "放行 ${port}/${proto}" -- ufw allow "${args[@]}"
}

# os::ufw_reload   重载 UFW 使规则生效
#
# 规则写进配置就已经生效于**新连接**，reload 是为了让 ufw 把规则集重新编译到
# 内核链上；不 reload 的表现是「规则列表里有，实际不通」，而那一步没有任何
# 报错。放行之后必须跟一次。
os::ufw_reload() {
    os::run --env "${OS_FIREWALL__ENV}" '重载 UFW 使规则生效' -- ufw reload
}
