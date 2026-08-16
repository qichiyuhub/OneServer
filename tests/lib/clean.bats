#!/usr/bin/env bats
#
# script/ops/clean.sh —— 空间清理
#
# 这个命令的价值全在「什么该删、什么不该删、删之前问几道门」上，而那三件事
# 都是静态可判定的。所以这里钉的是**结构**，不是输出文案：
#
#   * 无主归档只报告 —— 那一段里不许出现任何删除
#   * 危险档必须走 os::destroy_confirm（打全名），安全档走 os::confirm
#   * 扫描与删除共用同一份判据，不许各算各的
#
# 端到端跑一次真命令在 cli.bats 里（那边有装好的 /opt/oneserver）。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    CLEAN="${OS_TEST_REPO_ROOT}/script/ops/clean.sh"
    BODY="${BATS_TEST_TMPDIR}/body"
}

# 取出某个函数的函数体，用来做「这一段里有没有 X」这类断言。
#
# 用 index 逐字比对，**不用正则**：`name() {` 里的括号与花括号在 awk 的动态
# 正则里是分组与区间量词，转义又会触发 `escape sequence treated as plain`
# 警告并被吃掉 —— 结果是永远匹配不上，而用例红得毫无头绪。
fn_body() {
    local name=${1}
    awk -v fn="${name}() {" '
        index($0, fn) == 1 { on = 1 }
        on { print }
        on && $0 == "}" { exit }
    ' "${CLEAN}"
}

@test "无主归档只报告：那一段里没有任何删除" {
    fn_body action_archives >"${BODY}"
    [ -s "${BODY}" ]
    # 备份是用户的救命数据，而 backup remove 已经是管归档的正规入口。
    # 这里再开一个删除口，就是多一个能误删备份的地方
    run grep -nE 'rm |rmdir|os::run ' "${BODY}"
    [ "${status}" -ne 0 ]
    # 而且必须把正规入口打给用户，不能只说「不能在这里删」
    grep -q 'backup remove' "${BODY}"
}

@test "危险档：删上一版与删卷都要打全名" {
    local body
    for body in action_old action_volumes; do
        fn_body "${body}" | grep -q 'os::destroy_confirm' || {
            printf '%s 没有走 destroy_confirm\n' "${body}" >&2
            return 1
        }
    done
}

@test "危险档：不提供一次批准全部的开关" {
    # 规范 §10：不可逆操作必须各自独立确认。`safe` 是安全档的集合，
    # 它里面不许混进危险动作
    fn_body action_safe >"${BODY}"
    [ -s "${BODY}" ]
    run grep -nE 'action_old|action_volumes' "${BODY}"
    [ "${status}" -ne 0 ]
}

@test "安全档：每一项都有自己的确认点" {
    local body
    for body in action_apt action_tmp action_logs action_images; do
        fn_body "${body}" | grep -q 'os::confirm' || {
            printf '%s 没有确认点\n' "${body}" >&2
            return 1
        }
    done
}

@test "轮转日志：只删轮转产物，不碰正在写的那份" {
    fn_body scan_logs >"${BODY}"
    # 判据必须落在文件名模式上（*.gz / *.1）——删正在写的文件会让写入方
    # 继续往一个已 unlink 的 inode 里写：磁盘不释放，日志也再看不见
    grep -qF "name '*.gz'" "${BODY}"
    grep -qF "name '*.[0-9]'" "${BODY}"
    # oneserver.log / audit.log 这种活文件不许被直接点名
    run grep -nF 'oneserver.log' "${BODY}"
    [ "${status}" -ne 0 ]
}

@test "扫描与删除共用判据：清理动作先调对应的 scan_*" {
    fn_body action_apt | grep -q 'scan_apt'
    fn_body action_tmp | grep -q 'scan_tmp'
    fn_body action_logs | grep -q 'scan_logs'
    fn_body action_old | grep -q 'scan_old'
    fn_body action_volumes | grep -q 'scan_containers'
}

@test "默认动作是只读的 overview" {
    grep -qF 'os::action_menu --overview action_overview' "${CLEAN}"
    # overview 自己不许删任何东西
    fn_body action_overview >"${BODY}"
    run grep -nE 'os::run |rm -rf' "${BODY}"
    [ "${status}" -ne 0 ]
}

# D244 之后 os::tmpdir 只剩磁盘这一条通道，孤儿全在那儿 —— 扫描范围因此
# 比过去大，也才真的扫得全
@test "孤儿临时目录：扫的是 os::tmpdir 唯一的那个落点" {
    fn_body scan_tmp >"${BODY}"
    grep -qF '${OS_TMP_ROOT}' "${BODY}"
    # 落点已合并，不该再有第二个根
    run grep -nF 'OS_TMP_EXEC_ROOT' "${BODY}"
    [ "${status}" -ne 0 ]
}
