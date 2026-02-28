#!/bin/bash
#
# MariaDB 安装与升级管理脚本
#
# 功能描述：
#   本脚本用于自动化安装或升级 MariaDB 数据库服务器，包含安全初始化配置和远程访问配置。
#   支持版本检测、自动升级、密码安全管理
#
# 安全特性：
#   - 使用安全的密码输入方式
#   - 避免密码泄露到日志或进程列表

set -Eeuo pipefail

# 配置常量
readonly APP_NAME="MariaDB"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/install_mariadb.log"
readonly SECURE_CONF="/opt/oneserver/secure.conf"

# 颜色定义
readonly CYAN='\033[0;36m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# 创建日志目录并初始化日志文件
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
true > "$LOG_FILE"

# 日志记录函数
log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    
    echo -e "${color}${message}${NC}"
    printf "%s\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

# 安全执行命令并记录（过滤敏感信息）
run_command() {
    local command_str="$1"
    local description="$2"
    local sanitized_command
    
    # 过滤密码等敏感信息
    shopt -s extglob
    sanitized_command="${command_str//--password=*([^ ])/--password=***}"
    shopt -u extglob
    
    {
        echo "---"
        echo "执行: $description"
        echo "命令: $sanitized_command"
        
        if eval "$command_str"; then
            echo "状态: 成功"
        else
            local exit_code=$?
            echo "状态: 失败 (退出码: $exit_code)"
            log "RED" "错误: '${description}' 失败。详情请查看日志: ${LOG_FILE}"
            exit $exit_code
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

# 用户确认提示
ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer
    local hint="[Y/n]"
    
    if [[ "$default" == "n" ]]; then
        hint="[y/N]"
    fi
    
    while true; do
        read -rp "$prompt $hint: " answer
        answer=${answer:-$default}
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

# 版本比较函数
compare_versions() {
    local v1="$1" v2="$2"
    IFS='.' read -ra v1_parts <<< "$v1"
    IFS='.' read -ra v2_parts <<< "$v2"
    
    local max_len=$(( ${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]} ))
    
    for ((i = 0; i < max_len; i++)); do
        local p1=${v1_parts[i]:-0}
        local p2=${v2_parts[i]:-0}
        
        if (( 10#$p1 > 10#$p2 )); then
            return 1
        elif (( 10#$p1 < 10#$p2 )); then
            return 2
        fi
    done
    
    return 0
}

# 安装或升级 MariaDB
perform_mariadb_installation() {
    local is_upgrade=${1:-false}
    
    if [[ "$is_upgrade" == true ]]; then
        log "CYAN" "正在升级 MariaDB 软件包..."
    else
        log "CYAN" "正在安装 MariaDB 软件包..."
    fi

    run_command "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq" "更新软件包列表"
    run_command "apt-get install -y -qq mariadb-server mariadb-client" "安装 MariaDB 核心包"
    
    # 注意：初次安装后先不要重启，等配置修改完再统一重启
    if [[ "$is_upgrade" == true ]]; then
        run_command "systemctl restart mariadb" "重启 MariaDB 服务"
    else
        run_command "systemctl start mariadb" "启动 MariaDB 服务"
    fi

    if ! systemctl is-active --quiet mariadb; then
        log "RED" "错误：MariaDB 服务启动失败！"
        log "RED" "请运行 'systemctl status mariadb' 查看日志。"
        exit 1
    fi
    
    run_command "systemctl enable mariadb >/dev/null 2>&1" "设置 MariaDB 开机自启"
    log "GREEN" "MariaDB 安装/升级成功。"
}

# 安全初始化 MariaDB
perform_security_initialization() {
    log "CYAN" "正在执行 MariaDB 安全初始化..."
    
    # 检查现有密码
    local existing_pass=""
    if [[ -f "$SECURE_CONF" ]]; then
        existing_pass=$(grep '^DB_ROOT_PASS=' "$SECURE_CONF" | cut -d= -f2- | tr -d "'" || echo "")
    fi
    
    # 验证现有密码有效性
    if [[ -n "$existing_pass" ]]; then
        if mysqladmin ping -u root --password="${existing_pass}" >/dev/null 2>&1; then
            log "GREEN" "检测到有效的 root 密码，跳过初始化。"
            return 0
        else
            log "YELLOW" "警告：配置文件中的密码无效，将重新初始化。"
        fi
    fi

    # 安全获取新密码
    local DB_ROOT_PASS=""
    echo -e "${CYAN}请输入新的 MariaDB 'root' 用户密码:${NC}"
    
    while true; do
        read -r -s -p "密码: " DB_ROOT_PASS
        echo
        [[ -n "$DB_ROOT_PASS" ]] || {
            echo -e "${YELLOW}密码不能为空。${NC}"
            continue
        }
        
        local DB_ROOT_PASS2
        read -r -s -p "确认密码: " DB_ROOT_PASS2
        echo
        
        [[ "$DB_ROOT_PASS" == "$DB_ROOT_PASS2" ]] && break
        echo -e "${RED}两次输入的密码不一致，请重试。${NC}"
    done
    
    log "CYAN" "正在设置 root 密码并应用安全配置..."
    
    # 使用安全的方式执行 SQL 命令（避免密码出现在进程列表中）
    mysql --user=root <<EOSQL 2>>"$LOG_FILE"
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
        DELETE FROM mysql.user WHERE User='';
        DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
        DROP DATABASE IF EXISTS test;
        DELETE FROM mysql.db WHERE Db='test' OR Db='test\\\\_%';
        FLUSH PRIVILEGES;
EOSQL
    
    # 安全保存密码到配置文件
    run_command "mkdir -p \"$(dirname "$SECURE_CONF")\"" "创建配置目录"
    run_command "sed -i '/^DB_ROOT_PASS=/d' '$SECURE_CONF' 2>/dev/null || true" "清理旧密码"
    
    # 使用安全方式写入密码到 /opt/oneserver/secure.conf
    echo "DB_ROOT_PASS='${DB_ROOT_PASS}'" > "$SECURE_CONF"
    
    # 记录操作但不暴露密码
    {
        echo "---"
        echo "执行: 写入密码到配置文件"
        echo "命令: echo 'DB_ROOT_PASS=***' > '$SECURE_CONF'"
        echo "状态: 成功"
        echo "---"
    } >> "$LOG_FILE" 2>&1
    
    run_command "chmod 600 '$SECURE_CONF'" "设置密码文件权限"
    log "GREEN" "MariaDB root 密码已保存到 ${SECURE_CONF}。"
    log "GREEN" "安全初始化完成。"
}

# ==============================================================================
# 配置 MariaDB 允许远程访问
# ==============================================================================
configure_remote_access() {
    log "CYAN" "正在配置 MariaDB 网络访问权限..."
    
    if ! ask_yes_no "默认只允许本机访问，是否要修改配置以允许远程访问 (0.0.0.0)?" "y"; then
        log "YELLOW" "用户选择跳过远程访问配置。MariaDB 将保持默认的本机访问设置。"
        return 0
    fi

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log "CYAN" "检测到 UFW 防火墙已激活。"
        
        local ufw_prompt="是否要同时添加防火墙规则，允许 Podman 容器网络 (10.0.0.0/8) 访问此主机的 MariaDB (端口 3306)?"
        if ask_yes_no "$ufw_prompt" "y"; then
            run_command "ufw allow from 10.0.0.0/8 to any port 3306 proto tcp" "添加 UFW 规则允许 Podman 网络访问 3306 端口"
        else
            log "YELLOW" "用户选择跳过防火墙配置。请注意，您可能需要手动配置防火墙才能从 Podman 容器中访问。"
        fi
    fi
    # 查找 MariaDB 服务器配置文件
    local conf_file
    if [[ -f "/etc/mysql/mariadb.conf.d/50-server.cnf" ]]; then
        conf_file="/etc/mysql/mariadb.conf.d/50-server.cnf"
    else
        log "YELLOW" "未找到标准的 50-server.cnf，将尝试在目录中搜索..."
        conf_file=$(grep -rl "bind-address" /etc/mysql/mariadb.conf.d/ | head -n 1)
    fi
    
    if [[ -z "$conf_file" ]] || [[ ! -f "$conf_file" ]]; then
        log "RED" "错误：未找到任何包含 'bind-address' 的配置文件。无法自动配置。"
        return 1
    fi
    
    log "CYAN" "将在文件 '${conf_file}' 中修改 bind-address。"
    
    # 检查文件是否已配置正确，如果已配置则无需操作
    if grep -qE "^\s*bind-address\s*=\s*0\.0\.0\.0" "$conf_file"; then
        log "GREEN" "bind-address 已配置为 0.0.0.0，无需修改。"
        return 0
    fi

    local sed_command="sed -i -E 's/^[[:space:]]*#?[[:space:]]*bind-address[[:space:]]*=.*$/bind-address            = 0.0.0.0/' \"${conf_file}\""
    
    run_command "$sed_command" "修改 bind-address 为 0.0.0.0"
    
    if ! grep -qE "^\s*bind-address\s*=\s*0\.0\.0\.0" "$conf_file"; then
        log "RED" "错误：修改配置文件失败！请手动检查 ${conf_file}。"
        log "RED" "请确认该文件中存在 'bind-address' 配置项。"
        return 1
    fi
    
    log "GREEN" "配置文件修改成功。"
    run_command "systemctl restart mariadb" "重启 MariaDB 服务以应用新配置"
}

# 主执行逻辑
main() {
    log "CYAN" "--- ${APP_NAME} 安装与更新工具 ---"
    
    # 检查是否已安装 MariaDB
    if ! dpkg -s mariadb-server >/dev/null 2>&1; then
        log "CYAN" "${APP_NAME} 未安装，即将开始全新安装..."
        perform_mariadb_installation false
    else
        # 获取当前版本信息
        CURRENT_VERSION_FULL=$(dpkg-query -W -f='${Version}' mariadb-server 2>/dev/null || echo "")
        CURRENT_VERSION=$(echo "$CURRENT_VERSION_FULL" | cut -d':' -f2 | cut -d'-' -f1)
        log "GREEN" "检测到 ${APP_NAME} 已安装，当前版本: ${CURRENT_VERSION}"
        
        # 检查最新版本
        log "CYAN" "正在检查最新版本..."
        run_command "apt-get update -qq" "更新软件包列表"
        
        CANDIDATE_VERSION_FULL=$(apt-cache policy mariadb-server | grep 'Candidate:' | awk '{print $2}')
        LATEST_VERSION=$(echo "$CANDIDATE_VERSION_FULL" | cut -d':' -f2 | cut -d'-' -f1)
        
        if [[ -z "$LATEST_VERSION" ]]; then
            log "YELLOW" "警告: 无法获取最新版本信息。"
            if ! ask_yes_no "是否要强制重新安装?" "n"; then
                log "YELLOW" "操作已取消。"
                exit 0
            fi
            perform_mariadb_installation true
        else
            log "CYAN" "最新可用版本: ${LATEST_VERSION}"
            compare_versions "$CURRENT_VERSION" "$LATEST_VERSION"
            
            case $? in
                2)  # 发现新版本
                    log "YELLOW" "发现新版本！"
                    if ! ask_yes_no "是否从 ${CURRENT_VERSION} 升级到 ${LATEST_VERSION}?" "y"; then
                        log "YELLOW" "操作已取消。"
                        exit 0
                    fi
                    perform_mariadb_installation true
                    ;;
                *)  # 版本相同或更高
                    log "GREEN" "您已是最新版。"
                    if ! ask_yes_no "是否要强制重新安装?" "n"; then
                        log "YELLOW" "操作已取消。"
                        exit 0
                    fi
                    perform_mariadb_installation true
                    ;;
            esac
        fi
    fi
    
    perform_security_initialization
    configure_remote_access
    
    # 最终验证
    log "CYAN" "正在执行最终连接验证..."
    DB_ROOT_PASS=$(grep '^DB_ROOT_PASS=' "$SECURE_CONF" | cut -d= -f2- | tr -d "'" 2>/dev/null || echo "")
    
    if [[ -z "$DB_ROOT_PASS" ]] || ! mysqladmin ping -u root -h 127.0.0.1 --password="${DB_ROOT_PASS}" >/dev/null 2>&1; then
        log "RED" "验证失败"
        log "RED" "无法使用 ${SECURE_CONF} 中的密码连接到数据库！"
        exit 1
    fi
    
    MARIADB_VERSION=$(mysql -V 2>/dev/null | awk '{print $5}' | sed 's/,//')
    
    log "GREEN" "--- ${APP_NAME} 安装/升级成功！ ---"
    log "CYAN" "当前版本: ${NC}${MARIADB_VERSION:-未知}"
    log "CYAN" "连接状态: ${NC}成功"
    log "CYAN" "Root 密码文件: ${NC}${SECURE_CONF}"
    
    # 检查最终的监听地址
    local listen_address
    listen_address=$(ss -tlnp | (grep -E 'mysqld|mariadbd' || true) | awk '{print $4}')
    log "CYAN" "数据库监听地址: ${NC}${listen_address:-未监听或无法检测}"
    
    if [[ "$listen_address" == *"0.0.0.0"* ]]; then
        log "YELLOW" "警告：数据库现在允许远程连接。请确保您的防火墙(如ufw)配置正确，只开放给必要的IP。"
    fi
}

# 执行主函数
main "$@"
