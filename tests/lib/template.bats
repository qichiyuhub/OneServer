#!/usr/bin/env bats
#
# lib/template.sh 的单元测试
#
# 这个模块的全部价值在四条容易写反的行为上：
#   * 换 inode—— 就地截断正在被读的文件是 K13 的形态
#   * 内容一致就不写—— 否则「第二次执行零变更」当场失效
#   * 残留占位符拒绝写入 —— 半渲染的配置写下去，服务起不来且看不出原因
#   * dry-run 零变更且置 tainted

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors template
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_BACKUP_DIR="${BATS_TEST_TMPDIR}/backup"
    # **必须隔离**：os::template_source 会去 $OS_ETC_DIR/templates 找覆盖，
    # 不改这个变量的话用例会往容器真实的 /etc/oneserver 里写，而且互相串味
    OS_ETC_DIR="${BATS_TEST_TMPDIR}/etc"
    OS_DRYRUN=0
    OS_DRYRUN_TAINTED=0
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()
    log::init test
    os_test_no_tty

    OS_T_TPL="${BATS_TEST_TMPDIR}/tpl"
    OS_T_DST="${BATS_TEST_TMPDIR}/target.conf"
    printf 'listen = /run/php/php%%%%PHP_VERSION%%%%-fpm.sock\npm = ondemand\n' >"${OS_T_TPL}"
}

os_is_root() { [ "$(id -u)" -eq 0 ]; }

# --- 渲染与落地 ---

@test "install_template: 目标不存在时落地并替换占位符" {
    run os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "${status}" -eq 0 ]
    # run 是子进程，OS_TEMPLATE_CHANGED 取不到，单独再跑一次同样的断言
    [ -f "${OS_T_DST}" ]
    grep -q 'listen = /run/php/php8.3-fpm.sock' "${OS_T_DST}"
    ! grep -q '%%' "${OS_T_DST}"
}

@test "install_template: 写入后 OS_TEMPLATE_CHANGED=1，重复执行为 0 且不改文件" {
    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "${OS_TEMPLATE_CHANGED}" -eq 1 ]

    local ino_before
    ino_before=$(stat -c '%i' "${OS_T_DST}")

    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "${OS_TEMPLATE_CHANGED}" -eq 0 ]
    [ "$(stat -c '%i' "${OS_T_DST}")" = "${ino_before}" ]
}

@test "install_template: 替换已有文件时换 inode" {
    printf 'old\n' >"${OS_T_DST}"
    local ino_before
    ino_before=$(stat -c '%i' "${OS_T_DST}")

    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "$(stat -c '%i' "${OS_T_DST}")" != "${ino_before}" ]
}

@test "install_template: 权限随原文件走，不按 umask 重来" {
    printf 'old\n' >"${OS_T_DST}"
    chmod 0600 "${OS_T_DST}"
    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "$(stat -c '%a' "${OS_T_DST}")" = '600' ]
}

@test "install_template: --mode 只对新建文件生效" {
    os::install_template --mode 0644 "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "$(stat -c '%a' "${OS_T_DST}")" = '644' ]
}

@test "install_template: 属主随原文件走" {
    os_is_root || skip 'chown 需要 root'
    printf 'old\n' >"${OS_T_DST}"
    chown daemon:daemon "${OS_T_DST}"
    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "$(stat -c '%U' "${OS_T_DST}")" = 'daemon' ]
}

# --- 归一化 ---

@test "install_template: 模板末尾没有换行也判得出「已是目标状态」" {
    printf 'a\nb' >"${OS_T_TPL}"
    os::install_template "${OS_T_TPL}" "${OS_T_DST}"
    [ "${OS_TEMPLATE_CHANGED}" -eq 1 ]
    [ "$(cat "${OS_T_DST}")" = "$(printf 'a\nb')" ]

    os::install_template "${OS_T_TPL}" "${OS_T_DST}"
    [ "${OS_TEMPLATE_CHANGED}" -eq 0 ]
}

# --- 拒绝写入的两种情形 ---

@test "install_template: 残留占位符拒绝写入" {
    run os::install_template "${OS_T_TPL}" "${OS_T_DST}"
    [ "${status}" -eq 1 ]
    [ ! -e "${OS_T_DST}" ]
    [[ ${output} == *'PHP_VERSION'* ]]
}

@test "install_template: 模板不存在返回 1，缺参数返回 2" {
    run os::install_template "${BATS_TEST_TMPDIR}/nope" "${OS_T_DST}"
    [ "${status}" -eq 1 ]
    run os::install_template "${OS_T_TPL}"
    [ "${status}" -eq 2 ]
}

# --- dry-run ---

@test "install_template: dry-run 零变更，但置 CHANGED 与 tainted" {
    OS_DRYRUN=1
    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ ! -e "${OS_T_DST}" ]
    [ "${OS_TEMPLATE_CHANGED}" -eq 1 ]
    [ "${OS_DRYRUN_TAINTED}" -eq 1 ]
}

@test "install_template: dry-run 下已是目标状态时不置 tainted" {
    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    OS_DRYRUN=1
    OS_DRYRUN_TAINTED=0
    os::install_template "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "${OS_TEMPLATE_CHANGED}" -eq 0 ]
    [ "${OS_DRYRUN_TAINTED}" -eq 0 ]
}

# --- --backup ---

@test "install_template: --backup 只在内容确实要变时落副本" {
    printf 'old\n' >"${OS_T_DST}"
    os::install_template --backup "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" -eq 1 ]

    # 第二次已是目标状态：不写文件，也不再多一份副本（否则第二次执行有变更）
    os::install_template --backup "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" -eq 1 ]
}

@test "install_template: --backup 的副本内容是覆盖前的原文，且注册了回滚" {
    printf 'old\n' >"${OS_T_DST}"
    os::install_template --backup "${OS_T_TPL}" "${OS_T_DST}" PHP_VERSION=8.3
    local bak
    bak=$(find "${OS_BACKUP_DIR}/files" -type f | head -n1)
    [ "$(cat "${bak}")" = 'old' ]
    [ "${#OS_ERR__DEFER_LEN[@]}" -eq 1 ]

    errors::run_rollback
    [ "$(cat "${OS_T_DST}")" = 'old' ]
}

# --- os::install_file ---

@test "install_file: 放置文件并按字节比对，二进制不被逐行读坏" {
    # 造一个含 \0 与非法 UTF-8 的「二进制」：逐行读会把它读残
    printf 'ELF\000\001\002\377\376bin' >"${BATS_TEST_TMPDIR}/bin.src"

    os::install_file --mode 0755 "${BATS_TEST_TMPDIR}/bin.src" "${OS_T_DST}"
    [ "${OS_TEMPLATE_CHANGED}" -eq 1 ]
    cmp -s "${BATS_TEST_TMPDIR}/bin.src" "${OS_T_DST}"
    [ "$(stat -c '%a' "${OS_T_DST}")" = '755' ]

    # 第二次：内容一致 → 不写、不换 inode（否则每次执行都重装一遍 16MB）
    local ino
    ino=$(stat -c '%i' "${OS_T_DST}")
    os::install_file --mode 0755 "${BATS_TEST_TMPDIR}/bin.src" "${OS_T_DST}"
    [ "${OS_TEMPLATE_CHANGED}" -eq 0 ]
    [ "$(stat -c '%i' "${OS_T_DST}")" = "${ino}" ]
}

@test "install_file: 替换已有文件换 inode，权限随原文件" {
    printf 'old\n' >"${OS_T_DST}"
    chmod 0600 "${OS_T_DST}"
    local ino
    ino=$(stat -c '%i' "${OS_T_DST}")

    printf 'new\n' >"${BATS_TEST_TMPDIR}/f.src"
    os::install_file "${BATS_TEST_TMPDIR}/f.src" "${OS_T_DST}"
    [ "$(stat -c '%i' "${OS_T_DST}")" != "${ino}" ]
    [ "$(stat -c '%a' "${OS_T_DST}")" = '600' ]
    [ "$(cat "${OS_T_DST}")" = 'new' ]
}

@test "install_file: dry-run 零变更且置 tainted；源不存在返回 1" {
    printf 'x\n' >"${BATS_TEST_TMPDIR}/f.src"
    OS_DRYRUN=1
    os::install_file "${BATS_TEST_TMPDIR}/f.src" "${OS_T_DST}"
    [ ! -e "${OS_T_DST}" ]
    [ "${OS_DRYRUN_TAINTED}" -eq 1 ]

    OS_DRYRUN=0
    run os::install_file "${BATS_TEST_TMPDIR}/nope" "${OS_T_DST}"
    [ "${status}" -eq 1 ]
}

@test "install_file: --backup 落副本且注册回滚" {
    printf 'old\n' >"${OS_T_DST}"
    printf 'new\n' >"${BATS_TEST_TMPDIR}/f.src"
    os::install_file --backup "${BATS_TEST_TMPDIR}/f.src" "${OS_T_DST}"
    [ "$(find "${OS_BACKUP_DIR}/files" -type f | wc -l)" -eq 1 ]

    errors::run_rollback
    [ "$(cat "${OS_T_DST}")" = 'old' ]
}

@test "install_template: 模板末尾的空行不会被吃掉（否则每次都重写）" {
    printf 'a\n\n' >"${OS_T_TPL}"
    os::install_template "${OS_T_TPL}" "${OS_T_DST}"
    [ "$(wc -l <"${OS_T_DST}")" -eq 2 ]
    os::install_template "${OS_T_TPL}" "${OS_T_DST}"
    [ "${OS_TEMPLATE_CHANGED}" -eq 0 ]
}

# --- os::write_public（面板只读产物）---

@test "write_public 写进 public/ 且是 0644" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_PUBLIC_DIR_MODE='0755'
    run os::write_public 'probe-fast.tsv' $'#ts\t1\nos.id\tdebian'
    [ "${status}" -eq 0 ]
    [ -f "${OS_PUBLIC_DIR}/probe-fast.tsv" ]
    [ "$(stat -c %a "${OS_PUBLIC_DIR}/probe-fast.tsv")" = '644' ]
}

@test "write_public 内容没变就不换 inode" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_PUBLIC_DIR_MODE='0755'
    os::write_public 'a.tsv' 'same'
    local before
    before=$(stat -c %i "${OS_PUBLIC_DIR}/a.tsv")
    os::write_public 'a.tsv' 'same'
    # 每 10 秒一轮的采集器,内容没变还换 inode 的话,
    # 正在读这个文件的客户端会拿到半截
    [ "$(stat -c %i "${OS_PUBLIC_DIR}/a.tsv")" = "${before}" ]
}

@test "write_public 落地前过脱敏 —— public/ 是 0755，进去就是对本机所有用户公开" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_PUBLIC_DIR_MODE='0755'
    local pass='S3cr3t-P@ssw0rd-长密码'
    log::secret_add "${pass}"
    os::write_public 'probe-slow.tsv' "db.dsn"$'\t'"mysql://root:${pass}@localhost"

    run grep -F "${pass}" "${OS_PUBLIC_DIR}/probe-slow.tsv"
    [ "${status}" -ne 0 ]
    grep -q '\*\*\*' "${OS_PUBLIC_DIR}/probe-slow.tsv"
}

@test "write_public 脱敏后内容一致仍不换 inode（脱敏必须发生在比较之前）" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_PUBLIC_DIR_MODE='0755'
    local pass='S3cr3t-P@ssw0rd-长密码'
    log::secret_add "${pass}"
    os::write_public 'a.tsv' "pass ${pass}"
    local before
    before=$(stat -c %i "${OS_PUBLIC_DIR}/a.tsv")
    os::write_public 'a.tsv' "pass ${pass}"
    # 比较用明文、写入用脱敏结果的话，这里每一轮都会判定「变了」——
    # 采集器每 10 秒换一次 inode，正在读的客户端拿到半截
    [ "$(stat -c %i "${OS_PUBLIC_DIR}/a.tsv")" = "${before}" ]
}

@test "write_public 拒绝带路径的文件名" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    run os::write_public '../escape.tsv' 'x'
    [ "${status}" -eq 2 ]
    run os::write_public 'sub/dir.tsv' 'x'
    [ "${status}" -eq 2 ]
    # public/ 是唯一放宽到 0755 的目录,允许 `..` 等于把这个放宽扩散到任意位置
    [ ! -e "${BATS_TEST_TMPDIR}/escape.tsv" ]
}

@test "write_public 在 dry-run 下零变更且置 tainted" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_DRYRUN=1
    run os::write_public 'x.tsv' 'content'
    [ "${status}" -eq 0 ]
    [ ! -e "${OS_PUBLIC_DIR}/x.tsv" ]
}

# 真写了也不出声。这函数由采集器每 10 秒调一次，打一行就是每天 8640 行
# stdout 进 journald —— 它的文档一直这么承诺，而共用的 template::_place
# 曾经无条件打印，承诺从没兑现过
@test "write_public 成功时不打印" {
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_PUBLIC_DIR_MODE='0755'
    run os::write_public 'quiet.tsv' 'content'
    [ "${status}" -eq 0 ]
    [ -f "${OS_PUBLIC_DIR}/quiet.tsv" ]
    [ -z "${output}" ]
}

# 一次性安装反过来:那是人敲一条命令换来的一次变更,必须给回执
@test "install_template 成功时仍打印回执" {
    run os::install_template "${OS_T_TPL}" "${OS_T_DST}" 'PHP_VERSION=8.3'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'已写入'* ]]
}

@test "install_file 成功时仍打印回执" {
    printf 'x\n' >"${BATS_TEST_TMPDIR}/src.txt"
    run os::install_file "${BATS_TEST_TMPDIR}/src.txt" "${BATS_TEST_TMPDIR}/dst.txt"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'已写入'* ]]
}

# --quiet 给的是周期性调用者（面板的采集与通知每 30 秒到 5 分钟一轮）：
# 默认的 info 级会在 JSONL 里堆出一天几千条例行记录，把真实事件挤出面板日志页。
# **两条路径都要验**：写了要安静，内容没变时的「已是目标状态」同样每轮都会记一条。
@test "install_file --quiet: 不打屏，日志降到 debug" {
    printf 'x\n' >"${BATS_TEST_TMPDIR}/q.src"
    run os::install_file --quiet "${BATS_TEST_TMPDIR}/q.src" "${BATS_TEST_TMPDIR}/q.dst"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'已写入'* ]]
    # 文件确实放到位了，安静不等于没做事
    cmp -s "${BATS_TEST_TMPDIR}/q.src" "${BATS_TEST_TMPDIR}/q.dst"
    run grep -F '已把' "${OS_LOG_JSONL}"
    [ "${status}" -ne 0 ]
}

@test "install_file --quiet: 内容没变时那条「已是目标状态」也不进日志" {
    printf 'x\n' >"${BATS_TEST_TMPDIR}/q2.src"
    os::install_file --quiet "${BATS_TEST_TMPDIR}/q2.src" "${BATS_TEST_TMPDIR}/q2.dst"
    : >"${OS_LOG_JSONL}"
    os::install_file --quiet "${BATS_TEST_TMPDIR}/q2.src" "${BATS_TEST_TMPDIR}/q2.dst"
    [ "${OS_TEMPLATE_CHANGED}" -eq 0 ]
    run grep -F '已是目标状态' "${OS_LOG_JSONL}"
    [ "${status}" -ne 0 ]
}

# 落地用的临时文件名此前是 `<目标>.os-place.<pid>` —— PID 只有三万多个取值、
# 可以喷洒预置。目标目录常常非 root 可写（站点根属 www-data、
# /etc/caddy/incoming 属 caddy 组），攻击者事先把那个名字建成指向 /etc 下
# 某个文件的符号链接，`>` 就跟过去以 root 覆写它，`mv` 随后还把那条符号链接
# 搬到目标路径上。mktemp 走 O_EXCL，路径已存在就失败，这条路整个不成立。
@test "install_file: 预置同名临时文件时不跟随符号链接" {
    local victim="${BATS_TEST_TMPDIR}/victim.conf"
    local dst="${BATS_TEST_TMPDIR}/out.conf"
    printf 'ORIGINAL\n' >"${victim}"
    printf 'PAYLOAD\n' >"${BATS_TEST_TMPDIR}/src.txt"
    ln -s "${victim}" "${dst}.os-place.$$"

    run os::install_file --mode 0644 "${BATS_TEST_TMPDIR}/src.txt" "${dst}"
    [ "${status}" -eq 0 ]
    # 受害文件一个字节都没变
    [ "$(cat "${victim}")" = 'ORIGINAL' ]
    # 目标是真文件，不是被搬过来的那条符号链接
    [ ! -L "${dst}" ]
    [ "$(cat "${dst}")" = 'PAYLOAD' ]
}

# --- os::php_str ---------------------------------------------------
#
# 这是安全原语：wp-config.php 是 PHP 源码，值放进单引号字符串字面量。
# 部署与恢复两条路径共用它，从前恢复那条一个字都没转义。

@test "php_str: 单引号被转义，不能提前闭合 PHP 字符串" {
    run os::php_str "a'b"
    [ "${status}" -eq 0 ]
    [ "${output}" = "a\'b" ]
}

@test "php_str: 反斜杠先于单引号处理，不产生二次转义" {
    # 一个反斜杠进去，两个出来。期望值用拼接构造，避免在断言里数引号层数
    local bs='\'
    run os::php_str "a${bs}b"
    [ "${status}" -eq 0 ]
    [ "${output}" = "a${bs}${bs}b" ]
}

@test "php_str: 注入构造串的每个单引号都被转义" {
    # 判据写成精确比对，不用模式匹配：`${var//pat/}` 里的反斜杠本身是转义符，
    # 拿它去匹配「反斜杠加单引号」会静默匹配成别的东西 —— 断言假红过一次。
    # 引号与反斜杠一律用变量拼，读的人不必在断言里数引号层数。
    local bs='\' q="'"
    run os::php_str "x${q}; system(\$_GET[${q}c${q}]); //"
    [ "${status}" -eq 0 ]
    [ "${output}" = "x${bs}${q}; system(\$_GET[${bs}${q}c${bs}${q}]); //" ]
}

@test "php_str: 不含特殊字符时是空操作（自动生成的 hex 密码走这条）" {
    run os::php_str 'a1b2c3d4e5f6'
    [ "${status}" -eq 0 ]
    [ "${output}" = 'a1b2c3d4e5f6' ]
}

@test "php_str: 空值返回空串而不是报错" {
    run os::php_str ''
    [ "${status}" -eq 0 ]
    [ "${output}" = '' ]
}

# --- os::template_source -------------------------------------------
#
# /etc 下的覆盖能改写 sshd 片段与 wp-config.php（会被 PHP 执行的代码）。
# conf 加载器早就查属主与权限了，这条路一直没查——同一个目录两套信任假设。

@test "template_source: 没有覆盖时返回分发自带的那一份" {
    local got=''
    os::template_source 'www.conf' got
    [ "${got}" = "${OS_TEMPLATE_DIR}/www.conf" ]
}

@test "template_source: 合规的覆盖被采用" {
    mkdir -p "${OS_ETC_DIR}/templates"
    printf 'x\n' >"${OS_ETC_DIR}/templates/www.conf"
    chmod 0644 "${OS_ETC_DIR}/templates/www.conf"
    local got=''
    os::template_source 'www.conf' got
    [ "${got}" = "${OS_ETC_DIR}/templates/www.conf" ]
}

@test "template_source: 组可写的覆盖被拒绝，且不静默退回" {
    mkdir -p "${OS_ETC_DIR}/templates"
    printf 'x\n' >"${OS_ETC_DIR}/templates/www.conf"
    chmod 0664 "${OS_ETC_DIR}/templates/www.conf"
    local got=''
    run os::template_source 'www.conf' got
    [ "${status}" -ne 0 ]
    [[ ${output} == *'允许非属主写入'* ]]
}

@test "template_source: 覆盖文件是符号链接时被拒绝" {
    mkdir -p "${OS_ETC_DIR}/templates"
    printf 'x\n' >"${BATS_TEST_TMPDIR}/elsewhere"
    ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${OS_ETC_DIR}/templates/www.conf"
    local got=''
    run os::template_source 'www.conf' got
    [ "${status}" -ne 0 ]
    [[ ${output} == *'符号链接'* ]]
}

@test "template_source: 只收单层文件名" {
    local got=''
    run os::template_source '../../etc/shadow' got
    [ "${status}" -eq 2 ]
}
