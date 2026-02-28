#!/bin/bash
#
# ==============================================================================
#  数据库管理脚本
# ==============================================================================
#  功能：查看、创建、删除、备份、恢复数据库
#  特性：
#  - 安全：使用环境变量传递密码，避免进程泄露。
#  - 健壮：完美处理带空格的数据库/文件名。
#  - 现代化：默认创建 utf8mb4 数据库，权限% 支持 Docker/远程连接。
#  - 智能：自动关联数据库和用户，删除时一并清理。
# ==============================================================================

set -Eeuo pipefail

# --- 全局配置 ---
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/manage_db.log"
readonly CONFIG_DIR="/opt/oneserver"
readonly SECURE_CONF="${CONFIG_DIR}/secure.conf"
readonly DB_MAPPING_FILE="${CONFIG_DIR}/db_user_mapping.conf"
readonly BACKUP_DIR="/var/backups/db"

# --- 数据库默认设置 ---
readonly DB_CHARSET="utf8mb4"
readonly DB_COLLATE="utf8mb4_unicode_ci"
# 权限主机：'%' 适用于 Docker 或远程连接; 'localhost' 仅限本机。
readonly DB_USER_HOST="%"

# --- 颜色定义 ---
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'
# ==============================================================================
#  核心工具函数
# ==============================================================================

# 初始化环境，确保目录和文件存在
init() {
    mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
    mkdir -p "$CONFIG_DIR"
    touch "$DB_MAPPING_FILE" && chmod 600 "$DB_MAPPING_FILE"
    mkdir -p "$BACKUP_DIR"
}

# 统一日志记录函数
log() {
    local color_name="$1" message="$2"
    local color
    case "${color_name^^}" in
        CYAN)   color="$CYAN"   ;;
        GREEN)  color="$GREEN"  ;;
        RED)    color="$RED"    ;;
        YELLOW) color="$YELLOW" ;;
        *)      color="$NC"     ;;
    esac
    
    echo -e "${color}${message}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}
# 从安全配置文件中获取数据库 root 密码
get_db_password() {
    if [[ ! -f "$SECURE_CONF" ]]; then
        log "RED" "错误：安全配置文件 ${SECURE_CONF} 不存在。"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$SECURE_CONF"
    if [[ -z "${DB_ROOT_PASS:-}" ]]; then
        log "RED" "错误：在 ${SECURE_CONF} 中未找到 DB_ROOT_PASS。"
        exit 1
    fi
}

# 安全地执行 MariaDB/MySQL 命令
execute_mysql() {
    local sql_command="$1"
    # 使用 MYSQL_PWD 环境变量传递密码，最安全的方式
    MYSQL_PWD="$DB_ROOT_PASS" mysql -u root -e "$sql_command"
}

# 获取所有非系统数据库的列表
get_user_databases() {
    local -n _db_array=$1
    local excluded_dbs="'information_schema', 'performance_schema', 'mysql', 'sys'"
    local sql="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN (${excluded_dbs});"
    mapfile -t _db_array < <(execute_mysql "$sql" | tail -n +2)
}

# ==============================================================================
#  主功能函数
# ==============================================================================

# 1. 查看数据库列表及用户信息
list_databases() {
    log "CYAN" "正在获取数据库列表..."
    local -a databases
    get_user_databases databases

    if (( ${#databases[@]} == 0 )); then
        log "YELLOW" "没有找到用户创建的数据库。"
        return
    fi

    echo -e "\n${CYAN}===== 数据库列表及用户信息 =====${NC}"
    for db_name in "${databases[@]}"; do
        local user
        user=$(grep "^${db_name}:" "$DB_MAPPING_FILE" | cut -d: -f2 || true)

        echo -e "${GREEN}数据库: ${db_name}${NC}"
        if [[ -z "$user" ]]; then
            echo -e "  ${YELLOW}用户: 未在映射文件中找到关联用户${NC}"
        else
            echo -e "  ${CYAN}用户: ${user}@${DB_USER_HOST}${NC}"
        fi
        echo -e "${CYAN}---------------------------------${NC}"
    done
}

# 2. 创建数据库和用户
create_database() {
    log "CYAN" "--- 创建新数据库和用户 ---"
    local db_name username password password_confirm
    while true; do
        read -rp "$(echo -e "${CYAN}请输入新数据库名称: ${NC}")" db_name

        if [[ -z "$db_name" ]]; then
            log "RED" "错误：数据库名称不能为空，请重新输入。"
            continue
        fi

        if execute_mysql "SHOW DATABASES LIKE '$db_name';" | grep -q "."; then
            log "RED" "错误：数据库 '${db_name}' 已存在，请重新输入。"
            continue
        fi

        break
    done

    while true; do
        read -rp "$(echo -e "${CYAN}请输入关联的用户名: ${NC}")" username

        if [[ -z "$username" ]]; then
            log "RED" "错误：用户名不能为空，请重新输入。"
            continue
        fi

        if execute_mysql "SELECT User FROM mysql.user WHERE User = '$username' AND Host = '$DB_USER_HOST';" | grep -q "."; then
            log "RED" "错误：用户 '${username}'@'${DB_USER_HOST}' 已存在，请重新输入。"
            continue
        fi
        
        break
    done
    while true; do
        read -rsp "$(echo -e "${CYAN}请输入密码: ${NC}")" password; echo
        if [[ -z "$password" ]]; then
            log "RED" "错误：密码不能为空，请重新输入。"
            continue
        fi
        
        read -rsp "$(echo -e "${CYAN}请再次输入密码: ${NC}")" password_confirm; echo
        if [[ "$password" == "$password_confirm" ]]; then
            break
        else
            log "RED" "错误：两次输入的密码不一致，请重新输入。"
        fi
    done

    log "CYAN" "正在执行创建操作..."
    local create_db_sql="CREATE DATABASE \`$db_name\` CHARACTER SET $DB_CHARSET COLLATE $DB_COLLATE;"
    local create_user_sql="CREATE USER '$username'@'$DB_USER_HOST' IDENTIFIED BY '$password';"
    local grant_sql="GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$username'@'$DB_USER_HOST';"

    if execute_mysql "$create_db_sql" && \
       execute_mysql "$create_user_sql" && \
       execute_mysql "$grant_sql"; then
        
        echo "${db_name}:${username}" >> "$DB_MAPPING_FILE"
        log "GREEN" "数据库和用户创建成功！"
        
        echo -e "\n${GREEN}===== 数据库信息摘要 =====${NC}"
        echo -e "${CYAN}数据库名: ${NC}$db_name"
        echo -e "${CYAN}用户名:   ${NC}$username"
        echo -e "${CYAN}密码:     ${NC}$password"
        echo -e "${CYAN}授权主机: ${NC}$DB_USER_HOST (IP)"
        echo -e "${YELLOW}请妥善保存以上信息!${NC}"
    else
        log "RED" "错误：创建过程中发生错误，正在尝试回滚..."
        execute_mysql "DROP DATABASE IF EXISTS \`$db_name\`;" >/dev/null 2>&1
        execute_mysql "DROP USER IF EXISTS '$username'@'$DB_USER_HOST';" >/dev/null 2>&1
        log "RED" "回滚完成。操作失败。"
        return 1
    fi
}

# 3. 删除数据库和关联用户
delete_database() {
    log "CYAN" "--- 删除数据库及关联用户 ---"
    local -a databases
    get_user_databases databases
    
    if (( ${#databases[@]} == 0 )); then
        log "YELLOW" "没有可供删除的数据库。"
        return
    fi

    log "YELLOW" "请选择要删除的数据库:"
    select db_to_delete in "${databases[@]}" "取消操作"; do
        case "$db_to_delete" in
            "") log "RED" "无效选择，请重试。";;
            "取消操作") log "CYAN" "操作已取消。"; return 0;;
            *)
                local user_to_delete
                user_to_delete=$(grep "^${db_to_delete}:" "$DB_MAPPING_FILE" | cut -d: -f2)

                echo -e "${RED}警告：此操作将永久删除以下内容："
                echo -e "  - 数据库: ${YELLOW}${db_to_delete}${NC}"
                if [[ -n "$user_to_delete" ]]; then
                    echo -e "  - 关联用户: ${YELLOW}${user_to_delete}@${DB_USER_HOST}${NC}"
                fi
                echo -e "${RED}数据将无法恢复！${NC}"

                read -rp "请输入数据库名称 '${db_to_delete}' 以确认删除: " confirmation
                if [[ "$confirmation" != "$db_to_delete" ]]; then
                    log "RED" "确认失败，操作已取消。"
                    return 1
                fi

                log "CYAN" "正在删除数据库..."
                execute_mysql "DROP DATABASE \`$db_to_delete\`;"
                
                if [[ -n "$user_to_delete" ]]; then
                    log "CYAN" "正在删除关联用户..."
                    execute_mysql "DROP USER '$user_to_delete'@'$DB_USER_HOST';"
                    # 从映射文件中删除该行
                    sed -i "/^${db_to_delete}:/d" "$DB_MAPPING_FILE"
                fi
                log "GREEN" "数据库 '${db_to_delete}' 及关联用户已成功删除。"
                break
                ;;
        esac
    done
}

# 4. 备份单个数据库
backup_database() {
    log "CYAN" "--- 备份数据库 ---"
    local -a databases
    get_user_databases databases
    
    if (( ${#databases[@]} == 0 )); then
        log "YELLOW" "没有可供备份的数据库。"
        return
    fi
    
    log "YELLOW" "请选择要备份的数据库:"
    select db_to_backup in "${databases[@]}" "取消操作"; do
        case "$db_to_backup" in
            "") log "RED" "无效选择，请重试。";;
            "取消操作") log "CYAN" "操作已取消。"; return 0;;
            *)
                local timestamp
                timestamp=$(date +"%Y%m%d_%H%M%S")
                local backup_file="${BACKUP_DIR}/${db_to_backup}_${timestamp}.sql.gz"
                
                log "CYAN" "正在将数据库 '${db_to_backup}' 备份到 '${backup_file}'..."
                
                # 使用 MYSQL_PWD 和 mysqldump，通过管道压缩
                if MYSQL_PWD="$DB_ROOT_PASS" mysqldump --single-transaction --routines --triggers -u root "$db_to_backup" | gzip > "$backup_file"; then
                    log "GREEN" "数据库备份成功！"
                    log "CYAN" "备份文件位于: ${backup_file}"
                else
                    log "RED" "错误：数据库备份失败。"
                    rm -f "$backup_file" # 清理失败的备份文件
                    return 1
                fi
                break
                ;;
        esac
    done
}

# 5. 从备份恢复数据库
restore_database() {
    log "CYAN" "--- 从备份恢复数据库 ---"
    local backup_files_str
    backup_files_str=$(find "$BACKUP_DIR" -name "*.sql.gz" -printf "%f\n" 2>/dev/null || true)
    
    if [[ -z "$backup_files_str" ]]; then
        log "YELLOW" "在目录 ${BACKUP_DIR} 中没有找到任何备份文件 (*.sql.gz)。"
        return
    fi
    
    local -a backup_files
    mapfile -t backup_files <<< "$backup_files_str"

    log "YELLOW" "请选择要恢复的备份文件:"
    select backup_file in "${backup_files[@]}" "取消操作"; do
        case "$backup_file" in
            "") log "RED" "无效选择，请重试。";;
            "取消操作") log "CYAN" "操作已取消。"; return 0;;
            *)
                # 从文件名中提取数据库名 (例如 'mydb_20230101_120000.sql.gz' -> 'mydb')
                local db_to_restore
                db_to_restore=$(basename "$backup_file" | sed -E 's/_[0-9]{8}_[0-9]{6}\.sql\.gz$//')

                log "RED" "警告：这将使用 '${backup_file}' 的内容覆盖数据库 '${db_to_restore}'。"
                read -rp "确认要继续吗? (y/N): " response
                if [[ "${response,,}" != "y" ]]; then
                    log "CYAN" "操作已取消。"
                    return 0
                fi
                
                log "CYAN" "正在从 '${backup_file}' 恢复数据库 '${db_to_restore}'..."
                # 先解压，然后通过管道导入到 mysql 客户端
                if gunzip < "${BACKUP_DIR}/${backup_file}" | MYSQL_PWD="$DB_ROOT_PASS" mysql -u root "$db_to_restore"; then
                    log "GREEN" "数据库恢复成功！"
                else
                    log "RED" "错误：数据库恢复失败。"
                    return 1
                fi
                break
                ;;
        esac
    done
}

# ==============================================================================
#  主菜单和执行逻辑
# ==============================================================================

# 显示主菜单
show_menu() {
    echo -e "\n${CYAN}========== 数据库管理脚本 ==========${NC}"
    echo -e " 1. ${GREEN}查看所有数据库${NC}"
    echo -e " 2. ${GREEN}创建新数据库和用户${NC}"
    echo -e " 3. ${RED}删除数据库和用户${NC}"
    echo -e " 4. ${YELLOW}备份数据库${NC}"
    echo -e " 5. ${YELLOW}恢复数据库${NC}"
    echo -e " 0. ${CYAN}退出脚本${NC}"
    echo -e "${CYAN}===================================${NC}"
}

# 主执行函数
main() {
    init
    get_db_password

    if ! command -v mysql &> /dev/null; then
        log "RED" "致命错误：'mysql' 命令未找到。请确认 MariaDB/MySQL 客户端已安装。"
        exit 1
    fi
    if ! systemctl is-active --quiet mariadb; then
        log "RED" "致命错误：MariaDB 服务未运行。请使用 'systemctl start mariadb' 启动。"
        exit 1
    fi

    while true; do
        show_menu
        read -rp "$(echo -e "${CYAN}请输入您的选择 [1-5, 0]: ${NC}")" choice
        
        case "$choice" in
            1) list_databases ;;
            2) create_database ;;
            3) delete_database ;;
            4) backup_database ;;
            5) restore_database ;;
            0) break ;;
            *) log "RED" "无效输入，请输入 1-5 或 0。" ;;
        esac
        
        if [[ -n "$choice" && "$choice" != "q" && "$choice" != "Q" ]]; then
          read -n 1 -s -r -p "$(echo -e "\n${YELLOW}按任意键返回主菜单...${NC}")"
        fi
    done
    
    log "GREEN" "脚本执行完毕，已退出。"
}

# --- 脚本入口 ---
trap 'echo -e "${NC}"; exit' INT TERM
main "$@"
