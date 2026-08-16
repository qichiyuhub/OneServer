#!/bin/bash
#
# 容器卷
#
# @command      podman volume
# @name         容器卷
# @group        container
# @order        40
# @requires     podman
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<ls|create|rm>] [--name=<名字>] [--confirm-rm=<名字>]
# @description  列出、创建与删除命名卷；删除走不可逆流程
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 卷是数据
# ==================================================================
#
# 这是本模块与镜像那边最大的区别：**镜像删了能重拉，卷删了就没了**。
# 所以：
#
#   * 删卷走规范的完整流程（打全名 · `--yes` 无效 · dry-run 可预演）
#   * **删容器不删卷**（`oneserver podman rm` 已经是这么做的），
#     卷要单独删 —— 这是有意的两步，不是遗漏
#   * 卷在用时拒绝删，不给 `--force`：podman 自己的 `volume rm -f` 会把
#     容器一起停掉，那是把「删一个卷」悄悄升级成「停一个正在服务的容器」
#
# 卷也**不进任何组件的资源清单**（规范的「永不自动删除」明列了数据）：
# `oneserver uninstall container:<名>` 不该带走用户的数据库文件。

readonly NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$'

require_podman() {
    probe::component_version podman
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Podman。先 oneserver install podman'
    os::require_cmd podman
    return 0
}

# 哪些容器在用这个卷。`podman ps --filter volume=` 认命名卷，也认宿主路径
volume_users() {
    local __pv_out=${1} __pv_name=${2}
    os::query --timeout 20 -- podman ps -a --filter "volume=${__pv_name}" --format '{{.Names}}'
    printf -v "${__pv_out}" '%s' "${OS_RUN_OUTPUT}"
    return 0
}

# ------------------------------------------------------------------

# 总览表的编号就是当前操作周期的选择符，避免把同一批卷再打印一遍。
# 与容器清单同一套：列表缓存进数组，总览按它渲染，动作按它把编号翻回卷名 ——
# 序号与清单同源，才不会出现「看到的 3 号」与「删掉的 3 号」不是一个。
PV_LIST_READY=0
PV_NAMES=()
PV_DRIVERS=()
PV_MOUNTS=()
PV_USERS=()

load_volume_rows() {
    os::query --timeout 20 -- podman volume ls --format '{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}'
    local list=${OS_RUN_OUTPUT}

    PV_NAMES=()
    PV_DRIVERS=()
    PV_MOUNTS=()
    PV_USERS=()
    PV_LIST_READY=1

    local line name driver mount users
    local IFS=$'\n'
    for line in ${list}; do
        [[ -n ${line} ]] || continue
        IFS=$'\t' read -r name driver mount <<<"${line}"
        volume_users users "${name}"
        PV_NAMES+=("${name}")
        PV_DRIVERS+=("${driver}")
        PV_MOUNTS+=("${mount}")
        PV_USERS+=("${users//$'\n'/ }")
    done
    return 0
}

# 选一个已有的卷：编号或卷名都收。
#
# **清单没上屏时先列一遍**：从命令行直接跑时总览不会显示（它只在交互的动作
# 清单里跑），让人对着一个看不见的清单输编号不行。
select_volume() {
    local __pv_out=${1} __pv_prompt=${2}
    [[ ${PV_LIST_READY} -eq 1 ]] || action_ls
    [[ ${#PV_NAMES[@]} -gt 0 ]] || os::die 2 '没有卷可选'

    local picked=''
    os::ask --arg name "${__pv_prompt}（输入上方编号；命令行可传 --name）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        local -i sel=$((picked - 1))
        ((sel >= 0 && sel < ${#PV_NAMES[@]})) \
            || os::die 2 "没有编号为「${picked}」的卷"
        picked=${PV_NAMES[sel]}
    fi
    [[ ${picked} =~ ${NAME_RE} ]] || os::die 2 "卷名「${picked}」不合法"
    printf -v "${__pv_out}" '%s' "${picked}"
    return 0
}

action_ls() {
    require_podman
    load_volume_rows
    os::screen_heading '卷'
    if [[ ${#PV_NAMES[@]} -eq 0 ]]; then
        os::info '一个都没有。建一个：oneserver podman volume create --name=pgdata'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#PV_NAMES[@]}; i++)); do
        cells+=("[$((i + 1))]" "${PV_NAMES[i]}" "${PV_DRIVERS[i]}" "${PV_MOUNTS[i]}"
            "${PV_USERS[i]:-—}")
        os::output_item "volume=${PV_NAMES[i]}" "driver=${PV_DRIVERS[i]}" \
            "mountpoint=${PV_MOUNTS[i]}" "users=${PV_USERS[i]}"
    done
    os::table '编号' '名称' '驱动' '挂载点' '使用中' -- "${cells[@]}"
    os::info '卷里是数据 —— 删容器不会删卷，要删得单独来这里'
    os::output 0 count="${#PV_NAMES[@]}"
    return 0
}

action_create() {
    require_podman
    local name=''
    os::ask --arg name '卷名字' name ''
    [[ -n ${name} ]] || os::die 2 '要给出卷名字：--name=pgdata'
    [[ ${name} =~ ${NAME_RE} ]] || os::die 2 "卷名「${name}」不合法"

    if os::query --timeout 10 -- podman volume exists "${name}"; then
        os::ok "卷 ${name} 已存在，已是目标状态"
        os::output 0 name="${name}" changed=no
        return 0
    fi

    # 建卷属「必须回滚」类：本次创建，此刻还是空的，撤销安全
    os::defer podman volume rm "${name}"
    os::run '创建卷' -- podman volume create "${name}" || os::die 1 "创建失败：${name}"

    # dry-run 下 os::run 被跳过，卷根本没建出来——下面 podman volume inspect
    # 是只读的 os::query，dry-run 照常执行，对一个不存在的卷只会拿到空输出，
    # 而不看 OS_RUN_SKIPPED 就打「已创建」+ changed=yes，正是 D15 说的
    # 「会撒谎的 dry-run」（同 podman_image.sh 的 pull）
    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    os::query --timeout 10 -- podman volume inspect "${name}" --format '{{.Mountpoint}}'
    os::ok "卷 ${name} 已创建"
    os::kv '挂载点' "${OS_RUN_OUTPUT:-未知}"
    os::info "用它：oneserver podman run --name=db --image=... --volume=${name}:/var/lib/data"
    os::output 0 name="${name}" changed=yes
    return 0
}

action_rm() {
    require_podman
    local name=''
    select_volume name '要删哪个卷'

    os::query --timeout 10 -- podman volume exists "${name}" \
        || os::die 2 "没有叫 ${name} 的卷（oneserver podman volume ls 看有哪些）"

    # **在用就拒绝，不给 --force**：podman 的 `volume rm -f` 会把用它的容器
    # 一起停掉并删除 —— 那是把「删一个卷」悄悄升级成「停一个正在服务的容器」
    local users=''
    volume_users users "${name}"
    if [[ -n ${users} ]]; then
        os::die 2 "卷 ${name} 正在被这些容器使用：${users//$'\n'/ } —— 先删容器再删卷"
    fi

    os::query --timeout 10 -- podman volume inspect "${name}" --format '{{.Mountpoint}}'
    local mount=${OS_RUN_OUTPUT}
    local size='未知'
    if [[ -d ${mount} ]]; then
        os::query --timeout 30 -- du -sh "${mount}"
        size=${OS_RUN_OUTPUT%%[[:space:]]*}
    fi

    # 规范：具体路径、大小，不接受「将删除一个卷」这种概括
    if ! os::destroy_confirm --arg confirm-rm "${name}" -- \
        "卷 ${name}" \
        "数据目录 ${mount}（${size}）" \
        '**卷里的数据删了不可恢复，本工具不会替你先备份**'; then
        os::info '已取消，卷没有动'
        os::output 130 name="${name}" removed=no
        return 130
    fi

    os::record_change "删除了卷 ${name}（${mount}）"
    os::run '删除卷' -- podman volume rm "${name}" || os::die 1 "删除失败：${name}"
    os::ok "卷 ${name} 已删除"
    os::output 0 name="${name}" removed=yes
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
        'create=新建卷' 'rm=删除卷'
}

dispatch() {
    case ${1} in
        ls) action_ls ;;
        create) action_create ;;
        rm) action_rm ;;
        *) os::die 2 "未知操作「${1}」，可用：ls create rm" ;;
    esac
}

main "$@"
