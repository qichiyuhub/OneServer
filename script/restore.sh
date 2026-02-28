#!/bin/bash
#
# WordPress 恢复脚本
#
# 功能描述：
#   本脚本用于从远程存储（通过Rclone配置）下载WordPress备份文件，并提供四种恢复模式：
#     1. 仅恢复数据库
#     2. 仅恢复媒体库 (uploads目录)
#     3. 仅恢复全部网站文件 (不含数据库)
#     4. 完全恢复 (数据库 + 全部网站文件)
#
# 工作流程：
#   1. 加载环境配置并检查依赖
#   2. 从远程存储获取备份列表并选择要恢复的备份
#   3. 选择恢复模式
#   4. 最终确认操作（危险操作警告）
#   5. 下载、校验并执行恢复操作
#
# 依赖项：
#   mysql, mysqldump, rclone, tar, sha256sum, jq, gzip, sed, pigz (可选)
#
# 配置文件：
#   /opt/oneserver/secure.conf
#

set -Eeuo pipefail

# ==============================================================================
# 配置参数
# ==============================================================================
readonly APP_NAME="WordPress 恢复向导"
readonly CORE_DIR="/opt/oneserver"
readonly SECURE_CONF="${CORE_DIR}/secure.conf"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/restore.log"
readonly WP_DIR="/var/www/wordpress"

# ==============================================================================
# 输出样式定义
# ==============================================================================
readonly CYAN='\033[0;36m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'  # 重置颜色

# ==============================================================================
# 初始化设置
# ==============================================================================
mkdir -p "$LOG_DIR"
true > "$LOG_FILE"
DATE_SUFFIX=$(date +%F_%H-%M-%S)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
exec </dev/tty || true

# ==============================================================================
# 函数定义
# ==============================================================================

# 日志记录函数
log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    echo -e "${color}${message}${NC}"
    printf "%b\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

# 错误处理函数
fail_and_exit() {
    log "RED" "\n--- 操作失败 ---"
    for msg in "$@"; do
        log "YELLOW" "$msg"
    done
    read -n 1 -s -r -p "按任意键返回主菜单..."
    exit 1
}

# 命令执行函数
run_command() {
    local command_str="$1"
    local description="$2"
    {
        echo "---"
        echo "执行: $description"
        echo "命令: $command_str"
        if eval "$command_str"; then
            echo "状态: 成功"
        else
            local exit_code=$?
            echo "状态: 失败 (退出码: $exit_code)"
            fail_and_exit "命令 '${description}' 失败。"
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

# 数据库恢复函数
restore_database() {
    log "CYAN" "\n--- 正在执行数据库恢复 ---"
    local db_backup_path="${TMP_DIR}/db_before_restore_${DATE_SUFFIX}.sql.gz"
    export MYSQL_PWD="${DB_PASS}"
    
    log "CYAN" "  - 正在备份当前数据库 '${DB_NAME}'..."
    if ! mysqldump --user="${DB_USER}" --host="${DB_HOST:-localhost}" --single-transaction --routines --triggers --events --quick --hex-blob "${DB_NAME}" | gzip > "$db_backup_path" 2>>"$LOG_FILE"; then
        unset MYSQL_PWD
        fail_and_exit "备份当前数据库失败！"
    fi
    log "CYAN" "    当前数据库已备份至: ${NC}${db_backup_path}"
    
    log "CYAN" "  - 正在从备份导入数据库..."
    mysql --user="${DB_USER}" --host="${DB_HOST:-localhost}" -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >> "$LOG_FILE" 2>&1
    if ! mysql --user="${DB_USER}" --host="${DB_HOST:-localhost}" "${DB_NAME}" < "${EXTRACT_DIR}/database.sql" 2>>"$LOG_FILE"; then
        unset MYSQL_PWD
        fail_and_exit "从备份文件导入数据库失败！"
    fi
    unset MYSQL_PWD
    log "GREEN" "数据库恢复成功。"
}

# 媒体库恢复函数
restore_uploads() {
    log "CYAN" "\n--- 正在执行媒体库 (uploads) 恢复 ---"
    local uploads_dir="${WP_DIR}/wp-content/uploads"
    local uploads_backup_path="${WP_DIR}/wp-content/uploads.bak.${DATE_SUFFIX}"

    if [[ -d "$uploads_dir" ]]; then
        log "CYAN" "  - 正在备份当前的 'uploads' 目录..."
        run_command "sudo mv '$uploads_dir' '$uploads_backup_path'" "备份 uploads 目录"
        log "CYAN" "    当前 'uploads' 目录已备份至: ${NC}${uploads_backup_path}"
    fi

    log "CYAN" "  - 正在从备份中提取并恢复 'uploads' 目录..."
    run_command "sudo tar -xf '${EXTRACT_DIR}/wordpress_files.tar' -C '${WP_DIR}/wp-content/' 'wordpress/wp-content/uploads' --strip-components=2" "提取 uploads 目录"

    log "CYAN" "  - 正在为 'uploads' 目录设置权限..."
    run_command "sudo chown -R www-data:www-data '$uploads_dir'" "设置 uploads 所有者"
    run_command "sudo find '$uploads_dir' -type d -exec chmod 775 {} \;" "设置 uploads 目录权限"
    run_command "sudo find '$uploads_dir' -type f -exec chmod 664 {} \;" "设置 uploads 文件权限"

    log "GREEN" "媒体库 (uploads) 恢复成功。"
}

# 全站文件恢复函数
restore_all_files() {
    log "CYAN" "\n--- 正在执行全部网站文件恢复 ---"
    local files_backup_path="${WP_DIR}.bak.${DATE_SUFFIX}"
    
    if [[ -d "$WP_DIR" ]]; then
        log "CYAN" "  - 正在归档当前整个网站目录 '${WP_DIR}'..."
        run_command "sudo mv '$WP_DIR' '$files_backup_path'" "备份整个网站目录"
        log "CYAN" "    当前网站目录已重命名为: ${NC}${files_backup_path}"
    fi

    log "CYAN" "  - 正在恢复全部网站文件..."
    run_command "sudo tar -xf '${EXTRACT_DIR}/wordpress_files.tar' -C '$(dirname "$WP_DIR")'" "恢复全部网站文件"
    
log "CYAN" "  - 正在全面修正 'wp-config.php' 以匹配当前环境..."
local wp_config_path="${WP_DIR}/wp-config.php"
if [[ -f "$wp_config_path" ]]; then
    local db_pass_esc="${DB_PASS//&/\\&}"; db_pass_esc="${db_pass_esc//\//\\/}"
    run_command "sudo sed -i \"s/define( *'DB_NAME', *'[^']*' *);/define( 'DB_NAME', '${DB_NAME}' );/\" '$wp_config_path'" "修正 DB_NAME"
    run_command "sudo sed -i \"s/define( *'DB_USER', *'[^']*' *);/define( 'DB_USER', '${DB_USER}' );/\" '$wp_config_path'" "修正 DB_USER"
    run_command "sudo sed -i \"s/define( *'DB_PASSWORD', *'[^']*' *);/define( 'DB_PASSWORD', '${db_pass_esc}' );/\" '$wp_config_path'" "修正 DB_PASSWORD"
    run_command "sudo sed -i \"s/define( *'DB_CHARSET', *'utf8' *);/define( 'DB_CHARSET', 'utf8mb4' );/\" '$wp_config_path'" "修正 DB_CHARSET"
    
    run_command "sudo sed -i \"/define( *'FS_METHOD'/d\" '$wp_config_path'" "移除旧的 FS_METHOD 配置"
    run_command "sudo sed -i \"/define( *'WP_REDIS_HOST'/d\" '$wp_config_path'" "移除旧的 WP_REDIS_HOST 配置"
    run_command "sudo sed -i \"/define( *'WP_REDIS_PORT'/d\" '$wp_config_path'" "移除旧的 WP_REDIS_PORT 配置"
    run_command "sudo sed -i \"/define( *'WP_REDIS_PASSWORD'/d\" '$wp_config_path'" "移除旧的 WP_REDIS_PASSWORD 配置"
    run_command "sudo sed -i \"/define( *'WP_CACHE'/d\" '$wp_config_path'" "移除旧的 WP_CACHE 配置"
    
    local redis_pass_config=""; if [[ -n "${REDIS_PASS:-}" ]]; then redis_pass_config="define('WP_REDIS_PASSWORD', '${REDIS_PASS}');"; fi
    local config_block="define('FS_METHOD', 'direct');\n"; config_block+="define('WP_REDIS_HOST', '127.0.0.1');\n"; config_block+="define('WP_REDIS_PORT', 6379);\n"
    if [[ -n "$redis_pass_config" ]]; then config_block+="${redis_pass_config}\n"; fi; config_block+="define('WP_CACHE', true);"
    
    if grep -q "/\* That's all, stop editing! Happy publishing\. \*/" "$wp_config_path"; then
        awk -v config="$config_block" '/\/\* That.s all, stop editing! Happy publishing. \*\// { print config; print ""; } { print }' "$wp_config_path" | sudo tee "${wp_config_path}.tmp" >/dev/null && sudo mv "${wp_config_path}.tmp" "$wp_config_path"
    else
        echo -e "\n$config_block" | sudo tee -a "$wp_config_path" >/dev/null
    fi
    
    echo "附加配置已注入 wp-config.php" >> "$LOG_FILE"
    log "GREEN" "    wp-config.php 已全面修正。"
else
    log "YELLOW" "    警告: 未找到 'wp-config.php'，跳过配置修正。"
fi

    
    log "CYAN" "  - 正在设置完整的文件权限..."
    run_command "sudo chown -R www-data:www-data '$WP_DIR'" "设置网站目录所有者"
    run_command "sudo find '$WP_DIR' -type d -exec chmod 755 {} \;" "设置目录标准权限 (755)"
    run_command "sudo find '$WP_DIR' -type f -exec chmod 644 {} \;" "设置文件标准权限 (644)"
    run_command "sudo find '$WP_DIR/wp-content' -type d -exec chmod 775 {} \;" "设置 wp-content 目录宽松权限"
    run_command "sudo find '$WP_DIR/wp-content' -type f -exec chmod 664 {} \;" "设置 wp-content 文件宽松权限"
    
    local unlock_config
    read -rp "    是否开启插件对wp-config.php写入权限? (Y/n): " unlock_config
    unlock_config=${unlock_config:-y}
    if [[ "${unlock_config,,}" == "y" ]]; then
        sudo chmod 664 "$wp_config_path"
    else
        sudo chmod 644 "$wp_config_path"
    fi
    
    log "GREEN" "全部网站文件恢复成功。"
}

# ==============================================================================
# 主函数
# ==============================================================================
main() {
    log "CYAN" "--- ${APP_NAME} (专业版) ---"

    # 1. 加载配置和检查环境
    log "CYAN" "\n[1/5] 正在加载配置并检查环境..."
    if [[ ! -f "$SECURE_CONF" ]]; then
        fail_and_exit "错误: 配置文件不存在: \"${SECURE_CONF}\""
    fi
    
    # shellcheck disable=SC1090
    source "$SECURE_CONF"
    
    for var in DB_NAME DB_USER DB_PASS; do
        if [[ -z "${!var:-}" ]]; then
            fail_and_exit "错误: 配置信息不完整 (${var})。"
        fi
    done
    
    for cmd in mysql mysqldump rclone tar sha256sum jq gzip sed; do
        if ! command -v "$cmd" &>/dev/null; then
            fail_and_exit "错误: 缺少关键命令: '$cmd'"
        fi
    done
    
    if command -v pigz &>/dev/null; then
        TAR_DECOMPRESS_CMD="pigz -d"
    else
        TAR_DECOMPRESS_CMD="gzip -d"
    fi
    readonly TAR_DECOMPRESS_CMD
    log "GREEN" "环境检查通过。"

    # 2. 选择备份文件
    log "CYAN" "\n[2/5] 正在查找并选择备份文件..."
    local -a ALL_BACKUPS=()

    # 显示备份目录信息
    log "CYAN" "备份目录: ${RCLONE_REMOTE_NAME:-oneserver}:${RCLONE_BACKUP_DIR:-backup}"

    if ! mapfile -t ALL_BACKUPS < <(rclone lsf "${RCLONE_REMOTE_NAME:-oneserver}:${RCLONE_BACKUP_DIR:-backup}" --files-only 2>/dev/null | grep -E '\.(tar\.gz|tgz|zip|bak)$' | sort -r); then
        fail_and_exit "错误: 无法连接到远程存储或获取备份列表失败。" "请检查 Rclone 配置、网络连接以及远程备份目录是否存在。"
    fi

    if [[ ${#ALL_BACKUPS[@]} -eq 0 ]]; then
        fail_and_exit "错误: 无法从远程存储获取备份列表，或者远程目录为空。" "请确保 '${RCLONE_REMOTE_NAME:-oneserver}:${RCLONE_BACKUP_DIR:-backup}' 目录中存在备份文件。"
    fi

    log "GREEN" "=== 可用备份列表 (按文件名排序) ==="
    for i in "${!ALL_BACKUPS[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${ALL_BACKUPS[i]}"
    done

    local BACKUP_CHOICE
    read -rp "请选择要恢复的备份 (输入数字) [默认: 1]: " BACKUP_CHOICE
    BACKUP_CHOICE=${BACKUP_CHOICE:-1}

    if ! [[ "$BACKUP_CHOICE" =~ ^[0-9]+$ ]] || (( BACKUP_CHOICE < 1 || BACKUP_CHOICE > ${#ALL_BACKUPS[@]} )); then
        fail_and_exit "错误: 无效选择。"
    fi

    local BACKUP_FILE="${ALL_BACKUPS[$((BACKUP_CHOICE-1))]}"
    log "GREEN" "已选择备份: ${BACKUP_FILE}"


    # 3. 选择恢复模式
    log "CYAN" "\n[3/5] 选择恢复模式..."
    echo -e "  1) ${YELLOW}仅恢复数据库${NC}"
    echo -e "  2) ${YELLOW}仅恢复媒体库 (uploads 目录)${NC}"
    echo -e "  3) ${YELLOW}恢复全部网站文件 (不含数据库)${NC}"
    echo -e "  4) ${YELLOW}完全恢复 (数据库 + 全部网站文件)${NC}"
    
    local RESTORE_MODE
    read -rp "请输入选项 (1-4) [默认: 4]: " RESTORE_MODE
    RESTORE_MODE=${RESTORE_MODE:-4}
    
    local MODE_DESC
    case "$RESTORE_MODE" in
        1) MODE_DESC="仅恢复数据库";;
        2) MODE_DESC="仅恢复媒体库 (uploads 目录)";;
        3) MODE_DESC="恢复全部网站文件 (不含数据库)";;
        4) MODE_DESC="完全恢复 (数据库 + 全部网站文件)";;
        *) fail_and_exit "错误: 无效选项。";;
    esac
    log "GREEN" "已选择模式: ${MODE_DESC}"

    # 4. 最终确认
    log "CYAN" "\n[4/5] 最终确认..."
    echo -e "${RED}==================== 警告！危险操作！ ====================${NC}"
    echo -e "${YELLOW}您已选择: [${MODE_DESC}]${NC}"
    echo -e "${RED}此操作将使用备份文件覆盖现有数据：${NC}"
    [[ "$RESTORE_MODE" == 1 || "$RESTORE_MODE" == 4 ]] && echo -e "${YELLOW}  - 当前数据库 '${DB_NAME}' 将被清空并替换。${NC}"
    [[ "$RESTORE_MODE" == 2 ]] && echo -e "${YELLOW}  - 当前媒体库 '${WP_DIR}/wp-content/uploads' 将被替换。${NC}"
    [[ "$RESTORE_MODE" == 3 || "$RESTORE_MODE" == 4 ]] && echo -e "${YELLOW}  - 当前网站目录 '${WP_DIR}' 将被替换。${NC}"
    echo -e "${RED}==========================================================${NC}"
    
    local CONFIRM
    read -rp "我已完全理解风险并希望继续，请输入 'YES' 确认: " CONFIRM
    if [[ "$CONFIRM" != "YES" ]]; then
        log "YELLOW" "操作已取消。"
        exit 0
    fi

    # 5. 执行恢复
    log "CYAN" "\n[5/5] 开始执行恢复..."
    log "CYAN" "  - 正在下载、校验并解压核心备份文件..."
    local BACKUP_PATH_IN_TMP="${TMP_DIR}/${BACKUP_FILE}"
    run_command "rclone copyto '${RCLONE_REMOTE_NAME:-oneserver}:${RCLONE_BACKUP_DIR:-backup}/${BACKUP_FILE}' '$BACKUP_PATH_IN_TMP'" "下载备份文件"
    run_command "rclone copyto '${RCLONE_REMOTE_NAME:-oneserver}:${RCLONE_BACKUP_DIR:-backup}/${BACKUP_FILE}.sha256' '${BACKUP_PATH_IN_TMP}.sha256'" "下载校验文件"
    log "CYAN" "  - 正在执行文件完整性校验..."
    expected_hash=$(cut -d' ' -f1 "${BACKUP_PATH_IN_TMP}.sha256")
    actual_hash=$(sha256sum "$BACKUP_PATH_IN_TMP" | cut -d' ' -f1)

    if [[ "$expected_hash" == "$actual_hash" ]]; then
        echo "校验成功: 文件哈希值匹配 ($expected_hash)" >> "$LOG_FILE"
        log "GREEN" "校验成功。"
    else
        echo "校验失败: 期望哈希=$expected_hash, 实际哈希=$actual_hash" >> "$LOG_FILE"
        fail_and_exit "文件完整性校验失败！" "下载的文件可能已损坏或被篡改。"
    fi

    EXTRACT_DIR="${TMP_DIR}/extract"
    run_command "mkdir -p '$EXTRACT_DIR'" "创建解压目录"
    run_command "tar -I '$TAR_DECOMPRESS_CMD' -xf '$BACKUP_PATH_IN_TMP' -C '$EXTRACT_DIR'" "解压备份文件"
    log "GREEN" "核心备份文件准备就绪。"

    case "$RESTORE_MODE" in
        1) restore_database ;;
        2) restore_uploads ;;
        3) restore_all_files ;;
        4) restore_database; restore_all_files ;;
    esac

    log "GREEN" "\n--- 恢复操作全部完成 ---"
    log "CYAN" "  - 已根据您的选择 ${NC}[${MODE_DESC}]${CYAN} 从 '${NC}${BACKUP_FILE}${CYAN}' 完成恢复。"
    log "CYAN" "  - 详细日志请查看: ${NC}${LOG_FILE}"
}

# ==============================================================================
# 脚本入口点
# ==============================================================================
main "$@"
