#!/bin/bash
#
# 已装的应用
#
# @command      apps
# @name         已装列表
# @group        app
# @order        20
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<list|show>] [--name=<应用名>]
# @description  列出装过的应用与各自占用的资源
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 只列应用，不列别的组件
# ==================================================================
#
# **这不是 `oneserver state`。** 那一个列的是 state 里的**全部登记** ——
# 应用、建过的库（`db:<名>`）、部署过的站点（`wordpress:<名>`）、备份目标、
# 网络定位，全在一份账本上。两者回答的是不同问题：
#
#   这里         我装了哪些应用
#   state        本工具在这台机器上一共记了什么账
#
# 混成一个的后果试过：一个叫「已装列表」的东西列出 `db:testdb` 和 `network`，
# 名字和内容对不上，而用户要找的那几个应用埋在里面。
#
# --- 哪些算应用 ---
#
# type 出现在 `install_*.sh` 的 `@provides` 里的，就是应用 —— 判据是「本工具
# 能不能装它」，与安装脚本自己的声明同源，不手写第二份清单（D179）。
# 带实例的（`php:8.3`、`nodejs:22`）按实例逐条列：装了两个 PHP 就是两行，
# 它们各有各的版本与资源。

readonly INSTALL_DIR="${OS_SCRIPT_DIR}/install"
readonly ANY_INSTANCE_HINT='<'

APP_TYPES=()

# load_types   本工具能装的应用类型（同 install_apps.sh 的扫法）
load_types() {
    APP_TYPES=()
    # 模式与目录经位置参数进内层 shell，不拼进脚本文本（规范 §10）
    os::query --timeout 10 -- sh -c \
        "grep -rhE \"\$1\" \"\$2\" | sort -u" \
        sh '^#[[:space:]]*@provides[[:space:]]' "${INSTALL_DIR}" || return 0

    local line type seen=''
    local IFS=$'\n'
    for line in ${OS_RUN_OUTPUT}; do
        type=${line##*[[:space:]]}
        type=${type%%:*}
        [[ -n ${type} ]] || continue
        [[ ${type} == *"${ANY_INSTANCE_HINT}"* ]] && continue
        [[ ${seen} == *"|${type}|"* ]] && continue
        seen+="|${type}|"
        APP_TYPES+=("${type}")
    done
    return 0
}

# state 里属于应用的那些条目（含多实例的每一个）
APP_LIST_SHOWN=0
APP_IDS=()
load_installed() {
    APP_IDS=()
    load_types
    local type id
    for type in ${APP_TYPES[@]+"${APP_TYPES[@]}"}; do
        while IFS= read -r id; do
            [[ -n ${id} ]] && APP_IDS+=("${id}")
        done < <(os::state_list "${type}")
    done
    return 0
}

# app_resources <组件标识>   占用资源的条数摘要，结果写 APP_RES
APP_RES=''
app_resources() {
    local id=${1} kind n out=''
    local -a items=()
    for kind in pkg file divert alt; do
        mapfile -t items < <(os::state_resources "${id}" "${kind}")
        n=0
        local one
        for one in ${items[@]+"${items[@]}"}; do
            [[ -n ${one} ]] && n=$((n + 1))
        done
        ((n > 0)) && out+="${out:+ · }${kind} ${n}"
    done
    mapfile -t items < <(os::state_units "${id}")
    n=0
    local one
    for one in ${items[@]+"${items[@]}"}; do
        [[ -n ${one} ]] && n=$((n + 1))
    done
    ((n > 0)) && out+="${out:+ · }unit ${n}"
    APP_RES=${out:-无登记资源}
    return 0
}

# ------------------------------------------------------------------

action_list() {
    load_installed
    if [[ ${#APP_IDS[@]} -eq 0 ]]; then
        os::info '还没有用本工具装过任何应用 —— 装一个：oneserver install'
        os::output 0 count=0
        return 0
    fi

    os::screen_heading '已装的应用'
    local id ver method
    local -a cells=()
    local -i i
    for ((i = 0; i < ${#APP_IDS[@]}; i++)); do
        id=${APP_IDS[i]}
        ver=$(os::state_get "${id}" version)
        method=$(os::state_get "${id}" method)
        app_resources "${id}"
        cells+=("[$((i + 1))]" "${id}" "${ver:-未知}" "${method:-未记录}" "${APP_RES}")
        os::output_item id="${id}" version="${ver}" method="${method}"
    done
    os::table '编号' '应用' '版本' '安装方式' '资源' -- "${cells[@]}"
    APP_LIST_SHOWN=1
    # state 里记的是「本工具装过什么」。用户自己 apt 装的那份不在这儿，
    # 不说清的话，一台明明跑着 MariaDB 的机器上这份清单看起来像丢了东西
    os::info '只列本工具装的；手工装的应用不在 state 里，用 oneserver install 看全部状态'
    os::output 0 count="${#APP_IDS[@]}"
    return 0
}

# 选一个已装应用：编号或组件标识都收。
#
# **清单没上屏时先列一遍**：`oneserver apps show` 从命令行直接跑时总览不会
# 显示（它只在交互的动作清单里跑），让人对着一个看不见的清单输编号不行。
select_app() {
    local __ap_out=${1}
    load_installed
    [[ ${#APP_IDS[@]} -gt 0 ]] || os::die 2 '还没有用本工具装过任何应用'
    [[ ${APP_LIST_SHOWN} -eq 1 ]] || action_list

    local __ap_picked=''
    os::ask --arg name '看哪个应用（输入上方编号；命令行可传 --name）' __ap_picked
    if [[ ${__ap_picked} =~ ^[0-9]+$ ]]; then
        local -i __ap_sel=$((__ap_picked - 1))
        ((__ap_sel >= 0 && __ap_sel < ${#APP_IDS[@]})) \
            || os::die 2 "没有编号为「${__ap_picked}」的应用"
        __ap_picked=${APP_IDS[__ap_sel]}
    fi
    printf -v "${__ap_out}" '%s' "${__ap_picked}"
    return 0
}

action_show() {
    load_installed
    if [[ ${#APP_IDS[@]} -eq 0 ]]; then
        os::die 2 '还没有用本工具装过任何应用'
    fi

    local id=''
    select_app id

    local ver method installed_at
    ver=$(os::state_get "${id}" version)
    method=$(os::state_get "${id}" method)
    installed_at=$(os::state_get "${id}" installed_at)

    os::section "应用 ${id}"
    os::kv '版本' "${ver:-未知}" \
        '安装方式' "${method:-未记录}" \
        '登记时间' "${installed_at:-未记录}"

    # 资源逐条列出来，不只报条数：这份清单就是卸载时会被反向执行的东西，
    # 「卸载会动哪些包和文件」应该在卸载之前就能看见
    local kind one
    local -a items=()
    for kind in pkg file divert alt; do
        mapfile -t items < <(os::state_resources "${id}" "${kind}")
        for one in ${items[@]+"${items[@]}"}; do
            [[ -n ${one} ]] && os::kv "  ${kind}" "${one}"
        done
    done
    mapfile -t items < <(os::state_units "${id}")
    for one in ${items[@]+"${items[@]}"}; do
        [[ -n ${one} ]] && os::kv '  unit' "${one}"
    done

    os::output 0 id="${id}" version="${ver}" method="${method}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_list --arg action '操作' dispatch \
        'show=查看某个应用占用的资源'
}

dispatch() {
    case ${1} in
        list) action_list ;;
        show) action_show ;;
        *) os::die 2 "未知操作「${1}」，可用：list show" ;;
    esac
}

main "$@"
