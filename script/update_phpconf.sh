#!/bin/bash
#
# PHP配置更新脚本
#
# 功能：本脚本自动化更新PHP配置文件（php.ini和www.conf）
#       失败时回滚操作。自动检测已安装的PHP版本，
#       备份现有配置，从远程仓库下载新配置，应用配置，
#       验证配置有效性，并重启PHP-FPM服务。
#       若验证失败，自动回滚到更新前状态。
#
#

set -Eeuo pipefail

# --- 配置参数 ---
readonly APP_NAME="PHP配置更新"
readonly REPO_BASE="https://raw.githubusercontent.com/qichiyuhub/OneServer/refs/heads/main/config"
readonly KEEP_BACKUPS=5
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/update_phpconf.log"

# --- 终端颜色定义 ---
# shellcheck disable=SC2034
readonly CYAN='\033[0;36m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
# shellcheck disable=SC2034
readonly RED='\033[0;31m'
# shellcheck disable=SC2034
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
# 日志记录与命令执行框架
# ==============================================================================

mkdir -p "$LOG_DIR"
true > "$LOG_FILE"
TMP_DIR=$(mktemp -d) || { echo "错误：无法创建临时目录"; exit 1; }
trap 'rm -rf "$TMP_DIR"' EXIT
declare -a backups_made_this_run=()

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
        echo "操作: $description"
        echo "命令: ${command_and_args[*]}"
        if "${command_and_args[@]}"; then
            echo "状态: 成功"
        else
            local exit_code=$?
            echo "状态: 失败 (退出码: $exit_code)"
            log "RED" "错误: '${description}' 执行失败。查看日志: ${LOG_FILE}"
            exit $exit_code
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

# ==============================================================================
# 核心脚本功能
# ==============================================================================

rotate_backups() {
    local file_path="$1"
    {
        echo "---"
        echo "操作: 轮转备份文件（保留 ${KEEP_BACKUPS} 个最新备份）"
        echo "目标: $file_path"
        find "$(dirname "$file_path")" -maxdepth 1 -type f -name "$(basename "$file_path").*.bak" -printf '%T@ %p\n' \
        | sort -nr \
        | tail -n "+$((KEEP_BACKUPS + 1))" \
        | cut -d' ' -f2- \
        | xargs -r rm -f --
        echo "状态: 完成"
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

apply_config() {
    local source_file="$1"
    local target_path="$2"
    local php_version="$3"
    
    if [[ ! -f "$source_file" ]]; then
        log "RED" "错误: 源文件 ${source_file} 不存在"
        exit 1
    fi
    
    log "CYAN" "  - 正在应用 ${target_path}..."

    # 替换配置文件中的PHP版本占位符
    if [[ -n "$php_version" ]]; then
        run_command "替换版本占位符为 ${php_version}" sed -i "s/%%PHP_VERSION%%/${php_version}/g" "$source_file"
    fi

    if [[ -f "$target_path" ]]; then
        local backup_path
        backup_path="${target_path}.bak.$(date +%F_%H-%M-%S)"
        run_command "备份当前文件到 ${backup_path}" cp "$target_path" "$backup_path"
        backups_made_this_run+=("$backup_path")
    fi
    
    rotate_backups "$target_path"

    local owner="root:root"
    local perms="644"
    if [[ -e "$target_path" ]]; then
        owner=$(stat -c "%u:%g" "$target_path")
        perms=$(stat -c "%a" "$target_path")
    fi
    
    run_command "移动新文件到目标位置" mv "$source_file" "$target_path"
    run_command "恢复文件所有者" chown "$owner" "$target_path"
    run_command "恢复文件权限" chmod "$perms" "$target_path"
}

main() {
    log "CYAN" "--- ${APP_NAME} 开始执行 ---"

    # 步骤1: 检测已安装的PHP版本
    log "CYAN" "\n[1/6] 正在检测已安装的PHP版本..."
    local PHP_VERSION
    PHP_VERSION=$(find /etc/php -maxdepth 1 -mindepth 1 -type d -printf "%f\n" 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -z "$PHP_VERSION" ]]; then
        log "RED" "错误: 未检测到PHP安装。请先安装PHP。"
        exit 1
    fi
    local PHP_INI_PATH="/etc/php/${PHP_VERSION}/fpm/php.ini"
    local PHP_FPM_CONF_PATH="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    local PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
    log "GREEN" "检测到PHP版本: ${PHP_VERSION}"

    # 步骤2: 准备PHP日志目录
    log "CYAN" "\n[2/6] 正在准备PHP日志目录..."
    local PHP_LOG_DIR="/var/log/php${PHP_VERSION}"
    run_command "创建日志目录" mkdir -p "$PHP_LOG_DIR"
    run_command "创建错误日志文件" touch "${PHP_LOG_DIR}/fpm-error.log"
    run_command "设置日志目录所有者" chown -R www-data:www-data "$PHP_LOG_DIR"
    run_command "设置日志目录权限" chmod -R "u+rwX,go+rX,go-w" "$PHP_LOG_DIR"
    log "GREEN" "PHP日志目录 '${PHP_LOG_DIR}' 权限设置完成"

    # 步骤3: 从仓库下载配置文件
    log "CYAN" "\n[3/6] 正在下载配置文件..."
    local CONFIG_FILES=("php.ini" "www.conf")
    for filename in "${CONFIG_FILES[@]}"; do
        log "CYAN" "  - 正在下载 ${filename}..."
        if ! wget -O "${TMP_DIR}/${filename}" "${REPO_BASE}/${filename}" >> "$LOG_FILE" 2>&1; then
            log "RED" "错误: 下载 ${filename} 失败。检查网络或URL: ${REPO_BASE}/${filename}"
            exit 1
        fi
    done
    log "GREEN" "所有配置文件下载完成"

    # 步骤4: 应用新配置
    log "CYAN" "\n[4/6] 正在应用新配置..."
    apply_config "${TMP_DIR}/php.ini" "$PHP_INI_PATH" "$PHP_VERSION"
    apply_config "${TMP_DIR}/www.conf" "$PHP_FPM_CONF_PATH" "$PHP_VERSION"
    log "GREEN" "新配置应用完成"

    # 步骤5: 验证PHP-FPM配置
    log "CYAN" "\n[5/6] 正在验证PHP-FPM配置..."
    local php_fpm_cmd
    php_fpm_cmd=$(which "php-fpm${PHP_VERSION}" 2>/dev/null || which "php-fpm" 2>/dev/null || echo "php-fpm${PHP_VERSION}")
    
    local validation_output
    if ! validation_output=$("$php_fpm_cmd" -t 2>&1); then
        log "RED" "错误: PHP-FPM配置验证失败!"
        log "YELLOW" "正在执行自动回滚..."
        printf "--- PHP-FPM验证失败 ---\n%s\n---\n" "$validation_output" >> "$LOG_FILE"
        
        if [[ ${#backups_made_this_run[@]} -eq 0 ]]; then
            log "RED" "错误: 未找到回滚所需的备份记录!"
        else
            for backup_path in "${backups_made_this_run[@]}"; do
                local original_file="${backup_path%.bak.*}"
                if [[ -f "$backup_path" ]]; then
                    run_command "从 ${backup_path##*/} 回滚" cp "$backup_path" "$original_file"
                    log "CYAN" "  - 已从 $(basename "$backup_path") 恢复 ${original_file}"
                fi
            done
            log "GREEN" "回滚操作完成"
            
            log "CYAN" "尝试重启服务以恢复到之前的状态..."
            if systemctl restart "$PHP_FPM_SERVICE" >> "$LOG_FILE" 2>&1; then
                log "GREEN" "服务已成功重启，系统已恢复到更新前状态。"
            else
                log "YELLOW" "警告: 回滚后服务重启失败。系统可能需要手动干预。"
                log "YELLOW" "   请运行 'systemctl status ${PHP_FPM_SERVICE}' 检查服务状态"
            fi
        fi
        exit 1
    fi
    log "GREEN" "PHP-FPM配置验证通过"

    # 步骤6: 重启PHP-FPM服务
    log "CYAN" "\n[6/6] 正在重启PHP-FPM服务..."
    if ! systemctl restart "$PHP_FPM_SERVICE" >> "$LOG_FILE" 2>&1; then
        log "RED" "错误: 重启PHP-FPM服务 (${PHP_FPM_SERVICE}) 失败!"
        log "RED" "   请运行 'systemctl status ${PHP_FPM_SERVICE}' 和 'journalctl -u ${PHP_FPM_SERVICE} -n 50' 查看详情"
        exit 1
    fi
    log "GREEN" "PHP-FPM服务重启成功"

    log "GREEN" "\n--- PHP配置更新完成 ---"
}

main "$@"
