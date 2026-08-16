#!/usr/bin/env bats
#
# lib/sql.sh 的单元测试
#
# os::sql_ident / os::sql_str 是 V2 点名的七个函数之一。必测输入：
# 反引号、单引号、\、;、注释符 --、UTF-8、空串。
#
# 断言方式：除了看转义结果，还用真实的 MariaDB 跑一遍 —— 转义对不对
# 最终由数据库说了算，不由我对着规范推。没装 MariaDB 时跳过那几条。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors sql
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    # 临时目录根指到用例自己的沙箱里：defaults_file 那几条会经 os::tmpdir 建目录，
    # 而 bats 只 load lib、不装 EXIT trap，清理钩子根本不存在 —— 用真实的
    # /run/oneserver/tmp 就是每跑一轮往机器上留一份含明文口令的 my.cnf。
    # 实测过：跑三遍测试之后那里躺着 15 个目录。
    OS_TMP_ROOT="${BATS_TEST_TMPDIR}/tmp"
    log::init test
    os_test_no_tty
}

# --- 标识符 ---

@test "ident: 普通标识符加反引号" {
    [ "$(os::sql_ident 'wordpress')" = '`wordpress`' ]
}

@test "ident: 反引号翻倍" {
    [ "$(os::sql_ident 'we`ird')" = '`we``ird`' ]
    # 一个反引号 → 外层一对 + 内部翻倍 = 四个
    [ "$(os::sql_ident '`')" = '````' ]
}

@test "ident: 注入尝试被关进反引号里" {
    [ "$(os::sql_ident 'db`; DROP DATABASE x; --')" = '`db``; DROP DATABASE x; --`' ]
}

@test "ident: 空串拒绝" {
    run os::sql_ident ''
    [ "${status}" -eq 2 ]
}

@test "ident: UTF-8 原样保留" {
    [ "$(os::sql_ident '数据库')" = '`数据库`' ]
}

# --- 字符串字面量 ---

@test "str: 普通值加单引号" {
    [ "$(os::sql_str 'hello')" = "'hello'" ]
}

@test "str: 单引号转义" {
    [ "$(os::sql_str "it's")" = "'it\\'s'" ]
}

@test "str: 反斜杠先于其他转义" {
    # 输入一个反斜杠，输出必须是两个 —— 顺序错了会把后面新产生的转义符再转一次
    [ "$(os::sql_str '\')" = "'\\\\'" ]
    [ "$(os::sql_str "\\'")" = "'\\\\\\''" ]
}

@test "str: 分号与注释符只是普通字符" {
    [ "$(os::sql_str "; DROP TABLE x; --")" = "'; DROP TABLE x; --'" ]
}

@test "str: 换行与回车" {
    [ "$(os::sql_str $'a\nb')" = "'a\\nb'" ]
    [ "$(os::sql_str $'a\rb')" = "'a\\rb'" ]
}

@test "str: 空串" {
    [ "$(os::sql_str '')" = "''" ]
}

@test "str: UTF-8" {
    [ "$(os::sql_str '中文 🚀')" = "'中文 🚀'" ]
}

# --- 让数据库当裁判 ---
#
# 转义写得对不对，最终是 MariaDB 说了算。下面把恶意输入原样存进去再读出来，
# 断言完全相等 —— 既验证没被注入，也验证没被静默篡改（K9 旁边那条
# `tr -d "'"` 删字符的做法，注入是防住了，密码也被改了）。

os_sql_available() {
    command -v mysql >/dev/null 2>&1 || return 1
    mysqladmin ping >/dev/null 2>&1 || return 1
    return 0
}

@test "真实数据库: 恶意标识符与值的往返" {
    os_sql_available || skip '本机没有可用的 MariaDB'

    local db='os_t`est'
    local qdb
    qdb=$(os::sql_ident "${db}")
    mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --execute="DROP DATABASE IF EXISTS ${qdb}"
    # 显式用项目的默认字符集建库。MariaDB 10.11（Ubuntu 24.04）的建库默认不是
    # utf8mb4，存不下 4 字节 emoji —— 这不是转义问题，但会让本用例莫名其妙地
    # 只在一个发行版上失败。顺带也验证了 defaults.sh 里那两个值确实够用。
    mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --execute="CREATE DATABASE ${qdb} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE}"
    mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --execute="CREATE TABLE ${qdb}.\`t\` (v TEXT)"

    local -a payloads=(
        "it's"
        '\'
        "'; DROP DATABASE ${db}; --"
        '`backtick`'
        $'multi\nline'
        '中文 🚀'
        '"double"'
        '\\n'
    )
    local p qv got
    for p in "${payloads[@]}"; do
        qv=$(os::sql_str "${p}")
        mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --execute="INSERT INTO ${qdb}.\`t\` VALUES (${qv})"
    done

    # 库还在 = 没被 DROP 掉
    run mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --skip-column-names --execute="SHOW DATABASES LIKE $(os::sql_str "${db}")"
    [ -n "${output}" ]

    # 全部写进去了 = 没有一条因为转义出错被拒
    run mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --skip-column-names --execute="SELECT COUNT(*) FROM ${qdb}.\`t\`"
    [ "${output}" = "${#payloads[@]}" ]

    # 让数据库自己比对，而不是把行读回 shell 再比：`mysql --batch` 的输出会把
    # 换行、制表转义掉，读回来的东西和存进去的本来就不是同一串，比了也不算数。
    # 用 WHERE v = <转义后的值> 命中 1 行，才是「存进去的确实是我要的那个值」。
    for p in "${payloads[@]}"; do
        qv=$(os::sql_str "${p}")
        run mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --skip-column-names \
            --execute="SELECT COUNT(*) FROM ${qdb}.\`t\` WHERE v = ${qv}"
        [ "${output}" = '1' ]
    done

    mysql --default-character-set="${OS_DEFAULT_DB_CHARSET}" --batch --execute="DROP DATABASE ${qdb}"
}

# --- 只读查询在 dry-run 下照常执行---

@test "sql_query: dry-run 下照常执行，结果仍在 OS_RUN_OUTPUT 里" {
    os_sql_available || skip '本机没有可用的 MariaDB'

    OS_DRYRUN=1
    os::sql_query '查一个常量' -- 'SELECT 42;'
    OS_DRYRUN=0
    # 走 run_out 的话这里会是空串（副作用被跳过），而调用方拿它判
    # 「已经是目标状态了吗」—— 空串会被读成「什么都没有，需要改」，
    # 于是预演报出一堆根本不会发生的变更
    [ "${OS_RUN_OUTPUT}" = '42' ]
    [ "${OS_RUN_SKIPPED}" != '1' ]
}

@test "sql_exec: dry-run 下必须跳过（它是有副作用的那一个）" {
    os_sql_available || skip '本机没有可用的 MariaDB'

    OS_DRYRUN=1
    run os::sql_exec '建个不该存在的库' -- 'CREATE DATABASE os_dryrun_should_not_exist;'
    OS_DRYRUN=0
    [ "${status}" -eq 0 ]
    run mysql --batch --skip-column-names --execute="SHOW DATABASES LIKE 'os_dryrun_should_not_exist'"
    [ -z "${output}" ]
}

@test "sql_exec: SQL 语句经 stdin，不出现在渲染出的命令/审计日志里" {
    run os::sql_exec --allow-fail '测试' -- "SELECT 'S3cret-Value-xyz'"
    run grep -F 'S3cret-Value-xyz' "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
    run grep -F -- '--execute=' "${OS_AUDIT_LOG}"
    [ "${status}" -ne 0 ]
}

@test "sql_query: SQL 语句经 stdin，不出现在审计渲染里" {
    os_sql_available || skip '本机没有可用的 MariaDB'
    os::sql_query '查一个常量' -- "SELECT 'S3cret-Value-xyz'"
    run grep -F -- '--execute=' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

# --- 凭据不进 argv---

@test "defaults_file: 生成 0600 的临时配置，密码不进命令行" {
    local f
    os::sql_defaults_file f 'dbuser' 'S3cret-Password'
    [ -f "${f}" ]
    [ "$(stat -c %a "${f}")" = '600' ]
    grep -q '^user="dbuser"$' "${f}"
    grep -q '^password="S3cret-Password"$' "${f}"
    # 落在 tmpfs 上的 os::tmpdir 里，随进程退出自动清理
    [[ "${f}" == "${OS_TMP_ROOT}"/* ]]
}

# MySQL 的选项文件不是「等号右边原样取走」：`#` 在行中任意位置开始注释、
# 首尾空白被吃掉、反斜杠按转义表解释。裸写 `password=abc#def` 时
# my_print_defaults 读出来的是 `abc` —— 而且不报错，现场只表现为
# 「密码明明是对的却连不上」。加引号 + 转义反斜杠与双引号才是对称的。
@test "defaults_file: 含 # 空格 反斜杠 双引号的密码不被选项文件语法吃掉" {
    local f
    os::sql_defaults_file f 'db user' 'a#b c\d"e'
    grep -qF 'password="a#b c\\d\"e"' "${f}"
    grep -qF 'user="db user"' "${f}"
}

@test "defaults_file: 密码自动登记脱敏" {
    local f
    os::sql_defaults_file f 'dbuser' 'S3cret-Password'
    log::write info '密码是 S3cret-Password'
    run grep -F 'S3cret-Password' "${OS_LOG_MAIN}"
    [ "${status}" -ne 0 ]
}

# --- 分层 ---

@test "sql.sh 不依赖同层的 secure.sh" {
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/sql.sh' | grep -nE 'os::secure_'"
    [ "${status}" -ne 0 ]
}

@test "sql.sh 不 source 任何东西" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/sql.sh"
    [ "${status}" -ne 0 ]
}
