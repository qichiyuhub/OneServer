#!/usr/bin/env bats
#
# lib/errors.sh 的单元测试
#
# 重点在三分类各自的行为差异，以及中断语义 ——规范的核心断言是
# 「收到信号**不跑回滚栈**」，那是最容易实现反的一条。
#
# trap 相关的用例必须在真正的子进程里跑（bats 的 run 是同进程函数调用，
# 装不上 EXIT trap 也捕不到信号），所以下面用 helper 起独立 bash 进程。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log errors
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_BACKUP_DIR="${BATS_TEST_TMPDIR}/backup"
    log::init test
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()
    OS_ERR__CHANGES=()
    OS_ERR__BACKED_UP=()
    OS_ERR__ROLLED_BACK=()
    OS_ERR__ROLLBACK_FAILED=()
}

# 生成一段装好 errors.sh 的脚本，打印文件路径（不执行）。
# 拆出来是为了让需要「后台起进程再发信号」的用例复用同一份装配，
# 不必把那串 source 再抄一遍 —— 抄一遍就会有一份迟早对不上的装配顺序。
# 用法：os_script_file <脚本正文>
os_script_file() {
    local body=${1}
    local f="${BATS_TEST_TMPDIR}/case-${RANDOM}.sh"
    cat >"${f}" <<EOF
set -Eeuo pipefail
IFS=\$'\n\t'
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/exec.sh"
source "${OS_TEST_REPO_ROOT}/lib/errors.sh"
OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
OS_BACKUP_DIR="${BATS_TEST_TMPDIR}/backup"
log::init case
errors::install
${body}
EOF
    printf '%s' "${f}"
}

# 在独立进程里跑一段用了 errors.sh 的脚本
# 用法：os_run_script <脚本正文>
os_run_script() {
    bash "$(os_script_file "${1}")"
}

# --- 三分类 ---

@test "defer: 注册的动作在失败时逆序执行" {
    local marker="${BATS_TEST_TMPDIR}/order"
    run os_run_script "
os::defer bash -c 'echo 1 >> \"${marker}\"'
os::defer bash -c 'echo 2 >> \"${marker}\"'
os::defer bash -c 'echo 3 >> \"${marker}\"'
false
"
    [ "${status}" -ne 0 ]
    [ "$(tr -d '\n' <"${marker}")" = '321' ]
}

@test "defer: 成功退出时不执行回滚" {
    local marker="${BATS_TEST_TMPDIR}/nope"
    run os_run_script "
os::defer bash -c 'echo x >> \"${marker}\"'
exit 0
"
    [ "${status}" -eq 0 ]
    [ ! -f "${marker}" ]
}

# dry-run 里 os::run 全被跳过，副作用一件都没发生，可回滚栈里躺着的是真命令。
# 回放它们等于让一次预演删掉真实存在的东西 —— 不变量 5 说的是零变更。
@test "defer: dry-run 下失败也不回放回滚栈" {
    local marker="${BATS_TEST_TMPDIR}/dryrun-rollback"
    run os_run_script "
OS_DRYRUN=1
os::defer bash -c 'echo x >> \"${marker}\"'
false
"
    [ "${status}" -ne 0 ]
    [ ! -f "${marker}" ]
}

@test "defer: 参数里有空格和引号也能原样重放" {
    local out="${BATS_TEST_TMPDIR}/args"
    run os_run_script "
os::defer bash -c 'printf \"%s\n\" \"\$1\" > \"${out}\"' _ 'a b  c\"d'
false
"
    [ "$(cat "${out}")" = 'a b  c"d' ]
}

# os_run_script 的正文里 IFS 就是 $'\n\t'（规范要求每个脚本这么设），
# 所以这条用例跑的正是真实脚本的那种环境 —— D91 就是这么被撞出来的：
# 「已自动撤销」那一段把一条命令的每个参数打成了单独一行。
@test "回滚报告里的命令是一行，不按 IFS 拆成多行" {
    run os_run_script "
os::defer true /var/backups/x.conf /etc/target.conf
false
"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'true /var/backups/x.conf /etc/target.conf'* ]]
}

# --- os::commit ---
#
# 这一组守的是一个真实事故：同一个进程里连着做两件事（配 DNS 令牌、换配置），
# 第二件失败，回滚栈把第一件已经做成的东西一并撤了 —— 用户刚存好的令牌、
# 环境文件、systemd drop-in 全没了，而屏幕上只说「应用新配置失败」。
@test "commit: 提交过的撤销项不再被后面的失败连坐回放" {
    local done_marker="${BATS_TEST_TMPDIR}/committed"
    local late_marker="${BATS_TEST_TMPDIR}/late"
    run os_run_script "
os::defer bash -c 'echo x >> \"${done_marker}\"'
os::commit
os::defer bash -c 'echo y >> \"${late_marker}\"'
false
"
    [ "${status}" -ne 0 ]
    [ ! -f "${done_marker}" ]
    [ -f "${late_marker}" ]
}

# 撤销是动作，多做一次是破坏；变更清单是告知，中断时用户想知道的是
# 这个进程里发生过的全部事情。所以 commit 只作废前者。
@test "commit: 不清空变更清单" {
    run os_run_script "
os::record_change '装了 redis-server'
os::commit
false
"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'装了 redis-server'* ]]
}

# 「同一个文件只备份一次」防的是一次执行里落一堆一模一样的副本。可提交之后
# 下一个动作再改同一个文件时，进程启动时的那份原件已经不是回滚目标了 ——
# 不清的话第二个动作完全没有备份可还原。
@test "commit: 清空已备份清单，下一个动作能再备份一次" {
    local target="${BATS_TEST_TMPDIR}/conf2"
    printf 'first\n' >"${target}"
    run os_run_script "
os::backup_file '${target}'
printf 'second\n' > '${target}'
os::commit
os::backup_file '${target}'
printf 'third\n' > '${target}'
false
"
    [ "${status}" -ne 0 ]
    # 回滚还原的是第二个动作开始时的内容，不是进程启动时的
    [ "$(cat "${target}")" = 'second' ]
}

@test "record_change: 不注册回滚，只进清单" {
    local marker="${BATS_TEST_TMPDIR}/rc"
    run os_run_script "
os::record_change 'apt 安装了 redis-server'
false
"
    [ "${status}" -ne 0 ]
    [ ! -f "${marker}" ]
    [[ "${output}" == *'apt 安装了 redis-server'* ]]
    [[ "${output}" == *'人工确认'* ]]
}

@test "backup_file: 备份后失败会还原原内容" {
    local target="${BATS_TEST_TMPDIR}/conf"
    printf 'original\n' >"${target}"
    run os_run_script "
os::backup_file '${target}'
printf 'modified\n' > '${target}'
false
"
    [ "$(cat "${target}")" = 'original' ]
}

@test "backup_file: 文件不存在是空操作" {
    run os_run_script "
os::backup_file '${BATS_TEST_TMPDIR}/never-existed'
exit 0
"
    [ "${status}" -eq 0 ]
}

@test "backup_file: 还原换 inode，不就地截断" {
    local target="${BATS_TEST_TMPDIR}/inode"
    printf 'original\n' >"${target}"
    local before
    before=$(stat -c %i "${target}")
    run os_run_script "
os::backup_file '${target}'
printf 'modified\n' > '${target}'
false
"
    local after
    after=$(stat -c %i "${target}")
    [ "${before}" != "${after}" ]
}

# --- 失败输出---

@test "失败输出三段都在 stderr，调用栈不上屏" {
    local body="
os::record_change '装了个包'
false
"
    local out err
    out=$(os_run_script "${body}" 2>/dev/null) || true
    err=$(os_run_script "${body}" 2>&1 >/dev/null) || true

    # 整段报告都在 stderr —— 包括「已撤销/需人工确认」的明细行
    [ -z "${out}" ]
    [[ "${err}" == *'执行失败'* ]]
    [[ "${err}" == *'装了个包'* ]]
    [[ "${err}" == *'oneserver doctor --bundle'* ]]
    # 调用栈只进日志，不上屏
    [[ "${err}" != *'栈 #'* ]]
}

@test "调用栈进了日志" {
    OS_LOG_LEVEL=debug run os_run_script "
OS_LOG_LEVEL=debug
false
"
    grep -q '栈 #' "${OS_LOG_DIR}/case.log"
}

@test "退出码 130 不触发回滚" {
    local marker="${BATS_TEST_TMPDIR}/cancel"
    run os_run_script "
os::defer bash -c 'echo x >> \"${marker}\"'
exit 130
"
    [ "${status}" -eq 130 ]
    [ ! -f "${marker}" ]
}

@test "退出码 130 但已有变更时会点出来（脚本的确认点放晚了）" {
    run os_run_script "
os::record_change '已经装了东西'
exit 130
"
    [[ "${output}" == *'确认点放晚'* ]]
}

# 撞码：tar 用 2 表示 fatal error，而 §8 里 2 是「参数错误 · 未变更」。
# 让它穿到出口，框架就会按「前置检查拦下的」处理而**跳过回滚** —— 真机上的
# 后果是 WordPress 解包失败后，已经建好的库与账号全都留在机器上。
@test "退出码 2 但已有变更时归一为 1 并跑回滚" {
    local marker="${BATS_TEST_TMPDIR}/rolled-back"
    # 不写 `exit 2`，让它走真实路径：os::run 原样返回被调命令的 2，
    # set -e 把它带到进程出口 —— 这正是 deploy_wordpress 踩到的那条线
    run os_run_script "
os::record_change '建了库与账号'
os::defer bash -c 'echo x >> \"${marker}\"'
os::run '模拟 tar 的 fatal error' -- bash -c 'exit 2'
"
    [ "${status}" -eq 1 ]
    [ -f "${marker}" ]
    grep -q '声称未变更，但变更清单里有 1 项' "${OS_LOG_DIR}/case.log"
}

# 反面：没有变更时 2/3/4 仍然是「前置检查拦下的」，不能因为这条兜底
# 就把所有 2 都变成 1 —— 那会把「参数打错了」也说成执行失败
@test "退出码 2 且没有变更时保持 2，不回滚" {
    local marker="${BATS_TEST_TMPDIR}/should-not-exist"
    run os_run_script "
os::defer bash -c 'echo x >> \"${marker}\"'
exit 2
"
    [ "${status}" -eq 2 ]
    [ ! -f "${marker}" ]
}

# dry-run 下 os::run 一条都没真跑，而 record_change 照记（清单那时表达的是
# 「将会发生什么」）。拿它当「已经改了」的证据，会把一次正常的预演参数错
# 说成执行失败
@test "dry-run 下退出码 2 不被归一，也不回滚" {
    local marker="${BATS_TEST_TMPDIR}/dry-should-not-exist"
    run os_run_script "
OS_DRYRUN=1
os::record_change '预演里将要做的事'
os::defer bash -c 'echo x >> \"${marker}\"'
exit 2
"
    [ "${status}" -eq 2 ]
    [ ! -f "${marker}" ]
}

@test "退出码 3 与 4 同样按变更清单判定" {
    run os_run_script "
os::record_change '已经改了东西'
exit 3
"
    [ "${status}" -eq 1 ]
    run os_run_script "
exit 3
"
    [ "${status}" -eq 3 ]
}

@test "进程出口把外部未知退出码归一为 1，原始码仍进日志" {
    run os_run_script "
os::run '模拟外部失败' -- bash -c 'exit 7'
"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'模拟外部失败'* ]]
    grep -q '外部退出码 7 已归一' "${OS_LOG_DIR}/case.log"
}

# --- 中断语义---

@test "收到 TERM：不跑回滚栈、打变更清单、退出码 131" {
    local marker="${BATS_TEST_TMPDIR}/sig"
    local f="${BATS_TEST_TMPDIR}/sigcase.sh"
    cat >"${f}" <<EOF
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/errors.sh"
OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
log::init sig
errors::install
os::defer bash -c 'echo rolled >> "${marker}"'
os::record_change 'apt 装到一半'
echo ready
sleep 30
EOF
    local outfile="${BATS_TEST_TMPDIR}/sigout"
    bash "${f}" >"${outfile}" 2>&1 &
    local pid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${outfile}" 2>/dev/null && break
        sleep 0.1
    done
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" || status=$?

    [ "${status}" -eq 131 ]
    # 关键断言：**回滚栈没被执行**
    [ ! -f "${marker}" ]
    grep -q 'apt 装到一半' "${outfile}"
    grep -q '状态未知' "${outfile}"
}

# Ctrl-C 记成 warn 的后果不是多一行日志，是面板的「最近异常」被操作者自己按的
# Ctrl-C 刷满，真异常反而没人看。INT 与已经是 info 的「用户取消」(130) 同类
os_signal_level() {
    local sig=${1} f="${BATS_TEST_TMPDIR}/lv-${sig}.sh"
    local dir="${BATS_TEST_TMPDIR}/log-${sig}"
    cat >"${f}" <<EOF
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/errors.sh"
OS_LOG_DIR="${dir}"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
log::init sig
errors::install
echo ready
sleep 30
EOF
    bash "${f}" >"${BATS_TEST_TMPDIR}/out-${sig}" 2>&1 &
    local pid=$! i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/out-${sig}" 2>/dev/null && break
        sleep 0.1
    done
    kill "-${sig}" "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    grep -o '"level":"[a-z]*"' "${dir}/oneserver.jsonl" | tail -n 1
}

@test "INT 记成 info：操作者自己按的 Ctrl-C 不是异常" {
    [ "$(os_signal_level INT)" = '"level":"info"' ]
}

@test "HUP 仍记成 warn：外力打断，操作者可能不在场" {
    [ "$(os_signal_level HUP)" = '"level":"warn"' ]
}

@test "不可中断区段内收到信号：延后到区段结束" {
    local f="${BATS_TEST_TMPDIR}/critcase.sh"
    local outfile="${BATS_TEST_TMPDIR}/critout"
    cat >"${f}" <<EOF
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/paths.sh"
source "${OS_TEST_REPO_ROOT}/lib/defaults.sh"
source "${OS_TEST_REPO_ROOT}/lib/theme.sh"
source "${OS_TEST_REPO_ROOT}/lib/ui.sh"
source "${OS_TEST_REPO_ROOT}/lib/log.sh"
source "${OS_TEST_REPO_ROOT}/lib/errors.sh"
OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
log::init crit
errors::install
os::critical_begin '写入 state'
echo in-critical
sleep 2
echo critical-done
os::critical_end
echo never-reached
EOF
    bash "${f}" >"${outfile}" 2>&1 &
    local pid=$!
    local i
    for ((i = 0; i < 100; i++)); do
        grep -q in-critical "${outfile}" 2>/dev/null && break
        sleep 0.1
    done
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" || status=$?

    [ "${status}" -eq 131 ]
    # 区段跑完了才退出
    grep -q 'critical-done' "${outfile}"
    grep -q 'never-reached' "${outfile}" && false || true
}

# --- os::tmpdir 属主校验 ---

@test "tmpdir: 目录属主不是 root 时拒绝使用，不会当场 chown 抢过来" {
    [ "$(id -u)" -eq 0 ] || skip '需要 root 权限伪造被劫持的目录属主'
    local fake_root="${BATS_TEST_TMPDIR}/hijacked-var-tmp/oneserver"
    mkdir -p "${fake_root}"
    chmod 0777 "${fake_root}"
    chown 65534 "${fake_root}" 2>/dev/null || skip '当前环境不允许 chown 到任意 uid'
    OS_TMP_ROOT="${fake_root}"
    run os::tmpdir d
    [ "${status}" -ne 0 ]
    # 没有被强行改成 root：函数必须拒绝，而不是 chown 抢管理权
    [ "$(stat -c '%u' "${fake_root}")" = '65534' ]
}

# **故意不用 `run`。** run 把被测函数放进子 shell 跑，而这个接口的全部要点就是
# 路径要写回调用方的变量 —— 用 run 的话拿到的是 status 和 output，恰好绕开了
# 要验的那件事，改回 stdout 返回也照样绿。
@test "tmpdir: 目录属主是 root 时把路径写进调用方的变量" {
    [ "$(id -u)" -eq 0 ] || skip '需要 root 权限运行 os::tmpdir'
    OS_TMP_ROOT="${BATS_TEST_TMPDIR}/clean-var-tmp/oneserver"
    local d=''
    os::tmpdir d
    [ -n "${d}" ]
    [ -d "${d}" ]
}

@test "tmpdir: 变量名不合法时以 2 拒绝，不建目录" {
    OS_TMP_ROOT="${BATS_TEST_TMPDIR}/badname"
    run os::tmpdir '不是标识符'
    [ "${status}" -eq 2 ]
    [ ! -d "${BATS_TEST_TMPDIR}/badname" ]
}

# --- os::tmpdir 的清理必须发生在调用方的进程里 ---
#
# 这是它用输出变量而不是 stdout 的全部理由：把新目录登记进 OS_ERR__TMPDIRS 的
# 动作必须留在调用方进程里，而 `d=$(os::tmpdir)` 会把登记关进一个转瞬即逝的子
# shell —— 目录照建，父进程的清理列表却始终是空的，每调用一次泄漏一个，而清理
# 代码看上去一直在跑。
#
# 三条退出路径各测一次：EXIT trap 与信号 trap 是两段各自独立的清理调用，
# 漏一条就是一类泄漏。
#
# 判据是「跑完之后临时根目录为空」，不去读那个路径 —— 读它就得让变量名穿过两层
# heredoc 展开，而那正是这组用例要防的那类错误。

os_tmpdir_root() {
    local root="${BATS_TEST_TMPDIR}/tmproot"
    mkdir -p "${root}"
    printf '%s' "${root}"
}

@test "tmpdir: 正常退出后不留残留" {
    [ "$(id -u)" -eq 0 ] || skip 'os::tmpdir 要求临时目录根属主是 root'
    local root seen="${BATS_TEST_TMPDIR}/seen-ok"
    root=$(os_tmpdir_root)
    os_run_script "
OS_TMP_ROOT='${root}'
os::tmpdir d
ls -A '${root}' > '${seen}'
"
    [ -s "${seen}" ]
    [ -z "$(ls -A "${root}")" ]
}

@test "tmpdir: 失败退出后不留残留" {
    [ "$(id -u)" -eq 0 ] || skip 'os::tmpdir 要求临时目录根属主是 root'
    local root seen="${BATS_TEST_TMPDIR}/seen-fail"
    root=$(os_tmpdir_root)
    run os_run_script "
OS_TMP_ROOT='${root}'
os::tmpdir d
ls -A '${root}' > '${seen}'
exit 1
"
    [ "${status}" -eq 1 ]
    [ -s "${seen}" ]
    [ -z "$(ls -A "${root}")" ]
}

@test "tmpdir: 被 TERM 打断后不留残留" {
    [ "$(id -u)" -eq 0 ] || skip 'os::tmpdir 要求临时目录根属主是 root'
    local root seen="${BATS_TEST_TMPDIR}/seen-sig" f
    root=$(os_tmpdir_root)
    f=$(os_script_file "
OS_TMP_ROOT='${root}'
os::tmpdir d
ls -A '${root}' > '${seen}'
echo ready
sleep 30
")
    bash "${f}" >"${BATS_TEST_TMPDIR}/sig-out" 2>&1 &
    local pid=$! i
    for ((i = 0; i < 100; i++)); do
        grep -q ready "${BATS_TEST_TMPDIR}/sig-out" 2>/dev/null && break
        sleep 0.1
    done
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    [ -s "${seen}" ]
    [ -z "$(ls -A "${root}")" ]
}

# --- 分层与禁止项 ---

@test "errors.sh 无 eval" {
    # 排除注释：头注释里写「全文件无 eval」本身含这个词
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/errors.sh'         | grep -nE '(^|[^a-zA-Z_])eval[[:space:]]'"
    [ "${status}" -ne 0 ]
}

@test "errors.sh 不 source 任何东西" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/errors.sh"
    [ "${status}" -ne 0 ]
}

@test "errors.sh 不调用同层的 lock.sh" {
    run grep -nE '(^|[^a-zA-Z_])os::lock_' "${OS_TEST_REPO_ROOT}/lib/errors.sh"
    [ "${status}" -ne 0 ]
}

# --- os::replace_line---

# 造一个待改的配置文件，打印路径
make_conf() {
    local f="${BATS_TEST_TMPDIR}/conf-${RANDOM}${RANDOM}.conf"
    printf 'port 6379\nbind 0.0.0.0\nsave 900 1\n' >"${f}"
    printf '%s' "${f}"
}

@test "replace_line: 换掉匹配行，其余行原样" {
    local f
    f=$(make_conf)
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    [ "$(sed -n 2p "${f}")" = 'bind 127.0.0.1' ]
    [ "$(sed -n 1p "${f}")" = 'port 6379' ]
    [ "$(sed -n 3p "${f}")" = 'save 900 1' ]
}

@test "replace_line: 换 inode，不是就地截断（K13）" {
    local f before after
    f=$(make_conf)
    before=$(stat -c %i "${f}")
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    after=$(stat -c %i "${f}")
    [ "${before}" != "${after}" ]
}

@test "replace_line: 权限与属主随原文件走，不按 umask 新建" {
    local f
    f=$(make_conf)
    chmod 0600 "${f}"
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    [ "$(stat -c %a "${f}")" = '600' ]
}

@test "replace_line: 已是目标状态则不写" {
    local f before after
    f=$(make_conf)
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    before=$(stat -c %i "${f}")
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    after=$(stat -c %i "${f}")
    [ "${before}" = "${after}" ]
}

@test "replace_line: OS_REPLACE_CHANGED 报告这次到底写没写" {
    local f
    f=$(make_conf)
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    [ "${OS_REPLACE_CHANGED}" = '1' ]
    # 第二次已是目标状态 —— 调用方靠这一位决定不重启服务
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    [ "${OS_REPLACE_CHANGED}" = '0' ]
}

@test "replace_line: dry-run 的预览行过脱敏，密码不上屏" {
    local f
    f=$(make_conf)
    log::secret_add 'sup3rs3cr3t-value'
    OS_DRYRUN=1
    run os::replace_line --append-if-missing "${f}" '^requirepass ' 'requirepass sup3rs3cr3t-value'
    OS_DRYRUN=0
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'sup3rs3cr3t-value'* ]]
    [[ "${output}" == *'***'* ]]
}

@test "replace_line: --backup 只在真要写时才落副本" {
    local f
    f=$(make_conf)
    os::replace_line --backup "${f}" '^bind ' 'bind 127.0.0.1'
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" = '1' ]
    # 第二次已是目标状态：不写，也就不该再多一份副本
    os::replace_line --backup "${f}" '^bind ' 'bind 127.0.0.1'
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" = '1' ]
}

@test "backup_file: 同一次执行里同一个文件只备份一次" {
    local f
    f=$(make_conf)
    os::backup_file "${f}"
    printf 'changed
' >>"${f}"
    os::backup_file "${f}"
    # 改三行配置的脚本本来会落三份一模一样的副本
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" = '1' ]
}

@test "replace_line: 不认识的选项以退出码 2 拒绝" {
    local f
    f=$(make_conf)
    run os::replace_line --nosuchopt "${f}" '^bind ' 'bind 127.0.0.1'
    [ "${status}" -eq 2 ]
}

@test "replace_line: 一行都没匹配到时报错，不悄悄追加" {
    local f
    f=$(make_conf)
    run os::replace_line "${f}" '^nosuchkey ' 'nosuchkey 1'
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"没有匹配"* ]]
    run grep -c 'nosuchkey' "${f}"
    [ "${status}" -ne 0 ]
}

@test "replace_line: --append-if-missing 才追加" {
    local f
    f=$(make_conf)
    os::replace_line --append-if-missing "${f}" '^maxmemory ' 'maxmemory 256mb'
    [ "$(tail -n1 "${f}")" = 'maxmemory 256mb' ]
}

@test "replace_line: 多行匹配时全部替换 —— 不能留下一条仍然生效的旧行" {
    local f
    f="${BATS_TEST_TMPDIR}/multi.conf"
    printf 'bind 0.0.0.0\nport 1\nbind ::0\n' >"${f}"
    os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    [ "$(grep -c '^bind 127.0.0.1$' "${f}")" -eq 2 ]
    [ "$(grep -c '0.0.0.0' "${f}")" -eq 0 ]
}

@test "replace_line: dry-run 零变更" {
    local f before after
    f=$(make_conf)
    before=$(stat -c %i "${f}")
    OS_DRYRUN=1
    run os::replace_line "${f}" '^bind ' 'bind 127.0.0.1'
    OS_DRYRUN=0
    after=$(stat -c %i "${f}")
    [ "${status}" -eq 0 ]
    [ "${before}" = "${after}" ]
    [ "$(sed -n 2p "${f}")" = 'bind 0.0.0.0' ]
}

@test "replace_line: 文件不存在时报错而不是新建" {
    run os::replace_line "${BATS_TEST_TMPDIR}/nope.conf" '^x' 'x 1'
    [ "${status}" -eq 1 ]
    [ ! -e "${BATS_TEST_TMPDIR}/nope.conf" ]
}

@test "backup_file: dry-run 下不落副本" {
    local f
    f=$(make_conf)
    OS_DRYRUN=1
    run os::backup_file "${f}"
    OS_DRYRUN=0
    [ "${status}" -eq 0 ]
    [ ! -d "${OS_BACKUP_DIR}/files" ]
}

@test "backup_file: 非 dry-run 时照常落副本并注册回滚" {
    local f
    f=$(make_conf)
    os::backup_file "${f}"
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" -eq 1 ]
    [ "${#OS_ERR__DEFER_LEN[@]}" -eq 1 ]
}

# --- 失败呈现 ---

# 「执行失败：return "${rc}"」—— 框架里那些「接住退出码再 return」的函数，
# 会让 ERR trap 把自己的源码当成失败原因打给用户看。
# bash 的 ERR 只在最内层触发一次，调用点不会再触发，所以这里没有第二次机会。
@test "on_error: 传播用的 return 不当第一现场，不把框架源码打给用户" {
    run os_run_script "
inner() { local rc=0; false || rc=\$?; return \"\${rc}\"; }
inner
"
    [ "${status}" -ne 0 ]
    [[ "${output}" != *'return'* ]]
    [[ "${output}" == *'执行失败'* ]]
}

@test "on_error: 真实失败的命令照常显示" {
    run os_run_script 'false'
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'执行失败：false'* ]]
}

# 原文与行号仍要进日志 —— 屏幕上不打，不等于排查时也拿不到
@test "on_error: 被隐藏的 return 仍完整落进日志" {
    os_run_script "
inner() { local rc=0; false || rc=\$?; return \"\${rc}\"; }
inner
" || true
    grep -q 'return' "${BATS_TEST_TMPDIR}/log/case.log"
}

# --- 例行「完成」在周期性只读命令上降级 ---
#
# `root-nolock`（规范 §6）的定义就是「零系统副作用的**周期性**只读命令」。
# 面板的分档采集器每 10 秒跑一次，一句例行「完成」一天就是 8640 行，会把日志里
# 真正的事件挤出保留窗口。降级只针对**成功**这一条，失败路径必须原样保留。

@test "on_exit: root-nolock 成功退出不把「完成」写进 JSONL" {
    run os_run_script "
OS_META_PRIVILEGE=root-nolock
log::write info '标记' framework
exit 0
"
    [ "${status}" -eq 0 ]
    grep -q '"msg":"标记"' "${BATS_TEST_TMPDIR}/log/oneserver.jsonl"
    ! grep -q '"msg":"完成"' "${BATS_TEST_TMPDIR}/log/oneserver.jsonl"
}

@test "on_exit: 普通命令成功退出仍记「完成」" {
    run os_run_script "
OS_META_PRIVILEGE=root
exit 0
"
    [ "${status}" -eq 0 ]
    grep -q '"msg":"完成"' "${BATS_TEST_TMPDIR}/log/oneserver.jsonl"
}

# 降级只能吃掉「成功」。采集器自己挂了却不记，等于把唯一能发现它挂了的线索也删了
@test "on_exit: root-nolock 失败时照常记录" {
    run os_run_script "
OS_META_PRIVILEGE=root-nolock
false
"
    [ "${status}" -ne 0 ]
    grep -q '"level":"error"' "${BATS_TEST_TMPDIR}/log/oneserver.jsonl"
}
