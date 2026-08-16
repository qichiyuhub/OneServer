#!/bin/bash
#
# 主题预览
#
# @command      ui preview
# @name         主题预览
# @group        toolbox
# @order        20
# @privilege    any
# @requires_lib >= 1.3
# @args         [--demo] [--demo-ask]
# @description  展示主题的全部语义元素，用来调 theme.conf
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 调外观的唯一实用方式。没有它，改一次 /etc/oneserver/theme.conf
# 要跑一遍真实安装才看得到效果 —— 而「跑一遍真实安装」这件事本身有副作用。
#
# **这个脚本自己也必须零外观代码**。它一个色号、一个边框字符都没有：
# 展示什么样子，是下面两层说了算。预览脚本里但凡自己画一笔，
# 看到的就不再是真的 —— 那就等于没有这个命令。

section_messages() {
    os::section '消息'
    os::info '进行中的一句话'
    os::ok '成功'
    os::warn '需要注意（这一行走 stderr）'
    os::err '失败（这一行也走 stderr）'
    return 0
}

section_kv() {
    os::section '键值'
    os::kv \
        '版本' '2.0.0-dev' \
        '监听地址' '127.0.0.1' \
        '中文键要对齐' '按显示宽度补齐，不按字节' \
        '配置' '/etc/oneserver/theme.conf'
    return 0
}

section_table() {
    os::section '表格'
    os::table '组件' '版本' '状态' -- \
        'caddy' '2.8.4' '运行中' \
        'php:8.3' '8.3.11' '运行中' \
        'mariadb' '11.4.2' '已停止' \
        '中文列名也会对齐' '—' '—'
    return 0
}

# 按真实主屏的样子摆全套：状态总览、提示、分组标题、可执行条目、可下潜条目（`›`）
# 与导航页脚。少摆一样，这个命令就不再等于「看到的即是真的」。
#
# 编号从 1 数起 —— 每一屏都按屏重排，`@order` 只决定排序不上屏（D32）。
# `--keep-screen` 不能省：菜单默认清屏，不留着的话上面几节全被擦掉。
section_menu() {
    os::section '菜单'
    os::menu_render \
        --keep-screen \
        --title 'OneServer' \
        --notice '这一屏没有编号 9' \
        --status '系统' 'Debian 13 · 内核 6.12.0' \
        --status '已装' 'Caddy · MariaDB' \
        --group '服务' \
        --item 1 '数据库管理' \
        --subitem 2 'Podman 容器' '查看、启停、日志与删除' \
        --group '系统' \
        --subitem 3 '安装与部署' 'Caddy 安装 · Valkey 安装 等' \
        --hint '1,3' '只要这几个' \
        --hint 'none' '都不要' \
        --nav root
    return 0
}

section_box() {
    os::section '强调块'
    os::box '安装完成' -- \
        '站点目录  /var/www/blog' \
        '数据库    wp_blog' \
        '证书      由 Caddy 自动申请'
    return 0
}

# 失败时框架打的两段用的就是这里这几种样式：
# 错误行 + 强调块里的明细。样式取自同一套语义接口，
# 因此改主题时这里看到的与真出事时看到的是同一个东西
section_failure() {
    os::section '错误块'
    os::err '安装 Redis 失败（退出码 1）'
    os::box '已自动撤销' -- \
        '删除了 /etc/redis/redis.conf.oneserver' \
        '还原了 /etc/redis/redis.conf'
    os::box '需人工确认' -- \
        'apt 安装的 redis-server 未卸载' \
        'systemctl status redis-server'
    return 0
}

section_progress() {
    os::section '进度'
    # 非 TTY 下会降级成按比例打行，那也是要能看的一种样子
    os::progress 6 10 '下载中'
    os::progress 10 10 '完成'
    return 0
}

# 确认提示**真的调 os::confirm**，不照着样子仿一个：
# 仿出来的那份会随渲染层的改动悄悄失真，而这个命令的全部意义就是
# 「看到的即是真的」。这个确认点零副作用，选什么都不做事。
section_confirm() {
    os::section '确认提示'
    if os::confirm --arg demo '这是一个确认提示，选什么都不会有副作用' n; then
        os::ok '你选了「是」'
    else
        os::info '你选了「否」（或按了回车用默认值）'
    fi
    return 0
}

# 一次问答三行的样子：问题 + 尾注 · 说明 · 输入符。**这一节最值得看**，
# 因为「输入永远另起一行、`❯` 只属于那一行」是所有提问共用的形状，
# 改主题时一眼就能看出它有没有被破坏。零副作用，输入什么都只回显。
section_ask() {
    os::section '提问'
    local demo=''
    os::ask --arg demo-ask --hint '说明夹在问题与输入之间，说清怎样才算合法' \
        '这是一个提问' demo '回车就用这个默认值'
    os::kv '收到的答案' "${demo}"
    return 0
}

main() {
    section_messages
    section_kv
    section_table
    section_menu
    section_box
    section_failure
    section_progress
    section_ask
    section_confirm

    os::output 0
    return 0
}

main "$@"
