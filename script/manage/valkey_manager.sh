#!/bin/bash
#
# Valkey 管理
#
# @command      valkey
# @name         Valkey
# @group        db
# @order        20
# @privilege    root
# @requires_lib >= 4.8
# @args         [--action=<status|allow-containers>] [--allow-containers=<y|n>]
# @description  查看 Valkey 状态，按需放行容器访问
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 这个脚本为什么存在
#
# `install valkey` 是一次性的安装流程，装完就没有入口了。而「让容器连上缓存」
# 是**装完之后按需发生**的事：建一个新容器、加一个新的容器网络，都可能需要
# 重新放行一次。把它塞进安装器意味着用户为了改防火墙要重跑一遍安装，语义不对。
#
# **元数据里特意没有 `@requires valkey`**（同 db_manager 的理由）：那一条查的是
# state，而 state 里只有经 oneserver 装过的东西。用户自己 apt 装的、或者随镜像
# 来的，state 里一个字都没有 —— 于是这条命令会以「缺少依赖组件」拒绝执行，
# 而机器上的 Valkey 正跑得好好的。装没装一律经 probe 判（D93）。

readonly VALKEY_CONF='/etc/valkey/valkey.conf'
readonly VALKEY_UNIT='valkey-server.service'
readonly VALKEY_SECRET_KEY='valkey.password'

# ------------------------------------------------------------------

# 实际生效的端口。**不写死 6379**：用户改过 valkey.conf 的话，防火墙判据必须
# 跟着那个值走，否则查的是一个根本没人听的端口。
# 与 install_valkey.sh 的同名函数是第二处，按「两处相似不提取」不抽公共函数；
# 真出现第三处再评估。
valkey_port() {
    local line port=''
    if [[ -r ${VALKEY_CONF} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ ${line} =~ ^port[[:space:]]+([0-9]+) ]] || continue
            port=${BASH_REMATCH[1]}
            break
        done <"${VALKEY_CONF}"
    fi
    printf '%s' "${port:-6379}"
}

# 配置里当前的 bind 行内容（去掉关键字），读不到给空
valkey_bind() {
    local line out=''
    if [[ -r ${VALKEY_CONF} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ ${line} =~ ^bind[[:space:]]+(.*)$ ]] || continue
            out=${BASH_REMATCH[1]}
            break
        done <"${VALKEY_CONF}"
    fi
    printf '%s' "${out}"
}

# 这个网段放行过没有。规则匹配在 lib/firewall.sh（§11）
vk_subnet_allowed() {
    local subnet=${1} port=${2}
    probe::ufw_rules
    os::ufw_allowed "${OS_PROBE_VALUE}" "${port}" tcp "${subnet}"
}

# ------------------------------------------------------------------

action_status() {
    local port bind ver
    port=$(valkey_port)
    bind=$(valkey_bind)

    probe::component_version valkey
    ver=${OS_PROBE_VALUE:-未知}

    probe::service_active "${VALKEY_UNIT}"
    local running=${OS_PROBE_VALUE}

    os::screen_heading 'Valkey'
    os::kv '版本' "${ver}" \
        '服务状态' "${running}" \
        '监听地址' "${bind:-（配置里没有 bind 行）}" \
        '端口' "${port}" \
        '配置文件' "${VALKEY_CONF}" \
        '密码键名' "${VALKEY_SECRET_KEY}"

    # 容器连不连得上，是这个菜单存在的主要理由，所以直接答出来
    case ${bind} in
        *0.0.0.0* | *'*'*) os::info '监听地址已放开，容器可以连（前提是防火墙放行了对应网段）' ;;
        '') os::warn "${VALKEY_CONF} 里没有 bind 行，无法判断监听范围" ;;
        *) os::info '当前只监听本机，容器连不上 —— 要让容器连，选「允许容器访问」' ;;
    esac

    local allowed
    allowed=$(os::state_get valkey container_access '')
    [[ -z ${allowed} ]] || os::info "上次放行过的容器网段：${allowed}"
    os::info "取密码：oneserver secure get ${VALKEY_SECRET_KEY}"

    os::output 0 version="${ver}" bind="${bind}" port="${port}" running="${running}"
    return 0
}

# ==================================================================
# 允许容器访问
# ==================================================================
#
# 与 db_manager 的同名动作是同一套判据与同一条纪律，只是对象换成 Valkey：
# 放行探测出来的**真实容器网段**（不是拍一个私有段）、幂等可刷新、
# 三道前置缺一不可。差别只有两处 —— 端口从配置读，以及 Valkey 没有传输加密，
# 所以这里的告警要更重一档。
action_allow_containers() {
    local port
    port=$(valkey_port)

    probe::container_subnets
    local subnets=${OS_PROBE_VALUE}
    if [[ -z ${subnets} ]]; then
        os::info '没有探测到任何容器网络 —— docker 与 podman 都没装，或者都没有带网段的网络'
        os::info '装了容器引擎、建过容器之后再回来跑这一步'
        os::output 0 subnets='' changed=no
        return 0
    fi

    local -a nets=()
    mapfile -t nets <<<"${subnets}"

    # §15：放宽访问来源必须在同一步落实补偿控制。补偿控制有三条 ——
    # 放行范围只到实际网段、防火墙本身真的挡得住、以及 Valkey 自带的访问密码。
    #
    # **这一关必须排在下面那张表之前**，理由同 db_manager 的同一处：表里
    # 「已放行 / 本次新增」出自 os::ufw_allowed，而它读的规则文本来自
    # `ufw status` —— 防火墙停用时那条命令读不出任何规则，于是每个网段都会
    # 被标成「本次新增」，紧接着才是一句「防火墙没启用」。
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] \
        || os::die 3 '防火墙没启用，放行无从谈起（而监听地址会因此对全网开放）。先执行 oneserver firewall enable'
    probe::ufw_default_incoming
    case ${OS_PROBE_VALUE} in
        deny | reject) ;;
        *) os::die 3 "防火墙默认入站是 ${OS_PROBE_VALUE}，此时「只放行容器网段」没有意义 —— 没被规则覆盖的来源同样进得来。先把默认入站改成 deny" ;;
    esac

    os::section '将要放行的容器网段'
    local n
    local -a cells=()
    for n in "${nets[@]}"; do
        cells+=("${n}" "$(vk_subnet_allowed "${n}" "${port}" && printf '已放行' || printf '本次新增')")
    done
    os::table '网段' '状态' -- "${cells[@]}"
    os::info "放行之后，这些网段里的容器可以连宿主的 ${port} 端口；其余来源仍被防火墙拒绝"

    # Valkey 没有传输加密，密码在链路上是明文。容器网段内是本机虚拟网络，
    # 风险可接受；但这件事必须说出来，而不是等用户哪天把网段填宽了才发现
    local pass=''
    os::secure_load "${VALKEY_SECRET_KEY}" pass || true
    [[ -n ${pass} ]] \
        || os::die 3 "凭据库里没有 ${VALKEY_SECRET_KEY} —— 没有访问密码的 Valkey 不该放开监听。先跑 oneserver install valkey 让它生成一个"
    os::warn "监听地址会改成 0.0.0.0（容器要够得着），此后挡在外面的是防火墙与访问密码"
    os::warn 'Valkey 没有传输加密，密码在链路上是明文 —— 只放行容器网段，别把范围填宽'
    os::confirm --arg allow-containers '确认放行以上网段？' n \
        || os::die 130 '已取消，未做任何改动'

    local -i added=0
    for n in "${nets[@]}"; do
        vk_subnet_allowed "${n}" "${port}" && continue
        os::ufw_allow "${port}" tcp "${n}" || return 1
        added+=1
    done
    if ((added > 0)); then
        os::ufw_reload || return 1
    fi

    # 监听地址：容器连的是网桥网关，只听 127.0.0.1 的话规则放行了也连不上。
    # protected-mode 保持 yes —— 有密码时它不拦，没密码时它是最后一道闸
    os::replace_line --backup "${VALKEY_CONF}" '^bind ' 'bind 0.0.0.0' \
        || os::die 1 "${VALKEY_CONF} 里找不到 bind 行"
    # **紧邻着读**：OS_REPLACE_CHANGED 是单槽易失变量（§10）
    local -i bind_changed=${OS_REPLACE_CHANGED}
    if [[ ${bind_changed} -eq 1 ]]; then
        os::record_change '把 Valkey 的监听地址改成 0.0.0.0'
        os::systemd_restart "${VALKEY_UNIT}" || os::die 1 'Valkey 重启失败，监听地址可能未生效'
    fi

    local IFS=' '
    os::state_set valkey container_access="${nets[*]}" || true

    # 如实反映这一次有没有产生变更：全都已放行、监听地址也没变时就是 no
    # （§10 幂等：第二次执行不产生任何新变更）
    local changed='no'
    ((added > 0 || bind_changed == 1)) && changed='yes'

    os::ok "已放行 ${added} 个新网段（共 ${#nets[@]} 个）；以后新建了容器网络，重跑这一步即可补上"
    os::info "容器里连缓存用宿主网关地址，例如 docker 默认是 172.17.0.1、podman 默认是 10.88.0.1"
    os::info "密码取法：oneserver secure get ${VALKEY_SECRET_KEY}"
    os::output 0 subnets="${nets[*]}" added="${added}" changed="${changed}"
    return 0
}

# ------------------------------------------------------------------

main() {
    # 装没装一律经 probe（D93）：state 里只有本工具装过的，手工装的照样要能管
    probe::service_active "${VALKEY_UNIT}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::die 3 "Valkey 未在运行。先 oneserver install valkey，或 systemctl start ${VALKEY_UNIT}"
    fi

    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_status --arg action '操作' dispatch \
        'allow-containers=允许容器访问缓存'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        allow-containers) action_allow_containers ;;
        *) os::die 2 "未知操作「${1}」，可用：status allow-containers" ;;
    esac
}

main "$@"
