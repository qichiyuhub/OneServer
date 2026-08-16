#!/bin/bash
#
# 系统更新与自动安全更新
#
# 装 unattended-upgrades 这一半照章登记进 `auto-updates` 组件（一个本工具装的包
# 加一个新建的配置文件，卸载它不降低任何东西的可用性）—— 与 SSH 加固那边有意
# **不**登记配置文件是两回事，那边卸载即还原等于在卸载动作里降低安全性。
#
# @command      safe updates
# @name         系统更新与自动安全更新
# @group        security
# @order        30
# @privilege    root
# @requires_lib >= 4.2
# @provides     auto-updates
# @provides_unit ext:unattended-upgrades.service
# @args         [--upgrade=<y|n>] [--auto-security=<y|n>]
# @description  升级已装软件包，并打开每天自动安装安全补丁
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

readonly AUTO_UPGRADES_CONF='/etc/apt/apt.conf.d/20auto-upgrades'
readonly AUTO_UPDATES_ID='auto-updates'

main() {
    # 先刷索引再数数：拿着三个月前的索引报「0 个可升级」，
    # 是这条命令最容易给出的错误结论
    os::pkg_refresh || os::warn '刷新软件包索引失败，下面的数字来自现有索引'

    probe::apt_upgrade_stats
    local upgradable security
    IFS=$'\t' read -r upgradable security <<<"${OS_PROBE_VALUE}"
    [[ ${upgradable} =~ ^[0-9]+$ ]] || upgradable=0
    [[ ${security} =~ ^[0-9]+$ ]] || security=0

    os::section '系统更新'
    os::kv '可升级的包' "${upgradable}" \
        '其中安全更新' "${security}" \
        '数据来源' "$(probe::describe)"

    if ((upgradable > 0)); then
        if os::confirm --arg upgrade "现在升级这 ${upgradable} 个包？" y; then
            # 包边界统一处理 apt 环境、不可中断区段与禁止自动回滚的变更记录。
            os::pkg_upgrade
            # dry-run 下 os::run 被跳过，一个包都没升——不看 OS_RUN_SKIPPED
            # 就打「已升级」，是 D15 说的「会撒谎的 dry-run」
            if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
                os::info "[dry-run] 将升级 ${upgradable} 个包"
            else
                os::ok '软件包已升级'
            fi
        else
            os::info '已跳过升级'
        fi
    else
        os::ok '没有可升级的包，已是目标状态'
    fi

    # --- 自动安全更新 ---
    #
    # **这是这条命令里最值钱的一项。** 手工升级依赖人记得来跑，
    # 而绝大多数被入侵的机器，用的都是一个几个月前就有补丁的漏洞。
    if os::confirm --arg auto-security '开启自动安全更新（每天自动装安全补丁）？' y; then
        os::pkg_install unattended-upgrades || os::die 1 '安装 unattended-upgrades 失败'

        local -i conf_existed=0
        [[ -f ${AUTO_UPGRADES_CONF} ]] && conf_existed=1
        os::install_template --backup "${OS_TEMPLATE_DIR}/20auto-upgrades" "${AUTO_UPGRADES_CONF}" \
            || os::die 1 "写入 ${AUTO_UPGRADES_CONF} 失败"

        os::systemd_enable --now 'unattended-upgrades.service' ext

        # state：装了什么就记什么，卸载时才有原料。
        # **只记本次真正装上的包**（规范两层过滤），也只在文件是本次新建时
        # 才把它记成 file —— Ubuntu 出厂就带着这个文件（实测值就是 1;1），
        # 把它记成「我们创建的」会让卸载删掉发行版自己的配置
        probe::package_version unattended-upgrades
        os::state_set "${AUTO_UPDATES_ID}" version="${OS_PROBE_VALUE}" method=apt
        local pkg
        while IFS= read -r pkg; do
            [[ -n ${pkg} ]] || continue
            os::state_resource_add "${AUTO_UPDATES_ID}" pkg "${pkg}"
        done < <(os::pkg_installed_names)
        if [[ ${conf_existed} -eq 0 ]]; then
            os::state_resource_add "${AUTO_UPDATES_ID}" file "${AUTO_UPGRADES_CONF}"
        fi

        if [[ ${OS_TEMPLATE_CHANGED} -eq 0 ]]; then
            os::ok '自动安全更新已是开启状态'
        else
            os::ok "自动安全更新已开启（配置在 ${AUTO_UPGRADES_CONF}）"
        fi
        os::info '看它都干了什么：less /var/log/unattended-upgrades/unattended-upgrades.log'
    else
        os::info '已跳过自动安全更新'
    fi

    probe::reboot_required
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        os::warn '有更新要重启才生效。挑个合适的时间：reboot'
    fi

    probe::apt_upgrade_stats
    local upgradable_now
    IFS=$'\t' read -r upgradable_now _ <<<"${OS_PROBE_VALUE}"
    os::output 0 upgradable="${upgradable_now:-0}" security="${security}"
    return 0
}

main "$@"
