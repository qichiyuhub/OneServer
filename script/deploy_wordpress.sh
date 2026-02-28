#!/bin/bash
#
# WordPress 快速部署脚本
#
# 功能概述：
#   本脚本用于自动化部署 WordPress 站点，包括数据库创建、文件下载、配置生成和权限设置。
#   交互式输入数据库信息，并可选强制覆盖现有部署。
#
# 主要步骤：
#   1. 先决条件检查（配置文件、目录状态）
#   2. 数据库信息收集与验证
#   3. 数据库和用户创建（支持覆盖现有）权限localhost
#   4. WordPress 下载与解压
#   5. wp-config.php 配置（包括安全密钥和Redis设置）
#   6. 文件权限设置
#   7. 部署完成总结
#
# 依赖项：
#   - MariaDB/MySQL 客户端
#
# 日志文件：
#   所有操作日志保存在 /var/log/oneserver/deploy_wordpress.log
#
# 安全说明：
#   - 使用严格错误处理（set -Eeuo pipefail）
#   - 敏感信息（如数据库密码）通过安全配置文件管理
#   - 临时文件使用 mktemp 创建并在退出时清理
#   - 避免在命令行中暴露密码，使用 --defaults-extra-file
#

set -Eeuo pipefail

# ==============================================================================
# 配置常量
# ==============================================================================
readonly APP_NAME="WordPress 部署脚本"
readonly SECURE_CONF="/opt/oneserver/secure.conf"
readonly WP_DIR="/var/www/wordpress"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/deploy_wordpress.log"

# ==============================================================================
# 输出样式定义
# ==============================================================================
# shellcheck disable=SC2034
readonly CYAN='\033[0;36m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
# 初始化设置
# ==============================================================================
mkdir -p "$LOG_DIR"
true > "$LOG_FILE"
TMP_DIR=$(mktemp -d)
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# ==============================================================================
# 函数定义
# ==============================================================================

log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    echo -e "${color}${message}${NC}"
    printf "%s\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

run_command() {
    local description="$1"
    shift
    local command_and_args=("$@")
    {
        echo "---"
        echo "执行: $description"
        echo "命令: ${command_and_args[*]}"
        if "${command_and_args[@]}"; then
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

# ==============================================================================
# 主函数
# ==============================================================================
main() {
    log "CYAN" "--- ${APP_NAME} 启动 ---"

    # 步骤 1: 先决条件检查
    log "CYAN" "\n[1/7] 正在进行先决条件检查..."
    if [[ ! -f "$SECURE_CONF" ]]; then
        log "RED" "错误: 未找到安全配置文件: ${SECURE_CONF}"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$SECURE_CONF"
    if [[ -z "${DB_ROOT_PASS:-}" ]]; then
        log "RED" "错误: 未在 secure.conf 中找到 MariaDB root 密码 (DB_ROOT_PASS)。"
        exit 1
    fi

    if [ -d "$WP_DIR" ] && [ "$(ls -A "$WP_DIR")" ]; then
        log "RED" "警告: 目标目录 '${WP_DIR}' 已存在且不为空！"
        local confirm
        read -rp "是否强制覆盖执行? (y/N): " confirm < /dev/tty
        if [[ "${confirm,,}" != "y" ]]; then
            log "YELLOW" "已安全退出，未做任何修改。"
            exit 1
        fi
        log "RED" "!!! 注意：即将删除 ${WP_DIR} 并重新部署 !!!"
        run_command "删除现有 WordPress 目录" rm -rf "$WP_DIR"
    fi
    log "GREEN" "先决条件检查通过。"

    # 步骤 2-3: 收集并创建数据库信息
    log "CYAN" "\n[2-3/7] 收集并创建数据库信息..."
    local DB_NAME DB_USER DB_PASS
    while true; do
        while true; do
            read -rp "  - 数据库名: " DB_NAME < /dev/tty
            if [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then break; else echo -e "    ${RED}格式无效，仅允许字母、数字和下划线。${NC}"; fi
        done
        while true; do
            read -rp "  - 数据库用户: " DB_USER < /dev/tty
            if [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]]; then break; else echo -e "    ${RED}格式无效，仅允许字母、数字和下划线。${NC}"; fi
        done
        while true; do
            read -rsp "  - 数据库密码: " DB_PASS < /dev/tty; echo
            if [[ -n "$DB_PASS" ]]; then break; else echo -e "    ${RED}密码不能为空。${NC}"; fi
        done

        local DB_EXISTS USER_EXISTS
        DB_EXISTS=$(mariadb --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "$DB_ROOT_PASS") -sN -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '${DB_NAME}';")
        USER_EXISTS=$(mariadb --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "$DB_ROOT_PASS") -sN -e "SELECT User FROM mysql.user WHERE User = '${DB_USER}' AND Host = 'localhost';")

        if [[ -n "$DB_EXISTS" || -n "$USER_EXISTS" ]]; then
            log "YELLOW" "警告: 数据库 '${DB_NAME}' 或用户 '${DB_USER}' 已存在。"
            local confirm_delete
            read -rp "是否要删除并重建? (y/N): " confirm_delete < /dev/tty
            if [[ "${confirm_delete,,}" != "y" ]]; then
                log "CYAN" "好的，请重新输入数据库信息。"
                continue
            fi
            log "CYAN" "确认操作，即将删除并重建..."
        fi

        mariadb --defaults-extra-file=<(printf "[client]\nuser=root\npassword=%s" "$DB_ROOT_PASS") <<EOSQL >> "$LOG_FILE" 2>&1
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOSQL

        log "GREEN" "数据库和用户已成功创建。"
        break
    done

    log "CYAN" "正在将 WordPress 数据库凭据写入 ${SECURE_CONF}..."
    run_command "清理旧的 WordPress 凭据" sed -i -e '/^DB_NAME=/d' -e '/^DB_USER=/d' -e '/^DB_PASS=/d' "$SECURE_CONF"
    cat <<EOF >> "$SECURE_CONF"
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
EOF
    log "GREEN" "WordPress 数据库凭据已保存。"

    # 步骤 4: 下载并解压 WordPress
    log "CYAN" "\n[4/7] 正在下载并解压 WordPress..."
    if ! wget -q -O "${TMP_DIR}/wordpress.tar.gz" https://cn.wordpress.org/latest-zh_CN.tar.gz; then
        log "RED" "错误: 下载 WordPress 失败"
        exit 1
    fi
    run_command "解压 WordPress" tar -xzf "${TMP_DIR}/wordpress.tar.gz" -C "$TMP_DIR"
    run_command "确保 www 目录存在" mkdir -p "$(dirname "$WP_DIR")"
    run_command "移动 WordPress 文件" mv "${TMP_DIR}/wordpress" "$WP_DIR"
    log "GREEN" "WordPress 已部署到 ${WP_DIR}"

    # 步骤 5: 配置 wp-config.php
    log "CYAN" "\n[5/7] 正在配置 wp-config.php..."
    local WP_CONFIG_PATH="${WP_DIR}/wp-config.php"
    run_command "创建 wp-config.php 文件" cp "${WP_DIR}/wp-config-sample.php" "$WP_CONFIG_PATH"
    run_command "设置数据库名" sed -i "s/database_name_here/${DB_NAME}/" "$WP_CONFIG_PATH"
    run_command "设置数据库用户" sed -i "s/username_here/${DB_USER}/" "$WP_CONFIG_PATH"
    run_command "设置数据库密码" sed -i "s/password_here/${DB_PASS}/" "$WP_CONFIG_PATH"
    run_command "设置数据库字符集为 utf8mb4" sed -i "s/define( *'DB_CHARSET', *'utf8' *);/define( 'DB_CHARSET', 'utf8mb4' );/" "$WP_CONFIG_PATH"
    
    log "CYAN" "  - 正在配置安全密钥..."

    # 检查是否存在密钥区域标记
    if ! grep -q "/\*\*#@+" "$WP_CONFIG_PATH" || ! grep -q "/\*\*#@-\*/" "$WP_CONFIG_PATH"; then
        log "RED" "错误: 找不到安全密钥区域标记！"
        exit 1
    fi

    # 获取新的安全密钥
    log "YELLOW" "正在从WordPress API获取安全密钥..."
    local SALT_KEYS
    SALT_KEYS=$(wget -qO- https://api.wordpress.org/secret-key/1.1/salt/)
    if [[ -z "$SALT_KEYS" ]]; then
        log "RED" "错误: 无法从 WordPress API 获取安全密钥！"
        exit 1
    fi

    # 找到密钥区域的开始和结束行号
    local START_LINE END_LINE
    START_LINE=$(grep -n "/\*\*#@+" "$WP_CONFIG_PATH" | cut -d: -f1)
    END_LINE=$(grep -n "/\*\*#@-\*/" "$WP_CONFIG_PATH" | cut -d: -f1)

    # 删除开始标记和结束标记之间的所有内容（保留标记行）
    sed -i "${START_LINE},${END_LINE}{/define(/d;}" "$WP_CONFIG_PATH"

    # 重新找到结束标记的行号（因为删除操作可能改变了行号）
    END_LINE=$(grep -n "/\*\*#@-\*/" "$WP_CONFIG_PATH" | cut -d: -f1)

    # 在结束标记的上方插入新的密钥（使用 END_LINE-1 来定位）
    local TEMP_FILE
    TEMP_FILE=$(mktemp)
    echo "$SALT_KEYS" > "$TEMP_FILE"
    sed -i "$((END_LINE-1))r ${TEMP_FILE}" "$WP_CONFIG_PATH"
    rm -f "$TEMP_FILE"

    log "GREEN" "安全密钥已成功配置。"

    log "CYAN" "  - 正在配置 Redis 缓存支持..."

    # 检查是否已经存在 Redis 配置
    if grep -q "WP_REDIS_HOST" "$WP_CONFIG_PATH"; then
        log "YELLOW" "Redis 配置已存在，跳过配置。"
    else
        # 找到停止编辑行的行号
        local STOP_LINE
        STOP_LINE=$(grep -n "That's all, stop editing" "$WP_CONFIG_PATH" | cut -d: -f1)
        if [[ -z "$STOP_LINE" ]]; then
            log "RED" "错误: 找不到停止编辑行！"
            exit 1
        fi
        
        # 构建 Redis 配置
        local REDIS_CONFIG
        REDIS_CONFIG="define('WP_REDIS_HOST', '127.0.0.1');\n"
        REDIS_CONFIG+="define('WP_REDIS_PORT', 6379);\n"
        if [[ -n "${REDIS_PASS:-}" ]]; then
            REDIS_CONFIG+="define('WP_REDIS_PASSWORD', '${REDIS_PASS}');\n"
        fi
        REDIS_CONFIG+="define('WP_CACHE', true);\n"
        REDIS_CONFIG+="define('FS_METHOD', 'direct');"
        
        # 在停止编辑行的上方插入 Redis 配置
        TEMP_FILE=$(mktemp)
        echo -e "$REDIS_CONFIG" > "$TEMP_FILE"
        sed -i "$((STOP_LINE-1))r ${TEMP_FILE}" "$WP_CONFIG_PATH"
        rm -f "$TEMP_FILE"
        
        echo "Redis and FS_METHOD config injected." >> "$LOG_FILE"
    fi

    log "GREEN" "wp-config.php 配置完成。"

    # 步骤 6: 设置文件权限
    log "CYAN" "\n[6/7] 正在设置文件权限..."
    log "CYAN" "  - 正在将 'caddy' 用户添加到 'www-data' 组..."
    if id caddy &>/dev/null; then
        run_command "添加 caddy 到 www-data 组" usermod -a -G www-data caddy
    else
        log "YELLOW" "警告: 未找到 'caddy' 用户，跳过。"
    fi

    run_command "确保 /var/www 目录可访问" chmod 755 /var/www
    run_command "设置 WordPress 目录所有权" chown -R www-data:www-data "$WP_DIR"
    run_command "设置目录标准权限 (755)" find "$WP_DIR" -type d -exec chmod 755 {} \;
    run_command "设置文件标准权限 (644)" find "$WP_DIR" -type f -exec chmod 644 {} \;
    run_command "为 wp-content 目录设置宽松权限" find "$WP_DIR/wp-content" -type d -exec chmod 775 {} \;
    run_command "为 wp-content 文件设置宽松权限" find "$WP_DIR/wp-content" -type f -exec chmod 664 {} \;

    local unlock_config
    read -rp "是否开启插件对 wp-config.php 写入权限? (Y/n): " unlock_config < /dev/tty
    if [[ -z "${unlock_config}" || "${unlock_config,,}" == "y" ]]; then
        run_command "设置 wp-config.php 为可写 (664)" chmod 664 "$WP_CONFIG_PATH"
        log "YELLOW" "  - wp-config.php 已设为可写 (664)。安装插件后建议手动改回 644。"
    else
        run_command "设置 wp-config.php 为安全默认值 (644)" chmod 644 "$WP_CONFIG_PATH"
        log "GREEN" "  - wp-config.php 权限已设为安全默认值 (644)。"
    fi

    # 步骤 7: 最终说明
    log "CYAN" "\n[7/7] 部署完成！"
    log "CYAN" "所有凭据都已记录在: ${YELLOW}${SECURE_CONF}${NC}"
    log "GREEN" "\n--- WordPress 部署成功，请配置你的 PHP 和 Caddy ---"
}

main "$@"
