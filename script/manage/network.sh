#!/bin/bash
#
# 网络定位。**这台机器的容器端口对谁开放，只在这里定一次。**
#
# @command      network
# @name         网络定位（公网 / 内网）
# @group        security
# @order        40
# @privilege    root
# @requires_lib >= 1.26
# @provides_unit ext:docker.service
# @args         [--network-mode=<公网|内网>] [--confirm-internal=<y|n>] [--restart-docker=<y|n>]
# @description  定下容器端口绑本机还是对局域网开放
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# 它同时决定两件必须一致的事，而这正是它存在的理由 —— 分成两个开关的话，
# 用户每建一个容器都要想「绑哪个地址」还要再去改一次防火墙，两边对不上时
# 现场表现是「端口明明发布了却连不上」，而两处看起来都是对的：
#
#            容器端口绑定           ufw 转发策略
#   公网     127.0.0.1（只本机）    DROP
#   内网     0.0.0.0（局域网可达）  ACCEPT
#
# **两个引擎落实这张表的方式不同，而这不是实现细节，是安全边界本身：**
#
#   podman —— 绑定地址在建容器时写进 Quadlet（`oneserver podman run` 补的），
#             防火墙那一半由下面的 DEFAULT_FORWARD_POLICY 兜底。
#   docker —— 绑定地址写进 `/etc/docker/daemon.json` 的 `"ip"`，此后每一条
#             `docker run` 都算数。**防火墙那一半对它完全不成立** ——
#             dockerd 启动时把自己的跳转插在 FORWARD 链最前面，发布出去的
#             端口在 ufw 的任何规则之前就被 ACCEPT 了。把 Docker 的防护
#             寄托在 ufw 上，得到的是一个看起来两边都对、实际毫无防护的状态。
#
# 为什么防火墙那一半是 DEFAULT_FORWARD_POLICY 而不是按网桥或网段放行：
# 网桥不止一个也不固定 —— 默认网络是 podman0，`podman network create` 与
# compose 项目各自建网络会得到 podman1、podman2…，网桥名还能自定义；网段同理
# （默认 10.88.0.0/16，新建的从 default_subnet_pool 里分）。写死网桥或网段的
# 规则，用户建第二个网络那天就失效，**而失效是静默的**。
#
# 容器端口走的是转发不是入站：包一进来就被 DNAT 成容器地址，不再是本机地址，
# 于是走 FORWARD 链。所以 `ufw allow <端口>` 那种入站规则对容器一个字都不管用。
#

readonly UFW_DEFAULTS='/etc/default/ufw'
# ufw 的输出在不同 locale 下措辞不同，而下面要靠文本判定结果
readonly UFW_ENV='LC_ALL=C'
readonly DAEMON_JSON='/etc/docker/daemon.json'
# 网络定位落在 state 的这个组件下 —— 两个容器引擎都读它决定端口绑哪个地址
readonly NETWORK_ID='network'
readonly DOCKER_ID='docker'

# 转发策略只是**兜底**：显式的 `ufw route allow` 规则排在它前面，命中即放行，
# 默认策略根本轮不到。所以公网定位光把 DEFAULT_FORWARD_POLICY 设成 DROP 不够 ——
# 已有的 ALLOW FWD 规则会让容器端口照样可达，而界面上写着「只绑本机」。
# 不列出来的话，这句话就是假的。
#
# **只列不删**：删防火墙规则不可逆，而且这些规则未必都是入站放行 ——
# 「From 是容器网段」的那条是容器出网，删了所有容器连不上网。哪条该留只有人知道。
list_forward_rules() {
    # **先看防火墙开没开。** `ufw status` 在未启用时只打一行 `Status: inactive`，
    # 一条 FWD 规则都读不出来 —— 于是下面那个循环收不到东西、静默返回，
    # 用户拿到的是「没有规则会绕过转发策略」这个印象。而真相要严重得多：
    # 防火墙没启用时**整条转发策略都不生效**，不是被个别规则绕过。
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::warn '防火墙未启用，刚设的转发策略此刻一点约束力都没有 —— 容器转发一律放行。要它生效，先 oneserver firewall enable'
        os::info '公网定位的另一半（容器端口只绑 127.0.0.1）不依赖防火墙，那一半照常生效'
        return 0
    fi

    probe::ufw_rules
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    local line
    local -a fwd=()
    while IFS= read -r line; do
        [[ ${line} == *'ALLOW FWD'* ]] || continue
        fwd+=("${line}")
    done <<<"${OS_PROBE_VALUE}"
    [[ ${#fwd[@]} -gt 0 ]] || return 0

    os::warn '下列转发放行规则会绕过上面的转发策略 —— 命中它们的容器端口仍然可达：'
    for line in "${fwd[@]}"; do
        os::info "    ${line}"
    done
    os::info '读法是「目标 ALLOW FWD 来源」：来源为容器网段的那条是容器出网，删了容器断网；'
    os::info '目标为容器网段的那条才是外部进容器的放行'
    os::info '要关掉用 oneserver firewall 删，本命令不替你删'
    return 0
}

# /etc/default/ufw 里当前的转发策略，读不到按发行版默认的 DROP 算
forward_policy() {
    local p='DROP'
    if os::query --timeout 5 -- grep -oE '^DEFAULT_FORWARD_POLICY="[A-Z]+"' "${UFW_DEFAULTS}"; then
        p=${OS_RUN_OUTPUT#*\"}
        p=${p%\"}
    fi
    printf '%s' "${p}"
}

apply_forward_policy() {
    local want=${1}
    # 系统事实只出自 probe::（§3），不绕开它自己判 command -v
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::info '本机没有 ufw，转发不受限制，只记录定位'
        return 0
    fi
    [[ $(forward_policy) == "${want}" ]] && return 0

    # 「先备份再改」类：/etc/default/ufw 是发行版的 conffile，不可重建
    os::record_change "把 ${UFW_DEFAULTS} 的 DEFAULT_FORWARD_POLICY 改成 ${want}"
    os::replace_line --backup "${UFW_DEFAULTS}" '^DEFAULT_FORWARD_POLICY=' \
        "DEFAULT_FORWARD_POLICY=\"${want}\"" \
        || os::die 1 "${UFW_DEFAULTS} 里找不到 DEFAULT_FORWARD_POLICY 行，配置文件可能已被大改"

    # 未启用时 reload 是空操作：ufw 打「Firewall not enabled (skipping reload)」
    # 并返回 0 —— 那时说「已生效」是假话
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        os::run --env "${UFW_ENV}" '重载 UFW 使转发策略生效' -- ufw reload
    else
        os::warn 'UFW 当前未启用，转发策略要等启用后才生效（oneserver firewall enable）'
    fi
    return 0
}

# Docker 那一半的定位。**它与 ufw 那一半不是同一个机制**，理由见上面表格下的
# 说明：防火墙管不住 Docker 发布的端口，能管住的只有绑定地址本身。
#
# 只动**本工具放下的那一份** daemon.json（安装时登记在 docker 组件的 file
# 清单里）。用户自己的配置不覆盖（§12），那时只能明说这一半没落实 ——
# 装作落实了才是真正危险的。
apply_docker_bind_ip() {
    local mode=${1}

    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    # 与 install_docker.sh 是同一张表
    local bind_ip='127.0.0.1'
    [[ ${mode} == 内网 ]] && bind_ip='0.0.0.0'

    local f
    local -i owns=1 created=0
    if [[ -f ${DAEMON_JSON} ]]; then
        owns=0
        while IFS= read -r f; do
            if [[ ${f} == "${DAEMON_JSON}" ]]; then
                owns=1
                break
            fi
        done < <(os::state_resources "${DOCKER_ID}" file)
    else
        created=1
    fi

    if ((owns == 0)); then
        os::warn "${DAEMON_JSON} 是你自己的配置，本命令不改它 —— Docker 这一半的定位没有落实"
        os::info "要落实：在里面写 \"ip\": \"${bind_ip}\"，然后 systemctl restart docker"
        return 0
    fi

    if ! os::install_template --backup --mode 0644 \
        "${OS_TEMPLATE_DIR}/docker-daemon.json" "${DAEMON_JSON}" "BIND_IP=${bind_ip}"; then
        os::warn "写入 ${DAEMON_JSON} 失败 —— Docker 这一半的定位没有落实"
        return 0
    fi
    ((created == 1)) && os::state_resource_add "${DOCKER_ID}" file "${DAEMON_JSON}"
    [[ ${OS_TEMPLATE_CHANGED} -eq 1 ]] || return 0

    # 不重启就是「写进去了但没生效」，而界面上看不出这个区别。
    # 有容器在跑时才问：那时重启是一次真实的服务中断
    probe::docker_running
    local running=${OS_PROBE_VALUE:-0}
    [[ ${running} =~ ^[0-9]+$ ]] || running=0
    local -i do_restart=1
    if ((running > 0)); then
        os::warn "重启 dockerd 会中断正在跑的 ${running} 个容器（带重启策略的会自己起回来）"
        os::confirm --arg restart-docker '现在重启 dockerd 让新的绑定地址生效' y || do_restart=0
    fi
    if ((do_restart == 1)); then
        os::systemd_restart docker.service
        os::ok "Docker 新建容器的端口默认绑 ${bind_ip}"
    else
        os::warn "${DAEMON_JSON} 已写入但尚未生效 —— dockerd 重启之前，新建容器仍按旧的默认地址绑"
    fi
    return 0
}

# 已有容器的绑定地址是**建的时候就定死的**，改定位不会追溯 —— podman 写在
# Quadlet 里，Docker 写在容器自身的配置里。不列出来的话，用户以为切完就生效了，
# 而那几个容器还是老样子。
# **只列不改**：改绑定要重建容器，那是实打实的服务中断，得由人挑时间。
list_mismatched_containers() {
    local mode=${1}
    probe::podman_ports
    check_ports_against_mode "${mode}" 'oneserver podman'
    probe::docker_ports
    check_ports_against_mode "${mode}" 'oneserver docker'
    return 0
}

# 读 OS_PROBE_VALUE 里的「名字<制表符>映射」，挑出与定位不符的那些。
# 两个引擎的探测输出是同一种格式，所以判断只写一遍
check_ports_against_mode() {
    local mode=${1} how=${2}
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    local line name ports
    local -a bad=()
    while IFS=$'\t' read -r name ports; do
        [[ -n ${name} && -n ${ports} ]] || continue
        if [[ ${mode} == 内网 && ${ports} == *'127.0.0.1:'* ]]; then
            bad+=("${name}  ${ports}  —— 绑在本机，局域网连不上")
        elif [[ ${mode} == 公网 && ${ports} == *'0.0.0.0:'* ]]; then
            bad+=("${name}  ${ports}  —— 绑在 0.0.0.0，对外暴露")
        fi
    done <<<"${OS_PROBE_VALUE}"

    [[ ${#bad[@]} -gt 0 ]] || return 0
    os::warn "下列容器的端口绑定与新定位不符（绑定地址在建容器时定死，本命令不会改它）："
    for line in "${bad[@]}"; do
        os::info "    ${line}"
    done
    os::info "要让它们跟上，用 ${how} 删掉后按同一条 run 命令重建"
    return 0
}

# ------------------------------------------------------------------

main() {
    local current
    current=$(os::state_get "${NETWORK_ID}" mode '')

    os::section '网络定位'
    probe::ufw_active
    os::kv '当前定位' "${current:-（未设置，按公网处理）}" \
        'UFW' "$([[ ${OS_PROBE_VALUE} == yes ]] && printf '已启用' || printf '未启用')" \
        '转发策略' "$(forward_policy)"

    # **登记值与实际值可能对不上，必须当场说出来。** 最常见的成因是 ufw 被
    # purge 过：/etc/default/ufw 是发行版 conffile，purge 连它一起删，重装后回到
    # 默认 DROP，而 state 里那条记录没人去动。症状是内网定位下 podman 发布的
    # 端口连不上（走 FORWARD 链被兜底 DROP），而这一屏只报当前值的话看起来
    # 一切正常 —— 一个已经失效的设定伪装成生效的
    if [[ -n ${current} ]]; then
        local recorded actual
        recorded=$(os::state_get "${NETWORK_ID}" forward_policy '')
        actual=$(forward_policy)
        if [[ -n ${recorded} && ${recorded} != "${actual}" ]]; then
            os::warn "登记的转发策略是 ${recorded}，${UFW_DEFAULTS} 里实际是 ${actual} —— 防火墙那一半没生效（ufw 被重装过？）。下面重选一次定位即可修复"
        fi
    fi

    # `--keep-screen`：上面那几行（当前定位、转发策略、以及可能的「登记值与
    # 实际值对不上」告警）正是回答这个问题要看的东西，清屏就全没了
    local mode=''
    os::select --keep-screen --arg network-mode '这台机器怎么用？' mode \
        '公网=公网服务器 —— 容器端口只绑本机，一律走 Caddy 反代' \
        '内网=内网机器 —— 容器端口直接对局域网开放'

    if [[ ${mode} == 内网 ]]; then
        os::warn '内网定位会放开 ufw 的转发策略 —— 等于让本机转发它能路由的一切，不只是容器'
        if ! os::confirm --arg confirm-internal '确认这台机器在可信内网？' n; then
            os::info '已取消，定位未改变'
            os::output 0 mode="${current}" changed=no
            return 0
        fi
    fi

    local want_policy='DROP'
    [[ ${mode} == 内网 ]] && want_policy='ACCEPT'
    apply_forward_policy "${want_policy}"
    apply_docker_bind_ip "${mode}"

    os::state_set "${NETWORK_ID}" mode="${mode}" forward_policy="${want_policy}"
    os::ok "网络定位：${mode}"
    if [[ ${mode} == 内网 ]]; then
        os::info '此后新建容器发布的端口直接对局域网可达，不用再动防火墙'
    else
        os::info '此后新建容器发布的端口只绑 127.0.0.1，对外请用 oneserver caddy 反代'
    fi

    [[ ${mode} == 公网 ]] && list_forward_rules
    list_mismatched_containers "${mode}"
    os::output 0 mode="${mode}" policy="${want_policy}" changed=yes
    return 0
}

main "$@"
