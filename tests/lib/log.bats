#!/usr/bin/env bats
#
# lib/log.sh 的单元测试
#
# 两个 V2 点名的对抗性目标在这里：
#   * 脱敏（D33 按值不按位置）—— 断言明文不进主日志、不进 JSONL、不进审计
#   * os::json_escape 的底层实现 log::json_escape —— " \ 控制字符 换行 制表 UTF-8 空串

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log
    OS_LOG_TMP="${BATS_TEST_TMPDIR}/log"
    # 把日志落点整体挪到临时目录，别动真机的 /var/log
    OS_LOG_DIR="${OS_LOG_TMP}"
    OS_LOG_MAIN="${OS_LOG_TMP}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_TMP}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_TMP}/audit.log"
    OS_LOG__SECRETS=()
    log::init 'install redis'
}

# --- 初始化 ---

@test "init: 建目录、建四个文件、启用" {
    [ "${OS_LOG_ENABLED}" -eq 1 ]
    [ -f "${OS_LOG_MAIN}" ]
    [ -f "${OS_LOG_JSONL}" ]
    [ -f "${OS_AUDIT_LOG}" ]
    [ -f "${OS_LOG_TMP}/install-redis.log" ]
}

@test "init: 命令路径里的空格换成短横线，不产生嵌套目录" {
    [ "${OS_LOG_CMD_FILE}" = "${OS_LOG_TMP}/install-redis.log" ]
}

@test "init: 目录建不了时降级为禁用，不让脚本失败" {
    OS_LOG_DIR='/proc/nonexistent/oneserver'
    run log::init 'x'
    [ "${status}" -eq 0 ]
}

# K16：普通用户敲一条 @privilege root 的命令时，先蹦出一行
#   lib/log.sh: line NN: /var/log/oneserver/oneserver.log: Permission denied
# 然后才是那句真正有用的「此命令需要 root 权限」。
#
# 根因不是缺降级路径（OS_LOG_ENABLED=0 一直都在），而是**重定向的顺序**：
# `: >>"${f}" 2>/dev/null` 里那行报错是 bash 自己打的，而 bash 按出现顺序
# 处理重定向 —— 打不开 ${f} 的那一刻 stderr 还指着终端，`2>/dev/null` 根本
# 还没生效。把它挪到前面即可。
#
# 用「目标是个目录」来造这个错，是为了让用例在 root 下也测得到：
# root 写得进任何文件，但谁都不能把内容追加进一个目录。
@test "init: 日志文件打不开时静默降级，不漏 bash 的重定向报错（K16）" {
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/k16"
    mkdir -p "${OS_LOG_DIR}/thisisadir"
    OS_LOG_MAIN="${OS_LOG_DIR}/thisisadir"

    run log::init 'php config'
    [ "${status}" -eq 0 ]
    # run 把 stdout 与 stderr 都收进 output —— 一个字都不该有
    [ -z "${output}" ]

    log::init 'php config'
    [ "${OS_LOG_ENABLED}" -eq 0 ]
}

@test "write: 日志落点中途变得写不进去时，也不往终端漏东西" {
    OS_LOG_MAIN="${OS_LOG_TMP}/thisisadir"
    mkdir -p "${OS_LOG_MAIN}"
    run log::write info '一条正常的消息' framework
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

# --- 级别 ---

@test "level: 低于当前级别的不落盘" {
    OS_LOG_LEVEL='warn'
    log::write info '不该出现的信息'
    log::write error '该出现的错误'
    run grep -c '不该出现的信息' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
    grep -q '该出现的错误' "${OS_LOG_MAIN}"
}

@test "level: debug 级别打开后 debug 才落盘" {
    OS_LOG_LEVEL='info'
    log::write debug '藏起来'
    OS_LOG_LEVEL='debug'
    log::write debug '露出来'
    run grep -q '藏起来' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
    grep -q '露出来' "${OS_LOG_MAIN}"
}

# --- 脱敏（D33）---

@test "secret: 登记后明文不进主日志 / JSONL / 审计" {
    local pass='S3cr3t-P@ssw0rd-长密码'
    log::secret_add "${pass}"
    log::write info "连接串 user:${pass}@localhost"
    log::audit '连接数据库' 0 mysql --password="${pass}"

    run grep -F "${pass}" "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
    run grep -F "${pass}" "${OS_LOG_JSONL}"
    [ "${status}" -ne 0 ]
    run grep -F "${pass}" "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
    grep -q '\*\*\*' "${OS_LOG_MAIN}"
}

@test "secret: 短值拒绝登记（返回非零且不记）" {
    run log::secret_add 'abc'
    [ "${status}" -ne 0 ]
    run log::secret_add '12345'
    [ "${status}" -ne 0 ]
    run log::secret_add '123456'
    [ "${status}" -eq 0 ]
}

@test "secret: 短值被拒后不会把日志打成马赛克" {
    log::secret_add 'a' || true
    log::write info 'caddy 已安装'
    grep -q 'caddy 已安装' "${OS_LOG_MAIN}"
}

@test "secret: 含特殊字符的值也能被完整替换" {
    local pass='p@$$/w\o"rd*[x]'
    log::secret_add "${pass}"
    log::write info "密码是 ${pass} 结束"
    run grep -F "${pass}" "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

@test "secret: 同一个值重复登记不会叠加" {
    log::secret_add 'abcdef123'
    log::secret_add 'abcdef123'
    [ "${#OS_LOG__SECRETS[@]}" -eq 1 ]
}

@test "secret: 多个值全部生效" {
    log::secret_add 'first-secret'
    log::secret_add 'second-secret'
    log::write info 'first-secret 与 second-secret'
    run grep -E 'first-secret|second-secret' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

# --- JSON 转义（规范点名的对抗性用例）---

@test "json_escape: 空串" {
    log::json_escape ''
    [ "${OS_LOG__ESCAPED}" = '' ]
}

@test "json_escape: 双引号与反斜杠" {
    log::json_escape 'a"b'
    [ "${OS_LOG__ESCAPED}" = 'a\"b' ]
    log::json_escape 'a\b'
    [ "${OS_LOG__ESCAPED}" = 'a\\b' ]
    # 反斜杠必须先换，否则 \" 会被二次转义成 \\"
    log::json_escape '\"'
    [ "${OS_LOG__ESCAPED}" = '\\\"' ]
}

@test "json_escape: 换行 制表 回车" {
    log::json_escape "$(printf 'a\nb')"
    [ "${OS_LOG__ESCAPED}" = 'a\nb' ]
    log::json_escape "$(printf 'a\tb')"
    [ "${OS_LOG__ESCAPED}" = 'a\tb' ]
    log::json_escape $'a\rb'
    [ "${OS_LOG__ESCAPED}" = 'a\rb' ]
}

@test "json_escape: 其余控制字符转成 \\u00XX" {
    log::json_escape $'a\x01b'
    [ "${OS_LOG__ESCAPED}" = 'a\u0001b' ]
    log::json_escape $'\x1b'
    [ "${OS_LOG__ESCAPED}" = '\u001b' ]
}

@test "json_escape: UTF-8 原样保留" {
    log::json_escape '中文 · emoji 🚀'
    [ "${OS_LOG__ESCAPED}" = '中文 · emoji 🚀' ]
}

@test "json_escape: 组合起来仍是合法 JSON" {
    log::write info $'带"引号\t制表\n换行 与 \\ 反斜杠 与 中文'
    # python3 只在测试里用，产品代码不依赖它
    run python3 -c "
import json,sys
for line in open('${OS_LOG_JSONL}', encoding='utf-8'):
    json.loads(line)
print('ok')
"
    [ "${status}" -eq 0 ]
    [ "${output}" = 'ok' ]
}

# --- JSONL 结构 ---

@test "jsonl: 字段齐全" {
    log::write warn '磁盘快满了'
    run python3 -c "
import json
rec = [json.loads(l) for l in open('${OS_LOG_JSONL}', encoding='utf-8')][-1]
assert rec['level'] == 'warn', rec
assert rec['command'] == 'install redis', rec
assert rec['msg'] == '磁盘快满了', rec
assert 'ts' in rec and 'source' in rec
print('ok')
"
    [ "${output}" = 'ok' ]
}

@test "jsonl: exit_code 记录带退出码字段" {
    log::exit_code error '装不上' 1
    run python3 -c "
import json
rec = [json.loads(l) for l in open('${OS_LOG_JSONL}', encoding='utf-8')][-1]
assert rec['exit_code'] == 1, rec
print('ok')
"
    [ "${output}" = 'ok' ]
}

@test "jsonl: exit_code 一次事件只落一条，且 msg 里不重复写退出码" {
    log::exit_code warn '被信号 HUP 打断' 131
    run python3 -c "
import json
recs = [json.loads(l) for l in open('${OS_LOG_JSONL}', encoding='utf-8')]
# 两条只差一个「(退出码 N)」后缀的话，按 msg 去重的消费者合并不了 ——
# 面板的「最近异常」会被同一次中断刷成两行
assert len(recs) == 1, recs
assert recs[0]['msg'] == '被信号 HUP 打断', recs
assert recs[0]['exit_code'] == 131, recs
print('ok')
"
    [ "${output}" = 'ok' ]
    # 人读的那行仍要带退出码：那里没有字段可用
    grep -q '被信号 HUP 打断 (退出码 131)' "${OS_LOG_MAIN}"
}

@test "jsonl: 退出码不会漏给下一条记录" {
    log::exit_code error '装不上' 1
    log::write info '继续干别的'
    run python3 -c "
import json
recs = [json.loads(l) for l in open('${OS_LOG_JSONL}', encoding='utf-8')]
assert 'exit_code' not in recs[-1], recs[-1]
print('ok')
"
    [ "${output}" = 'ok' ]
}

@test "jsonl: 被级别过滤掉的退出码也不会漏给下一条" {
    # debug 默认不落盘，那一跳提前 return —— 码要是没在入口清掉，
    # 就会挂到下一条毫不相干的记录上
    log::exit_code debug '这条被过滤' 7
    log::write info '下一条'
    run python3 -c "
import json
recs = [json.loads(l) for l in open('${OS_LOG_JSONL}', encoding='utf-8')]
assert 'exit_code' not in recs[-1], recs[-1]
print('ok')
"
    [ "${output}" = 'ok' ]
}

# --- 分层 ---

@test "log.sh 不调用任何 ui::*（同层禁止互相依赖）" {
    # 排除注释行：头注释里说明「不会出现 ui::* 调用」本身含这个串
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/log.sh' | grep -nE 'ui::'"
    [ "${status}" -ne 0 ]
}

@test "log.sh 不 source 任何东西" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/log.sh"
    [ "${status}" -ne 0 ]
}

@test "时间戳带真实时区偏移，不谎报 UTC" {
    log::_now
    # 形如 `YYYY-MM-DDThh:mm:ss+0800` —— `%()T` 取的是本地时间，
    # 写死 Z 会让下游按 UTC 解析，整体偏掉一个时区
    [[ ${OS_LOG__TS} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$ ]]
    [[ ${OS_LOG__TS} != *Z ]]
}

@test "JSONL 的 ts 能被按 ISO 8601 解析回同一时刻" {
    log::init test
    log::write info '时区检查'
    local ts
    ts=$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' "${OS_LOG_JSONL}" | tail -1)
    [ -n "${ts}" ]
    # date -d 认得的偏移量才是真偏移；与当前时刻相差不应超过 5 秒
    local parsed now
    parsed=$(date -d "${ts}" +%s)
    now=$(date +%s)
    [ "$((now - parsed))" -lt 5 ]
    [ "$((now - parsed))" -gt -5 ]
}
