#!/bin/bash
# os-contract: updater
#
# OneServer 更新切换器 ——规范的阶段 3 与 4
#
#   updater.sh switch   --root=<目录> --staging=<目录> [--version=<版本>]
#   updater.sh rollback --root=<目录>
#
# ==================================================================
# 这个文件为什么不许 source lib/，也不许调 os::*
# ==================================================================
#
# `oneserver update` 这个进程启动时已经把旧版本的 `lib/*.sh` **读进了内存**。
# 它随后要替换 `lib/`，此后它执行的是**旧版本的函数**、操作的是**新版本的布局** ——
# 而 `@requires_lib` 的存在本身就承认了新旧 lib 的接口会有差异，
# 所以这个组合的行为是未定义的。
#
# 切换器必须站在两个版本之外：只用 bash 内建与基础 coreutils，
# 不 source 任何东西、不调用任何 `os::*`。它是框架接口条款的自包含例外。
#
# 它还必须**先被复制到 $OS_ROOT 之外**（调用方复制到 /run/oneserver）再执行：
# 它要替换的正是自己所在的那棵树，留在原地等于在自己脚下抽地板 ——
# bash 会从旧偏移量继续读一个已经被换掉的文件（K13 的形态）。
#
# ==================================================================
# 切换是怎么做到「原子」的，以及它没做到的部分
# ==================================================================
#
# 每个顶层目录一次 `mv -T`（同一文件系统内的 rename，内核保证原子）：
#
#     <root>/bin       → <root>/.old/bin       （旧的挪走）
#     <root>/.staging/bin → <root>/bin         （新的换上）
#
# **单个目录的替换是原子的，五个目录的整体替换不是。** 在两次 rename 之间
# 被 SIGKILL / 掉电打断，会留下「新 lib + 旧 script」这种半截状态。
# 这一点无法用 rename 消除（除非把整棵树做成符号链接指向版本目录，
# 而那要求每个脚本头部的 `source /opt/oneserver/lib/bootstrap.sh` 跟着变 ——
# 那一行是规范逐字规定的）。
#
# 所以这里的做法是**让半截状态可被发现、可被修复**：
#   * 切换前写 `.update-in-progress` 标记，全部完成后删除
#   * 标记还在 = 上次没走完，`oneserver update` 下次开跑时看得见并明说
#   * `.old/` 一直留到自检通过之后才删，回滚随时有料
#   * 窗口本身是毫秒级的五次 rename，不含任何 I/O 等待
#
# 顺序也不是随手排的：**先换 lib，最后换 bin**。bin 是入口 ——
# 万一在中途断了，一个还没被换掉的旧入口配上新 lib，比一个新入口配上
# 半截的 lib 更可能起得来，也更可能让人再跑一次 update 把状态推完。

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 022

# 与 install.sh 的 OWNED_TOP 必须一致：清单覆盖哪些，切换就换哪些。
# 运行时数据（state/ secure.conf）不在其中，切换不碰它们。
TOP_ORDER=('lib' 'templates' 'packaging' 'script' 'bin')

# 清单还覆盖三个**根级文件**，它们不在任何目录里，此前一个都没被换过。
#
# 后果不是少了点什么：`install.sh` 会把它们放到 $ROOT 下，而更新只换那五个
# 目录 —— 于是任何一次 `oneserver update` 之后，README 指的那条卸载入口
# （`bash /opt/oneserver/uninstall.sh`）跑的都是**旧版脚本配新版 lib**。
# 更糟的是 update.sh 的 verify_staging 会把这三个文件也算进「全部文件校验
# 通过」，而它们一个字节都没上线 —— 报告与事实不符。
#
# VERSION 也在里面：它原来单独一段特判，与这三个文件做的是同一件事。
TOP_FILES=('VERSION' 'install.sh' 'uninstall.sh')

# 自检的墙钟上限（秒）。doctor --selftest 在真机上是几秒的事，
# 给到三分钟是留给「systemctl 卡在某个挂死的 unit 上」这类外部拖累。
SELFCHECK_TIMEOUT=180

ROOT=''
STAGING=''
VERSION=''
ACTION=''

log() { printf '[updater] %s\n' "${1}" >&2; }
die() {
    printf '[updater] 错误：%s\n' "${1}" >&2
    exit "${2:-1}"
}

parse_args() {
    ACTION=${1-}
    shift || true
    local a
    for a in "$@"; do
        case ${a} in
            --root=*) ROOT=${a#*=} ;;
            --staging=*) STAGING=${a#*=} ;;
            --version=*) VERSION=${a#*=} ;;
            *) die "不认识的参数：${a}" 2 ;;
        esac
    done
    [[ -n ${ROOT} ]] || die '缺 --root' 2
    [[ -d ${ROOT} ]] || die "根目录不存在：${ROOT}" 2
    return 0
}

# 把 <root>/<top> 挪进 .old，再把 .staging 里的换上。
# 每一步都是同目录内的 rename —— 跨文件系统的 mv 是「复制 + 删除」，不原子。
swap_in() {
    local top=${1}
    local live="${ROOT}/${top}"
    local new="${STAGING}/${top}"
    local old="${ROOT}/.old/${top}"

    [[ -e ${new} ]] || die "暂存区里没有 ${top}，拒绝换（半截的清单比不更新更危险）"

    if [[ -e ${live} ]]; then
        mv -T -- "${live}" "${old}" || die "挪不走 ${live}"
    fi
    mv -T -- "${new}" "${live}" || {
        # 这一步失败时上一版还在 .old 里，立刻放回去，别留下一个空洞
        if [[ -e ${old} ]]; then
            mv -T -- "${old}" "${live}" 2>/dev/null || true
        fi
        die "换不上 ${live}"
    }
    return 0
}

swap_back() {
    local top=${1}
    local live="${ROOT}/${top}"
    local old="${ROOT}/.old/${top}"
    [[ -e ${old} ]] || return 0
    # 回滚时**丢掉**换上去的那一版（它已经被判定为坏的），不再往回存一份
    [[ -e ${live} ]] && rm -rf -- "${live}"
    mv -T -- "${old}" "${live}" || die "回滚失败：放不回 ${live}"
    return 0
}

do_switch() {
    [[ -n ${STAGING} ]] || die '缺 --staging' 2
    [[ -d ${STAGING} ]] || die "暂存区不存在：${STAGING}" 2

    # 每一样都得在，否则不动手（部分替换正是最难查的那种坏法）
    local top
    for top in "${TOP_ORDER[@]}"; do
        [[ -e "${STAGING}/${top}" ]] || die "暂存区缺 ${top}，什么都没有替换"
    done
    local topf
    for topf in "${TOP_FILES[@]}"; do
        [[ -e "${STAGING}/${topf}" ]] || die "暂存区缺 ${topf}，什么都没有替换"
    done

    # update.sh 以 umask 027 解包并配合 tar --no-same-permissions。文件权限随后
    # 会按 manifest 校正，但 Git 不记录目录模式，目录此前会原样停在 0750。
    # 换上线后，Caddy 等非 root 服务连 templates/ 都无法遍历，面板的静态文件
    # 于是返回空 403。分发树只含程序与公开模板，目录统一为 0755；state/data
    # 不在 TOP_ORDER，仍严格保持 0750。
    for top in "${TOP_ORDER[@]}"; do
        find "${STAGING}/${top}" -type d -exec chmod 0755 -- {} + \
            || die "无法校正暂存区 ${top} 的目录权限"
    done

    # data/ 是跨版本保留的运行时状态，不在 TOP_ORDER 里。必须在第一次 rename
    # 之前保证它能被 unit 的 ReadWritePaths 使用；否则代码已经切换后才发现
    # 目录创建失败，会把机器留在「新版代码 + 不可用数据目录」的状态。
    [[ ! -L "${ROOT}/data" ]] || die "运行时数据目录不得是符号链接：${ROOT}/data"
    [[ ! -e "${ROOT}/data" || -d "${ROOT}/data" ]] || die "运行时数据路径不是目录：${ROOT}/data"
    mkdir -p -- "${ROOT}/data" || die "建不了 ${ROOT}/data"
    chown root:root -- "${ROOT}/data" || die "无法设置 ${ROOT}/data 的属主"
    chmod 0750 -- "${ROOT}/data" || die "无法设置 ${ROOT}/data 的权限"

    rm -rf -- "${ROOT}/.old"
    mkdir -p "${ROOT}/.old" || die "建不了 ${ROOT}/.old"

    : >"${ROOT}/.update-in-progress" || die '写不了进行中标记'

    log "开始切换到 ${VERSION:-新版本}"
    for top in "${TOP_ORDER[@]}"; do
        swap_in "${top}"
    done

    # 根级文件是文件不是目录，同样走「换 inode」而不是覆盖写。
    # 旧的先存进 .old/，回滚要靠它
    for topf in "${TOP_FILES[@]}"; do
        [[ -f "${STAGING}/${topf}" ]] || continue
        [[ -f "${ROOT}/${topf}" ]] && cp -- "${ROOT}/${topf}" "${ROOT}/.old/${topf}"
        mv -f -- "${STAGING}/${topf}" "${ROOT}/${topf}" || die "换不上 ${topf}"
    done

    rm -f -- "${ROOT}/.update-in-progress"
    log '目录已切换，开始自检'

    # --- 阶段 4：自检 ---
    #
    # **以子进程跑，不 exec**（规范的注）：exec 出去之后就没有任何
    # 进程还能撤销这次切换了，而本进程是唯一站在两个版本之外的那个。
    #
    # **必须有超时。** 自检跑的是刚换上去、还没被任何人验证过的那一版；
    # 它挂住的话（等一个永远不来的输入、卡在一次探测上）整条更新就永远停在
    # 「.old 还在、锁还握着」的状态，而这个进程正是唯一能把它推完或回滚的那个。
    # 超时按「自检挂了」处理，走下面同一条回滚路径。
    local -i rc=0
    timeout "${SELFCHECK_TIMEOUT}" "${ROOT}/bin/oneserver" doctor --selftest || rc=$?

    if ((rc == 0)); then
        rm -rf -- "${ROOT}/.old"
        rm -rf -- "${STAGING}"
        log "更新完成：${VERSION:-新版本}"
        return 0
    fi

    log "自检未通过（退出码 ${rc}），正在回滚"
    do_rollback
    die "已回滚到上一版；跨版本运行时数据按设计保留" 1
}

do_rollback() {
    [[ -d "${ROOT}/.old" ]] || die '没有 .old，无法回滚（可能上一次更新已经成功并清理过了）' 2

    : >"${ROOT}/.update-in-progress" || true
    # 回滚按切换的**逆序**：换上去时最后动的是 bin，放回去就先放 bin，
    # 让入口尽早回到与它匹配的那一版
    local -i i
    local top
    for ((i = ${#TOP_ORDER[@]} - 1; i >= 0; i--)); do
        top=${TOP_ORDER[i]}
        swap_back "${top}"
    done
    local topf
    for topf in "${TOP_FILES[@]}"; do
        if [[ -f "${ROOT}/.old/${topf}" ]]; then
            mv -f -- "${ROOT}/.old/${topf}" "${ROOT}/${topf}" || true
        fi
    done
    rm -rf -- "${ROOT}/.old"
    rm -rf -- "${ROOT}/.staging"
    rm -f -- "${ROOT}/.update-in-progress"
    log '已回滚到上一版'
    return 0
}

main() {
    parse_args "$@"
    case ${ACTION} in
        switch) do_switch ;;
        rollback) do_rollback ;;
        *) die "用法：updater.sh <switch|rollback> --root=<目录> [--staging=<目录>] [--version=<版本>]" 2 ;;
    esac
}

main "$@"
