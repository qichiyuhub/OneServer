#!/usr/bin/env bats
#
# lib/lock.sh 的单元测试
#
# os::lock_acquire 是 V2 点名的七个函数之一，必测两条对抗性输入：
#   * 持锁进程 kill -9 后能否接管
#   * 两个进程同时抢
# 两条都只能在真进程里测，同进程调函数测不出来。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log lock
    OS_LOCK_TMP="${BATS_TEST_TMPDIR}/run"
    mkdir -p "${OS_LOCK_TMP}"
}

# 起一个持锁进程，锁住后打印 ready，然后等
os_lock_holder_script() {
    cat <<EOF
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/lock.sh"
OS_RUN_DIR="${OS_LOCK_TMP}"
OS_LOCK_FILE="${OS_LOCK_TMP}/oneserver.lock"
OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
log::init "\${1:-holder}"
EOF
}

@test "acquire: 单进程能取到锁并写入持锁者信息" {
    local f="${BATS_TEST_TMPDIR}/one.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'echo held'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *held* ]]
    grep -q '^pid=' "${OS_LOCK_TMP}/oneserver.lock"
    grep -q '^command=' "${OS_LOCK_TMP}/oneserver.lock"
    grep -q '^started=' "${OS_LOCK_TMP}/oneserver.lock"
}

@test "acquire: 重复调用是幂等的" {
    local f="${BATS_TEST_TMPDIR}/twice.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'os::lock_acquire 5'
        echo 'echo ok'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *ok* ]]
}

# --- 对抗性一：两个进程同时抢 ---

@test "acquire: 第二个进程拿不到锁，退出码 5 且报出持锁者" {
    local holder="${BATS_TEST_TMPDIR}/holder.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'echo ready'
        echo 'sleep 30'
    } >"${holder}"

    bash "${holder}" >"${BATS_TEST_TMPDIR}/holder.out" 2>&1 &
    local hpid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/holder.out" 2>/dev/null && break
        sleep 0.1
    done

    local second="${BATS_TEST_TMPDIR}/second.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 1'
        echo 'echo should-not-happen'
    } >"${second}"

    run bash "${second}"
    kill -TERM "${hpid}" 2>/dev/null || true
    wait "${hpid}" 2>/dev/null || true

    [ "${status}" -eq 5 ]
    [[ "${output}" != *should-not-happen* ]]
    [[ "${output}" == *'另一个 OneServer 实例正在运行'* ]]
    [[ "${output}" == *'PID'* ]]
}

@test "acquire: 两个进程同时抢，只有一个进临界区" {
    local counter="${BATS_TEST_TMPDIR}/counter"
    : >"${counter}"
    local racer="${BATS_TEST_TMPDIR}/racer.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 10'
        # 非原子的读-改-写：没有锁保护一定会丢更新
        echo "n=\$(cat '${counter}' 2>/dev/null || echo 0)"
        echo 'sleep 0.2'
        echo "printf '%d' \$((n + 1)) > '${counter}'"
    } >"${racer}"

    bash "${racer}" >/dev/null 2>&1 &
    local p1=$!
    bash "${racer}" >/dev/null 2>&1 &
    local p2=$!
    wait "${p1}" "${p2}" 2>/dev/null || true

    # 串行化成功才会是 2；没锁的话两个进程都读到 0，结果是 1
    [ "$(cat "${counter}")" = '2' ]
}

# --- 对抗性二：持锁进程被 kill -9 ---

# 持锁者用 `read < fifo` 阻塞：read 是内建命令，不产生子进程。
# 这一点是本用例的关键 —— 用 `sleep` 的话被测的就不是「持锁进程死了」，
# 而是下面那个「子进程还活着」的情形。
@test "acquire: 持锁进程 kill -9 后（无存活子进程）新进程能接管" {
    local fifo="${BATS_TEST_TMPDIR}/wait.fifo"
    mkfifo "${fifo}"
    local holder="${BATS_TEST_TMPDIR}/k9.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'echo ready'
        echo "read -r _ < '${fifo}'"
    } >"${holder}"

    bash "${holder}" >"${BATS_TEST_TMPDIR}/k9.out" 2>&1 &
    local hpid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/k9.out" 2>/dev/null && break
        sleep 0.1
    done
    [ -z "$(pgrep -P "${hpid}" 2>/dev/null)" ]

    # kill -9 打不到 trap —— 靠 trap 释放锁的实现会在这里永久留下死锁
    kill -9 "${hpid}" 2>/dev/null || true
    wait "${hpid}" 2>/dev/null || true

    local taker="${BATS_TEST_TMPDIR}/taker.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 3'
        echo 'echo taken'
    } >"${taker}"
    run bash "${taker}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *taken* ]]
}

# 与上一条相反的情形，锁**应该**继续被持有。
# flock 的 fd 会被子进程继承：父进程被 kill -9 时 apt 还在跑，
# 此时放开锁 = 让另一个实例并发去动 dpkg，正是这把锁要防的事。
@test "acquire: 持锁进程死了但子进程还活着时，锁继续被持有" {
    local holder="${BATS_TEST_TMPDIR}/orphan.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'echo ready'
        echo 'sleep 30'
    } >"${holder}"

    bash "${holder}" >"${BATS_TEST_TMPDIR}/orphan.out" 2>&1 &
    local hpid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/orphan.out" 2>/dev/null && break
        sleep 0.1
    done
    local child
    child=$(pgrep -P "${hpid}" 2>/dev/null | head -n1)
    [ -n "${child}" ]

    kill -9 "${hpid}" 2>/dev/null || true
    wait "${hpid}" 2>/dev/null || true

    local taker="${BATS_TEST_TMPDIR}/taker2.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 1'
        echo 'echo taken'
    } >"${taker}"
    run bash "${taker}"
    kill -9 "${child}" 2>/dev/null || true

    [ "${status}" -eq 5 ]
    [[ "${output}" != *taken* ]]
}

# --- 规范条款 ---

@test "锁文件在 /run 不在 /tmp（D23 / K5）" {
    [ "${OS_RUN_DIR}" = '/run/oneserver' ]
    [ "${OS_LOCK_FILE}" = '/run/oneserver/oneserver.lock' ]
}

@test "lock.sh 不 source 任何东西，也不依赖同层的 errors.sh" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/lock.sh"
    [ "${status}" -ne 0 ]
    run grep -nE '(^|[^a-zA-Z_])(os::defer|os::record_change|errors::)' "${OS_TEST_REPO_ROOT}/lib/lock.sh"
    [ "${status}" -ne 0 ]
}

# --- 释放与持锁者报告 ---

@test "release: 释放之后别的进程立刻取得到" {
    local f="${BATS_TEST_TMPDIR}/rel.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'os::lock_release'
        echo '[ "${OS_LOCK_HELD}" -eq 0 ] || exit 21'
        echo 'os::lock_acquire 5'
        echo 'echo reacquired'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *reacquired* ]]
}

@test "release: 没持锁时调用它是无害的" {
    local f="${BATS_TEST_TMPDIR}/rel-noop.sh"
    {
        os_lock_holder_script
        echo 'os::lock_release'
        echo 'os::lock_release'
        echo 'echo ok'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
}

# 取锁失败时唯一能帮到人的就是这段输出：谁占着、从什么时候开始、怎么去看它。
# 少了它，用户看到的是「取不到锁」四个字，然后无从下手
@test "report_holder: 把锁文件里的 PID、命令与起始时间说出来" {
    local f="${BATS_TEST_TMPDIR}/report.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'os::lock_report_holder'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'无法取得全局锁'* ]]
    [[ "${output}" == *'持锁进程 PID'* ]]
    [[ "${output}" == *'开始时间'* ]]
    [[ "${output}" == *'ps -p'* ]]
}

@test "report_holder: 锁文件不在时也要给句话，不能沉默" {
    local f="${BATS_TEST_TMPDIR}/report-empty.sh"
    {
        os_lock_holder_script
        echo 'os::lock_report_holder'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'没有持锁者信息'* ]]
}

# --- --try：锁被占是正常情形，不是失败 ---
#
# 这一档存在的理由是实测出来的：通知器每 30 秒跑一次、默认取锁，用户在菜单里
# 停留时它每轮等满 30 秒再以 5 退出，往 JSONL 写数条错误，而 JSONL 正是面板要
# 发布的产物 —— 一变就整份重写。所以「拿不到锁」必须能安静地表达。

@test "acquire --try: 没人持锁时照常拿到" {
    local f="${BATS_TEST_TMPDIR}/try-free.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire --try 1 && echo got'
    } >"${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *got* ]]
}

@test "acquire --try: 锁被占时返回 1，不退出、不打印、不写错误日志" {
    local holder="${BATS_TEST_TMPDIR}/try-holder.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'echo ready'
        echo 'sleep 30'
    } >"${holder}"

    bash "${holder}" >"${BATS_TEST_TMPDIR}/try-holder.out" 2>&1 &
    local hpid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/try-holder.out" 2>/dev/null && break
        sleep 0.1
    done

    # 关键：返回 1 之后调用方**还活着**，能自己决定怎么办（这里打印 skipped
    # 并以 0 退出，正是 bootstrap 对 root-trylock 做的事）
    local second="${BATS_TEST_TMPDIR}/try-second.sh"
    {
        os_lock_holder_script
        echo 'if os::lock_acquire --try 1; then echo got; else echo skipped; fi'
        echo 'exit 0'
    } >"${second}"

    run bash "${second}"
    kill -TERM "${hpid}" 2>/dev/null || true
    wait "${hpid}" 2>/dev/null || true

    [ "${status}" -eq 0 ]
    [[ "${output}" == *skipped* ]]
    [[ "${output}" != *got* ]]
    # 不得报出持锁者：那是给「真的失败了」用的输出
    [[ "${output}" != *pid=* ]]
}

@test "acquire --try: 失败后不留下指向锁文件的描述符" {
    local holder="${BATS_TEST_TMPDIR}/fd-holder.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire 5'
        echo 'echo ready'
        echo 'sleep 30'
    } >"${holder}"

    bash "${holder}" >"${BATS_TEST_TMPDIR}/fd-holder.out" 2>&1 &
    local hpid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/fd-holder.out" 2>/dev/null && break
        sleep 0.1
    done

    # 试锁失败后 fd 必须关掉：留着会被子进程继承，于是「进程都退了锁还被持着」
    local probe="${BATS_TEST_TMPDIR}/fd-probe.sh"
    {
        os_lock_holder_script
        echo 'os::lock_acquire --try 1 || true'
        echo 'echo "fd=${OS_LOCK__FD:-none}"'
    } >"${probe}"

    run bash "${probe}"
    kill -TERM "${hpid}" 2>/dev/null || true
    wait "${hpid}" 2>/dev/null || true

    [ "${status}" -eq 0 ]
    [[ "${output}" == *fd=none* ]]
}
