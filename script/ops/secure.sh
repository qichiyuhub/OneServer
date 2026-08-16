#!/bin/bash
#
# 凭据库
#
# @command      secure
# @name         凭据库
# @group        security
# @order        60
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<list|get|del>] [--key=<凭据 key>] [--confirm-del=<y|n>]
# @description  查看、读取、删除凭据库（secure.conf）里的条目
#
# db_manager.sh / caddy-manager.sh 一直提示用户「取密码：oneserver secure get
# <key>」，但这条命令过去并不存在 —— lib/secure.sh 的读写接口齐全，缺的只是
# 一层暴露给 CLI 的薄壳。没有它，用户唯一的出路是 `cat secure.conf`：一次性
# 摊开全部凭据、不留审计记录，正是这里想避免的访问方式。

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# 总览表的编号就是当前操作周期的选择符，避免把同一批 key 再打印一遍。
# 与容器清单同一套：清单缓存进数组，总览按它渲染，动作按它把编号翻回 key ——
# 序号与清单同源，才不会出现「看到的 3 号」与「删掉的 3 号」不是一个。
SC_LIST_READY=0
SC_KEYS=()

load_key_rows() {
    SC_KEYS=()
    mapfile -t SC_KEYS < <(os::secure_list)
    SC_LIST_READY=1
    return 0
}

action_list() {
    load_key_rows
    os::screen_heading '凭据库'
    if [[ ${#SC_KEYS[@]} -eq 0 ]]; then
        os::info '凭据库是空的'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#SC_KEYS[@]}; i++)); do
        cells+=("[$((i + 1))]" "${SC_KEYS[i]}")
        os::output_item key="${SC_KEYS[i]}"
    done
    os::table '编号' '凭据 key' -- "${cells[@]}"
    os::info "共 ${#SC_KEYS[@]} 条。**只列 key，不列值** —— 看某一条的值走「读取凭据」"
    os::output 0 count="${#SC_KEYS[@]}"
    return 0
}

# 本函数的局部变量全带 `__sc_` 前缀，这不是风格洁癖。
#
# `printf -v "${__sc_out}"` 是在**本函数的作用域里**写变量：调用方写
# `pick_key key` 时 __sc_out 恰好是 `key`，而本函数原来也有一个 `local key`——
# 于是选中的值写进了这个局部变量，调用方的 `key` 一个字都没拿到，不报错、
# 不警告，表现为紧接着的一句「凭据 key「」缺少命名空间」。
# os::ask 早就因为同一个坑加了 `__os_` 前缀，这里是同一件事的第二现场。
#
# 编号或完整 key 都收。**清单没上屏时先列一遍**：`oneserver secure get` 从命令行
# 直接跑时总览不会显示（它只在交互的动作清单里跑），让人对着一个看不见的清单
# 输编号不行。
pick_key() {
    local __sc_out=${1}
    [[ ${SC_LIST_READY} -eq 1 ]] || action_list
    [[ ${#SC_KEYS[@]} -gt 0 ]] || os::die 2 '凭据库是空的'

    local __sc_picked=''
    os::ask --arg key '要操作哪条凭据（输入上方编号；命令行可传 --key）' __sc_picked
    if [[ ${__sc_picked} =~ ^[0-9]+$ ]]; then
        local -i __sc_sel=$((__sc_picked - 1))
        ((__sc_sel >= 0 && __sc_sel < ${#SC_KEYS[@]})) \
            || os::die 2 "没有编号为「${__sc_picked}」的凭据"
        __sc_picked=${SC_KEYS[__sc_sel]}
    fi
    printf -v "${__sc_out}" '%s' "${__sc_picked}"
    return 0
}

action_get() {
    local key=${1-}
    if [[ -z ${key} ]]; then
        pick_key key
    fi
    os::secure_key_valid "${key}" || os::die 2 "凭据 key「${key}」缺少命名空间"
    os::secure_list | grep -qx -- "${key}" || os::die 2 "凭据库里没有「${key}」"

    # 这是本命令唯一的目的：把值交给调用者。与其它地方「dry-run/日志里
    # 绝不能明文」的纪律不冲突 —— 这里走的是用户主动发起的读取动作。
    # JSON 模式不能先 printf 明文再发信封，否则 stdout 是两段拼接的非法 JSON。
    local value=''
    os::secure_load "${key}" value || os::die 2 "凭据库里没有「${key}」"
    if [[ ${OS_OUTPUT} == text ]]; then
        printf '%s\n' "${value}"
    fi
    os::output 0 key="${key}" value="${value}"
    return 0
}

action_del() {
    local key=${1-}
    if [[ -z ${key} ]]; then
        pick_key key
    fi
    os::secure_key_valid "${key}" || os::die 2 "凭据 key「${key}」缺少命名空间"
    os::secure_list | grep -qx -- "${key}" || os::die 2 "凭据库里没有「${key}」"

    if ! os::confirm --arg confirm-del "删除凭据「${key}」？依赖它的服务可能连不上，需要的话会在下次相关操作时重新生成" n; then
        os::info '已取消，未删除'
        os::output 130 key="${key}" deleted=no
        return 130
    fi

    os::secure_del "${key}" || os::die 1 "删除凭据 ${key} 失败"
    os::ok "已删除凭据 ${key}"
    os::output 0 key="${key}" deleted=yes
    return 0
}

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}" "${2-}"
        return 0
    fi

    os::action_menu --overview action_list --arg action '操作' dispatch \
        'get=读取某条凭据的值' 'del=删除某条凭据'
}

dispatch() {
    case ${1} in
        list) action_list ;;
        get) action_get "${2-}" ;;
        del) action_del "${2-}" ;;
        *) os::die 2 "未知操作「${1}」，可用：list get del" ;;
    esac
}

main "$@"
