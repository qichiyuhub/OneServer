#!/bin/bash
#
# 容器镜像
#
# @command      docker image
# @name         容器镜像
# @group        container
# @order        80
# @requires     docker
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<ls|pull|rm|prune>] [--image=<镜像>] [--refresh=<y|n>] [--confirm-rm=<镜像>] [--confirm-prune=<prune>]
# @description  列出、拉取、删除镜像与清理悬空层
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 镜像是缓存，不是资产
# ==================================================================
#
# 与 `podman_image.sh` 是同一套逻辑，命令换成 docker（D191 同样适用：不装
# jq，`--format` 就够）。**镜像不进任何组件的资源清单**：删了能重拉，记进
# 清单只会带来一种坏结果——卸载某个容器时顺手把一个**别的容器也在用**的
# 基础镜像删掉。
#
# 所以删除只做两件事：删之前查有没有容器在用它（用了就拒绝），以及走规范的
# 确认。剩下的交给 docker 自己 —— 它比我们清楚层是怎么共享的。
#
# docker 没有 `image exists` 这个子命令（podman 有），改用
# `docker image inspect` 的退出码判断存在性，效果等价。

readonly IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$'

require_docker() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Docker。先 oneserver install docker'
    os::require_cmd docker
    probe::service_active docker.service
    [[ ${OS_PROBE_VALUE} == active ]] \
        || os::die 3 "dockerd 没在跑（当前 ${OS_PROBE_VALUE:-未知}）—— 先 systemctl start docker.service"
    return 0
}

# ------------------------------------------------------------------

# 总览表的编号就是当前操作周期的选择符，避免把同一批镜像再打印一遍。
# 与 docker_container.sh 的容器清单是同一套：列表缓存进数组，总览按它渲染，
# 动作按它把编号翻回镜像名。序号与清单同源，才不会出现「看到的 3 号」
# 与「删掉的 3 号」不是一个。
DI_LIST_READY=0
DI_REFS=()
DI_SIZES=()
DI_CREATED=()

load_image_rows() {
    os::query --timeout 30 -- \
        docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'
    local list=${OS_RUN_OUTPUT}

    DI_REFS=()
    DI_SIZES=()
    DI_CREATED=()
    DI_LIST_READY=1

    local line ref size created
    local IFS=$'\n'
    for line in ${list}; do
        [[ -n ${line} ]] || continue
        IFS=$'\t' read -r ref size created <<<"${line}"
        DI_REFS+=("${ref}")
        DI_SIZES+=("${size}")
        DI_CREATED+=("${created}")
    done
    return 0
}

# 选一个已有镜像：编号或完整镜像名都收。
#
# **清单没上屏时先列一遍**：`oneserver docker image rm` 从命令行直接跑时总览
# 不会显示（它只在交互的动作清单里跑），让人对着一个看不见的清单输编号不行。
select_image() {
    local __di_out=${1} __di_prompt=${2}
    [[ ${DI_LIST_READY} -eq 1 ]] || action_ls
    [[ ${#DI_REFS[@]} -gt 0 ]] || os::die 2 '没有镜像可选'

    local picked=''
    os::ask --arg image "${__di_prompt}（输入上方编号；命令行可传 --image）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        local -i sel=$((picked - 1))
        ((sel >= 0 && sel < ${#DI_REFS[@]})) \
            || os::die 2 "没有编号为「${picked}」的镜像"
        picked=${DI_REFS[sel]}
    fi
    [[ ${picked} =~ ${IMAGE_RE} ]] || os::die 2 "镜像名「${picked}」不合法"
    printf -v "${__di_out}" '%s' "${picked}"
    return 0
}

action_ls() {
    require_docker
    load_image_rows
    os::screen_heading '镜像'
    if [[ ${#DI_REFS[@]} -eq 0 ]]; then
        os::info '一个都没有。拉一个：oneserver docker image pull --image=docker.io/library/nginx:alpine'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#DI_REFS[@]}; i++)); do
        cells+=("[$((i + 1))]" "${DI_REFS[i]}" "${DI_SIZES[i]}" "${DI_CREATED[i]}")
        os::output_item "image=${DI_REFS[i]}" "size=${DI_SIZES[i]}" "created=${DI_CREATED[i]}"
    done
    os::table '编号' '镜像' '大小' '创建于' -- "${cells[@]}"
    os::output 0 count="${#DI_REFS[@]}"
    return 0
}

action_pull() {
    require_docker
    local image=''
    os::ask --match "${IMAGE_RE}" --hint '写全名，如 docker.io/library/nginx:alpine' --arg image '要拉哪个镜像（写全名）' image
    case ${image} in
        */*) ;;
        *) os::warn "「${image}」没写仓库前缀，实际拉哪个取决于 dockerd 的默认仓库 —— 建议写全名" ;;
    esac

    # 本地已有就是目标状态，除非明确要求刷新。**不查就无条件重拉**违反
    # 不变量 6：`:latest` 这类可变 tag 的上游 digest 变了，本地镜像会被
    # 换成新内容，所有引用它的容器下次重启就换了镜像——一次「看起来
    # 什么都没做」的命令产生了实质变更
    local refresh=''
    os::confirm --arg refresh '本地已有的话仍要重新拉取（可能替换正在使用的镜像内容）？' n \
        && refresh=1

    if [[ -z ${refresh} ]]; then
        if os::query --timeout 10 -- docker image inspect "${image}"; then
            os::ok "镜像 ${image} 已存在，已是目标状态"
            os::output 0 image="${image}" changed=no
            return 0
        fi
    fi

    # 拉镜像属「禁止自动回滚」类：拉下来的层可能已经被别的镜像共享，
    # 失败时删掉它比留着破坏更大
    os::record_change "拉取了镜像 ${image}"
    # **`os::run` 没有 `--timeout`**（那是 `os::query` 的选项）。拉镜像本来
    # 也不该有超时：几百兆的层在慢网络上拉十分钟是正常的，掐断它只会留下半个镜像
    os::run '拉取镜像' -- docker pull "${image}" \
        || os::die 1 "拉取失败：${image}"

    # dry-run 下 os::run 被跳过，docker 根本没执行——不看 OS_RUN_SKIPPED
    # 就打「已拉取」+ changed=yes，是「会撒谎的 dry-run」
    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        os::output 0 image="${image}" changed=dry-run
        return 0
    fi

    os::ok "已拉取 ${image}"
    os::output 0 image="${image}" changed=yes
    return 0
}

# 有没有容器（包括停着的）在用这个镜像
image_in_use() {
    local __di_out=${1} __di_image=${2}
    os::query --timeout 20 -- docker ps -a --filter "ancestor=${__di_image}" --format '{{.Names}}'
    printf -v "${__di_out}" '%s' "${OS_RUN_OUTPUT}"
    return 0
}

action_rm() {
    require_docker
    local image=''
    select_image image '要删哪个镜像'

    local users=''
    image_in_use users "${image}"
    if [[ -n ${users} ]]; then
        local IFS=' '
        os::die 2 "还有容器在用这个镜像：${users//$'\n'/ } —— 先删容器（oneserver docker rm）"
    fi

    if ! os::destroy_confirm --arg confirm-rm "${image}" -- \
        "镜像 ${image}（本地副本）" \
        '删掉之后要用它得重新拉一次'; then
        os::info '已取消'
        os::output 130 image="${image}" removed=no
        return 130
    fi

    os::record_change "删除了镜像 ${image}"
    os::run '删除镜像' -- docker rmi "${image}" || os::die 1 "删除失败：${image}"
    os::ok "已删除 ${image}"
    os::output 0 image="${image}" removed=yes
    return 0
}

# 悬空层（`<none>:<none>`）：换标签、重新构建之后留下的旧层。
# 它们**一定没有容器在用**（用着的层不会悬空），所以这一条是安全的清理。
action_prune() {
    require_docker
    os::query --timeout 30 -- docker images --filter dangling=true --format '{{.ID}}'
    local dangling=${OS_RUN_OUTPUT}
    local -i n=0
    if [[ -n ${dangling} ]]; then
        local line
        local IFS=$'\n'
        for line in ${dangling}; do
            [[ -n ${line} ]] && n+=1
        done
    fi

    os::section '清理悬空镜像层'
    if ((n == 0)); then
        os::ok '没有悬空层，已是目标状态'
        os::output 0 pruned=0
        return 0
    fi

    if ! os::destroy_confirm --arg confirm-prune 'prune' -- \
        "${n} 个悬空镜像层（没有任何镜像名指向它们）" \
        '正在被容器或有名镜像使用的层不受影响'; then
        os::info '已取消'
        os::output 130 pruned=0
        return 130
    fi

    os::record_change "清理了 ${n} 个悬空镜像层"
    os::run '清理悬空镜像层' -- docker image prune -f || os::die 1 '清理失败'
    os::ok "已清理 ${n} 个悬空层"
    os::output 0 pruned="${n}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_ls --arg action '操作' dispatch \
        'pull=拉取镜像' 'rm=删除镜像' 'prune=清理悬空层'
}

dispatch() {
    case ${1} in
        ls) action_ls ;;
        pull) action_pull ;;
        rm) action_rm ;;
        prune) action_prune ;;
        *) os::die 2 "未知操作「${1}」，可用：ls pull rm prune" ;;
    esac
}

main "$@"
