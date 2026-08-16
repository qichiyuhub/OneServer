#!/usr/bin/env bats
#
# lib/firewall.sh 的单元测试
#
# 重点全在 os::ufw_allowed 的正则上 —— 那是这个模块存在的理由：判定错了
# **不报错**，只是让「已经放行过了」或「还没放行」得出相反的结论，而两个方向
# 的后果都藏得很深（前者让放行提示永远不出现，后者让变更清单多出一条假记录）。
# 四个调用点从前各写一份，这里一次把边界压完。
#
# os::ufw_allow / os::ufw_reload 只验「拼出来的 ufw 命令对不对」和 dry-run 下
# 不落地：真去改这台机器的防火墙不是单元测试该做的事。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors firewall
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()
    OS_ERR__CHANGES=()
    log::init test
    os_test_no_tty
}

# `ufw status numbered` 的样子。真机上就是这个格式，缩进与列宽都照抄
RULES='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 8730/tcp                   ALLOW IN    Anywhere
[ 3] 3306/tcp                   ALLOW IN    10.88.0.0/16
[ 4] 53                         ALLOW IN    Anywhere'

# --- os::ufw_allowed：不限来源 ---

@test "认得出放行过的端口" {
    os::ufw_allowed "${RULES}" 8730 tcp
}

@test "没放行的端口返回 1" {
    run os::ufw_allowed "${RULES}" 9000 tcp
    [ "${status}" -eq 1 ]
}

@test "不做子串匹配：8730 放行了不等于 730 或 18730 放行了" {
    run os::ufw_allowed "${RULES}" 730 tcp
    [ "${status}" -eq 1 ]
    run os::ufw_allowed "${RULES}" 18730 tcp
    [ "${status}" -eq 1 ]
}

# 协议后面那个锚点：少了它 `(/tcp)?` 匹配空串也算数，于是一条 `8730/udp`
# 会被读成「TCP 已放行」。web.sh 真机上栽的就是这一下
@test "协议要对上：8730/tcp 不算 8730/udp 放行了" {
    run os::ufw_allowed "${RULES}" 8730 udp
    [ "${status}" -eq 1 ]
}

# 动作那一列。**从前来源为空的分支匹配到端口后面的空白就收尾**，于是下面
# 四种规则一律被读成「已放行」—— 方向正好反了：一条明确拦截的规则会让调用方
# 以为端口通着，跳过放行也不提示。web.sh 与 install_caddy 传的正是空来源。
ACTIONS='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 3306/tcp                   DENY IN     Anywhere
[ 2] 5432/tcp                   REJECT IN   Anywhere
[ 3] 8080/tcp                   ALLOW OUT   Anywhere
[ 4] 9000/tcp                   ALLOW FWD   10.88.0.0/16
[ 5] 22/tcp                     LIMIT IN    Anywhere'

@test "DENY IN 不是放行 —— 拦截规则被读成已放行，方向正好反了" {
    run os::ufw_allowed "${ACTIONS}" 3306 tcp
    [ "${status}" -eq 1 ]
}

@test "REJECT IN 不是放行" {
    run os::ufw_allowed "${ACTIONS}" 5432 tcp
    [ "${status}" -eq 1 ]
}

# 出站规则管的是本机往外连，跟「外面能不能连进来」无关
@test "ALLOW OUT 不是入站放行" {
    run os::ufw_allowed "${ACTIONS}" 8080 tcp
    [ "${status}" -eq 1 ]
}

# 转发规则走 FORWARD 链，管的是过路流量，不代表本机这个端口通
@test "ALLOW FWD 不是本机端口放行" {
    run os::ufw_allowed "${ACTIONS}" 9000 tcp
    [ "${status}" -eq 1 ]
}

# `ufw limit` 是放行加限速。判成没放行的话，调用方会再补一条 Anywhere，
# 反倒把限速绕过去了
@test "LIMIT IN 算放行" {
    os::ufw_allowed "${ACTIONS}" 22 tcp
}

# 限来源那条路同样要认 LIMIT
@test "限来源时 LIMIT IN 也算放行" {
    local rules='[ 1] 3306/tcp                   LIMIT IN    10.88.0.0/16'
    os::ufw_allowed "${rules}" 3306 tcp '10.88.0.0/16'
}

# `ufw allow 53`（不带协议）生成的规则行就是 `53`，它同时覆盖 tcp 与 udp
@test "不带协议的规则同时算 tcp 与 udp 放行了" {
    os::ufw_allowed "${RULES}" 53 tcp
    os::ufw_allowed "${RULES}" 53 udp
}

# --- os::ufw_allowed：带来源 ---

@test "带来源时按端口加来源认" {
    os::ufw_allowed "${RULES}" 3306 tcp '10.88.0.0/16'
}

@test "同端口不同来源不算放行过" {
    run os::ufw_allowed "${RULES}" 3306 tcp '10.89.0.0/16'
    [ "${status}" -eq 1 ]
}

# 来源里的 `.` 不转义的话它是正则通配符，`10x88y0z0/16` 也会被判成匹配
@test "来源里的点按字面量认，不当通配符" {
    run os::ufw_allowed "${RULES}" 3306 tcp '10x88y0z0/16'
    [ "${status}" -eq 1 ]
}

# 限了网段的规则也让这个端口通（只是通的范围窄）。把它判成「未放行」的话，
# 调用方会再放行一条 Anywhere —— 那是实打实的放宽，必须由调用方自己决定
@test "不限来源地问时，一条限了网段的规则也算这个端口通着" {
    os::ufw_allowed "${RULES}" 3306 tcp
}

@test "规则文本为空时一律返回 1" {
    run os::ufw_allowed '' 80 tcp
    [ "${status}" -eq 1 ]
}

# --- 参数校验 ---

@test "协议只收 tcp 与 udp，别的以 2 拒绝" {
    run os::ufw_allowed "${RULES}" 80 sctp
    [ "${status}" -eq 2 ]
    run os::ufw_allow 80 sctp
    [ "${status}" -eq 2 ]
}

@test "缺端口以 2 拒绝" {
    run os::ufw_allowed "${RULES}" '' tcp
    [ "${status}" -eq 2 ]
    run os::ufw_allow '' tcp
    [ "${status}" -eq 2 ]
}

# 端口位上误传 `80/tcp` 进了正则不会报错，只会永远匹配不上 —— 而「判错了
# 不报错」正是这个模块要防的那一类
@test "端口位上带协议的写法以 2 拒绝，不静默判成未放行" {
    run os::ufw_allowed "${RULES}" 80/tcp tcp
    [ "${status}" -eq 2 ]
    run os::ufw_allow 80/tcp tcp
    [ "${status}" -eq 2 ]
}

@test "端口范围写法照收" {
    OS_DRYRUN=1
    run os::ufw_allow 8000:9000 tcp
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ufw allow 8000:9000/tcp"* ]]
}

# --- os::ufw_allow：拼出来的命令 ---
#
# dry-run 下 os::run 只打印不执行，正好用来看它到底要跑什么

@test "不带来源时拼成 ufw allow <端口>/<协议>" {
    OS_DRYRUN=1
    run os::ufw_allow 443 udp
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ufw allow 443/udp"* ]]
}

@test "带来源时拼成 ufw allow from <来源> to any port <端口> proto <协议>" {
    OS_DRYRUN=1
    run os::ufw_allow 6379 tcp '10.88.0.0/16'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ufw allow from 10.88.0.0/16 to any port 6379 proto tcp"* ]]
}

@test "放行记进变更清单，来源写在里面" {
    OS_DRYRUN=1
    os::ufw_allow 6379 tcp '10.88.0.0/16'
    printf '%s\n' "${OS_ERR__CHANGES[@]}" | grep -q '放行 6379/tcp，来源 10.88.0.0/16'
}

@test "不带来源时变更清单写「所有来源」" {
    OS_DRYRUN=1
    os::ufw_allow 80 tcp
    printf '%s\n' "${OS_ERR__CHANGES[@]}" | grep -q '放行 80/tcp，来源 所有来源'
}

# 每条都 reload 会把一次重载放大成 N 次，所以 allow 自己不 reload
@test "allow 自己不 reload" {
    OS_DRYRUN=1
    run os::ufw_allow 80 tcp
    [[ "${output}" != *"ufw reload"* ]]
}

@test "reload 跑的就是 ufw reload" {
    OS_DRYRUN=1
    run os::ufw_reload
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ufw reload"* ]]
}
