#!/usr/bin/env bats
#
# lib/exec.sh 的单元测试
#
# os::run --secret-val 是 V2 点名的七个函数之一。必测：特殊字符 / 短值 / 空值，
# 并断言**日志、JSONL、审计三处**均无明文。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_LOG__SECRETS=()
    OS_DRYRUN=0
    OS_DRYRUN_TAINTED=0
    log::init test
    os_test_no_tty
}

# --- 三个函数的分工 ---

@test "run: 执行成功返回 0，命令的 stdout 不回给调用方而是进日志" {
    run os::run '写点东西' -- printf 'to-log\n'
    [ "${status}" -eq 0 ]
    # os::run 自己会打一行进度（规范允许），但命令的输出不在里面
    [[ "${output}" != *'to-log'* ]]
    grep -q 'to-log' "${OS_LOG_DIR}/test.log"
}

@test "run: 命令失败时返回真实退出码" {
    run os::run '注定失败' -- bash -c 'exit 7'
    [ "${status}" -eq 7 ]
}

@test "run_out: 输出在 OS_RUN_OUTPUT 里，stderr 进日志" {
    os::run_out '取值' -- bash -c 'printf out-value; printf err-text >&2'
    [ "${OS_RUN_OUTPUT}" = 'out-value' ]
    grep -q 'err-text' "${OS_LOG_DIR}/test.log"
}

@test "run_out / query 都不打印 —— 否则调用方用 \$( ) 会丢掉状态与跳过标志" {
    run os::run_out '取值' -- printf 'value-here'
    [[ "${output}" != *'value-here'* ]]
    run os::query -- printf 'value-here'
    [[ "${output}" != *'value-here'* ]]
}

@test "query: 只读，不产生审计记录" {
    : >"${OS_AUDIT_LOG}"
    os::query -- printf 'read-only'
    [ "${OS_RUN_OUTPUT}" = 'read-only' ]
    [ ! -s "${OS_AUDIT_LOG}" ]
}

@test "run / run_out 产生审计记录" {
    : >"${OS_AUDIT_LOG}"
    os::run '有副作用' -- true
    os::run_out '有副作用要输出' -- printf x
    [ "$(wc -l <"${OS_AUDIT_LOG}")" -eq 2 ]
}

@test "query: 超时会被打断（D18）" {
    local start end
    start=$(date +%s)
    run os::query --timeout 1 -- sleep 10
    end=$(date +%s)
    [ "${status}" -ne 0 ]
    [ $((end - start)) -lt 5 ]
}

# --- dry-run---

@test "dry-run: 有副作用的跳过并置 tainted" {
    OS_DRYRUN=1
    local marker="${BATS_TEST_TMPDIR}/should-not-exist"
    run os::run '建文件' -- touch "${marker}"
    [ "${status}" -eq 0 ]
    [ ! -e "${marker}" ]
}

@test "dry-run: os::run 跳过后 OS_DRYRUN_TAINTED 置 1" {
    OS_DRYRUN=1
    os::run '建文件' -- touch "${BATS_TEST_TMPDIR}/x"
    [ "${OS_DRYRUN_TAINTED}" -eq 1 ]
}

@test "dry-run: run_out 输出为空且标记为跳过" {
    OS_DRYRUN=1
    os::run_out '取值' -- printf 'real-value'
    [ -z "${OS_RUN_OUTPUT}" ]
    [ "${OS_RUN_SKIPPED}" -eq 1 ]
}

@test "dry-run: 只读命令照常执行" {
    OS_DRYRUN=1
    os::query -- printf 'still-runs'
    [ "${OS_RUN_OUTPUT}" = 'still-runs' ]
}

@test "dry-run: 全局脱敏表（非 --secret-val）登记的密码不上屏（os::run）" {
    OS_DRYRUN=1
    local pass='S3cr3t-Passw0rd-abc123'
    log::secret_add "${pass}"
    run os::run '建账号' -- printf 'CREATE USER x IDENTIFIED BY %s' "${pass}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"${pass}"* ]]
    [[ "${output}" == *'***'* ]]
}

@test "dry-run: 全局脱敏表登记的密码不上屏（os::run_out）" {
    OS_DRYRUN=1
    local pass='S3cr3t-Passw0rd-abc123'
    log::secret_add "${pass}"
    run os::run_out '建账号' -- printf 'CREATE USER x IDENTIFIED BY %s' "${pass}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"${pass}"* ]]
    [[ "${output}" == *'***'* ]]
}

# --- --secret-val（D33）---

@test "secret-val: 明文不进日志 / JSONL / 审计三处" {
    local token='Xk9#mQ2-no-keyword-here'
    os::run --secret-val "${token}" '调用外部 API' -- printf '%s\n' "--token=${token}"

    run grep -F "${token}" "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
    run grep -F "${token}" "${OS_LOG_JSONL}"
    [ "${status}" -ne 0 ]
    run grep -F "${token}" "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
    run grep -F "${token}" "${OS_LOG_DIR}/test.log"
    [ "${status}" -ne 0 ]
    grep -q '\*\*\*' "${OS_AUDIT_LOG}"
}

@test "secret-val: 按值匹配，参数位置变了照样命中" {
    local token='Xk9#mQ2-no-keyword-here'
    # 在命令中间插一个参数 —— 按位置脱敏在这里就错位了，按值不受影响
    os::run --secret-val "${token}" '带额外参数' -- printf '%s %s %s\n' '--verbose' "--token=${token}" '--json'
    run grep -F "${token}" "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
}

@test "secret-val: 短值拒绝执行" {
    local marker="${BATS_TEST_TMPDIR}/short"
    run os::run --secret-val 'abc' '不该跑' -- touch "${marker}"
    [ "${status}" -eq 2 ]
    [ ! -e "${marker}" ]
}

@test "secret-val: 空值拒绝执行" {
    local marker="${BATS_TEST_TMPDIR}/empty"
    run os::run --secret-val '' '不该跑' -- touch "${marker}"
    [ "${status}" -eq 2 ]
    [ ! -e "${marker}" ]
}

@test "secret-val: 含特殊字符的值也被完整替换" {
    local token='p@$$/w\o"rd*[x]'
    os::run --secret-val "${token}" '特殊字符' -- printf '%s\n' "${token}"
    run grep -F "${token}" "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
}

# --- --env---

@test "env: 值送到子进程，但不进 argv" {
    os::run_out --env SECRET_TOKEN='env-secret-1' '读环境变量' -- bash -c 'printf "%s" "${SECRET_TOKEN}"'
    [ "${OS_RUN_OUTPUT}" = 'env-secret-1' ]
    # 命令行渲染里没有值 —— 因为它压根不在 argv 里
    run grep -F 'env-secret-1' "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
}

@test "env: 不污染调用方自身的环境" {
    os::run --env LEAKY='leaky-value' '跑一下' -- true
    [ -z "${LEAKY:-}" ]
}

@test "env: 值自动登记脱敏" {
    os::run --env PASS='env-secret-2' '跑一下' -- true
    log::write info '密码是 env-secret-2'
    run grep -F 'env-secret-2' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

# --- --stdin-secret ---

@test "stdin-secret: 值从标准输入进去，不进 argv" {
    os::run_out --stdin-secret 'stdin-secret-1' '读 stdin' -- cat
    [ "${OS_RUN_OUTPUT}" = 'stdin-secret-1' ]
    run grep -F 'stdin-secret-1' "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
}

# --- --stdin（非凭据，与 --stdin-secret 同通道但不登记脱敏）---

@test "stdin: 值从标准输入进去，不进 argv，也不进脱敏表" {
    os::run_out --stdin 'plain-body-1' '读 stdin' -- cat
    [ "${OS_RUN_OUTPUT}" = 'plain-body-1' ]
    run grep -F 'plain-body-1' "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
    # 不是凭据，日志里允许原样出现（没有理由脱敏一段库名/SQL 子句）
    log::write info 'plain-body-1'
    run grep -F 'plain-body-1' "${OS_LOG_MAIN}"
    [ "${status}" -eq 0 ]
}

@test "query: --stdin 把文本喂给只读命令，不进 argv" {
    os::query --stdin 'query-stdin-1' -- cat
    [ "${OS_RUN_OUTPUT}" = 'query-stdin-1' ]
}

# --- --allow-fail ---

@test "allow-fail: 失败不记为框架级错误" {
    run os::run --allow-fail '允许失败' -- bash -c 'exit 3'
    [ "${status}" -eq 3 ]
    run grep -F '命令失败' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

@test "allow-fail: 未声明时失败会记 error" {
    os::run '不允许失败' -- bash -c 'exit 3' || true
    grep -q '命令失败' "${OS_LOG_MAIN}"
}

# --- 参数错误 ---

@test "缺少 -- 之后的命令时返回 2" {
    run os::run '只有描述'
    [ "${status}" -eq 2 ]
    run os::run_out '只有描述'
    [ "${status}" -eq 2 ]
    run os::query
    [ "${status}" -eq 2 ]
}

# --- 分层 ---

@test "exec.sh 不依赖同层的 errors.sh / lock.sh" {
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/exec.sh' \
        | grep -nE '(os::defer|os::record_change|os::critical_|os::lock_|errors::)'"
    [ "${status}" -ne 0 ]
}

@test "exec.sh 不 source 任何东西" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/exec.sh"
    [ "${status}" -ne 0 ]
}

@test "exec.sh 无 eval" {
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/exec.sh' \
        | grep -nE '(^|[^a-zA-Z_])eval[[:space:]]'"
    [ "${status}" -ne 0 ]
}

# --- dry-run 的跳过标志（D15）---

@test "dry-run: OS_RUN_SKIPPED 置 1，让脚本能区分「跳过」与「真的没输出」" {
    OS_DRYRUN=1
    os::run '建文件' -- touch "${BATS_TEST_TMPDIR}/x"
    [ "${OS_RUN_SKIPPED}" -eq 1 ]
    os::run_out '取值' -- printf 'v'
    [ "${OS_RUN_SKIPPED}" -eq 1 ]
}

@test "非 dry-run 时 OS_RUN_SKIPPED 是 0" {
    os::run '真跑' -- true
    [ "${OS_RUN_SKIPPED}" -eq 0 ]
    os::run_out '真跑' -- printf 'v'
    [ "${OS_RUN_SKIPPED}" -eq 0 ]
}

# --- os::retry---

@test "retry: 第一次就成功则不重试" {
    run os::retry 3 '试一下' -- true
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"次失败"* ]]
}

@test "retry: 失败到第 N 次成功" {
    OS_DEFAULT_RETRY_BASE_WAIT=0
    local marker="${BATS_TEST_TMPDIR}/retry-count"
    : >"${marker}"
    run os::retry 4 '第三次才成' -- bash -c "printf x >>'${marker}'; [ \"\$(wc -c <'${marker}')\" -ge 3 ]"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"1/4 次失败"* ]]
    [[ "${output}" == *"2/4 次失败"* ]]
    [ "$(wc -c <"${marker}")" -eq 3 ]
}

@test "retry: 全部失败时返回最后一次的退出码，不吞掉失败" {
    OS_DEFAULT_RETRY_BASE_WAIT=0
    run os::retry 2 '注定失败' -- bash -c 'exit 7'
    [ "${status}" -eq 7 ]
}

@test "retry: 退避是指数的，不是固定间隔" {
    run os::retry 3 '注定失败' -- false
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"1 秒后重试"* ]]
    [[ "${output}" == *"2 秒后重试"* ]]
}

@test "retry: dry-run 下只「跑」一次，命令一次都不执行" {
    OS_DRYRUN=1
    local marker="${BATS_TEST_TMPDIR}/retry-dry"
    run os::retry 3 '不该跑' -- touch "${marker}"
    [ "${status}" -eq 0 ]
    [ ! -e "${marker}" ]
    [[ "${output}" != *"次失败"* ]]
    os::retry 3 '不该跑' -- touch "${marker}"
    [ "${OS_RUN_SKIPPED}" -eq 1 ]
}

@test "retry: os::run 的选项照样透传" {
    run os::retry 2 '看环境变量' --env SECRET_TOKEN=hunter2xyz -- bash -c '[ -n "${SECRET_TOKEN}" ]'
    [ "${status}" -eq 0 ]
}

@test "retry: 次数给 0 或负数时至少跑一次" {
    run os::retry 0 '至少一次' -- true
    [ "${status}" -eq 0 ]
}

# --- os::query --env ---

@test "query: --env 注入环境变量，且不进 argv" {
    os::query --timeout 5 --env 'OS_TEST_TOKEN=s3cr3t-token' -- sh -c 'printf "%s" "${OS_TEST_TOKEN}"'
    [ "${OS_RUN_OUTPUT}" = 's3cr3t-token' ]
}

@test "query: --env 的值自动登记脱敏（与 os::run 对齐）" {
    os::query --timeout 5 --env 'TOK=query-env-secret-1' -- true
    log::write info '令牌是 query-env-secret-1'
    run grep -F 'query-env-secret-1' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

@test "query: 不给 --env 时那个变量就是空的" {
    os::query --timeout 5 -- sh -c 'printf "[%s]" "${OS_TEST_TOKEN-}"'
    [ "${OS_RUN_OUTPUT}" = '[]' ]
}

@test "query: --env 之后的 --timeout 与 -- 仍然认得" {
    os::query --env 'OS_TEST_A=1' --timeout 5 -- sh -c 'printf "%s" "${OS_TEST_A}"'
    [ "${OS_RUN_OUTPUT}" = '1' ]
}

# --- os::query --want-stderr ---

# 有一类命令把结论写在 stderr 上（caddy validate 整份诊断都在那儿，stdout 是空的）。
# 默认丢弃时调用方拿到空字符串，屏幕上就只剩「校验未通过」四个字。
@test "query: --want-stderr 把 stderr 收进 OS_RUN_OUTPUT" {
    os::query --timeout 5 --want-stderr -- sh -c 'echo 出事了 >&2' || true
    [[ "${OS_RUN_OUTPUT}" == *'出事了'* ]]
}

@test "query: 默认不收 stderr（探测取的是值，噪音不该混进来）" {
    os::query --timeout 5 -- sh -c 'echo 噪音 >&2; printf 干净'
    [ "${OS_RUN_OUTPUT}" = '干净' ]
}

@test "query: --want-stderr 下 stdout 与 stderr 都在，退出码照旧" {
    run os::query --timeout 5 --want-stderr -- sh -c 'echo 上; echo 下 >&2; exit 7'
    [ "${status}" -eq 7 ]
    os::query --timeout 5 --want-stderr -- sh -c 'echo 上; echo 下 >&2' || true
    [[ "${OS_RUN_OUTPUT}" == *'上'* ]]
    [[ "${OS_RUN_OUTPUT}" == *'下'* ]]
}

# 这条通道专门用来把命令原话打给用户看，凭据不能跟着一起上屏
@test "query: --want-stderr 的输出照样脱敏" {
    os::query --timeout 5 --want-stderr --env 'TOK=want-stderr-secret-1' \
        -- sh -c 'echo "token is ${TOK}" >&2' || true
    [[ "${OS_RUN_OUTPUT}" != *'want-stderr-secret-1'* ]]
}

@test "query: --want-stderr 与 --stdin 并用" {
    os::query --timeout 5 --want-stderr --stdin 'hello' -- cat
    [[ "${OS_RUN_OUTPUT}" == *'hello'* ]]
}

# --- 失败要说得出是什么失败了 ---

# 命令自己的 stdout/stderr 全进了日志，ERR trap 抓到的又是框架的 return，
# 两头都指望不上 —— 不在这一层说，屏幕上就只剩一个光秃秃的退出码
@test "run: 失败时把 desc 与退出码打上屏，不是无声退出" {
    run os::run '装点什么' -- sh -c 'exit 100'
    [ "${status}" -eq 100 ]
    [[ "${output}" == *'装点什么'* ]]
    [[ "${output}" == *'100'* ]]
}

@test "run: --allow-fail 的失败是预期内的，不上屏" {
    run os::run --allow-fail '试一下' -- sh -c 'exit 3'
    [ "${status}" -eq 3 ]
    [[ "${output}" != *'失败'* ]]
}

@test "run_out: 失败同样上屏" {
    run os::run_out '取点什么' -- sh -c 'exit 2'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'取点什么'* ]]
}

# 认不出的长选项此前落进「第一个非选项参数当 desc」那条分支：
# `os::run_out --timeout 15 '发送告警' -- curl …` 的现场是 desc 变成
# `--timeout`（审计里记下的是这个）、`15` 被吃掉、超时根本没生效，
# 三件事没有一件报错。选项拼错是写代码的人的失误，该在第一次运行就停下来。
@test "run: 不认识的长选项硬失败，不当成 desc 吞掉" {
    run os::run --timeout 15 '真正的描述' -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'--timeout'* ]]
}

@test "query: 不认识的长选项硬失败" {
    run os::query --nosuchopt v -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *'--nosuchopt'* ]]
}
