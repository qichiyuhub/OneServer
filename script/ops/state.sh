#!/bin/bash
#
# 组件状态
#
# @command      state
# @name         组件状态
# @group        monitor
# @order        20
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<list|show|rebuild>] [--id=<组件标识>] [--confirm-rebuild]
# @description  列出装过的组件与登记的资源，可按探测重建
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 为什么 `rebuild` 必须把「重建不回来的东西」说清楚
# ==================================================================
#
# 规范承诺 state 损坏时「提供 `oneserver state rebuild`」。但探测能回答的
# 只有「装没装、什么版本」，**回答不了「本工具当初往这台机器上放了哪些文件、
# 装了哪些包、做了哪些 divert」** —— 那份资源清单是安装时一条条记下来的，
# 丢了就是丢了。
#
# 所以重建之后：`@requires` 能正常工作（它只问装没装），
# 而 `oneserver uninstall` 对这些重建出来的组件**只能删 state 里的那一行**，
# 卸不干净。这句话必须在重建时当面说，不能藏在文档里 ——
# 一个「看起来修好了」的 state 比一个明显坏掉的 state 危险得多。
#
# 重建的类型清单也不是手写的：它来自各个安装脚本自己声明的 `@provides`
# 。手写一份等于第二份真相，而那正是 `script_list.txt` 的教训（D179）。

readonly ANY_INSTANCE_HINT='<'

# ------------------------------------------------------------------

# 总览表的编号就是当前操作周期的选择符，避免把同一批组件再打印一遍。
# 与容器清单同一套：清单缓存进数组，总览按它渲染，动作按它把编号翻回组件标识
# —— 序号与清单同源，才不会出现「看到的 3 号」与「查看的 3 号」不是一个。
ST_LIST_READY=0
ST_IDS=()
ST_VERS=()
ST_METHODS=()
ST_RES=()

load_component_rows() {
    ST_IDS=()
    ST_VERS=()
    ST_METHODS=()
    ST_RES=()
    ST_LIST_READY=1

    local id ver method units files pkgs
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        ver=$(os::state_get "${id}" version)
        method=$(os::state_get "${id}" method)
        units=$(os::state_resources "${id}" unit | grep -c . || true)
        files=$(os::state_resources "${id}" file | grep -c . || true)
        pkgs=$(os::state_resources "${id}" pkg | grep -c . || true)
        ST_IDS+=("${id}")
        ST_VERS+=("${ver:-未知}")
        ST_METHODS+=("${method:-未记来源}")
        ST_RES+=("unit ${units} · 文件 ${files} · 包 ${pkgs}")
    done < <(os::state_list)
    return 0
}

# 选一个已登记的组件：编号或完整组件标识都收。
#
# **清单没上屏时先列一遍**：`oneserver state show` 从命令行直接跑时总览不会
# 显示（它只在交互的动作清单里跑），让人对着一个看不见的清单输编号不行。
select_component() {
    local __st_out=${1}
    [[ ${ST_LIST_READY} -eq 1 ]] || action_list
    [[ ${#ST_IDS[@]} -gt 0 ]] || os::die 2 'state 里一个组件都没有'

    local __st_picked=''
    os::ask --arg id '要看哪个组件（输入上方编号；命令行可传 --id）' __st_picked
    if [[ ${__st_picked} =~ ^[0-9]+$ ]]; then
        local -i __st_sel=$((__st_picked - 1))
        ((__st_sel >= 0 && __st_sel < ${#ST_IDS[@]})) \
            || os::die 2 "没有编号为「${__st_picked}」的组件"
        __st_picked=${ST_IDS[__st_sel]}
    fi
    printf -v "${__st_out}" '%s' "${__st_picked}"
    return 0
}

action_list() {
    load_component_rows
    os::screen_heading '已登记的组件'
    if [[ ${#ST_IDS[@]} -eq 0 ]]; then
        os::info '一个都没有：本工具还没装过任何组件，或者 state 被重置过'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#ST_IDS[@]}; i++)); do
        cells+=("[$((i + 1))]" "${ST_IDS[i]}" "${ST_VERS[i]}" "${ST_METHODS[i]}" "${ST_RES[i]}")
        os::output_item "id=${ST_IDS[i]}" "version=${ST_VERS[i]}" "method=${ST_METHODS[i]}"
    done
    os::table '编号' '组件' '版本' '来源' '资源' -- "${cells[@]}"
    os::output 0 count="${#ST_IDS[@]}"
    return 0
}

action_show() {
    # 位置参数优先，没给就**从清单里挑**。
    # 不问「完整标识」：那是让人去猜一个只有 state 才知道的字符串，
    # 而他手上正好没有那份清单 —— 有清单的话他也不用跑这条命令了
    local id=${1-}
    if [[ -z ${id} ]]; then
        select_component id
    fi
    os::state_has "${id}" || os::die 2 "state 里没有「${id}」（oneserver state list 看有哪些）"

    os::section "${id}"
    os::kv '版本' "$(os::state_get "${id}" version)" \
        '安装方式' "$(os::state_get "${id}" method)" \
        '登记时间' "$(os::state_get "${id}" installed_at)"

    local key val
    local -i total=0
    for key in unit alt divert file pkg path db; do
        local -a vals=()
        mapfile -t vals < <(os::state_resources "${id}" "${key}")
        [[ ${#vals[@]} -gt 0 ]] || continue
        os::section "${key}（${#vals[@]}）"
        for val in "${vals[@]}"; do
            [[ -n ${val} ]] || continue
            os::info "    ${val}"
            os::output_item "id=${id}" "key=${key}" "value=${val}"
            total+=1
        done
    done

    if ((total == 0)); then
        os::warn '这个组件没有登记任何资源 —— oneserver uninstall 对它只能删掉 state 里的记录'
    fi
    os::output 0 id="${id}" resources="${total}"
    return 0
}

# 本工具能装的组件类型。**来自各安装脚本自己声明的 `@provides`**，
# 不手写第二份清单（D179 的教训）。带实例占位符的（`php:<version>`）
# 在这里只取类型部分。
collect_types() {
    local __st_out=${1}
    os::query --timeout 10 -- \
        grep -rhE '^#[[:space:]]*@provides[[:space:]]' "${OS_SCRIPT_DIR}" || true

    local line type seen='' out=''
    local IFS=$'\n'
    for line in ${OS_RUN_OUTPUT}; do
        type=${line##*[[:space:]]}
        type=${type%%:*}
        [[ -n ${type} ]] || continue
        [[ ${type} == *"${ANY_INSTANCE_HINT}"* ]] && continue
        [[ ${seen} == *"|${type}|"* ]] && continue
        seen+="|${type}|"
        out+="${type}"$'\n'
    done
    printf -v "${__st_out}" '%s' "${out}"
    return 0
}

action_rebuild() {
    local types=''
    collect_types types
    [[ -n ${types} ]] || os::die 1 '没能从脚本里读出任何 @provides 声明'

    # 先探一遍，把「装着但 state 里没有」的挑出来
    local -a found=() found_ver=()
    local type ver
    local IFS=$'\n'
    for type in ${types}; do
        [[ -n ${type} ]] || continue
        os::state_has "${type}" && continue
        local -a insts=()
        mapfile -t insts < <(os::state_list "${type}")
        [[ ${#insts[@]} -gt 0 ]] && continue

        probe::component_version "${type}"
        ver=${OS_PROBE_VALUE%%$'\n'*}
        ver=${ver%% *}
        ver=${ver#v}
        [[ -n ${ver} ]] || continue
        found+=("${type}")
        found_ver+=("${ver}")
    done

    os::section 'state 重建'
    if [[ ${#found[@]} -eq 0 ]]; then
        os::ok '探测到的组件都已经在 state 里，没有要补的'
        os::output 0 added=0
        return 0
    fi

    local -i i
    for ((i = 0; i < ${#found[@]}; i++)); do
        os::kv "${found[i]}" "${found_ver[i]}"
    done

    # **把重建不回来的东西当面说清楚**（见文件头）
    os::warn "重建只能恢复「装没装、什么版本」这两件事"
    os::warn '资源清单（哪些包、哪些文件、哪些 divert / alternatives）恢复不了 ——'
    os::warn "它是安装时一条条记下来的，丢了就是丢了；对这些组件 uninstall 只能删掉 state 里的记录"
    os::info '要拿回完整的资源清单，只能重新跑一遍对应的安装命令'
    os::info '多实例组件（如 php:8.3）不在重建范围内 —— 探测答不出「哪个实例是本工具装的」'

    # **这里用 os::confirm 而不是 os::destroy_confirm**，是想清楚了的：
    # rebuild 只往 state 里**补**探测到的组件，不覆盖任何已有记录、不删任何东西
    # （上面那轮筛选已经跳过了 state 里已有的）。规范管的是「删除数据、覆盖
    # 不可重建的文件」，套到这里只会打出一句「以下内容将被删除」——
    # 屏幕上说的话与实际做的事不一致，比多问一次严重得多。
    # 默认 n：它写进去的是猜出来的东西，不该一路回车就写下去。
    if ! os::confirm --arg confirm-rebuild "把这 ${#found[@]} 个组件写进 state？" n; then
        os::info '已取消，state 未改动'
        os::output 130 added=0
        return 130
    fi

    for ((i = 0; i < ${#found[@]}; i++)); do
        # method=probe 是**诚实的来源标注**：这一行不是安装时记下的，
        # 是事后猜出来的。将来 doctor 或 uninstall 想区别对待时有据可依
        os::state_set "${found[i]}" version="${found_ver[i]}" method=probe || {
            os::warn "写入 ${found[i]} 失败"
            continue
        }
    done

    os::ok "已补上 ${#found[@]} 个组件"
    os::output 0 added="${#found[@]}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        # 多带一个位置参数：`oneserver state show php:8.3` 里的标识。
        # 走二级菜单时它是空的，action_show 会自己问
        dispatch "${action}" "${@:2}"
        return 0
    fi

    os::action_menu --overview action_list --arg action '操作' dispatch \
        'show=查看某个组件' 'rebuild=按探测重建 state'
}

dispatch() {
    case ${1} in
        list) action_list ;;
        show) action_show "${2-}" ;;
        rebuild) action_rebuild ;;
        *) os::die 2 "未知操作「${1}」，可用：list show rebuild" ;;
    esac
}

main "$@"
