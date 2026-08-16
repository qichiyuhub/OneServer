#!/usr/bin/env bats
#
# packaging/updater.sh 的行为测试
#
# 切换器是全项目唯一允许违反规范的代码，代价是它必须完全自包含 —— 而这也
# 意味着**它的正确性没有任何框架能兜底**：lint 只查它有没有引用 lib，
# 查不出它换错了目录、回滚漏了一个、或者顺手删掉了用户的凭据库。
#
# 它干的又恰恰是最不能出错的事：替换自己脚下那棵树，失败时把系统退回上一版。
# 而这条路径在真实更新里几乎不走 —— 自检通常是过的，回滚分支只在
# 「新版本恰好坏了」的那一次执行，也就是最不该再出第二个问题的时刻。
#
# 所以这里不测「更新能不能成」，测的是**坏掉的时候会怎样**：自检不过、
# 暂存区残缺、没有可回滚的上一版。假的 bin/oneserver 用退出码驱动这些分支。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    UPDATER="${OS_TEST_REPO_ROOT}/packaging/updater.sh"
    ROOT="${BATS_TEST_TMPDIR}/opt"
    STAGING="${ROOT}/.staging"
}

# 切换覆盖的五个顶层目录，与切换器的 TOP_ORDER 一致
os_tops() { printf '%s\n' lib templates packaging script bin; }

# 造一棵「已装好的」树：五个目录各放一个标记文件，外加运行时数据。
# 运行时数据是重点 —— 它们与被替换的目录同在一个父目录下，
# 而切换器绝不该碰它们（state 是卸载依据，secure.conf 是这台机器的全部密码）
os_mk_root() {
    local top
    while read -r top; do
        mkdir -p "${ROOT}/${top}"
        printf 'old\n' >"${ROOT}/${top}/mark"
    done < <(os_tops)
    printf '1.0.0\n' >"${ROOT}/VERSION"
    # 根级脚本也在清单里、也由切换器替换（TOP_FILES）。从前它们一次都没被换过，
    # 于是更新完 README 指的那条卸载入口跑的是旧脚本配新 lib
    printf 'old\n' >"${ROOT}/install.sh"
    printf 'old\n' >"${ROOT}/uninstall.sh"
    mkdir -p "${ROOT}/state"
    printf 'caddy\tinstalled\n' >"${ROOT}/state/components.tsv"
    printf 'db.password=s3cret\n' >"${ROOT}/secure.conf"
}

# 造暂存区。$1 = 假 oneserver 自检的退出码；$2… = 要故意漏掉的顶层目录
os_mk_staging() {
    local rc=${1}
    shift || true
    local skip=" $* " top
    while read -r top; do
        [[ ${skip} == *" ${top} "* ]] && continue
        mkdir -p "${STAGING}/${top}"
        printf 'new\n' >"${STAGING}/${top}/mark"
    done < <(os_tops)
    printf '2.0.0\n' >"${STAGING}/VERSION"
    printf 'new\n' >"${STAGING}/install.sh"
    printf 'new\n' >"${STAGING}/uninstall.sh"
    if [[ -d "${STAGING}/bin" ]]; then
        printf '#!/bin/bash\nexit %s\n' "${rc}" >"${STAGING}/bin/oneserver"
        chmod 0755 "${STAGING}/bin/oneserver"
    fi
}

os_marks_are() {
    local want=${1} top
    while read -r top; do
        [[ "$(cat "${ROOT}/${top}/mark")" == "${want}" ]] || return 1
    done < <(os_tops)
    return 0
}

# --- 切换成功 -----------------------------------------------------

@test "switch: 五个顶层目录全部换成新版，VERSION 跟着走" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}" --version=2.0.0
    [ "${status}" -eq 0 ]
    os_marks_are new
    [ "$(cat "${ROOT}/VERSION")" = '2.0.0' ]
}

@test "switch: 成功之后不留 .old、.staging 与进行中标记" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.staging" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "switch: 运行时数据一个字节都不动" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ROOT}/state/components.tsv")" = "$(printf 'caddy\tinstalled')" ]
    [ "$(cat "${ROOT}/secure.conf")" = 'db.password=s3cret' ]
}

@test "switch: umask 收紧过的分发目录上线前统一校正为 0755" {
    os_mk_root
    os_mk_staging 0
    local top
    while read -r top; do
        mkdir -p "${STAGING}/${top}/nested"
        chmod 0750 "${STAGING}/${top}" "${STAGING}/${top}/nested"
    done < <(os_tops)

    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    while read -r top; do
        [ "$(stat -c %a "${ROOT}/${top}")" = '755' ]
        [ "$(stat -c %a "${ROOT}/${top}/nested")" = '755' ]
    done < <(os_tops)
    # 运行时目录不属于分发树，仍保持最小权限
    [ "$(stat -c %a "${ROOT}/data")" = '750' ]
}

@test "switch: 老版本没有 data 时在切换前建成 root:root 0750" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ -d "${ROOT}/data" ]
    [ "$(stat -c %a "${ROOT}/data")" = '750' ]
    [ "$(stat -c %U:%G "${ROOT}/data")" = 'root:root' ]
}

@test "switch: 既有 data 内容保留并校正权限" {
    os_mk_root
    mkdir -p "${ROOT}/data"
    printf 'history\n' >"${ROOT}/data/history.tsv"
    chmod 0777 "${ROOT}/data"
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ROOT}/data/history.tsv")" = 'history' ]
    [ "$(stat -c %a "${ROOT}/data")" = '750' ]
}

@test "switch: data 被文件占用时在任何目录切换前失败" {
    os_mk_root
    printf 'blocker\n' >"${ROOT}/data"
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'不是目录'* ]]
    os_marks_are old
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

# --- 自检不过就地回滚 ---------------------------------------------
#
# 规范承诺「自检失败就地回滚并以非零码退出」。这是整条更新链上唯一
# 「系统已经被改过了」的失败分支，它没走对的后果是机器停在半新半旧的状态。

@test "switch: 自检不过时全部退回上一版并以非零码退出" {
    os_mk_root
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}" --version=2.0.0
    [ "${status}" -ne 0 ]
    os_marks_are old
    [ "$(cat "${ROOT}/VERSION")" = '1.0.0' ]
}

@test "switch: 回滚之后同样不留 .old 与进行中标记" {
    os_mk_root
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "switch: 回滚不碰运行时数据" {
    os_mk_root
    mkdir -p "${ROOT}/data"
    printf 'history\n' >"${ROOT}/data/history.tsv"
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [ "$(cat "${ROOT}/secure.conf")" = 'db.password=s3cret' ]
    [ -f "${ROOT}/state/components.tsv" ]
    [ "$(cat "${ROOT}/data/history.tsv")" = 'history' ]
}

# --- 暂存区残缺：一步都不许迈 -------------------------------------

@test "switch: 暂存区缺一个顶层目录就什么都不换" {
    os_mk_root
    os_mk_staging 0 script
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *script* ]]
    os_marks_are old
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "switch: 暂存区缺 VERSION 同样拒绝动手" {
    os_mk_root
    os_mk_staging 0
    rm -f "${STAGING}/VERSION"
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    os_marks_are old
}

@test "switch: 暂存区根本不在时以退出码 2 拒绝" {
    os_mk_root
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${ROOT}/nope"
    [ "${status}" -eq 2 ]
    os_marks_are old
}

# --- rollback 子命令 ----------------------------------------------

@test "rollback: 把 .old 里的上一版放回去" {
    os_mk_root
    os_mk_staging 0
    # 先切过去，再手工把上一版摆回 .old —— 切换成功后 .old 会被清掉，
    # 而 `oneserver update rollback` 面对的正是「上一次切换留下的 .old」
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    local top
    mkdir -p "${ROOT}/.old"
    while read -r top; do
        mkdir -p "${ROOT}/.old/${top}"
        printf 'old\n' >"${ROOT}/.old/${top}/mark"
    done < <(os_tops)
    printf '1.0.0\n' >"${ROOT}/.old/VERSION"

    run bash "${UPDATER}" rollback --root="${ROOT}"
    [ "${status}" -eq 0 ]
    os_marks_are old
    [ "$(cat "${ROOT}/VERSION")" = '1.0.0' ]
    [ ! -e "${ROOT}/.old" ]
    [ ! -e "${ROOT}/.update-in-progress" ]
}

@test "rollback: 没有上一版时以退出码 2 拒绝，不动现有的树" {
    os_mk_root
    run bash "${UPDATER}" rollback --root="${ROOT}"
    [ "${status}" -eq 2 ]
    os_marks_are old
}

# --- 参数 ---------------------------------------------------------

@test "参数: 根目录不存在时以退出码 2 拒绝" {
    run bash "${UPDATER}" switch --root="${BATS_TEST_TMPDIR}/nowhere" --staging="${BATS_TEST_TMPDIR}/s"
    [ "${status}" -eq 2 ]
}

@test "参数: 不认识的参数以退出码 2 拒绝" {
    os_mk_root
    run bash "${UPDATER}" switch --root="${ROOT}" --wat=1
    [ "${status}" -eq 2 ]
}

@test "参数: 不认识的动作以退出码 2 拒绝并打出用法" {
    os_mk_root
    run bash "${UPDATER}" frobnicate --root="${ROOT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *用法* ]]
}

# --- 根级文件：清单覆盖它们，切换就必须换它们 --------------------
#
# 从前只换五个顶层目录 + VERSION，install.sh / uninstall.sh 一次都没被换过。
# 现场表现是任何一次 update 之后，README 指的那条卸载入口
# （bash /opt/oneserver/uninstall.sh）跑的都是旧脚本配新 lib。

@test "switch: 根级脚本跟着一起换成新版" {
    os_mk_root
    os_mk_staging 0
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ROOT}/install.sh")" = 'new' ]
    [ "$(cat "${ROOT}/uninstall.sh")" = 'new' ]
}

@test "switch: 暂存区缺 uninstall.sh 就什么都不换" {
    os_mk_root
    os_mk_staging 0
    rm -f "${STAGING}/uninstall.sh"
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    os_marks_are old
    [ "$(cat "${ROOT}/install.sh")" = 'old' ]
}

@test "switch: 自检不过时根级脚本一并退回上一版" {
    os_mk_root
    os_mk_staging 1
    run bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}"
    [ "${status}" -ne 0 ]
    [ "$(cat "${ROOT}/install.sh")" = 'old' ]
    [ "$(cat "${ROOT}/uninstall.sh")" = 'old' ]
    [ "$(cat "${ROOT}/VERSION")" = '1.0.0' ]
}

@test "rollback: 根级脚本从 .old 放回去" {
    os_mk_root
    os_mk_staging 0
    bash "${UPDATER}" switch --root="${ROOT}" --staging="${STAGING}" >/dev/null 2>&1 || true
    printf 'new\n' >"${ROOT}/uninstall.sh"
    mkdir -p "${ROOT}/.old"
    printf 'old\n' >"${ROOT}/.old/uninstall.sh"
    run bash "${UPDATER}" rollback --root="${ROOT}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ROOT}/uninstall.sh")" = 'old' ]
}
