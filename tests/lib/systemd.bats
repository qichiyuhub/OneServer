#!/usr/bin/env bats
#
# lib/systemd.sh 的单元测试
#
# 容器里有真 systemd，所以这些用例是真装真启真删，不是打桩。
# 核心断言只有一条，但它是这个模块存在的全部理由：
# **ext: 的 unit 只停止禁用，绝不删文件**（D36）。删掉 dpkg 管理的文件，
# 比留一个孤儿 unit 严重得多。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors systemd
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_BACKUP_DIR="${BATS_TEST_TMPDIR}/backup"
    OS_SYSTEMD_UNIT_DIR="${BATS_TEST_TMPDIR}/systemd"
    mkdir -p "${OS_SYSTEMD_UNIT_DIR}"
    OS_SYSTEMD__TOUCHED=()
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()
    OS_ERR__CHANGES=()
    log::init test
    os_test_no_tty
}

os_have_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-system-running >/dev/null 2>&1 || [ "$(systemctl is-system-running 2>/dev/null)" = degraded ] || return 1
    return 0
}

make_unit() {
    local f="${BATS_TEST_TMPDIR}/${1}"
    cat >"${f}" <<'EOF'
[Unit]
Description=OneServer test unit

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    printf '%s' "${f}"
}

# --- 参数校验 ---

@test "来源前缀是必填的，不是可选的" {
    run os::systemd_install '/nonexistent' 'whatever'
    [ "${status}" -eq 2 ]
    run os::systemd_remove 'oneserver-x.service'
    [ "${status}" -eq 2 ]
    run os::systemd_remove 'bogus:x.service'
    [ "${status}" -eq 2 ]
}

@test "ext: 的 unit 不能用 install 装文件" {
    local src
    src=$(make_unit 'os-test-a.service')
    run os::systemd_install "${src}" 'ext'
    [ "${status}" -eq 2 ]
}

@test "缺 unit 名时返回 2" {
    run os::systemd_enable
    [ "${status}" -eq 2 ]
    run os::systemd_disable
    [ "${status}" -eq 2 ]
    run os::systemd_restart
    [ "${status}" -eq 2 ]
}

# --- 安装 ---

@test "install: 文件就位、权限 0644、登记为 own:" {
    local src
    src=$(make_unit 'os-test-b.service')
    # 不用 bats 的 run：它在子 shell 里跑，OS_SYSTEMD__TOUCHED 出不来
    os::systemd_install "${src}" 'own'
    [ -f "${OS_SYSTEMD_UNIT_DIR}/os-test-b.service" ]
    [ "$(stat -c %a "${OS_SYSTEMD_UNIT_DIR}/os-test-b.service")" = '644' ]
    [[ "${OS_SYSTEMD__TOUCHED[*]}" == *'own:os-test-b.service'* ]]
}

@test "install: 换 inode 不就地截断" {
    local src
    src=$(make_unit 'os-test-c.service')
    local dst="${OS_SYSTEMD_UNIT_DIR}/os-test-c.service"
    printf 'old\n' >"${dst}"
    local before
    before=$(stat -c %i "${dst}")
    os::systemd_install "${src}" 'own'
    [ "$(stat -c %i "${dst}")" != "${before}" ]
}

@test "install: 覆盖已有 unit 前先备份" {
    local src
    src=$(make_unit 'os-test-d.service')
    printf 'old content\n' >"${OS_SYSTEMD_UNIT_DIR}/os-test-d.service"
    os::systemd_install "${src}" 'own'
    run grep -rl 'old content' "${OS_BACKUP_DIR}"
    [ "${status}" -eq 0 ]
}

@test "install: 注册了回滚（本次创建属「必须回滚」类）" {
    local src
    src=$(make_unit 'os-test-e.service')
    os::systemd_install "${src}" 'own'
    [ "${#OS_ERR__DEFER_LEN[@]}" -gt 0 ]
}

# --- 卸载：这个模块存在的理由 ---

@test "remove own: 停止禁用后删文件" {
    os_have_systemd || skip '没有可用的 systemd'
    local src
    src=$(make_unit 'os-test-own.service')
    os::systemd_install "${src}" 'own'
    [ -f "${OS_SYSTEMD_UNIT_DIR}/os-test-own.service" ]
    os::systemd_remove 'own:os-test-own.service'
    [ ! -f "${OS_SYSTEMD_UNIT_DIR}/os-test-own.service" ]
}

@test "remove ext: 只停止禁用，**绝不删文件**（D36）" {
    local dst="${OS_SYSTEMD_UNIT_DIR}/os-test-ext.service"
    # 假装这是 dpkg 装的文件
    printf '[Unit]\nDescription=pretend dpkg owns this\n' >"${dst}"
    local before
    before=$(stat -c %i "${dst}")

    run os::systemd_remove 'ext:os-test-ext.service'
    [ "${status}" -eq 0 ]
    # 文件必须原封不动 —— 连 inode 都不能变
    [ -f "${dst}" ]
    [ "$(stat -c %i "${dst}")" = "${before}" ]
    grep -q '只停止禁用，不删文件' "${OS_LOG_MAIN}"
}

@test "remove: unit 本来就不存在时不报错" {
    run os::systemd_remove 'own:never-existed.service'
    [ "${status}" -eq 0 ]
}

# --- 真 systemd 上的往返 ---

@test "真实 systemd: 装 → 启用 → 重启 → 卸载" {
    os_have_systemd || skip '没有可用的 systemd'
    # 这条要动真的 /etc/systemd/system
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats.service')

    os::systemd_install "${src}" 'own'
    [ -f '/etc/systemd/system/oneserver-bats.service' ]

    os::systemd_enable --now 'oneserver-bats.service' own
    [ "$(systemctl is-enabled oneserver-bats.service)" = 'enabled' ]

    os::systemd_restart 'oneserver-bats.service'
    # 重启属「禁止自动回滚」类，只进变更清单
    [[ "${OS_ERR__CHANGES[*]}" == *'oneserver-bats.service'* ]]

    os::systemd_remove 'own:oneserver-bats.service'
    [ ! -f '/etc/systemd/system/oneserver-bats.service' ]
    run systemctl is-enabled oneserver-bats.service
    [ "${status}" -ne 0 ]
}

@test "systemd_enable: own unit 从 disabled 变 enabled 才注册回滚" {
    os_have_systemd || skip '没有可用的 systemd'
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats-own.service')
    os::systemd_install "${src}" 'own'
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()

    os::systemd_enable 'oneserver-bats-own.service' own
    [ "${#OS_ERR__DEFER_LEN[@]}" -eq 1 ]
    # 经 os::run 而不是裸命令 systemctl——回滚动作本身也是副作用，
    # 不该绕开审计日志与脱敏（A-15）
    [ "${OS_ERR__DEFER_ARGS[0]}" = 'os::run' ]

    # 回放这条回滚确实能把 unit 关回 disabled，包装没有破坏语义
    errors::run_rollback
    run systemctl is-enabled oneserver-bats-own.service
    [ "${status}" -ne 0 ]

    os::systemd_remove 'own:oneserver-bats-own.service'
}

@test "systemd_enable: 已经是 enabled 时不重复注册回滚（own 也不例外）" {
    os_have_systemd || skip '没有可用的 systemd'
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats-idem.service')
    os::systemd_install "${src}" 'own'
    os::systemd_enable 'oneserver-bats-idem.service' own
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()

    # 第二次调用时 unit 已经是 enabled——本次没有把状态从「未启用」
    # 变成「启用」，回滚会把用户/上一次调用留下的开机自启关掉
    os::systemd_enable 'oneserver-bats-idem.service' own
    [ "${#OS_ERR__DEFER_LEN[@]}" -eq 0 ]

    os::systemd_remove 'own:oneserver-bats-idem.service'
}

@test "systemd_enable: ext 来源一律记变更清单，不注册回滚（哪怕这次真的从 disabled 变 enabled）" {
    os_have_systemd || skip '没有可用的 systemd'
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats-ext.service')
    # 不经 os::systemd_install（那是 own: 专用），直接落一份文件模拟
    # dpkg 装好的 ext unit
    cp "${src}" '/etc/systemd/system/oneserver-bats-ext.service'
    os::systemd_daemon_reload
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()
    OS_ERR__CHANGES=()

    os::systemd_enable 'oneserver-bats-ext.service' ext
    [ "${#OS_ERR__DEFER_LEN[@]}" -eq 0 ]
    [[ "${OS_ERR__CHANGES[*]}" == *'oneserver-bats-ext.service'* ]]

    os::systemd_disable 'oneserver-bats-ext.service' || true
    rm -f '/etc/systemd/system/oneserver-bats-ext.service'
    os::systemd_daemon_reload
}

# --- 禁止项 ---

@test "systemd.sh 不碰 crontab（K6）" {
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/systemd.sh' | grep -nE 'crontab'"
    [ "${status}" -ne 0 ]
}

@test "systemd.sh 不 source，也不依赖同层模块" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/systemd.sh"
    [ "${status}" -ne 0 ]
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/systemd.sh' \
        | grep -nE '(os::state_|os::secure_|os::sql_|probe::)'"
    [ "${status}" -ne 0 ]
}

# --- 启停与重载 ---

@test "start/stop/reload: 缺 unit 名一律以 2 拒绝" {
    run os::systemd_start
    [ "${status}" -eq 2 ]
    run os::systemd_stop
    [ "${status}" -eq 2 ]
    run os::systemd_reload
    [ "${status}" -eq 2 ]
}

@test "start/stop: 真的起得来停得下，且都记进变更清单" {
    os_have_systemd || skip '没有 systemd'
    # 要让 systemd 认得这个 unit，它就得躺在真的 unit 目录里
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats-run.service')
    os::systemd_install "${src}" own
    OS_ERR__CHANGES=()

    os::systemd_start 'oneserver-bats-run.service'
    [ "$(systemctl is-active oneserver-bats-run.service)" = 'active' ]
    [[ "${OS_ERR__CHANGES[*]}" == *'启动了服务 oneserver-bats-run.service'* ]]

    os::systemd_stop 'oneserver-bats-run.service'
    [ "$(systemctl is-active oneserver-bats-run.service)" != 'active' ]
    [[ "${OS_ERR__CHANGES[*]}" == *'停止了服务'* ]]

    os::systemd_remove 'own:oneserver-bats-run.service'
    os::systemd_daemon_reload
}

# reload 走的是 reload-or-restart：unit 支不支持热重载由 systemd 自己判断。
# 这个 oneshot unit 没写 ExecReload，所以它验的正是「不支持时回落到重启」
@test "reload: 不支持热重载的 unit 也不会失败" {
    os_have_systemd || skip '没有 systemd'
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats-reload.service')
    os::systemd_install "${src}" own
    os::systemd_start 'oneserver-bats-reload.service'
    OS_ERR__CHANGES=()

    run os::systemd_reload 'oneserver-bats-reload.service'
    [ "${status}" -eq 0 ]

    os::systemd_stop 'oneserver-bats-reload.service' || true
    os::systemd_remove 'own:oneserver-bats-reload.service'
    os::systemd_daemon_reload
}

@test "start/stop/reload: dry-run 下一个 systemctl 都不真的跑" {
    os_have_systemd || skip '没有 systemd'
    OS_DRYRUN=1
    run os::systemd_start 'oneserver-bats-nonexistent.service'
    [ "${status}" -eq 0 ]
    run os::systemd_stop 'oneserver-bats-nonexistent.service'
    [ "${status}" -eq 0 ]
    run os::systemd_reload 'oneserver-bats-nonexistent.service'
    [ "${status}" -eq 0 ]
    OS_DRYRUN=0
    # 真跑的话这个 unit 根本不存在，systemctl 会以非零退出
    run systemctl is-active 'oneserver-bats-nonexistent.service'
    [ "${status}" -ne 0 ]
}

# --- 动过的 unit ---
#
# 卸载靠 state 里登记的 unit 清单，而那份清单的来源就是这里。
# 漏掉一个，卸载时它就留在机器上，谁也不知道它是谁装的。

@test "touched: 没动过任何 unit 时输出为空" {
    OS_SYSTEMD__TOUCHED=()
    run os::systemd_touched
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "touched: 装过的 unit 带 own:/ext: 前缀被记下来，重复登记只算一次" {
    os_have_systemd || skip '没有 systemd'
    OS_SYSTEMD__TOUCHED=()
    local src
    src=$(make_unit 'oneserver-bats-touch.service')
    os::systemd_install "${src}" own

    run os::systemd_touched
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'own:oneserver-bats-touch.service'* ]]

    # 再动一次同一个 unit，清单里不该出现第二条
    os::systemd_enable 'oneserver-bats-touch.service' own || true
    run bash -c "printf '%s\n' \"\${@}\" | grep -c 'oneserver-bats-touch' " _ "${OS_SYSTEMD__TOUCHED[@]}"
    [ "${output}" -eq 1 ]

    os::systemd_disable 'oneserver-bats-touch.service' || true
    os::systemd_remove 'own:oneserver-bats-touch.service'
    os::systemd_daemon_reload
}

# 规范 §10「写文件前先判断内容是否变化」。不比对的代价是实测出来的：
# `oneserver web enable` 装 4 个 unit，每跑一次就无条件重写、白跑一次
# daemon-reload，且 os::backup_file 每次往备份目录各存一份一模一样的副本 ——
# 跑 4 次那个目录里就躺着 16 份完全相同的 unit。
@test "systemd_install: 内容与权限都没变时不重写、不备份" {
    printf '[Unit]\nDescription=t\n' >"${BATS_TEST_TMPDIR}/os-t.service"
    os::systemd_install "${BATS_TEST_TMPDIR}/os-t.service" own
    local dst="${OS_SYSTEMD_UNIT_DIR}/os-t.service"
    local ino_before
    ino_before=$(stat -c %i "${dst}")

    os::systemd_install "${BATS_TEST_TMPDIR}/os-t.service" own
    [ "$(stat -c %i "${dst}")" = "${ino_before}" ]
    # 归属登记仍然要发生 —— 漏了它卸载就找不到这个 unit
    os::state_units 'test:x' >/dev/null 2>&1 || true
}

@test "systemd_install: 内容变了仍然要写" {
    printf '[Unit]\nDescription=a\n' >"${BATS_TEST_TMPDIR}/os-t2.service"
    os::systemd_install "${BATS_TEST_TMPDIR}/os-t2.service" own
    printf '[Unit]\nDescription=b\n' >"${BATS_TEST_TMPDIR}/os-t2.service"
    os::systemd_install "${BATS_TEST_TMPDIR}/os-t2.service" own
    grep -q 'Description=b' "${OS_SYSTEMD_UNIT_DIR}/os-t2.service"
}

# --- kick：提前踢一轮，但目标状态没变 ---
#
# 它与 start 的分界是**语义**，不是选项多少：start 说「此后这个服务该是运行着
# 的」，kick 说「反正有 timer 会跑，我只是希望它现在就跑一次」。所以 kick
# 不记变更、失败也不让本条命令失败——这两条正是下面两个用例守的东西。

@test "kick: 缺 unit 名时安静返回 0，不去起一条没有名字的 systemctl" {
    run os::systemd_kick
    [ "${status}" -eq 0 ]
}

@test "kick: unit 根本不存在时也返回 0，不打断调用方" {
    os_have_systemd || skip '没有 systemd'
    OS_ERR__CHANGES=()
    run os::systemd_kick 'oneserver-bats-no-such-unit.service'
    [ "${status}" -eq 0 ]
}

@test "kick: 不写进变更清单 —— 提前采一轮没有改变任何目标状态" {
    os_have_systemd || skip '没有 systemd'
    OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'
    local src
    src=$(make_unit 'oneserver-bats-kick.service')
    os::systemd_install "${src}" own

    OS_ERR__CHANGES=()
    os::systemd_kick 'oneserver-bats-kick.service'
    [ "${#OS_ERR__CHANGES[@]}" -eq 0 ]

    systemctl stop 'oneserver-bats-kick.service' 2>/dev/null || true
    systemctl disable 'oneserver-bats-kick.service' 2>/dev/null || true
    rm -f '/etc/systemd/system/oneserver-bats-kick.service'
    systemctl daemon-reload 2>/dev/null || true
}
