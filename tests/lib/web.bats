#!/usr/bin/env bats
#
# Web 面板的两道真实边界：Caddy 必须读得到页面，访问控制必须先于静态文件。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    WEB="${OS_TEST_REPO_ROOT}/script/ops/web.sh"
    TEMPLATE="${OS_TEST_REPO_ROOT}/templates/caddy-dashboard.conf"
}

@test "Caddy 模板：来源限制位于保序 route 内并先于两个 file_server" {
    local route guard first_handle route_end
    route=$(grep -n $'^\troute {$' "${TEMPLATE}" | cut -d: -f1)
    guard=$(grep -n '^%%GUARD%%$' "${TEMPLATE}" | cut -d: -f1)
    first_handle=$(grep -n $'^\t\thandle / {$' "${TEMPLATE}" | cut -d: -f1)
    route_end=$(grep -n $'^\t}$' "${TEMPLATE}" | tail -n 1 | cut -d: -f1)

    [ -n "${route}" ]
    [ "${route}" -lt "${guard}" ]
    [ "${guard}" -lt "${first_handle}" ]
    [ "${first_handle}" -lt "${route_end}" ]
}

@test "面板状态：不再只用文件存在判断页面已就位" {
    grep -Fq 'runuser -u caddy -- test -r "${page}"' "${WEB}"
    grep -Fq '面板页面存在，但 Caddy 用户读不到' "${WEB}"
    grep -Fq "面板页面' '已就位 · Caddy 可读" "${WEB}"
}
