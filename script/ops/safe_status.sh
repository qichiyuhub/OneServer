#!/bin/bash
#
# 安全体检 —— 只读，一个字都不改
#
# **每条风险后面都跟一条可直接复制的命令**。体检报告只报数等于把判断全推给
# 用户，而看得懂「passwordauthentication yes」意味着什么的人，本来也不需要
# 这个工具。
#
# 防火墙只报一句开没开，装卸启停与规则全归 `oneserver firewall`：同一件事有
# 两个入口的话，用户得先猜自己要的在哪一边，两边的实现还会各漂各的。
#
# **`root-nolock`**：全程只有 probe，一个副作用都没有（§6 允许的那一档）。
# 要 root 是因为非 root 探测只会得到降级值 —— 把降级值当体检结论比不体检更糟。
# 不持全局锁是因为体检最该派上用场的时刻，恰恰是别的命令正跑着或刚出过事那会儿，
# 而持锁会让它以退出码 5 拒绝。代价照 §6 说清：它可能撞上一次正在进行的变更，
# 于是报出中途状态（装了一半的包、刚停还没启的服务）—— 再跑一次就对了。
#
# @command      safe status
# @name         安全体检
# @group        security
# @order        10
# @privilege    root-nolock
# @requires_lib >= 1.26
# @description  一屏看清 SSH、防火墙与更新现状并给出建议
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

readonly SSHD_DROPIN='/etc/ssh/sshd_config.d/00-oneserver.conf'

# 这台机器是不是 socket 激活的 SSH。socket 激活时监听由 systemd 完成、端口写在
# ssh.socket 的 ListenStream 里，sshd_config 的 `Port` 完全不起作用 —— 不报这一行，
# 用户看到的端口号可能根本不是真在听的那个。
#
# 与 safe_ssh.sh 里那份是同一段。**两处相似不提取**：下沉到 lib 要为一个只有
# 两个消费者的判断新增公开接口与 API 版本，第三个消费者出现时再说。
safe_socket_activated() {
    probe::unit_exists 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == yes ]] || return 1
    probe::service_enabled 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == enabled ]] && return 0
    probe::service_active 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == active ]] && return 0
    return 1
}

main() {
    probe::ssh_port
    local port=${OS_PROBE_VALUE}
    local port_src
    port_src=$(probe::describe)

    local socket='no'
    safe_socket_activated && socket='yes'

    probe::sshd_effective passwordauthentication
    local pw=${OS_PROBE_VALUE:-未知}
    probe::sshd_effective kbdinteractiveauthentication
    local kbd=${OS_PROBE_VALUE:-未知}
    probe::sshd_effective pubkeyauthentication
    local pubkey=${OS_PROBE_VALUE:-未知}
    probe::sshd_effective permitrootlogin
    local rootlogin=${OS_PROBE_VALUE:-未知}

    # root 的公钥数。**不问用户看谁**：体检不该有交互点，
    # 而 root 是这个工具的运行身份，也是绝大多数 VPS 的登录身份
    probe::ssh_authkeys root
    local rootkeys=${OS_PROBE_VALUE}

    probe::ufw_active
    local ufw=${OS_PROBE_VALUE}

    probe::apt_upgrade_stats
    local upgradable security
    IFS=$'\t' read -r upgradable security <<<"${OS_PROBE_VALUE}"
    # 探测超时或 apt 不可用时值是空的。**空串不能直接进 (( ))** ——
    # 文件头是 `set -u`，算术里的空/非数字会当变量名解析，直接把脚本带走
    [[ ${upgradable} =~ ^[0-9]+$ ]] || upgradable=0
    [[ ${security} =~ ^[0-9]+$ ]] || security=0
    probe::auto_upgrades
    local auto=${OS_PROBE_VALUE}
    local auto_txt='未开启'
    [[ ${auto} =~ ^[1-9] ]] && auto_txt='已开启'
    probe::reboot_required
    local reboot=${OS_PROBE_VALUE:-no}

    local dropin='未使用'
    [[ -f ${SSHD_DROPIN} ]] && dropin=${SSHD_DROPIN}

    os::section 'SSH'
    os::kv '监听端口' "${port}" \
        'socket 激活' "${socket}" \
        '密码登录' "${pw}" \
        'PAM 交互式登录' "${kbd}" \
        '公钥登录' "${pubkey}" \
        'root 登录' "${rootlogin}" \
        'root 的公钥数' "${rootkeys}" \
        '本工具的配置片段' "${dropin}" \
        '数据来源' "${port_src}"

    os::section '防火墙与更新'
    os::kv 'UFW' "$([[ ${ufw} == yes ]] && printf '已启用' || printf '未启用')" \
        '可升级的包' "${upgradable}" \
        '其中安全更新' "${security}" \
        '自动安全更新' "${auto_txt}" \
        '需要重启' "${reboot}"

    local -i todo=0
    os::section '建议'
    if [[ ${pw} == yes ]]; then
        todo+=1
        if ((rootkeys > 0)); then
            os::warn '密码登录开着 —— 公网机器上被暴力破解的主要入口。已有公钥，可以关：oneserver safe ssh --password-auth=no'
        else
            os::warn '密码登录开着，而 root 还没有任何公钥。先装公钥：oneserver safe ssh --pubkey="ssh-ed25519 AAAA..." --password-auth=no'
        fi
    fi
    if [[ ${rootlogin} == yes && ${pw} == yes ]]; then
        todo+=1
        os::warn 'root 可以直接用密码登录，这是最坏的一档：oneserver safe ssh --permit-root-login=prohibit-password'
    fi
    if [[ ${ufw} != yes ]]; then
        todo+=1
        os::warn '防火墙没启用，所有监听中的端口都对公网开着：oneserver firewall enable'
    fi
    if ((security > 0)); then
        todo+=1
        os::warn "有 ${security} 个安全更新待安装：oneserver safe updates"
    fi
    if [[ ${auto_txt} == 未开启 ]]; then
        todo+=1
        os::info '没开自动安全更新 —— 装完就不用惦记的一件事：oneserver safe updates --auto-security=y'
    fi
    if [[ ${reboot} == yes ]]; then
        todo+=1
        os::warn '有更新要重启才生效：reboot'
    fi
    if ((todo == 0)); then
        os::ok '没有发现需要处理的项'
    fi

    os::output 0 port="${port}" socket_activated="${socket}" \
        password_auth="${pw}" permit_root_login="${rootlogin}" \
        pubkey_auth="${pubkey}" root_authkeys="${rootkeys}" \
        ufw_active="${ufw}" upgradable="${upgradable}" security_upgradable="${security}" \
        auto_updates="${auto_txt}" reboot_required="${reboot}" todo="${todo}"
    return 0
}

main "$@"
