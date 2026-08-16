#!/usr/bin/env bash
#
# 开发机侧：把当前工作区送到测试机，供 `dev-update.sh local` 安装
#
#   bash tests/dev-sync.sh [测试机]
#
# 测试机缺省取 $TESTENV_HOST，再缺省是 tests/testenv.sh 里的默认值。
#
# 它只做两件事：生成清单、同步工作区。**顺序不能反，也不能只做后者** ——
# 同步用 tar 且排除 `.git`，测试机上不是 git 仓库，清单只能在这边生成后
# 一起传过去。漏了这一步的现象是测试机报「manifest.txt 不在」，而人在
# 另一台机器上，排查要绕一圈。收成一条命令就是为了让它漏不掉。
#
# 开发期专用，不随分发落地。

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

die() {
    printf 'dev-sync: 错误: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\ndev-sync: === %s ===\n' "$*"
}

main() {
    local host=${1:-${TESTENV_HOST:-}}

    cd "${REPO_ROOT}" || die "进不去 ${REPO_ROOT}"

    # 测试必须基于一个提交。工作区脏着同步会踩两个坑：新增文件没 `git add`
    # 就不进清单（文件在磁盘上，装完却没有它，而清单里压根没列）；清单的
    # commit 字段记的是 HEAD，与实际内容对不上，那份清单从此无法复现。
    # 提交一次两个都没了 —— 迭代中不想攒 wip 提交就 `git commit --amend`
    step '检查工作区'
    local dirty=''
    dirty=$(git status --porcelain) || die '取不到 git 状态'
    if [[ -n ${dirty} ]]; then
        printf '%s\n' "${dirty}" >&2
        die '工作区有未提交的改动 —— 先 git commit 再同步'
    fi
    printf 'dev-sync: 干净，HEAD 是 %s\n' "$(git rev-parse --short HEAD)"

    step '生成清单'
    bash packaging/make-manifest.sh || die '生成清单失败'

    step '同步工作区'
    if [[ -n ${host} ]]; then
        TESTENV_HOST=${host} bash tests/testenv.sh sync || die '同步失败'
    else
        bash tests/testenv.sh sync || die '同步失败'
    fi

    # 提示用完整路径而不是 `osup local`：全新的测试机上还没配过那个 alias，
    # 照着一句用不了的提示去敲，第一次上手就卡住
    local remote=${TESTENV_REMOTE_SRC:-/root/oneserver-src}
    printf '\ndev-sync: 完成 —— 到测试机上执行：\n'
    printf '  bash %s/tests/dev-update.sh local\n' "${remote}"
    printf '  （配过 alias 的话就是 osup local）\n'
}

main "$@"
