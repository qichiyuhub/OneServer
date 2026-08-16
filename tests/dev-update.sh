#!/usr/bin/env bash
#
# 测试机一键更新
#
#   bash dev-update.sh          从 GitHub 拉最新代码后安装（改动已推送时用）
#   bash dev-update.sh local    装已同步到本机的源码（改动还没推送时用）
#
# 两种模式的差别只在「源码从哪来」：
#
#   默认    /root/OneServer      git clone 的仓库，先 git pull 再生成清单
#   local   /root/oneserver-src  开发机用 `testenv.sh sync` 传过来的工作区，
#                                里面没有 .git，清单是开发机生成后一起传来的
#
# 开发期专用，不随分发落地 —— 清单只收 VERSION、install.sh 与
# bin/lib/script/templates/packaging，tests/ 不在其中。
#
# --- 为什么全部逻辑在 main 里、最后一行才调用 ---
#
# 默认模式第一步就是 `git pull`，而它可能改写的正是本文件自己。bash 是边读边
# 执行的，文件在执行途中变了，它会从旧偏移量继续读一份新内容 —— 以 root 执行
# 错乱的字节。把调用放在最后一行，bash 读到那里时整个文件已经进了缓冲区，
# 之后磁盘上怎么变都不影响这一次运行。

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly GIT_DIR_DEFAULT='/root/OneServer'
readonly SYNC_DIR='/root/oneserver-src'
readonly MANIFEST='/tmp/oneserver-dev-manifest.txt'

die() {
    printf 'dev-update: 错误: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\ndev-update: === %s ===\n' "$*"
}

# 两个 prepare_* 把结果写进这个变量，不用 `$( )` 返回 —— 它们中间要打印进度，
# 命令替换会把那些输出一起吞进变量里（同 lib/registry.sh 的「不打印，只写变量」）
SRC_DIR=''

# 从 git 仓库取源码：拉最新代码，就地生成清单
prepare_from_git() {
    local dir=${REPO_ROOT}
    # 本脚本可能是从同步目录跑起来的（那里没有 .git），这种情况下回退到
    # 约定的 clone 位置，而不是报「不是 git 仓库」让人自己猜
    [[ -d "${dir}/.git" ]] || dir=${GIT_DIR_DEFAULT}
    [[ -d "${dir}/.git" ]] || die "找不到 git 仓库（试过 ${REPO_ROOT} 和 ${GIT_DIR_DEFAULT}）"

    # make-manifest.sh 用 `git rev-parse --show-toplevel` 定位仓库，认的是
    # **当前目录**而不是它自己所在的目录。不先 cd 过去，从家目录调用它会得到
    # 「不在 git 仓库里」——而那时源码明明就在眼前
    cd "${dir}" || die "进不去 ${dir}"

    step '拉取最新代码'
    # --ff-only：测试机上不该产生合并提交。真出现分叉说明这台机器上有本地
    # 改动，那时候停下来让人看一眼，比默默合并出一棵谁也说不清的树要好
    git pull --ff-only || die 'git pull 失败'

    step '生成清单'
    bash packaging/make-manifest.sh "${MANIFEST}" || die '生成清单失败'

    SRC_DIR=${dir}
}

# 从同步目录取源码：清单是开发机生成后一起传来的，这里只做存在性检查
prepare_from_sync() {
    [[ -d ${SYNC_DIR} ]] || die "${SYNC_DIR} 不在 —— 需要先在开发机上执行 testenv.sh sync"
    [[ -f "${SYNC_DIR}/manifest.txt" ]] \
        || die "${SYNC_DIR}/manifest.txt 不在 —— 开发机同步前漏了 make-manifest.sh"

    step '使用已同步的源码'
    printf 'dev-update: 源码 %s\n' "${SYNC_DIR}"
    printf 'dev-update: 清单 %s（生成于开发机）\n' "${SYNC_DIR}/manifest.txt"

    cp -- "${SYNC_DIR}/manifest.txt" "${MANIFEST}" || die '复制不了清单'
    SRC_DIR=${SYNC_DIR}
}

main() {
    local mode=${1:-git}
    case ${mode} in
        git | local) ;;
        -h | --help)
            printf '用法: dev-update.sh [git|local]\n'
            printf '  git    （默认）从 GitHub 拉最新代码后安装\n'
            printf '  local  装 %s 里已同步的源码\n' "${SYNC_DIR}"
            return 0
            ;;
        *) die "不认识的模式「${mode}」，只能是 git 或 local" ;;
    esac

    [[ ${EUID:-$(id -u)} -eq 0 ]] || die '需要 root'

    if [[ ${mode} == local ]]; then
        prepare_from_sync
    else
        prepare_from_git
    fi

    step '安装'
    bash "${SRC_DIR}/install.sh" \
        --manifest="${MANIFEST}" \
        --from="${SRC_DIR}" \
        --yes || die '安装失败'

    step '自检'
    oneserver doctor --selftest || die '自检未通过'

    printf '\ndev-update: 完成 —— 敲 os 进菜单\n'
}

main "$@"
