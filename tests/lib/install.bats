#!/usr/bin/env bats
#
# install.sh 的清单解析与校验测试
#
# 安装器与切换器一样是自包含的例外代码，同样没有框架给它兜底。它处理的
# **清单是从网上取来的**：manifest 自己没有任何校验（SHA256 提供的是
# 完整性，不是真实性），所以清单里的每一个字段都是不可信输入，而它决定的是
# 「以 root 往哪些路径写哪些文件」。`../../etc/shadow` 这种路径必须死在
# 解析这一步，不能指望生成器把过关。
#
# 这里不跑真正的安装（那要 root、要网络、要动 /opt/oneserver），只把
# install.sh 的函数装进子 shell 单独喂输入 —— 清单解析、哈希校验、
# 幂等与孤儿清理，四段逻辑各自都能在临时目录里完整走一遍。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"

    # install.sh 以 `main "$@"` 收尾，剥掉这一行才能把它的函数 source 出来。
    # **先断言它确实是最后一行**：这份副本与真文件只允许差这一行，
    # 哪天入口改了写法，这里要当场失败，而不是安静地测一个别的东西
    [ "$(tail -n 1 "${OS_TEST_REPO_ROOT}/install.sh")" = 'main "$@"' ]
    STUB="${BATS_TEST_TMPDIR}/install-stub.sh"
    sed '$d' "${OS_TEST_REPO_ROOT}/install.sh" >"${STUB}"

    ROOT="${BATS_TEST_TMPDIR}/opt"
    STAGING="${BATS_TEST_TMPDIR}/staging"
    mkdir -p "${STAGING}/src"
}

# 在子 shell 里装好 install.sh 的函数，**把它认识的每一个系统路径都改指到
# 临时目录**再执行。少改一个的后果是跑一次测试就在开发机 / CI 上真的建出
# /etc/oneserver 与 /var/log/oneserver —— 单元测试不该在机器上留下任何东西。
#
# 用例里也因此不调 setup_dirs：它 chown root:root，非 root 跑当场失败，
# 而 place_files 自己会按需建目录，测这几段逻辑并不需要它。
os_install_run() {
    run bash -c "
        source '${STUB}'
        # install.sh 的 EXIT trap 会把 STAGING 整个删掉（真实安装里那是收尾清理）。
        # 一个用例里调它两次时，第一次退出就把源码与清单一起带走了，
        # 第二次拿到的是「文件不在」——而要测的恰恰是「第二次执行零变更」
        trap - EXIT
        ROOT='${ROOT}'
        STAGING='${STAGING}'
        ETC_DIR='${BATS_TEST_TMPDIR}/etc'
        LOG_DIR='${BATS_TEST_TMPDIR}/log'
        BACKUP_DIR='${BATS_TEST_TMPDIR}/backup'
        BIN_LINKS='${BATS_TEST_TMPDIR}/usrbin'
        COMPLETION_DIR='${BATS_TEST_TMPDIR}/completion'
        LOGROTATE_DIR='${BATS_TEST_TMPDIR}/logrotate'
        $1
    "
}

readonly OS_MF_COMMIT='0123456789abcdef0123456789abcdef01234567'

@test "平台边界接受全部 Debian 与 Ubuntu 版本" {
    os_install_run "
        platform_supported debian 8
        platform_supported debian 13
        platform_supported ubuntu 18.04
        platform_supported ubuntu 24.04
        ! platform_supported alpine 3.22
        ! platform_supported '' ''
    "
    [ "${status}" -eq 0 ]
}

os_mf_head() {
    printf 'schema\t1\nversion\t9.9.9\ncommit\t%s\ngenerated\t1700000000\n' "${OS_MF_COMMIT}"
}

# 造源码树 + 与之匹配的清单
os_mk_src() {
    mkdir -p "${STAGING}/src/bin" "${STAGING}/src/lib"
    printf 'entry\n' >"${STAGING}/src/bin/oneserver"
    printf 'paths\n' >"${STAGING}/src/lib/paths.sh"
    printf '9.9.9\n' >"${STAGING}/src/VERSION"

    local rel sum
    {
        os_mf_head
        for rel in bin/oneserver lib/paths.sh VERSION; do
            sum=$(sha256sum "${STAGING}/src/${rel}")
            printf 'file\t%s\t0644\t%s\n' "${sum%% *}" "${rel}"
        done
    } >"${STAGING}/manifest.txt"
}

# 一行 file 记录 + 合法头部，用于喂坏输入
os_mf_with() {
    {
        os_mf_head
        printf '%b\n' "${1}"
    } >"${STAGING}/manifest.txt"
}

# --- 清单解析：合法输入 -------------------------------------------

@test "parse: 合法清单解析出版本、commit 与文件数" {
    os_mk_src
    os_install_run "parse_manifest '${STAGING}/manifest.txt'
        printf '%s|%s|%s\n' \"\${MF_VERSION}\" \"\${MF_COMMIT}\" \"\${#MF_PATH[@]}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"9.9.9|${OS_MF_COMMIT}|3"* ]]
}

@test "parse: 不认识的字段只告警不失败（旧版本要读得懂新清单）" {
    {
        os_mf_head
        printf 'signature\tdeadbeef\n'
        printf 'file\t%s\t0644\tbin/oneserver\n' "$(printf 'a%.0s' $(seq 64))"
    } >"${STAGING}/manifest.txt"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; echo done"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *不认识* ]]
    [[ "${output}" == *done* ]]
}

# --- 清单解析：不可信输入 -----------------------------------------
#
# 清单来自网络，下面每一条都是「生成器不会产出、但攻击者会写」的形态。

@test "parse: 路径里有 .. 的行被拒绝" {
    os_mf_with "file\t$(printf 'a%.0s' $(seq 64))\t0644\t../../etc/shadow"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *路径不合法* ]]
}

@test "parse: 绝对路径被拒绝" {
    os_mf_with "file\t$(printf 'a%.0s' $(seq 64))\t0644\t/etc/shadow"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *路径不合法* ]]
}

@test "parse: 路径含空白被拒绝" {
    os_mf_with "file\t$(printf 'a%.0s' $(seq 64))\t0644\tbin/one server"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *路径不合法* ]]
}

@test "parse: 哈希不是 64 位十六进制被拒绝" {
    os_mf_with 'file\tnothash\t0644\tbin/oneserver'
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *哈希不合法* ]]
}

@test "parse: 权限不是 0nnn 被拒绝" {
    os_mf_with "file\t$(printf 'a%.0s' $(seq 64))\t755\tbin/oneserver"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *权限不合法* ]]
}

@test "parse: 字段缺一列被拒绝（空字段会让后面的字段整体左移）" {
    os_mf_with "file\t$(printf 'a%.0s' $(seq 64))\t0644"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *字段不全* ]]
}

@test "parse: schema 不是 1 被拒绝" {
    {
        printf 'schema\t2\nversion\t9.9.9\ncommit\t%s\n' "${OS_MF_COMMIT}"
        printf 'file\t%s\t0644\tbin/oneserver\n' "$(printf 'a%.0s' $(seq 64))"
    } >"${STAGING}/manifest.txt"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *读不了* ]]
}

@test "parse: commit 不是 40 位十六进制被拒绝" {
    {
        printf 'schema\t1\nversion\t9.9.9\ncommit\tmain\n'
        printf 'file\t%s\t0644\tbin/oneserver\n' "$(printf 'a%.0s' $(seq 64))"
    } >"${STAGING}/manifest.txt"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *commit* ]]
}

@test "parse: 一个 file 行都没有的清单被拒绝" {
    os_mf_head >"${STAGING}/manifest.txt"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *一个文件都没有* ]]
}

# --- 哈希校验 -----------------------------------------------------

@test "verify: 全部对得上时通过" {
    os_mk_src
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; verify_source"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *全部文件校验通过* ]]
}

@test "verify: 一个文件对不上就整个拒绝，什么都没有安装" {
    os_mk_src
    printf 'tampered\n' >"${STAGING}/src/lib/paths.sh"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; verify_source"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *什么都没有安装* ]]
    [ ! -e "${ROOT}/lib" ]
    [ ! -e "${ROOT}/bin" ]
}

@test "verify: 清单里有、包里没有的文件同样拒绝" {
    os_mk_src
    rm -f "${STAGING}/src/lib/paths.sh"
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; verify_source"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *清单里有* ]]
}

# --- 落地与幂等 ---------------------------------------------------

@test "place: 第二次执行零变更（不变量 6）" {
    os_mk_src
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; place_files"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"3 个更新"* ]]

    os_install_run "parse_manifest '${STAGING}/manifest.txt'; place_files"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"0 个更新 · 3 个已是目标状态"* ]]
}

@test "place: 按清单落的权限就是清单里写的那个" {
    os_mk_src
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; place_files"
    [ "${status}" -eq 0 ]
    [ "$(stat -c '%a' "${ROOT}/bin/oneserver")" = '644' ]
}

# --- 孤儿清理 -----------------------------------------------------
#
# 上一版有、这一版没有的文件必须删掉：一个被删掉的旧脚本仍然带着 @command，
# 注册表照样扫得到它，用户就在菜单里看见一条本版本已经不存在的命令。
#
# 而运行时数据与它们同在一个父目录下 —— 清理时多扫一层，删掉的就是
# 这台机器上所有组件的登记和全部自动生成的密码。

@test "orphans: 清掉不属于本版本的文件" {
    os_mk_src
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; place_files"
    [ "${status}" -eq 0 ]
    printf 'stale\n' >"${ROOT}/lib/gone.sh"

    os_install_run "parse_manifest '${STAGING}/manifest.txt'; remove_orphans"
    [ "${status}" -eq 0 ]
    [ ! -e "${ROOT}/lib/gone.sh" ]
    [ -f "${ROOT}/lib/paths.sh" ]
}

@test "orphans: 不碰 state/ 与 secure.conf" {
    os_mk_src
    os_install_run "parse_manifest '${STAGING}/manifest.txt'; place_files"
    [ "${status}" -eq 0 ]
    mkdir -p "${ROOT}/state"
    printf 'caddy\tinstalled\n' >"${ROOT}/state/components.tsv"
    printf 'db.password=s3cret\n' >"${ROOT}/secure.conf"

    os_install_run "parse_manifest '${STAGING}/manifest.txt'; remove_orphans"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ROOT}/secure.conf")" = 'db.password=s3cret' ]
    [ -f "${ROOT}/state/components.tsv" ]
}

# 面板数据在 /run/oneserver-public（tmpfs）。早先的版本在程序目录下也建过一个
# 同名目录，没有任何东西往里写 —— 装过那些版本的机器会一直留着一个空的
# 全局可读目录，而 remove_orphans 扫不到它（不在 OWNED_TOP 里）
@test "dirs: 不再建 public/，并收掉旧版本留下的空壳" {
    mkdir -p "${ROOT}/public"
    os_install_run 'setup_dirs'
    [ "${status}" -eq 0 ]
    [ ! -e "${ROOT}/public" ]
    [ -d "${ROOT}/state" ]
}

@test "dirs: 旧 public/ 里有东西时不动它（那是用户的文件）" {
    mkdir -p "${ROOT}/public"
    printf 'mine\n' >"${ROOT}/public/keep.txt"
    os_install_run 'setup_dirs'
    [ "${status}" -eq 0 ]
    [ -f "${ROOT}/public/keep.txt" ]
}

# --- 参数 ---------------------------------------------------------

@test "参数: 不认识的选项以退出码 2 拒绝" {
    os_install_run "parse_args --frobnicate"
    [ "${status}" -eq 2 ]
}

@test "参数: 明文 http:// 的清单地址被拒绝（它是整条信任链的锚点）" {
    os_install_run "MANIFEST_SRC='http://example.com/manifest.txt'; obtain_manifest"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *明文* ]]
}
