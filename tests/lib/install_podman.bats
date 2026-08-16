#!/usr/bin/env bats
# install_podman.sh 的组件级平台门槛。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    STUB="${BATS_TEST_TMPDIR}/install-podman-stub.sh"
    # 剥掉绝对 bootstrap 装配与 main，只加载本脚本定义的判定函数。
    sed -e '/^source \/opt\/oneserver\/lib\/bootstrap\.sh$/d' -e '$d' \
        "${OS_TEST_REPO_ROOT}/script/install/install_podman.sh" >"${STUB}"
}

podman_gate_run() {
    run bash -c "
        source '${OS_TEST_REPO_ROOT}/lib/bootstrap.sh'
        source '${STUB}'
        $1
    "
}

@test "Podman 发行版门槛是 Debian 13 与 Ubuntu 24.04" {
    podman_gate_run '
        podman_platform_supported debian 13
        podman_platform_supported debian 14
        podman_platform_supported ubuntu 24.04
        podman_platform_supported ubuntu 26.04
        ! podman_platform_supported debian 12
        ! podman_platform_supported ubuntu 22.04
        ! podman_platform_supported ubuntu ""
    '
    [ "${status}" -eq 0 ]
}

@test "Ubuntu 22.04 在提问前以 4 拒绝并解释 Quadlet、建议 Docker" {
    podman_gate_run '
        probe::os_id() { OS_PROBE_VALUE=ubuntu; }
        probe::os_version() { OS_PROBE_VALUE=22.04; }
        podman_source_candidate() { printf -v "${1}" "%s" ""; }
        podman_platform_preflight
    '
    [ "${status}" -eq 4 ]
    [[ "${output}" == *'Quadlet'* ]]
    [[ "${output}" == *'oneserver install docker'* ]]
}
