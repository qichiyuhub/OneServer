#!/bin/bash
#
# 站点管理：列出 · 详情 · 删除
#
# @command      site
# @name         站点
# @group        web
# @order        10
# @privilege    root
# @requires     caddy
# @requires_lib >= 1.26
# @args         [--action=<list|show|delete>] [--name=<站点名>] [--confirm-delete-site=<站点名>]
# @description  列出已部署的站点、查看详情、删除站点
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 站点是什么
# ==================================================================
#
# state 里带 `path` 键、且类型在站点白名单内的组件（`wordpress:<名字>`）。
# 判据与 backup.sh 的 bk_sites 完全一致，**白名单也共用同一个变量** ——
# 两处各维护一份「哪些类型算站点」，加第二种站点类型时必然漏掉一处，
# 表现是站点能建能备份却在这里列不出来。
#
# --- 与 caddy 的分工 ---
#
# 部署站点**不写任何 Caddy 配置**（见 deploy_wordpress.sh 结尾的提示）：
# 建目录、建库、放程序文件是这里的事，域名怎么指过来是 `oneserver caddy` 的事。
# 所以 state 里没有域名，本文件也就答不出「这个站点的证书快到期了吗」——
# 详情里报的是「Caddy 配置里有没有引用这个目录」，那才是这份数据能回答的问题。
#
# --- 删除删什么 ---
#
# 站点目录**真删**，数据库**不删**。
#
# 目录真删：不删就只剩划掉一行 state 记录，而磁盘上那份东西还在 —— 那种
# 「删了但没删」正是最坏的一种，用户以为清理干净了，几个月后才发现盘还是满的。
# 所以它走 os::destroy_confirm，打全名确认。
#
# 数据库不删：删库已经有自己的一条路（`oneserver mariadb delete`），那里会先
# 自动备份再 DROP。在这里顺手删掉，等于让一个「删站点」的操作附带执行另一个
# 危险操作，而用户是在站点的确认清单上打的字。清单里写清楚库还在、怎么删。

readonly CADDY_CONF_DIR='/etc/caddy'

# 同一下标横跨这三个数组即一个站点
SITE_IDS=()
SITE_NAMES=()
SITE_PATHS=()

# load_sites   扫 state，填上面三个数组
load_sites() {
    SITE_IDS=()
    SITE_NAMES=()
    SITE_PATHS=()

    local -a types=()
    local IFS=$', \t\n'
    read -ra types <<<"${OS_DEFAULT_BACKUP_SITE_TYPES}"
    IFS=$'\n\t'

    local type id path
    for type in ${types[@]+"${types[@]}"}; do
        [[ -n ${type} ]] || continue
        while IFS= read -r id; do
            [[ -n ${id} ]] || continue
            path=$(os::state_get "${id}" path)
            # 没有 path 的不是站点（将来可能有只存配置的同类型组件）
            [[ -n ${path} ]] || continue
            SITE_IDS+=("${id}")
            SITE_NAMES+=("${id#*:}")
            SITE_PATHS+=("${path}")
        done < <(os::state_list "${type}")
    done
    return 0
}

# site_pick <提示> <出参名>   让用户从站点清单里挑一个，结果是**组件标识**
#
# 挑而不是手敲：站点名会进 state 的实例标识，敲错一个字符要么白跑一趟，
# 要么（删除时）指向另一个站点。
#
# 总览表的编号就是选择符 —— **清单没上屏时先列一遍**：从命令行直接跑时总览
# 不会显示（它只在交互的动作清单里跑），让人对着一个看不见的清单输编号不行。
SITE_LIST_SHOWN=0
site_pick() {
    local __sp_prompt=${1} __sp_out=${2}
    load_sites
    if [[ ${#SITE_IDS[@]} -eq 0 ]]; then
        os::die 2 '一个站点都没有'
    fi
    [[ ${SITE_LIST_SHOWN} -eq 1 ]] || action_list

    local __sp_picked=''
    os::ask --arg name "${__sp_prompt}（输入上方编号；命令行可传 --name）" __sp_picked
    if [[ ${__sp_picked} =~ ^[0-9]+$ ]]; then
        local -i __sp_sel=$((__sp_picked - 1))
        ((__sp_sel >= 0 && __sp_sel < ${#SITE_IDS[@]})) \
            || os::die 2 "没有编号为「${__sp_picked}」的站点"
        __sp_picked=${SITE_IDS[__sp_sel]}
    fi
    printf -v "${__sp_out}" '%s' "${__sp_picked}"
    return 0
}

# site_dir_usage <目录>   目录占多少磁盘，结果写 SITE_DIR_USAGE；目录不存在时为空
SITE_DIR_USAGE=''
site_dir_usage() {
    SITE_DIR_USAGE=''
    [[ -d ${1} ]] || return 0
    # 大站点的 du 可能要走很久，超时就当作答不出来 —— 一个查看详情的命令
    # 不该卡在统计磁盘上
    os::query --timeout 20 -- du -sh "${1}" || return 0
    SITE_DIR_USAGE=${OS_RUN_OUTPUT%%[[:space:]]*}
    return 0
}

# site_caddy_ref <目录>   Caddy 配置里有没有引用这个目录，结果写 SITE_CADDY_REF
#
# **只报引用与否，不解析出域名。** Caddyfile 的语法足够自由（站点块可以写
# 多个域名、可以 import 片段、root 可以带 matcher），照着某一种写法去提取域名，
# 换个写法就答错 —— 而答错的方向是「说站点没配好」，比不答更糟。
SITE_CADDY_REF=''
site_caddy_ref() {
    SITE_CADDY_REF=''
    [[ -d ${CADDY_CONF_DIR} ]] || return 0
    os::query --timeout 10 -- grep -rlF "${1}" "${CADDY_CONF_DIR}" || return 0
    local one out='' sep=''
    local IFS=$'\n'
    for one in ${OS_RUN_OUTPUT}; do
        [[ -n ${one} ]] || continue
        out+="${sep}${one}"
        sep=' · '
    done
    SITE_CADDY_REF=${out}
    return 0
}

# site_secrets <组件标识>   这个站点在凭据库里留下的 key，结果写 SITE_SECRETS
#
# 前缀由 os::secure_ns 生成，不自己拼 —— 写入端（deploy_wordpress）也是用它
# 算的 key，两边各拼一次迟早对不上，而对不上的表现是删完站点密码还留在
# secure.conf 里，没有任何报错
SITE_SECRETS=()
site_secrets() {
    SITE_SECRETS=()
    local ns k
    ns=$(os::secure_ns "${1}")
    while IFS= read -r k; do
        [[ -n ${k} ]] || continue
        [[ ${k} == "${ns}."* ]] && SITE_SECRETS+=("${k}")
    done < <(os::secure_list)
    return 0
}

# site_db_exists <库名>   库在不在，结果写 SITE_DB_STATE（yes/no/unknown）
#
# MariaDB 没跑时是 unknown 而不是 no：把「查不到」说成「不存在」，
# 用户会以为站点的库丢了
SITE_DB_STATE=''
site_db_exists() {
    SITE_DB_STATE='unknown'
    [[ -n ${1} ]] || return 0
    probe::service_active mariadb.service
    [[ ${OS_PROBE_VALUE} == active ]] || return 0
    local q
    q=$(os::sql_str "${1}")
    os::sql_query '检查站点数据库是否存在' -- "SHOW DATABASES LIKE ${q};" || return 0
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        SITE_DB_STATE='yes'
    else
        SITE_DB_STATE='no'
    fi
    return 0
}

# ------------------------------------------------------------------

action_list() {
    load_sites
    local -i n=${#SITE_IDS[@]}
    if ((n == 0)); then
        os::info "还没有部署任何站点 —— 用 oneserver deploy wordpress 部署一个"
        os::output 0 count=0
        return 0
    fi

    os::screen_heading '站点'
    local -a cells=()
    local -i i
    local db exists
    for ((i = 0; i < n; i++)); do
        db=$(os::state_get "${SITE_IDS[i]}" db)
        exists=${SITE_PATHS[i]}
        [[ -d ${SITE_PATHS[i]} ]] || exists='目录已丢失'
        cells+=("[$((i + 1))]" "${SITE_NAMES[i]}" "${exists}" "${db:-—}")
        os::output_item name="${SITE_NAMES[i]}" id="${SITE_IDS[i]}" \
            path="${SITE_PATHS[i]}" db="${db}"
    done
    os::table '编号' '站点' '目录' '数据库' -- "${cells[@]}"
    SITE_LIST_SHOWN=1
    os::output 0 count="${n}"
    return 0
}

action_show() {
    local id=''
    site_pick '看哪个站点' id

    local name=${id#*:} type=${id%%:*}
    local path db db_user db_host
    path=$(os::state_get "${id}" path)
    db=$(os::state_get "${id}" db)
    db_user=$(os::state_get "${id}" db_user)
    db_host=$(os::state_get "${id}" db_host)

    site_dir_usage "${path}"
    site_caddy_ref "${path}"
    site_db_exists "${db}"

    local dir_state='不存在（目录已被删除或移走）'
    [[ -d ${path} ]] && dir_state="存在${SITE_DIR_USAGE:+ · 占用 ${SITE_DIR_USAGE}}"

    local db_txt='（本工具没有为它建库）'
    if [[ -n ${db} ]]; then
        case ${SITE_DB_STATE} in
            yes) db_txt="${db} · 存在" ;;
            no) db_txt="${db} · 已不存在" ;;
            *) db_txt="${db} · 无法确认（MariaDB 未运行）" ;;
        esac
    fi

    os::section "站点 ${name}"
    os::kv '组件标识' "${id}" \
        '类型' "${type}" \
        '目录' "${path}" \
        '目录状态' "${dir_state}" \
        '数据库' "${db_txt}" \
        '数据库账号' "${db_user:-（无）}${db_user:+@${db_host}}" \
        'Caddy 配置' "${SITE_CADDY_REF:-没有任何配置文件引用这个目录}"

    # 库记着却不在了，是数据丢失的信号（被手工删掉、或恢复到了别的实例），
    # 混在 kv 行里容易被扫过去 —— 单独一句警告
    [[ ${SITE_DB_STATE} == no ]] \
        && os::warn "记录里的数据库 ${db} 在 MariaDB 里已经不存在了，站点多半打不开"
    if [[ -z ${SITE_CADDY_REF} ]]; then
        os::info "站点还没接上 Web 服务 —— 用 oneserver caddy 给 ${path} 配一个站点块"
    fi
    os::info '证书按域名签发，与站点不是一一对应：oneserver caddy cert 看全部证书'

    os::output 0 name="${name}" id="${id}" path="${path}" db="${db}" \
        db_exists="${SITE_DB_STATE}" dir_usage="${SITE_DIR_USAGE}"
    return 0
}

action_delete() {
    local id=''
    site_pick '删哪个站点' id

    local name=${id#*:}
    local path db
    path=$(os::state_get "${id}" path)
    db=$(os::state_get "${id}" db)

    site_dir_usage "${path}"
    site_secrets "${id}"

    local -a items=("删除站点目录 ${path}${SITE_DIR_USAGE:+（${SITE_DIR_USAGE}）}，其中的主题、插件与上传的媒体一并消失")
    items+=("从组件清单里划掉 ${id}")
    if [[ ${#SITE_SECRETS[@]} -gt 0 ]]; then
        items+=("从凭据库删除 ${#SITE_SECRETS[@]} 条凭据（${SITE_SECRETS[*]}）")
    fi
    if [[ -n ${db} ]]; then
        # 库不在这次删除的范围里，但必须在清单上说清楚 —— 否则用户以为
        # 「删站点」把库也带走了，留下一个再也没人认领的库
        items+=("数据库 ${db} 不会被删除（要删另跑 oneserver mariadb delete --name=${db}）")
    fi
    items+=('Caddy 配置不会被改动，站点块要自己去 oneserver caddy 清理')

    os::destroy_confirm --arg confirm-delete-site "${name}" -- "${items[@]}"

    if [[ -d ${path} ]]; then
        os::record_change "删除了站点目录 ${path}"
        # 「禁止自动回滚」类：删掉的站点文件恢复不回来，注册一个假的回滚
        # 只会让失败报告里多一句谎话
        os::run '删除站点目录' -- rm -rf -- "${path}"
    else
        os::warn "站点目录 ${path} 本来就不在，只清理组件登记"
    fi

    # 凭据排在 state 之前删：state 记录没了就再也算不出该删哪些 key，
    # 密码会永久留在 secure.conf 里而没有任何报错（同 uninstall 的顺序）
    local k
    for k in ${SITE_SECRETS[@]+"${SITE_SECRETS[@]}"}; do
        os::secure_del "${k}" || os::warn "删除凭据 ${k} 失败，请手工确认 secure.conf"
    done

    os::state_del "${id}"
    os::ok "站点 ${name} 已删除"
    if [[ -n ${db} ]]; then
        os::info "数据库 ${db} 仍在：oneserver mariadb delete --name=${db}"
    fi
    os::output 0 name="${name}" id="${id}" changed=yes
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
        'show=查看站点详情' 'delete=删除站点'
}

dispatch() {
    case ${1} in
        list) action_list ;;
        show) action_show ;;
        delete) action_delete ;;
        *) os::die 2 "未知操作「${1}」，可用：list show delete" ;;
    esac
}

main "$@"
