#!/usr/bin/env bats
#
# lib/state.sh 的单元测试
#
# os::state_set 是 V2 点名的七个函数里最后一个。必测：
#   * 写入中途被 kill（模拟断电）后文件仍可读
#   * 并发写
#   * 单行损坏后其余可恢复

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors state
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    OS_STATE_FILE="${OS_STATE_DIR}/components.tsv"
    OS_STATE_BAK="${OS_STATE_FILE}.bak"
    log::init test
    os_test_no_tty
}

# --- 组件标识（D35）---

@test "id: 合法与非法" {
    os::state_id_valid 'caddy'
    os::state_id_valid 'php:8.3'
    os::state_id_valid 'wordpress:blog'
    ! os::state_id_valid 'PHP'
    ! os::state_id_valid 'php:'
    ! os::state_id_valid ':8.3'
    ! os::state_id_valid ''
}

@test "id: type 与 instance 拆分" {
    [ "$(os::state_type 'php:8.3')" = 'php' ]
    [ "$(os::state_instance 'php:8.3')" = '8.3' ]
    [ "$(os::state_type 'caddy')" = 'caddy' ]
    [ -z "$(os::state_instance 'caddy')" ]
}

# --- 基本读写 ---

@test "set/get: 写入后读出" {
    os::state_set 'redis' version=8.0.1 method=apt
    [ "$(os::state_get 'redis' version)" = '8.0.1' ]
    [ "$(os::state_get 'redis' method)" = 'apt' ]
}

@test "get: 不存在时返回默认值" {
    [ "$(os::state_get 'nope' version 'DEFAULT')" = 'DEFAULT' ]
    os::state_set 'redis' version=1
    [ "$(os::state_get 'redis' missing 'DEFAULT')" = 'DEFAULT' ]
}

@test "set: 覆盖同一个键不留旧值" {
    os::state_set 'redis' version=8.0.1
    os::state_set 'redis' version=8.0.2
    [ "$(os::state_get 'redis' version)" = '8.0.2' ]
    [ "$(grep -c $'^redis\tversion' "${OS_STATE_FILE}")" -eq 1 ]
}

@test "set: 首次登记自动写 installed_at" {
    os::state_set 'redis' version=8.0.1
    [ -n "$(os::state_get 'redis' installed_at)" ]
}

@test "del: 只删该组件，其他不动" {
    os::state_set 'redis' version=8.0.1
    os::state_set 'caddy' version=2.8.4
    os::state_del 'redis'
    [ -z "$(os::state_get 'redis' version)" ]
    [ "$(os::state_get 'caddy' version)" = '2.8.4' ]
}

# --- 多实例（D35）---

@test "多实例: 两个 PHP 版本互不覆盖" {
    os::state_set 'php:8.1' version=8.1.29 method=apt
    os::state_set 'php:8.3' version=8.3.14 method=apt
    [ "$(os::state_get 'php:8.1' version)" = '8.1.29' ]
    [ "$(os::state_get 'php:8.3' version)" = '8.3.14' ]
}

@test "多实例: list 按 type 过滤出全部实例" {
    os::state_set 'php:8.1' version=8.1.29
    os::state_set 'php:8.3' version=8.3.14
    os::state_set 'caddy' version=2.8.4
    run os::state_list php
    [ "${#lines[@]}" -eq 2 ]
    [[ "${output}" == *'php:8.1'* ]]
    [[ "${output}" == *'php:8.3'* ]]
    [[ "${output}" != *'caddy'* ]]
}

@test "多实例: 删掉一个实例不影响另一个" {
    os::state_set 'php:8.1' version=8.1.29
    os::state_set 'php:8.3' version=8.3.14
    os::state_del 'php:8.1'
    [ -z "$(os::state_get 'php:8.1' version)" ]
    [ "$(os::state_get 'php:8.3' version)" = '8.3.14' ]
}

# --- unit 归属（D36）---

@test "unit: 追加而不覆盖，且要求 own:/ext: 前缀" {
    os::state_set 'php:8.3' version=8.3.14
    os::state_unit_add 'php:8.3' 'ext:php8.3-fpm.service'
    os::state_unit_add 'php:8.3' 'own:oneserver-php-tune.timer'
    run os::state_units 'php:8.3'
    [ "${#lines[@]}" -eq 2 ]

    run os::state_unit_add 'php:8.3' 'php8.3-fpm.service'
    [ "${status}" -eq 2 ]
}

@test "unit: 重复登记不叠加" {
    os::state_unit_add 'redis' 'ext:redis-server.service'
    os::state_unit_add 'redis' 'ext:redis-server.service'
    run os::state_units 'redis'
    [ "${#lines[@]}" -eq 1 ]
}

# --- 值的转义 ---

@test "值里含制表符与换行不会撕开行式格式" {
    os::state_set 'redis' note="$(printf 'a\tb\nc')"
    # 三元组永远一行一条
    [ "$(grep -c $'^redis\t' "${OS_STATE_FILE}")" -eq 2 ]
    [ "$(os::state_get 'redis' note)" = "$(printf 'a\tb\nc')" ]
}

@test "值里含反斜杠的往返" {
    os::state_set 'redis' note='back\slash'
    [ "$(os::state_get 'redis' note)" = 'back\slash' ]
    os::state_set 'redis' note='\t'
    [ "$(os::state_get 'redis' note)" = '\t' ]
}

# --- 对抗性一：写入中途被 kill ---

@test "写入中途被 kill 后，文件仍是完整的旧版本" {
    os::state_set 'redis' version=8.0.1
    local before
    before=$(cat "${OS_STATE_FILE}")

    # 在真进程里写，写到一半打断
    local f="${BATS_TEST_TMPDIR}/killcase.sh"
    cat >"${f}" <<EOF
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/exec.sh"
source "${OS_TEST_REPO_ROOT}/lib/errors.sh"
source "${OS_TEST_REPO_ROOT}/lib/state.sh"
OS_LOG_DIR="${OS_LOG_DIR}"
OS_STATE_DIR="${OS_STATE_DIR}"
OS_STATE_FILE="${OS_STATE_FILE}"
OS_STATE_BAK="${OS_STATE_BAK}"
log::init kill
# 拦住 mv，让 .tmp 写好但永不就位 —— 正是断电最可能发生的那一刻
mv() { echo ready > "${BATS_TEST_TMPDIR}/at-mv"; sleep 30; }
os::state_set 'caddy' version=2.8.4
EOF
    bash "${f}" >/dev/null 2>&1 &
    local pid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        [ -f "${BATS_TEST_TMPDIR}/at-mv" ] && break
        sleep 0.1
    done
    kill -9 "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true

    # 原文件一字未动，仍然完整可读
    [ "$(cat "${OS_STATE_FILE}")" = "${before}" ]
    [ "$(os::state_get 'redis' version)" = '8.0.1' ]
}

# --- 对抗性二：单行损坏 ---

@test "单行损坏时其余记录仍可读" {
    os::state_set 'redis' version=8.0.1
    os::state_set 'caddy' version=2.8.4
    # 塞一行垃圾进去
    printf 'THIS IS NOT A VALID LINE\n' >>"${OS_STATE_FILE}"
    printf '\t\t\n' >>"${OS_STATE_FILE}"

    [ "$(os::state_get 'redis' version)" = '8.0.1' ]
    [ "$(os::state_get 'caddy' version)" = '2.8.4' ]
    run os::state_list
    [[ "${output}" == *'redis'* ]]
    [[ "${output}" == *'caddy'* ]]
    [[ "${output}" != *'THIS'* ]]
}

@test "重写时丢弃损坏的行并告警" {
    os::state_set 'redis' version=8.0.1
    printf 'BAD LINE\n' >>"${OS_STATE_FILE}"
    os::state_set 'caddy' version=2.8.4
    run grep -c 'BAD LINE' "${OS_STATE_FILE}"
    [ "${status}" -ne 0 ]
    grep -q '损坏的行' "${OS_LOG_MAIN}"
}

@test "主文件不可读时回退 .bak" {
    os::state_set 'redis' version=8.0.1
    os::state_set 'redis' version=8.0.2
    [ -f "${OS_STATE_BAK}" ]
    mv "${OS_STATE_FILE}" "${OS_STATE_FILE}.gone"
    # .bak 里是上一版
    [ "$(os::state_get 'redis' version)" = '8.0.1' ]
}

# --- 对抗性三：并发写 ---

@test "并发写：两个进程各写各的组件，都不丢" {
    local f="${BATS_TEST_TMPDIR}/concurrent.sh"
    cat >"${f}" <<EOF
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/exec.sh"
source "${OS_TEST_REPO_ROOT}/lib/errors.sh"
source "${OS_TEST_REPO_ROOT}/lib/lock.sh"
source "${OS_TEST_REPO_ROOT}/lib/state.sh"
OS_LOG_DIR="${OS_LOG_DIR}"
OS_STATE_DIR="${OS_STATE_DIR}"
OS_STATE_FILE="${OS_STATE_FILE}"
OS_STATE_BAK="${OS_STATE_BAK}"
OS_RUN_DIR="${BATS_TEST_TMPDIR}/run"
OS_LOCK_FILE="\${OS_RUN_DIR}/oneserver.lock"
log::init conc
# state 的并发安全由全局锁保证，不是靠 state.sh 自己
os::lock_acquire 20
os::state_set "\$1" version="\$2"
EOF
    bash "${f}" alpha 1.0 &
    local p1=$!
    bash "${f}" beta 2.0 &
    local p2=$!
    wait "${p1}" "${p2}" 2>/dev/null || true

    [ "$(os::state_get 'alpha' version)" = '1.0' ]
    [ "$(os::state_get 'beta' version)" = '2.0' ]
}

# --- 版本比较---

@test "version_cmp: 基本比较" {
    [ "$(os::version_cmp 1.0 1.0)" = '0' ]
    [ "$(os::version_cmp 1.1 1.0)" = '1' ]
    [ "$(os::version_cmp 1.0 1.1)" = '-1' ]
    [ "$(os::version_cmp 2.0 10.0)" = '-1' ]
    [ "$(os::version_cmp 8.3 8.3.1)" = '-1' ]
}

@test "version_cmp: 带发行版后缀" {
    [ "$(os::version_cmp '8.3.11-1ubuntu2' '8.3.11')" = '0' ]
    [ "$(os::version_cmp '1:11.4.2-1' '1:11.4.2')" = '0' ]
    [ "$(os::version_cmp '2.8.4' '2.10.0')" = '-1' ]
}

@test "version_cmp: 前导零不当八进制" {
    [ "$(os::version_cmp '1.08' '1.9')" = '-1' ]
    [ "$(os::version_cmp '1.08' '1.08')" = '0' ]
}

@test "version_cmp: 空与缺省" {
    [ "$(os::version_cmp '' '')" = '0' ]
    [ "$(os::version_cmp '1' '')" = '1' ]
}

# --- 权限与分层 ---

@test "权限: state 文件是 0640" {
    os::state_set 'redis' version=1
    [ "$(stat -c %a "${OS_STATE_FILE}")" = '640' ]
}

@test "state.sh 不 source，也不依赖同层模块" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/state.sh"
    [ "${status}" -ne 0 ]
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/state.sh' \
        | grep -nE '(os::secure_|os::sql_|os::systemd_|probe::)'"
    [ "${status}" -ne 0 ]
}

# --- 资源清单---

@test "resource_add: 五类资源都是多值键，追加不覆盖" {
    os::state_resource_add caddy pkg caddy
    os::state_resource_add caddy file /usr/bin/caddy.custom
    os::state_resource_add caddy file /etc/apt/sources.list.d/caddy-stable.list
    os::state_resource_add caddy divert /usr/bin/caddy
    os::state_resource_add caddy alt 'caddy:/usr/bin/caddy.custom'
    os::state_resource_add caddy alt 'caddy:/usr/bin/caddy.default'

    [ "$(os::state_resources caddy file | wc -l)" -eq 2 ]
    [ "$(os::state_resources caddy alt | wc -l)" -eq 2 ]
    [ "$(os::state_resources caddy pkg)" = 'caddy' ]
    [ "$(os::state_resources caddy divert)" = '/usr/bin/caddy' ]
}

@test "resource_add: 重复登记被吞掉（脚本可以无脑调用）" {
    os::state_resource_add caddy file /usr/bin/caddy.custom
    os::state_resource_add caddy file /usr/bin/caddy.custom
    os::state_resource_add caddy file /usr/bin/caddy.custom
    [ "$(os::state_resources caddy file | wc -l)" -eq 1 ]
}

@test "resource_add: 未知类型与空值都以退出码 2 拒绝" {
    run os::state_resource_add caddy nosuchkind /tmp/x
    [ "${status}" -eq 2 ]
    run os::state_resource_add caddy file ''
    [ "${status}" -eq 2 ]
}

@test "resource_add: 普通键仍然是覆盖语义，别被多值键带跑" {
    os::state_set caddy version=2.11.3
    os::state_set caddy version=2.11.4
    [ "$(os::state_get caddy version)" = '2.11.4' ]
    # 同时 unit 仍是多值
    os::state_unit_add caddy ext:caddy.service
    os::state_unit_add caddy own:oneserver-caddy.timer
    [ "$(os::state_units caddy | wc -l)" -eq 2 ]
}

# resource_del 的存在理由：装 Docker 要 purge 掉 podman 登记在自己名下的
# podman-docker。摘不掉的话 state 里留一条假事实，而它是卸载的唯一依据。
@test "resource_del: 只删指定的那一条，同键的其他值原样留着" {
    os::state_resource_add podman pkg podman
    os::state_resource_add podman pkg podman-compose
    os::state_resource_add podman pkg podman-docker

    os::state_resource_del podman pkg podman-docker
    [ "$(os::state_resources podman pkg | wc -l)" -eq 2 ]
    [ -z "$(os::state_resources podman pkg | grep -x podman-docker || true)" ]
    [ -n "$(os::state_resources podman pkg | grep -x podman || true)" ]
    [ -n "$(os::state_resources podman pkg | grep -x podman-compose || true)" ]
}

@test "resource_del: 不碰同组件的普通键与其他资源类型" {
    os::state_set podman version=5.4.1 method=apt
    os::state_resource_add podman pkg podman-docker
    os::state_resource_add podman file /etc/containers/nodocker
    os::state_unit_add podman ext:podman.socket

    os::state_resource_del podman pkg podman-docker
    [ "$(os::state_get podman version)" = '5.4.1' ]
    [ "$(os::state_get podman method)" = 'apt' ]
    [ "$(os::state_resources podman file)" = '/etc/containers/nodocker' ]
    [ "$(os::state_units podman)" = 'ext:podman.socket' ]
    [ -z "$(os::state_resources podman pkg)" ]
}

@test "resource_del: 不碰别的组件同名的资源" {
    os::state_resource_add podman pkg podman-docker
    os::state_resource_add docker pkg podman-docker
    os::state_resource_del podman pkg podman-docker
    [ -z "$(os::state_resources podman pkg)" ]
    [ "$(os::state_resources docker pkg)" = 'podman-docker' ]
}

@test "resource_del: 清单里没有它时是成功且零变更（幂等）" {
    os::state_resource_add podman pkg podman
    local before
    before=$(cat "${OS_STATE_FILE}")
    os::state_resource_del podman pkg podman-docker
    [ "$(cat "${OS_STATE_FILE}")" = "${before}" ]
}

@test "resource_del: 未知类型与空值都以退出码 2 拒绝" {
    run os::state_resource_del podman nosuchkind /tmp/x
    [ "${status}" -eq 2 ]
    run os::state_resource_del podman pkg ''
    [ "${status}" -eq 2 ]
}

@test "resource_add: 不同组件的清单互不干扰" {
    os::state_resource_add caddy pkg caddy
    os::state_resource_add 'php:8.3' pkg php8.3-fpm
    [ "$(os::state_resources caddy pkg)" = 'caddy' ]
    [ "$(os::state_resources 'php:8.3' pkg)" = 'php8.3-fpm' ]
    [ "$(os::state_resources caddy pkg | wc -l)" -eq 1 ]
}

# --- dry-run 零变更---

@test "dry-run: 不写 state 文件" {
    os::state_set demo version=1.0
    OS_DRYRUN=1
    run os::state_set demo version=9.9
    OS_DRYRUN=0
    [ "${status}" -eq 0 ]
    # state 是「已是目标状态吗」的判据来源，被预演改掉之后
    # 后续每一次幂等判断都会失准
    [ "$(os::state_get demo version)" = '1.0' ]
}

# --- 存在性判断 ---
#
# 卸载与「装过没有」两条路径都从它出发。它答错的后果不对称：
# 多答一个 yes 会让卸载去删一个不存在的东西，少答一个 yes 会让组件永远卸不掉。

@test "has: 登记过的答 yes，没登记的答 no" {
    os::state_set demo version '1.0'
    os::state_has demo
    run os::state_has 'never-registered'
    [ "${status}" -ne 0 ]
}

@test "has: 实例是身份 —— db:a 登记了不等于 db:b 也登记了" {
    os::state_set 'db:alpha' user 'alpha'
    os::state_has 'db:alpha'
    run os::state_has 'db:beta'
    [ "${status}" -ne 0 ]
    # 也不能拿 type 名当整个标识用
    run os::state_has 'db'
    [ "${status}" -ne 0 ]
}

@test "has: state 文件还不存在时答 no，而不是报错" {
    rm -f "${OS_STATE_FILE}"
    run os::state_has demo
    [ "${status}" -ne 0 ]
}

# 规范 §10「写文件前先判断内容是否变化」+ §3 不变量 6「第二次执行不产生任何
# 新变更」。不比对的话，一条已经幂等的命令第二次执行仍会换掉 state 的 inode
# 并轮转 .bak —— 而 .bak 本该是**上一版**，空转几次之后它只是当前版的副本，
# 真损坏时可回退的那一份就没了。
@test "state_set: 值没变时不换 inode、不轮转 .bak" {
    os::state_set 'php:8.3' version=8.3
    local ino_before bak_before
    ino_before=$(stat -c %i "${OS_STATE_FILE}")
    cp -a -- "${OS_STATE_FILE}" "${OS_STATE_BAK}"
    printf 'SENTINEL\n' >"${OS_STATE_BAK}"

    os::state_set 'php:8.3' version=8.3
    [ "$(stat -c %i "${OS_STATE_FILE}")" = "${ino_before}" ]
    # .bak 没被轮转掉，哨兵还在
    [ "$(cat "${OS_STATE_BAK}")" = 'SENTINEL' ]
    [ "$(os::state_get 'php:8.3' version)" = '8.3' ]
}

@test "state_set: 值真的变了仍然要写，且 .bak 存的是上一版" {
    os::state_set 'php:8.3' version=8.3
    os::state_set 'php:8.3' version=8.4
    [ "$(os::state_get 'php:8.3' version)" = '8.4' ]
    grep -q '8\.3' "${OS_STATE_BAK}"
}

# 规范 §12：「损坏时逐行恢复，整份不可读时回退备份，两者都坏进入降级模式
# 并明确告知卸载不可靠」。此前的判据只是「文件读得到」—— 被写坏的
# components.tsv 照样可读，逐行解析后全是坏行，得到一个空清单，而空清单跟
# 「还没装过任何组件」不可区分。实测后果：卸载说「没有登记任何资源」，
# 包、文件、unit 全部残留，而 .bak 里明明躺着完整清单。
@test "state 损坏：整份读不出有效记录时回退 .bak 并说出来" {
    os::state_set 'php:8.3' version=8.3
    cp -a -- "${OS_STATE_FILE}" "${OS_STATE_BAK}"
    printf '垃圾数据没有制表符
' >"${OS_STATE_FILE}"
    OS_STATE__SOURCE_DONE=0

    run os::state_list
    [[ "${output}" == *'php:8.3'* ]]
    [[ "${output}" == *'回退'* ]]
}

@test "state 损坏：主文件与备份都坏时明确告知卸载不可靠" {
    os::state_set 'php:8.3' version=8.3
    printf '坏
' >"${OS_STATE_FILE}"
    printf '也坏
' >"${OS_STATE_BAK}"
    OS_STATE__SOURCE_DONE=0

    run os::state_list
    [[ "${output}" == *'卸载会漏删资源'* ]]
}

@test "state 空文件是正常状态，不报损坏" {
    os::state_set 'php:8.3' version=8.3
    : >"${OS_STATE_FILE}"
    rm -f -- "${OS_STATE_BAK}"
    OS_STATE__SOURCE_DONE=0

    run os::state_list
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'不可信'* ]]
    [[ "${output}" != *'回退'* ]]
}

@test "state 删除最后一个组件后不从 .bak 复活它" {
    os::state_set 'php:8.3' version=8.3
    os::state_del 'php:8.3'

    [ ! -s "${OS_STATE_FILE}" ]
    grep -q 'php:8.3' "${OS_STATE_BAK}"
    run os::state_list
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'php:8.3'* ]]
    [[ "${output}" != *'回退'* ]]
}

@test "state 来源选择缓存在当前进程生效" {
    os::state_set 'php:8.3' version=8.3
    state::_source_file
    [ "${OS_STATE__SOURCE_DONE}" -eq 1 ]
    [ "${OS_STATE__SOURCE}" = "${OS_STATE_FILE}" ]

    printf '\u0001随后损坏\n' >"${OS_STATE_FILE}"
    state::_source_file
    [ "${OS_STATE__SOURCE}" = "${OS_STATE_FILE}" ]
}

@test "state_health 区分缺失、空、正常、回退与双损坏" {
    local health=''
    os::state_health health
    [ "${health}" = 'missing' ]

    mkdir -p "${OS_STATE_DIR}"
    : >"${OS_STATE_FILE}"
    OS_STATE__SOURCE_DONE=0
    os::state_health health
    [ "${health}" = 'empty' ]

    printf 'php:8.3\tversion\t8.3\n' >"${OS_STATE_FILE}"
    OS_STATE__SOURCE_DONE=0
    os::state_health health
    [ "${health}" = 'ok' ]

    cp -a -- "${OS_STATE_FILE}" "${OS_STATE_BAK}"
    printf '\u0001坏\n' >"${OS_STATE_FILE}"
    OS_STATE__SOURCE_DONE=0
    os::state_health health
    [ "${health}" = 'recovered' ]

    printf '\u0001也坏\n' >"${OS_STATE_BAK}"
    OS_STATE__SOURCE_DONE=0
    os::state_health health
    [ "${health}" = 'corrupt' ]
}

@test "state_health 拒绝非变量名输出参数" {
    run os::state_health 'arr[0]'
    [ "${status}" -eq 2 ]
}

@test "双损坏 state 拒绝普通写入且保留故障现场" {
    mkdir -p "${OS_STATE_DIR}"
    printf '\u0001主文件损坏\n' >"${OS_STATE_FILE}"
    printf '\u0002备份也损坏\n' >"${OS_STATE_BAK}"
    local main_before bak_before
    main_before=$(sha256sum "${OS_STATE_FILE}")
    bak_before=$(sha256sum "${OS_STATE_BAK}")

    run os::state_set caddy version=2.10
    [ "${status}" -eq 1 ]
    [ "$(sha256sum "${OS_STATE_FILE}")" = "${main_before}" ]
    [ "$(sha256sum "${OS_STATE_BAK}")" = "${bak_before}" ]
}

@test "从有效 bak 恢复写入时不拿损坏主文件覆盖 bak" {
    mkdir -p "${OS_STATE_DIR}"
    printf 'php:8.3\tversion\t8.3\n' >"${OS_STATE_BAK}"
    printf '\u0001主文件损坏\n' >"${OS_STATE_FILE}"
    local bak_before
    bak_before=$(sha256sum "${OS_STATE_BAK}")

    os::state_set caddy version=2.10
    [ "$(os::state_get 'php:8.3' version)" = '8.3' ]
    [ "$(os::state_get caddy version)" = '2.10' ]
    [ "$(sha256sum "${OS_STATE_BAK}")" = "${bak_before}" ]
}

# --- os::state_snapshot ---
#
# 它是 registry::requires_met 的取数通道，替掉的是「每个组件一次 os::state_list
# 加一次 os::state_get」那两个子 shell。**因此它必须与被替掉的两个接口逐位同义**：
# 顺序、去重、非法 id 过滤跟 os::state_list，取哪一条 version 跟 os::state_get。
# 差一点点的后果不是慢，是菜单把某条命令藏了或者多显示了。

@test "snapshot: id 的顺序、去重与非法过滤同 os::state_list" {
    os::state_set caddy version=2.10
    os::state_set 'php:8.3' version=8.3.11
    os::state_set 'php:8.1' version=8.1.2
    # 非法 id 与空行直接塞进文件：os::state_set 写不出这种行
    printf 'PHP\tversion\t9\n:8.3\tversion\t9\n\n' >>"${OS_STATE_FILE}"

    os::state_snapshot
    local ids='' one
    for one in "${OS_STATE_SNAP_IDS[@]}"; do ids+="${one},"; done
    local listed=''
    while IFS= read -r one; do listed+="${one},"; done < <(os::state_list)
    [ "${ids}" = "${listed}" ]
    [ "${ids}" = 'caddy,php:8.3,php:8.1,' ]
}

@test "snapshot: 版本与 os::state_get 一致，含转义值的解码" {
    os::state_set caddy version=2.10
    os::state_set 'php:8.3' version=8.3.11
    os::state_set weird version="$(printf 'a\tb')"

    os::state_snapshot
    local -i i
    for ((i = 0; i < ${#OS_STATE_SNAP_IDS[@]}; i++)); do
        [ "${OS_STATE_SNAP_VERSIONS[i]}" = "$(os::state_get "${OS_STATE_SNAP_IDS[i]}" version)" ]
    done
}

@test "snapshot: 有 id 没有 version 行时保留 id、版本为空" {
    os::state_set caddy method=apt
    os::state_snapshot
    [ "${#OS_STATE_SNAP_IDS[@]}" -eq 1 ]
    [ "${OS_STATE_SNAP_IDS[0]}" = 'caddy' ]
    [ -z "${OS_STATE_SNAP_VERSIONS[0]}" ]
}

@test "snapshot: 同一 id 多条 version 行取第一条，同 os::state_get" {
    mkdir -p "${OS_STATE_DIR}"
    printf 'caddy\tversion\t2.10\ncaddy\tversion\t9.99\n' >"${OS_STATE_FILE}"
    os::state_snapshot
    [ "${OS_STATE_SNAP_VERSIONS[0]}" = '2.10' ]
    [ "${OS_STATE_SNAP_VERSIONS[0]}" = "$(os::state_get caddy version)" ]
}

@test "snapshot: state 文件不存在或为空时是空数组，不报错" {
    os::state_snapshot
    [ "${#OS_STATE_SNAP_IDS[@]}" -eq 0 ]
    [ "${#OS_STATE_SNAP_VERSIONS[@]}" -eq 0 ]

    mkdir -p "${OS_STATE_DIR}"
    : >"${OS_STATE_FILE}"
    os::state_snapshot
    [ "${#OS_STATE_SNAP_IDS[@]}" -eq 0 ]
}

@test "snapshot: 主文件损坏时回退 .bak，同其余读接口" {
    mkdir -p "${OS_STATE_DIR}"
    printf 'php:8.3\tversion\t8.3\n' >"${OS_STATE_BAK}"
    printf '\u0001主文件损坏\n' >"${OS_STATE_FILE}"
    os::state_snapshot
    [ "${OS_STATE_SNAP_IDS[0]}" = 'php:8.3' ]
    [ "${OS_STATE_SNAP_VERSIONS[0]}" = '8.3' ]
}

# 这一条是本接口的核心契约，改动时最先会被牺牲掉的也是它：
# 一旦有人为了再快一点加上跨调用缓存，同一个进程里 install / uninstall 之后的
# 判定就会用上写入前的答案 —— 刚装完的组件在菜单里不出现，且不报错。
@test "snapshot: 每次调用重读文件，不跨调用缓存" {
    os::state_set caddy version=2.6.4
    os::state_snapshot
    [ "${OS_STATE_SNAP_VERSIONS[0]}" = '2.6.4' ]

    os::state_set caddy version=2.8.0
    os::state_snapshot
    [ "${OS_STATE_SNAP_VERSIONS[0]}" = '2.8.0' ]

    os::state_set valkey version=8.0.1
    os::state_snapshot
    [ "${#OS_STATE_SNAP_IDS[@]}" -eq 2 ]

    os::state_del caddy
    os::state_snapshot
    [ "${#OS_STATE_SNAP_IDS[@]}" -eq 1 ]
    [ "${OS_STATE_SNAP_IDS[0]}" = 'valkey' ]
}

# id 校验按「id 变了才做一次」跳着走，因此必须压两种反例：同一个 id 不连续、
# 非法 id 连着好几行。任一处判错，菜单就会多显示或少显示一整块功能。
@test "snapshot: id 交错出现、非法 id 连续多行时结论不变" {
    mkdir -p "${OS_STATE_DIR}"
    printf 'caddy\tversion\t2.10\n' >"${OS_STATE_FILE}"
    printf 'PHP\tversion\t9\nPHP\tmethod\tapt\n' >>"${OS_STATE_FILE}"
    printf 'valkey\tversion\t8.0.1\n' >>"${OS_STATE_FILE}"
    printf 'caddy\tmethod\tapt\n' >>"${OS_STATE_FILE}"
    printf 'valkey\tversion\t9.9.9\n' >>"${OS_STATE_FILE}"

    os::state_snapshot
    [ "${#OS_STATE_SNAP_IDS[@]}" -eq 2 ]
    [ "${OS_STATE_SNAP_IDS[0]}" = 'caddy' ]
    [ "${OS_STATE_SNAP_IDS[1]}" = 'valkey' ]
    [ "${OS_STATE_SNAP_VERSIONS[0]}" = '2.10' ]
    [ "${OS_STATE_SNAP_VERSIONS[1]}" = '8.0.1' ]
}
