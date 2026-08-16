#!/bin/bash
#
# OneServer 命令脚本开发骨架（以 Redis 为示例）
#
# 本文件供开发新命令时复制参考，不是真实的 Redis 安装命令，
# 也不会被命令注册器载入或显示在用户菜单中。
# 以下元数据与实现仅用于展示完整的命令脚本结构。
# @command      install redis
# @name         安装/升级 Redis
# @group        install
# @order        100
# @privilege    root
# @requires_lib >= 1.0
# @provides     redis
# @provides_unit ext:redis-server.service
# @args         [--bind=<addr>] [--allow-remote]
# @description  安装 Redis 并完成基础安全配置
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

main() {
    # 1) 幂等检查 —— 系统事实一律经 probe（规范）
    local installed_ver
    installed_ver=$(probe::component_version redis) || true
    if [[ -n "${installed_ver}" ]]; then
        os::ok "Redis ${installed_ver} 已安装，无需变更"
        return 0
    fi

    # 2) 交互 —— 每个调用点都有 --arg，且名字已在 @args 声明
    local bind_addr
    os::ask --arg bind "Redis 监听地址" bind_addr "127.0.0.1"

    # 3) 安全默认值 —— 放宽监听必须默认 n，且同步落实补偿控制
    if [[ "${bind_addr}" != "127.0.0.1" ]]; then
        os::confirm --arg allow-remote "监听 ${bind_addr} 会暴露服务，确认?" n \
            || os::die 130 "已取消"
        os::run "限制 6379 来源" -- ufw allow from 10.0.0.0/8 to any port 6379 proto tcp
    fi

    # 4) 安装 —— apt 属「禁止自动回滚」类，只记录不撤销
    #    包管理器事务放进不可中断区段
    os::record_change "apt 安装 redis-server"
    os::critical_begin "安装 redis-server"
    os::run "安装 Redis" -- apt-get install -y --no-install-recommends redis-server
    os::critical_end

    # 5) 改配置 —— 属「先备份再改」类，替换用临时文件 + mv
    os::backup_file /etc/redis/redis.conf
    os::replace_line /etc/redis/redis.conf '^bind ' "bind ${bind_addr}"

    # 6) 凭据 —— 命名空间 key，密码经环境变量不进 argv（规范）
    local pass
    pass=$(os::run_out "生成密码" -- openssl rand -base64 32)
    os::secure_set "global.redis_pass" "${pass}"
    os::run --env REDISCLI_AUTH="${pass}" "验证连接" -- redis-cli ping

    # 7) unit —— 经 lib/systemd.sh，已在 @provides_unit 声明为 ext:
    os::systemd_enable redis-server.service

    # 8) 状态上报 —— 组件标识完整
    local ver
    ver=$(probe::component_version redis)
    os::state_set redis version="${ver}" method=apt

    # 9) 结果 —— 结构化输出，不自行排版
    os::kv "版本" "${ver}" "监听" "${bind_addr}" "配置" /etc/redis/redis.conf
    os::ok "Redis ${ver} 安装完成"
}

main "$@"
