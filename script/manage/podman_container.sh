#!/bin/bash
#
# 容器管理
#
# @command      podman
# @name         Podman 容器
# @self_name    容器列表与操作
# @group        container
# @order        10
# @requires     podman
# @privilege    root
# @requires_lib >= 4.0
# @provides_unit ext:podman-auto-update.timer
# @args         [--action=<ls|start|stop|restart|logs|rm|autoupdate|au-on|au-off|au-now>] [--name=<名字>] [--auto-update=<on|off>] [--lines=<行数>] [--confirm-rm=<名字>]
# @description  创建、查看、启停、日志、删除与自动更新
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 本脚本只管**已有**容器：看、启停、看日志、删、切自动更新
# ==================================================================
#
# 建容器（粘 run 命令翻译成 Quadlet）在 `oneserver podman run` 里 —— 那部分
# 逻辑（切词、flag 表、Quadlet 生成）体量与这里的管理动作不是一类事，拆开维护。
#
# **本工具建的容器一律走 Quadlet**（`/etc/containers/systemd/<名>.container`），
# 所以这里的启停走 systemd 的 `<名>.service`，删除时**只停止禁用 unit、
# 不删 unit 文件**（文件是 Quadlet 生成的，不是我们放的，D36）。
#
# **不是本工具建的容器照样列出来，但不碰**（`ls` 里「本工具托管」那一栏）：
# 机器上可能有别人 `podman run` 起来的东西，把它们藏起来会让人以为没有，
# 而替它们做决定更糟。
#
# ==================================================================
# 自动更新是**标签 + 定时器**两件事，缺一不成
# ==================================================================
#
# 标签（Quadlet 里的 `AutoUpdate=registry`）说的是「这个容器愿意被更新」，
# 真正去拉镜像重启容器的是系统自带的 `podman-auto-update.timer`。**只打标签
# 不开定时器，什么都不会发生** —— 这正是「切换了自动更新却没有任何反应」的
# 来源，所以这一屏两件事都要能管，列表页两件事都要显示。
#
# 定时器是 `ext:` 的（发行版包带来的），开关只用 enable/disable，**不删文件**。
# 它是全机一份，开关影响机器上所有打了标签的容器，不是单个容器的设置。

readonly QUADLET_DIR='/etc/containers/systemd'
readonly NAME_RE='^[a-z0-9][a-z0-9_-]{0,62}$'
readonly AUTOUPDATE_TIMER='podman-auto-update.timer'

# ------------------------------------------------------------------

# Quadlet 生成的服务名。`foo.container` → `foo.service`（Quadlet 的固定约定）
unit_of() {
    local __pc_out=${1} __pc_name=${2}
    printf -v "${__pc_out}" '%s' "${__pc_name}.service"
    return 0
}

quadlet_file_of() {
    local __pc_out=${1} __pc_name=${2}
    printf -v "${__pc_out}" '%s' "${QUADLET_DIR}/${__pc_name}.container"
    return 0
}

require_podman() {
    probe::component_version podman
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Podman。先 oneserver install podman'
    os::require_cmd podman systemctl
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "容器名「${name}」不合法：只收小写字母、数字、下划线与短横线，且以字母或数字开头"
    return 0
}

# 同一屏里的表格编号就是后续操作的选择符；不再为了选容器再弹一份名单。
# 只在这轮进程里缓存，任何操作结束后回到总览都会重新查询，不会拿旧编号办事。
PC_LIST_READY=0
PC_IDS=()
PC_NAMES=()
PC_IMAGES=()
PC_STATUS=()
PC_PORTS=()
PC_MANAGED=()
PC_PROJECTS=()
PC_AUTOUPDATE=()

short_cell() {
    local text=${1-}
    local -i limit=${2:-32}
    if ((${#text} > limit)); then
        printf '%s…\n' "${text:0:limit-1}"
    else
        printf '%s\n' "${text}"
    fi
    return 0
}

# 从一份 .container 文件里读出镜像、端口与自动更新标记。
# 纯 bash 读文件，不起外部进程：这是列表里每个「只剩配置」的容器都要走一次的路。
QM_IMAGE=''
QM_PORTS=''
QM_AUTOUPDATE=''
quadlet_meta() {
    local __pc_file=${1} __pc_line
    QM_IMAGE=''
    QM_PORTS=''
    QM_AUTOUPDATE=''
    while IFS= read -r __pc_line || [[ -n ${__pc_line} ]]; do
        case ${__pc_line} in
            Image=*) QM_IMAGE=${__pc_line#Image=} ;;
            PublishPort=*) QM_PORTS="${QM_PORTS:+${QM_PORTS},}${__pc_line#PublishPort=}" ;;
            AutoUpdate=registry) QM_AUTOUPDATE='registry' ;;
        esac
    done <"${__pc_file}"
    return 0
}

load_container_rows() {
    os::query --timeout 20 -- \
        podman ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{index .Labels "io.podman.compose.project"}}\t{{index .Labels "com.docker.compose.project"}}\t{{index .Labels "io.containers.autoupdate"}}'
    local list=${OS_RUN_OUTPUT}

    PC_IDS=()
    PC_NAMES=()
    PC_IMAGES=()
    PC_STATUS=()
    PC_PORTS=()
    PC_MANAGED=()
    PC_PROJECTS=()
    PC_AUTOUPDATE=()
    PC_LIST_READY=1

    local line line_safe id name image status ports proj_podman proj_docker autoupdate project qfile managed
    local IFS=$'\n'
    for line in ${list}; do
        [[ -n ${line} ]] || continue
        # 制表符是 IFS 空白，会折叠连续空字段；先换成非空白哨兵再拆。
        line_safe=${line//$'\t'/$'\x01'}
        IFS=$'\x01' read -r id name image status ports proj_podman proj_docker autoupdate <<<"${line_safe}"
        [[ ${proj_podman} == '<no value>' ]] && proj_podman=''
        [[ ${proj_docker} == '<no value>' ]] && proj_docker=''
        [[ ${autoupdate} == '<no value>' ]] && autoupdate=''
        project=${proj_podman:-${proj_docker}}
        quadlet_file_of qfile "${name}"
        managed=0
        [[ -f ${qfile} ]] && managed=1

        PC_IDS+=("${id}")
        PC_NAMES+=("${name}")
        PC_IMAGES+=("${image}")
        PC_STATUS+=("${status}")
        PC_PORTS+=("${ports}")
        PC_MANAGED+=("${managed}")
        PC_PROJECTS+=("${project}")
        PC_AUTOUPDATE+=("${autoupdate}")
    done

    # --- Quadlet 里定义着、而 podman 已经没有的容器 ---
    #
    # 服务失败到 start-limit-hit 之后，Quadlet 会把容器对象删掉，于是
    # `podman ps -a` 里一行都不剩 —— **本工具建的容器从本工具的列表里消失**，
    # 而那正是用户最需要找到它去看日志、去删了重建的时刻。`.container` 文件
    # 还在，名字从文件名来，状态问 systemd 要。
    #
    # **先把 IFS 拨回来。** 上面按行切 podman 输出时把它改成了 `$'\n'`，而下面
    # 这一段一个字符串都不用切，却要调 unit_of / probe / quadlet_meta ——
    # 让框架接口在一个被改过的 IFS 下运行是 D91 那个坑的来源。
    IFS=$'\n\t'

    local qf qname qunit qstate
    local -i k found
    for qf in "${QUADLET_DIR}"/*.container; do
        [[ -f ${qf} ]] || continue
        qname=${qf##*/}
        qname=${qname%.container}

        found=0
        for ((k = 0; k < ${#PC_NAMES[@]}; k++)); do
            if [[ ${PC_NAMES[k]} == "${qname}" ]]; then
                found=1
                break
            fi
        done
        ((found == 0)) || continue

        unit_of qunit "${qname}"
        probe::service_active "${qunit}"
        qstate=${OS_PROBE_VALUE}
        quadlet_meta "${qf}"

        # ID 留空不是遗漏，是这一行要传达的事实：容器对象已经不存在了。
        # 后续动作（启停、日志、删除）全部按名字走 unit 与 .container 文件，
        # 不碰 ID，所以这样的行照样可选、可操作。
        PC_IDS+=('')
        PC_NAMES+=("${qname}")
        PC_IMAGES+=("${QM_IMAGE}")
        PC_STATUS+=("${qstate} · 无容器")
        PC_PORTS+=("${QM_PORTS}")
        PC_MANAGED+=(1)
        PC_PROJECTS+=('')
        PC_AUTOUPDATE+=("${QM_AUTOUPDATE}")
    done
    return 0
}

select_managed_container() {
    local __pc_out=${1} prompt=${2}
    if [[ ${PC_LIST_READY} -ne 1 ]]; then
        action_ls
    fi

    local -i i selected=-1
    for ((i = 0; i < ${#PC_NAMES[@]}; i++)); do
        [[ ${PC_MANAGED[i]} == 1 ]] && break
    done
    ((i < ${#PC_NAMES[@]})) || os::die 2 '没有本工具托管的 Podman 容器可选'

    local picked=''
    os::ask --arg name "${prompt}（输入上方编号；命令行可传 --name）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        selected=$((picked - 1))
        ((selected >= 0 && selected < ${#PC_NAMES[@]})) \
            || os::die 2 "没有编号为「${picked}」的容器"
        [[ ${PC_MANAGED[selected]} == 1 ]] \
            || os::die 2 "${PC_NAMES[selected]} 不是本工具托管的 Quadlet 容器"
        picked=${PC_NAMES[selected]}
    fi
    validate_name "${picked}"
    local qfile
    quadlet_file_of qfile "${picked}"
    [[ -f ${qfile} ]] || os::die 2 "${picked} 不是本工具托管的容器（没有 ${qfile}）"
    printf -v "${__pc_out}" '%s' "${picked}"
    return 0
}

# ------------------------------------------------------------------

action_ls() {
    require_podman

    load_container_rows
    os::screen_heading '当前容器'
    if [[ ${#PC_NAMES[@]} -eq 0 ]]; then
        os::info '一个都没有。建一个：oneserver podman run'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local managed_label autoupdate_label
    local -i i any_autoupdate=0 any_ghost=0
    for ((i = 0; i < ${#PC_NAMES[@]}; i++)); do
        [[ -z ${PC_IDS[i]} && ${PC_MANAGED[i]} == 1 ]] && any_ghost=1
        managed_label='—'
        if [[ ${PC_MANAGED[i]} == 1 ]]; then
            managed_label='✔ Quadlet'
        elif [[ -n ${PC_PROJECTS[i]} ]]; then
            managed_label="compose:${PC_PROJECTS[i]}"
        fi
        autoupdate_label='—'
        if [[ -n ${PC_AUTOUPDATE[i]} ]]; then
            autoupdate_label='✔ 已标记'
            any_autoupdate=1
        fi
        cells+=("[$((i + 1))]" "${PC_IDS[i]:0:12}" "${PC_NAMES[i]}"
            "$(short_cell "${PC_IMAGES[i]}" 34)" "$(short_cell "${PC_STATUS[i]}" 18)"
            "${managed_label}" "${autoupdate_label}")
        os::output_item "id=${PC_IDS[i]}" "name=${PC_NAMES[i]}" "image=${PC_IMAGES[i]}" \
            "status=${PC_STATUS[i]}" "ports=${PC_PORTS[i]}" "quadlet=${managed_label}" \
            "compose_project=${PC_PROJECTS[i]}" "auto_update=${PC_AUTOUPDATE[i]}"
    done
    os::table '编号' 'ID' '名称' '镜像' '状态' '自启' '自动更新标记' -- "${cells[@]}"

    if ((any_ghost == 1)); then
        os::warn '「无容器」的那几行：配置还在，容器对象已被清掉 —— 多半是服务反复失败到 systemd 不再重试。用「查看日志」看原因，修好配置要删了重建'
    fi

    # 标签与定时器是两件事，只显示标签会让人以为已经开好了
    probe::service_active "${AUTOUPDATE_TIMER}"
    local svc=${OS_PROBE_VALUE}
    local svc_label='未开启'
    [[ ${svc} == active ]] && svc_label='已开启'
    probe::timer_next "${AUTOUPDATE_TIMER}"
    local next=${OS_PROBE_VALUE}
    os::kv '自动更新服务' "${svc_label}${next:+（下次 ${next}）}"
    if ((any_autoupdate == 1)) && [[ ${svc_label} == 未开启 ]]; then
        os::warn '有容器打了自动更新标记，但自动更新服务没开 —— 标记不会生效，用「开启自动更新服务」把它起来'
    fi

    os::output 0 count="${#PC_NAMES[@]}" auto_update_service="${svc_label}"
    return 0
}

# start / stop / restart 共用一段：它们的区别只有一个动词
action_power() {
    local verb=${1}
    require_podman

    local name='' prompt=''
    case ${verb} in
        start) prompt='选择要启动的容器' ;;
        stop) prompt='选择要停止的容器' ;;
        restart) prompt='选择要重启的容器' ;;
    esac
    select_managed_container name "${prompt}"

    local unit qfile
    unit_of unit "${name}"
    quadlet_file_of qfile "${name}"
    [[ -f ${qfile} ]] || os::die 2 "${name} 不是本工具托管的容器（没有 ${qfile}）—— 别处起的容器请直接用 podman"

    case ${verb} in
        start) os::systemd_start "${unit}" ;;
        stop) os::systemd_stop "${unit}" ;;
        restart) os::systemd_restart "${unit}" ;;
    esac

    probe::service_active "${unit}"
    os::ok "${name}：${OS_PROBE_VALUE}"
    os::output 0 name="${name}" action="${verb}" status="${OS_PROBE_VALUE}"
    return 0
}

action_logs() {
    require_podman
    local name='' lines=''
    select_managed_container name '选择要查看日志的容器'
    os::ask --arg lines '显示最近多少行' lines '50'
    [[ ${lines} =~ ^[0-9]+$ ]] || os::die 2 "--lines 要是正整数，收到「${lines}」"

    local unit
    unit_of unit "${name}"
    os::query --timeout 30 -- journalctl -u "${unit}" --no-pager -n "${lines}"
    os::section "${name} 最近 ${lines} 行"
    os::info "${OS_RUN_OUTPUT}"
    os::info "要实时跟：journalctl -u ${unit} -f"
    os::output 0 name="${name}" lines="${lines}"
    return 0
}

action_rm() {
    require_podman
    local name=''
    select_managed_container name '选择要删除的容器'

    local unit qfile
    unit_of unit "${name}"
    quadlet_file_of qfile "${name}"
    [[ -f ${qfile} ]] || os::die 2 "${name} 不是本工具托管的容器（没有 ${qfile}）"

    # 删容器是不可逆的：容器里没写进卷的东西删了就没了。
    # 但**卷本身不删** —— 那是数据，永不自动删除
    if ! os::destroy_confirm --arg confirm-rm "${name}" -- \
        "容器 ${name} 与它的服务 ${unit}" \
        "Quadlet 配置 ${qfile}" \
        '容器内未写入卷的数据（卷本身不会被删）'; then
        os::info '已取消，什么都没有动'
        os::output 130 name="${name}" removed=no
        return 130
    fi

    os::record_change "删除了容器 ${name}"
    # `ext:` 前缀：停止 + 禁用，**不删 unit 文件** —— 那文件是 Quadlet 生成的，
    # 根本不在我们手里（D36）
    os::systemd_remove "ext:${unit}" || true
    os::backup_file "${qfile}" || true
    os::run '删除 Quadlet 配置' -- rm -f -- "${qfile}"
    os::systemd_daemon_reload
    # 服务由生成器产出，daemon-reload 之后就不存在了；容器本体可能还留着
    os::run --allow-fail '清理容器本体' -- podman rm -f "${name}" || true

    os::state_del "container:${name}" || os::warn "从 state 里删除 container:${name} 失败"
    os::ok "容器 ${name} 已删除"
    os::info '它用过的卷与镜像都还在：oneserver podman volume（卷）· oneserver podman image（镜像）'
    os::output 0 name="${name}" removed=yes
    return 0
}

# 切换容器的自动更新标签。**改的是 Quadlet 文件，不是运行中的容器**：
# `io.containers.autoupdate` 标签在容器创建那一刻就定死了，podman 不支持
# 给一个已经在跑的容器改标签，所以这里改完文件必须重启服务，让 systemd
# 用新文件重新 `podman run` 一次 —— 会有一次短暂中断，操作前说清楚。
action_autoupdate() {
    require_podman
    local name=''
    select_managed_container name '选择要设置自动更新的容器'

    local qfile unit
    quadlet_file_of qfile "${name}"
    unit_of unit "${name}"

    local cur='关'
    os::query --timeout 5 -- grep -q '^AutoUpdate=registry$' "${qfile}" \
        && cur='开'

    local target=''
    os::select --arg auto-update "容器 ${name} 当前自动更新：${cur}，改成" target \
        'on=开' 'off=关'
    local target_label='关'
    [[ ${target} == on ]] && target_label='开'

    if [[ ${target_label} == "${cur}" ]]; then
        os::ok "容器 ${name} 的自动更新已经是「${cur}」，未改动"
        os::output 0 name="${name}" auto_update="${target}" changed=no
        return 0
    fi
    os::warn "这会重启容器 ${name} 让新标签生效（有短暂中断）"

    local dir tmp line
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    tmp="${dir}/${name}.container"
    : >"${tmp}"
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} == 'AutoUpdate='* ]] && continue
        printf '%s\n' "${line}" >>"${tmp}"
        if [[ ${target} == on && ${line} == "ContainerName=${name}" ]]; then
            printf 'AutoUpdate=registry\n' >>"${tmp}"
        fi
    done <"${qfile}"

    os::record_change "改了容器 ${name} 的自动更新设置为 ${target_label}"
    os::install_file --backup --mode 0640 "${tmp}" "${qfile}" || os::die 1 "写入 ${qfile} 失败"

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] Quadlet 文件没有真的改，容器不会重启'
        os::output 0 name="${name}" auto_update="${target}" changed=dry-run
        return 0
    fi

    os::systemd_daemon_reload
    os::systemd_restart "${unit}"

    probe::service_active "${unit}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::err "${unit} 没有进入 active"
        os::query --timeout 20 -- journalctl -u "${unit}" --no-pager -n 30
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 "容器 ${name} 重启后没能跑起来，Quadlet 文件已改，容器状态需要人工确认"
    fi

    os::ok "容器 ${name} 的自动更新标签已设为「${target_label}」"
    if [[ ${target} == on ]]; then
        probe::service_active "${AUTOUPDATE_TIMER}"
        [[ ${OS_PROBE_VALUE} == active ]] \
            || os::warn '自动更新服务没开，这个标签暂时不会生效 —— 用「开启自动更新服务」把它起来'
    fi
    os::output 0 name="${name}" auto_update="${target}" changed=yes
    return 0
}

# ------------------------------------------------------------------
# 自动更新服务（全机一份的定时器）
# ------------------------------------------------------------------

# 这个 unit 是发行版包提供的，老版本 podman 没有它。缺了就明说，
# 不能装作开过 —— 「开了但什么都没发生」比「这台机器不支持」难查得多
require_autoupdate_unit() {
    probe::unit_exists "${AUTOUPDATE_TIMER}"
    [[ ${OS_PROBE_VALUE} == yes ]] \
        || os::die 3 "这个 podman 版本没有 ${AUTOUPDATE_TIMER}，自动更新服务无从开启"
    return 0
}

action_au_on() {
    require_podman
    require_autoupdate_unit

    probe::service_active "${AUTOUPDATE_TIMER}"
    if [[ ${OS_PROBE_VALUE} == active ]]; then
        os::ok '自动更新服务已经开着，未改动'
        os::output 0 auto_update_service=on changed=no
        return 0
    fi

    # ext:：包自带的 unit，卸载时只停止禁用、禁止删文件（D36）
    os::systemd_enable --now "${AUTOUPDATE_TIMER}" ext
    os::ok '自动更新服务已开启 —— 只动打了自动更新标记的容器，其余一概不碰'
    os::info '给容器打标记：本屏的「切换自动更新标签」'
    os::output 0 auto_update_service=on changed=yes
    return 0
}

action_au_off() {
    require_podman
    require_autoupdate_unit

    # 两样都要问：只看 active 的话，一个「这次没跑但开机会自启」的定时器会被
    # 当成已经关了，于是重启之后它自己回来
    probe::service_enabled "${AUTOUPDATE_TIMER}"
    local enabled=${OS_PROBE_VALUE}
    probe::service_active "${AUTOUPDATE_TIMER}"
    if [[ ${OS_PROBE_VALUE} != active && ${enabled} != enabled ]]; then
        os::ok '自动更新服务本来就没开，未改动'
        os::output 0 auto_update_service=off changed=no
        return 0
    fi

    # 停 + 禁用两件都要做：只 stop 的话重启机器它照样回来，
    # 而用户以为已经关掉了。容器上的标记留着，再开启时原样生效
    os::systemd_stop "${AUTOUPDATE_TIMER}"
    os::systemd_disable "${AUTOUPDATE_TIMER}"
    os::ok '自动更新服务已关闭（容器上的标记留着，再开启时照旧生效）'
    os::output 0 auto_update_service=off changed=yes
    return 0
}

# 手动跑一轮，不等定时器。定时器没开的人也用得上 ——
# 「我自己决定什么时候更新」是一种合理的用法，不是非要开定时器不可
action_au_now() {
    require_podman

    local -i marked=0
    local -i i
    load_container_rows
    for ((i = 0; i < ${#PC_NAMES[@]}; i++)); do
        [[ -n ${PC_AUTOUPDATE[i]} ]] && marked=1
    done
    ((marked == 1)) \
        || os::die 2 '没有容器打过自动更新标记，跑了也不会动任何东西 —— 先用「切换自动更新标签」标一个'

    os::warn '打了标记的容器里，镜像有新版本的会被拉取并重启，期间这些容器会短暂中断'
    os::record_change '手动执行了一次 podman 自动更新'
    os::run_out '执行一次自动更新' -- podman auto-update \
        || os::die 1 '自动更新执行失败（详情看日志）'

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 更新没有真的执行，结果无从确认'
        os::output 0 changed=dry-run
        return 0
    fi
    os::section '更新结果'
    os::info "${OS_RUN_OUTPUT}"
    os::output 0 changed=yes
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
        'start=启动' 'stop=停止' 'restart=重启' \
        'logs=查看日志' 'rm=删除容器' \
        'autoupdate=切换自动更新标签' \
        'au-on=开启自动更新服务' 'au-off=关闭自动更新服务' 'au-now=立即检查更新'
}

dispatch() {
    case ${1} in
        ls) action_ls ;;
        start) action_power start ;;
        stop) action_power stop ;;
        restart) action_power restart ;;
        logs) action_logs ;;
        rm) action_rm ;;
        autoupdate) action_autoupdate ;;
        au-on) action_au_on ;;
        au-off) action_au_off ;;
        au-now) action_au_now ;;
        *) os::die 2 "未知操作「${1}」，可用：ls start stop restart logs rm autoupdate au-on au-off au-now" ;;
    esac
}

main "$@"
