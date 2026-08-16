#!/usr/bin/env bats
#
# lib/secure.sh 的单元测试
#
# os::secure_set / os::secure_get 是 V2 点名的七个函数之一。必测输入：
# 值含 ' " \ $(...) 反引号 换行 空串 超长 —— **写入→读出必须完全相等**。
#
# 另外三条针对已知缺陷：K1（截断整个文件）· K7（扁平 key）· K12（source）。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors secure
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_SECURE_CONF="${BATS_TEST_TMPDIR}/secure.conf"
    OS_LOG__SECRETS=()
    log::init test
    os_test_no_tty
}

# 写进去再读出来，断言完全相等
#
# 不用 $( ) 取值：命令替换会吃掉尾部换行，值本身以换行结尾的用例会被测成
# 假阴性 —— 那是 bash 的行为，不是 secure.sh 的问题。改成落文件后 cmp。
assert_roundtrip() {
    local key=${1} value=${2}
    os::secure_set "${key}" "${value}"
    local got="${BATS_TEST_TMPDIR}/rt.got" want="${BATS_TEST_TMPDIR}/rt.want"
    os::secure_get "${key}" >"${got}"
    printf '%s' "${value}" >"${want}"
    cmp -s "${got}" "${want}"
}

# --- 命名空间（K7）---

@test "key: 扁平 key 被拒绝" {
    run os::secure_set 'DB_PASS' 'whatever'
    [ "${status}" -eq 2 ]
    run os::secure_get 'DB_PASS'
    [ "${status}" -eq 2 ]
}

@test "key: 带命名空间的 key 被接受" {
    run os::secure_set 'site.blog.db_pass' 'x'
    [ "${status}" -eq 0 ]
    run os::secure_set 'global.cloudflare_token' 'x'
    [ "${status}" -eq 0 ]
    run os::secure_set 'db.wordpress.user' 'x'
    [ "${status}" -eq 0 ]
}

@test "ns: 组件标识转写成命名空间前缀" {
    [ "$(os::secure_ns 'caddy')" = 'caddy' ]
    [ "$(os::secure_ns 'php:8.3')" = 'php.8-3' ]
    [ "$(os::secure_ns 'wordpress:blog')" = 'wordpress.blog' ]
}

@test "K7: 两个站点的凭据互不覆盖" {
    os::secure_set 'site.blog.db_pass' 'blog-secret-1'
    os::secure_set 'site.shop.db_pass' 'shop-secret-2'
    [ "$(os::secure_get 'site.blog.db_pass')" = 'blog-secret-1' ]
    [ "$(os::secure_get 'site.shop.db_pass')" = 'shop-secret-2' ]
}

# --- K1：写一条不能毁掉其他条 ---

@test "K1: 写入新 key 不截断已有内容" {
    os::secure_set 'global.a' 'aaa-value'
    os::secure_set 'global.b' 'bbb-value'
    os::secure_set 'global.c' 'ccc-value'
    [ "$(os::secure_get 'global.a')" = 'aaa-value' ]
    [ "$(os::secure_get 'global.b')" = 'bbb-value' ]
    [ "$(os::secure_get 'global.c')" = 'ccc-value' ]
    [ "$(wc -l <"${OS_SECURE_CONF}")" -eq 3 ]
}

@test "K1: 覆盖已有 key 是就地替换，不追加也不清空" {
    os::secure_set 'global.a' 'first'
    os::secure_set 'global.b' 'keep-me'
    os::secure_set 'global.a' 'second'
    [ "$(os::secure_get 'global.a')" = 'second' ]
    [ "$(os::secure_get 'global.b')" = 'keep-me' ]
    [ "$(wc -l <"${OS_SECURE_CONF}")" -eq 2 ]
}

@test "K1: 替换换 inode，不就地截断" {
    os::secure_set 'global.a' 'first'
    local before
    before=$(stat -c %i "${OS_SECURE_CONF}")
    os::secure_set 'global.a' 'second'
    local after
    after=$(stat -c %i "${OS_SECURE_CONF}")
    [ "${before}" != "${after}" ]
}

@test "del: 只删一条，其余保留" {
    os::secure_set 'global.a' 'aaa-value'
    os::secure_set 'global.b' 'bbb-value'
    os::secure_del 'global.a'
    [ -z "$(os::secure_get 'global.a')" ]
    [ "$(os::secure_get 'global.b')" = 'bbb-value' ]
}

# --- 对抗性输入---

@test "roundtrip: 单引号" {
    assert_roundtrip 'global.t' "it's a 'quoted' value"
}

@test "roundtrip: 双引号与反斜杠" {
    assert_roundtrip 'global.t' 'say "hi" and \ backslash'
    assert_roundtrip 'global.t' '\\\\'
    assert_roundtrip 'global.t' '\n'
    assert_roundtrip 'global.t' '\\n'
}

@test "roundtrip: 命令替换与反引号不被执行也不被改写" {
    assert_roundtrip 'global.t' '$(rm -rf /)'
    assert_roundtrip 'global.t' '`whoami`'
    assert_roundtrip 'global.t' '${HOME}'
}

@test "roundtrip: 换行与回车" {
    assert_roundtrip 'global.t' "$(printf 'line1\nline2\nline3')"
    assert_roundtrip 'global.t' $'a\rb'
    assert_roundtrip 'global.t' $'\n'
}

@test "roundtrip: 空串" {
    os::secure_set 'global.t' ''
    [ "$(os::secure_get 'global.t')" = '' ]
    # 空串与「不存在」要能区分：不存在时返回默认值，存在时不返回默认值
    [ "$(os::secure_get 'global.t' 'DEFAULT')" = '' ]
    [ "$(os::secure_get 'global.never' 'DEFAULT')" = 'DEFAULT' ]
}

@test "roundtrip: 超长值" {
    local long
    long=$(printf 'x%.0s' {1..5000})
    assert_roundtrip 'global.t' "${long}"
}

@test "roundtrip: 中文与 emoji" {
    assert_roundtrip 'global.t' '密码里有中文 🚀 和 emoji'
}

@test "roundtrip: 换行值不会撕开行式格式" {
    os::secure_set 'global.a' "$(printf 'one\ntwo')"
    os::secure_set 'global.b' 'after'
    # 两条记录各占一行，值里的换行已编码
    [ "$(wc -l <"${OS_SECURE_CONF}")" -eq 2 ]
    [ "$(os::secure_get 'global.a')" = "$(printf 'one\ntwo')" ]
    [ "$(os::secure_get 'global.b')" = 'after' ]
}

@test "roundtrip: 值末尾是反斜杠" {
    assert_roundtrip 'global.t' 'ends-with-backslash\'
}

@test "roundtrip: 值本身长得像另一条记录" {
    assert_roundtrip 'global.t' "global.other='injected'"
    os::secure_set 'global.other' 'real-value'
    [ "$(os::secure_get 'global.other')" = 'real-value' ]
}

# --- K12：不 source ---

@test "K12: secure.sh 全文件不出现 source" {
    run grep -nE '(^|[^a-zA-Z_])(source|\.)[[:space:]]+["$]' "${OS_TEST_REPO_ROOT}/lib/secure.sh"
    [ "${status}" -ne 0 ]
}

@test "K12: 配置文件里的可执行内容不会被执行" {
    printf "global.evil='\$(touch %s/pwned)'\n" "${BATS_TEST_TMPDIR}" >"${OS_SECURE_CONF}"
    run os::secure_get 'global.evil'
    [ ! -f "${BATS_TEST_TMPDIR}/pwned" ]
    [ "${output}" = '$(touch '"${BATS_TEST_TMPDIR}"'/pwned)' ]
}

# --- 权限与脱敏 ---

@test "权限: secure.conf 是 0600" {
    os::secure_set 'global.t' 'value-here'
    [ "$(stat -c %a "${OS_SECURE_CONF}")" = '600' ]
}

@test "脱敏: 写入的值自动登记，不会出现在日志里" {
    os::secure_set 'global.t' 'Sup3r-Secret-Value'
    log::write info '刚写了 Sup3r-Secret-Value'
    run grep -F 'Sup3r-Secret-Value' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

@test "list: 只列 key 不列值" {
    os::secure_set 'global.a' 'aaa-value'
    os::secure_set 'site.blog.db_pass' 'bbb-value'
    run os::secure_list
    [[ "${output}" == *'global.a'* ]]
    [[ "${output}" == *'site.blog.db_pass'* ]]
    [[ "${output}" != *'aaa-value'* ]]
    [[ "${output}" != *'bbb-value'* ]]
}

# --- require ---

@test "require: 缺凭据以退出码 3 终止" {
    os::secure_set 'global.have' 'value-here'
    run bash -c "
set -Eeuo pipefail
source '${OS_TEST_REPO_ROOT}/lib/paths.sh'
source '${OS_TEST_REPO_ROOT}/lib/defaults.sh'
source '${OS_TEST_REPO_ROOT}/lib/theme.sh'
source '${OS_TEST_REPO_ROOT}/lib/ui.sh'
source '${OS_TEST_REPO_ROOT}/lib/log.sh'
source '${OS_TEST_REPO_ROOT}/lib/exec.sh'
source '${OS_TEST_REPO_ROOT}/lib/errors.sh'
source '${OS_TEST_REPO_ROOT}/lib/secure.sh'
OS_SECURE_CONF='${OS_SECURE_CONF}'
OS_LOG_DIR='${OS_LOG_DIR}'
log::init t
os::secure_require global.have global.missing
"
    [ "${status}" -eq 3 ]
    [[ "${output}" == *'global.missing'* ]]
}

# --- os::secure_load ---

@test "load: 读进变量并在当前 shell 登记脱敏（不是子 shell）" {
    os::secure_set 'redis.password' 'plain-text-secret'
    local got=''
    os::secure_load 'redis.password' got
    [ "${got}" = 'plain-text-secret' ]
    # 关键断言：脱敏表是在**当前** shell 里长出来的。
    # `pass=$(os::secure_get ...)` 那种写法这一条永远过不了 —— 值拿到了，
    # 脱敏表却随子 shell 一起消失，此后任何一行预览都是明文（同 D74）
    log::redact 'the value is plain-text-secret here'
    [[ "${OS_LOG__REDACTED}" != *'plain-text-secret'* ]]
}

@test "load: key 不存在时变量置空并返回 1" {
    local got='not-touched'
    run os::secure_load 'redis.nosuchkey' got
    [ "${status}" -eq 1 ]
}

# --- dry-run 零变更---

@test "dry-run: 不写凭据库" {
    os::secure_set 'redis.password' 'real-password-here'
    OS_DRYRUN=1
    run os::secure_set 'redis.password' 'dryrun-password'
    OS_DRYRUN=0
    [ "${status}" -eq 0 ]
    # 预演改了凭据而配置文件没改 —— 两边对不上，服务当场连不上
    [ "$(os::secure_get 'redis.password')" = 'real-password-here' ]
}

@test "dry-run: 不删凭据" {
    os::secure_set 'redis.password' 'real-password-here'
    OS_DRYRUN=1
    run os::secure_del 'redis.password'
    OS_DRYRUN=0
    [ "$(os::secure_get 'redis.password')" = 'real-password-here' ]
}

# --- key 命名空间 ---
#
# 扁平 key 是 K7 的形态：第二个同类事物一进来就静默覆盖第一个的密码。
# 而 key 的格式是对外承诺的一部分（§14），放宽它等于让已有的凭据读不回来。

@test "key_valid: 带命名空间的收，扁平的一律拒" {
    os::secure_key_valid 'db.mysite.password'
    os::secure_key_valid 'php.8-3.pool_user'
    os::secure_key_valid 'redis.password'

    run os::secure_key_valid 'password'
    [ "${status}" -ne 0 ]
    run os::secure_key_valid ''
    [ "${status}" -ne 0 ]
}

@test "key_valid: 大写、冒号与首尾的点都不是合法 key" {
    run os::secure_key_valid 'DB.password'
    [ "${status}" -ne 0 ]
    # 组件标识里的 `:` 必须先经 os::secure_ns 转写，不能直接进 key
    run os::secure_key_valid 'php:8.3.password'
    [ "${status}" -ne 0 ]
    run os::secure_key_valid '.password'
    [ "${status}" -ne 0 ]
    run os::secure_key_valid 'db.'
    [ "${status}" -ne 0 ]
}
