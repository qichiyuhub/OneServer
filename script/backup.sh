#!/bin/bash
#
# WordPress 备份脚本 - 支持 Rclone 远程存储
#
# 功能描述:
# 本脚本自动化 WordPress 备份流程，包括数据库和文件备份，
# 上传到配置的 Rclone 远程存储，并管理本地和远程的保留策略。
# 支持交互式设置向导和自动化备份执行。
#
# 使用方法:
# ./backup.sh --run    # 执行备份
#
# 依赖项: rclone, mysqldump, tar, gzip/pigz, flock, jq
#

set -Eeuo pipefail

# --- 配置常量 ---
readonly CORE_DIR="/opt/oneserver"
readonly SECURE_CONF="${CORE_DIR}/secure.conf"
readonly BACKUP_DIR="/var/backups/oneserver"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/backup.log"
readonly LOCK_FILE="/tmp/oneserver_backup.lock"
readonly WP_DIR="/var/www/wordpress"

# --- 颜色代码 ---
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
# 日志记录函数
# ==============================================================================

# 函数: echocolor
echocolor() {
    local color_name="$1" message="$2"
    local color_var="${color_name^^}"
    echo -e "${!color_var}${message}${NC}" > /dev/tty
}

# 函数: log
log() {
    printf "%s\n" "$1"
}
# ==============================================================================
# 核心备份功能
# ==============================================================================
run_backup() {
    # 创建一个临时暂存目录
    local TMP_STAGING
    TMP_STAGING=$(mktemp -d)
    chmod 700 "$TMP_STAGING"
    local backup_result=1
    (
        exec >> "$LOG_FILE" 2>&1

        # shellcheck disable=SC1090
        source "$SECURE_CONF"
        
        flock -n 200 || { log "[$(TZ='Asia/Shanghai' date '+%F %T')] [警告] 备份任务已在运行，本次退出"; exit 1; }
        
        log ""
        log "==================== [ $(TZ='Asia/Shanghai' date '+%F %T') ] ===================="
        log "[信息] 开始执行备份..."

        : "${DB_NAME?错误: DB_NAME 未在 secure.conf 中设置}"
        : "${DB_USER?错误: DB_USER 未在 secure.conf 中设置}"
        : "${DB_PASS?错误: DB_PASS 未在 secure.conf 中设置}"
        : "${RCLONE_REMOTE_NAME?错误: RCLONE_REMOTE_NAME 未在 secure.conf 中设置}"
        : "${RCLONE_BACKUP_DIR?错误: RCLONE_BACKUP_DIR 未在 secure.conf 中设置}"
        : "${LOCAL_KEEP_COUNT?错误: LOCAL_KEEP_COUNT 未在 secure.conf 中设置}"
        : "${REMOTE_KEEP_COUNT?错误: REMOTE_KEEP_COUNT 未在 secure.conf 中设置}"

        local GZIP_CMD DATE_STR FINAL_ARCHIVE MYSQL_CNF
        GZIP_CMD=$(command -v pigz 2>/dev/null || echo "gzip")
        DATE_STR=$(TZ='Asia/Shanghai' date +%F_%H-%M-%S)
        FINAL_ARCHIVE="${BACKUP_DIR}/wp-backup-${DATE_STR}.tar.gz"
        MYSQL_CNF=$(mktemp -p "$TMP_STAGING")
        chmod 600 "$MYSQL_CNF"

        cat > "$MYSQL_CNF" <<EOF
[client]
user=${DB_USER}
password=${DB_PASS}
host=${DB_HOST:-localhost}
EOF

        log "[信息] 正在备份数据库 '${DB_NAME}'..."
        if ! mysqldump --defaults-extra-file="$MYSQL_CNF" \
            --single-transaction --routines --triggers --events --quick --hex-blob \
            "${DB_NAME}" > "${TMP_STAGING}/database.sql"; then
            log "[错误] 数据库备份失败！"
            exit 1
        fi

        log "[信息] 正在备份网站文件 '${WP_DIR}'..."
        tar -C "$(dirname "$WP_DIR")" -cf "${TMP_STAGING}/wordpress_files.tar" "$(basename "$WP_DIR")"

        log "[信息] 正在创建最终归档文件..."
        tar -C "$TMP_STAGING" -cf - database.sql wordpress_files.tar | $GZIP_CMD -c > "$FINAL_ARCHIVE"
        (cd "$(dirname "$FINAL_ARCHIVE")" && sha256sum "$(basename "$FINAL_ARCHIVE")") > "${FINAL_ARCHIVE}.sha256"

        log "[信息] 正在上传至 ${RCLONE_REMOTE_NAME}:${RCLONE_BACKUP_DIR}..."
        rclone copy "$FINAL_ARCHIVE" "${RCLONE_REMOTE_NAME}:${RCLONE_BACKUP_DIR}" --stats-one-line --stats 5s
        rclone copy "${FINAL_ARCHIVE}.sha256" "${RCLONE_REMOTE_NAME}:${RCLONE_BACKUP_DIR}"

        log "[信息] 正在校验远程文件完整性..."
        local REMOTE_CHECKSUM LOCAL_CHECKSUM
        REMOTE_CHECKSUM=$(rclone cat "${RCLONE_REMOTE_NAME}:${RCLONE_BACKUP_DIR}/$(basename "${FINAL_ARCHIVE}").sha256" | awk '{print $1}')
        LOCAL_CHECKSUM=$(awk '{print $1}' "${FINAL_ARCHIVE}.sha256")

        if [[ "$LOCAL_CHECKSUM" == "$REMOTE_CHECKSUM" ]]; then
            log "[信息] 远程文件校验成功"
        else
            log "[错误] 远程文件校验失败！"
            exit 1
        fi

        log "[信息] 正在清理本地旧备份 (保留最新的 ${LOCAL_KEEP_COUNT} 个)..."
        mapfile -t local_backups < <(find "$BACKUP_DIR" -maxdepth 1 -name "wp-backup-*.tar.gz" | sort)
        local total_local=${#local_backups[@]}
        if (( total_local > LOCAL_KEEP_COUNT )); then
            local to_delete_local=$(( total_local - LOCAL_KEEP_COUNT ))
            log "[信息] 本地共有 ${total_local} 个备份，超过 ${LOCAL_KEEP_COUNT} 的限制，将删除最旧的 ${to_delete_local} 个。"
            for ((i=0; i<to_delete_local; i++)); do
                log "  - 正在删除: $(basename "${local_backups[i]}")"
                rm -f "${local_backups[i]}" "${local_backups[i]}.sha256"
            done
            log "[信息] 本地旧备份清理完成。"
        else
            log "[信息] 本地备份数量 (${total_local}) 未达到上限 (${LOCAL_KEEP_COUNT})，无需清理。"
        fi

        log "[信息] 正在清理远程旧备份 (保留最新的 ${REMOTE_KEEP_COUNT} 个)..."
        local CLEANED_RCLONE_BACKUP_DIR="${RCLONE_BACKUP_DIR%/}"
        if [[ -z "${CLEANED_RCLONE_BACKUP_DIR}" ]]; then
            log "[致命错误] 远程备份目录 (RCLONE_BACKUP_DIR) 为空！为防止数据丢失，已终止远程清理。"
            exit 1
        else
            local remote_path="${RCLONE_REMOTE_NAME}:${CLEANED_RCLONE_BACKUP_DIR}"
            log "[信息] 正在获取远程备份列表..."

            local -a remote_archives
            mapfile -t remote_archives < <(rclone lsf "$remote_path" --files-only --include "*.tar.gz" | grep '^wp-backup-' | sort)
            
            local total_remote=${#remote_archives[@]}
            if (( total_remote > REMOTE_KEEP_COUNT )); then
                local delete_count=$(( total_remote - REMOTE_KEEP_COUNT ))
                log "[信息] 远程共有 ${total_remote} 个备份，超过 ${REMOTE_KEEP_COUNT} 的限制，将删除最旧的 ${delete_count} 个。"

                local files_to_delete_list
                files_to_delete_list=$(mktemp -p "$TMP_STAGING")
                local -a all_remote_files
                mapfile -t all_remote_files < <(rclone lsf "$remote_path" --files-only)

                for ((i=0; i<delete_count; i++)); do
                    local archive_basename="${remote_archives[i]%.tar.gz}"
                    for remote_file in "${all_remote_files[@]}"; do
                        if [[ "$remote_file" == "${archive_basename}"* ]]; then
                            log "  - 标记删除: ${remote_file}"
                            echo "${CLEANED_RCLONE_BACKUP_DIR}/${remote_file}" >> "$files_to_delete_list"
                        fi
                    done
                done
                
                log "[信息] 正在执行批量删除..."
                rclone delete "${RCLONE_REMOTE_NAME}:" --files-from "$files_to_delete_list" --no-traverse 2>>"$LOG_FILE"
                
                log "[信息] 远程旧备份清理完成。"
            else
                log "[信息] 远程备份数量 (${total_remote}) 未达到上限 (${REMOTE_KEEP_COUNT})，无需清理。"
            fi
        fi

        log "[成功] 备份任务圆满完成"
        log "==================== [ $(TZ='Asia/Shanghai' date '+%F %T') ] ===================="

    ) 200>"$LOCK_FILE"

    backup_result=$?
    rm -rf "$TMP_STAGING"
    return $backup_result
}

# ==============================================================================
# 交互式配置向导
# ==============================================================================
run_setup() {
    setup_log() {
        printf "%s\n" "$1" >> "$LOG_FILE"
    }

    echocolor "CYAN" "--- WordPress 备份配置向导 ---"
    setup_log "--- 启动配置向导 ---"

    # shellcheck disable=SC1090
    [[ -f "$SECURE_CONF" ]] && source "$SECURE_CONF"

    echocolor "CYAN" "\n[1/6] 检查依赖..."
    local packages_to_install=()
    for cmd in rclone mysqldump tar crontab jq; do
        if ! command -v "$cmd" &>/dev/null; then
            case "$cmd" in
                rclone)
                    echocolor "YELLOW" "检测到 'rclone' 未安装，将尝试自动安装..."
                    setup_log "检测到 'rclone' 未安装，尝试自动安装..."
                    if curl -s https://rclone.org/install.sh | bash >> "$LOG_FILE" 2>&1; then
                        echocolor "GREEN" "Rclone 安装成功。"
                        setup_log "Rclone 安装成功。"
                    else
                        echocolor "RED" "错误: Rclone 自动安装失败，请手动执行 'curl https://rclone.org/install.sh | sudo bash' 后重试。"
                        setup_log "错误: Rclone 自动安装失败。"
                        exit 1
                    fi
                    ;;
                jq) packages_to_install+=("jq");;
                mysqldump)
                    echocolor "RED" "错误: 缺少 'mysqldump'。请尝试使用 'apt install mysql-client' 或 'apt install mariadb-client' 安装。"
                    setup_log "错误: 缺少 'mysqldump'。"
                    exit 1
                    ;;
                *)
                    echocolor "RED" "错误: 缺少关键命令 '$cmd'，请使用包管理器安装它。"
                    setup_log "错误: 缺少关键命令 '$cmd'。"
                    exit 1
                    ;;
            esac
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        echocolor "YELLOW" "检测到依赖未安装: ${packages_to_install[*]}，将尝试自动安装..."
        setup_log "检测到依赖未安装: ${packages_to_install[*]}，尝试自动安装..."
        if apt-get update >> "$LOG_FILE" 2>&1 && apt-get install -y "${packages_to_install[@]}" >> "$LOG_FILE" 2>&1; then
            echocolor "GREEN" "依赖包 ${packages_to_install[*]} 安装成功。"
            setup_log "依赖包 ${packages_to_install[*]} 安装成功。"
        else
            echocolor "RED" "错误: 自动安装失败，请手动执行 'apt install ${packages_to_install[*]}' 后重试。"
            setup_log "错误: 自动安装依赖失败。"
            exit 1
        fi
    fi
    echocolor "GREEN" "依赖检查通过"
    setup_log "依赖检查通过。"

    echocolor "CYAN" "\n[2/6] 配置 Rclone 远程..."
    local RCLONE_REMOTE_NAME=""
    local -a EXISTING_REMOTES
    mapfile -t EXISTING_REMOTES < <(rclone listremotes 2>>"$LOG_FILE" | sed 's/://g')

    if (( ${#EXISTING_REMOTES[@]} == 0 )); then
        echocolor "YELLOW" "未检测到任何 Rclone 远程配置"
        setup_log "未检测到 Rclone 远程。"
        local RUN_SETUP
        read -rp "是否立即运行 OneDrive 配置脚本 (onedrive_setup.sh)(Y/n): " RUN_SETUP < /dev/tty
        if [[ "${RUN_SETUP:-y}" =~ ^[Yy]$ ]]; then
            local this_script_dir; this_script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
            if [[ -x "${this_script_dir}/onedrive_setup.sh" ]]; then
                bash "${this_script_dir}/onedrive_setup.sh"
                mapfile -t EXISTING_REMOTES < <(rclone listremotes | sed 's/://g')
                if (( ${#EXISTING_REMOTES[@]} == 0 )); then
                    echocolor "RED" "错误: 运行配置脚本后仍未找到 Rclone 远程"
                    setup_log "错误: 运行 onedrive_setup.sh 后仍未找到远程。"
                    exit 1
                fi
                RCLONE_REMOTE_NAME="${EXISTING_REMOTES[0]}"
                echocolor "GREEN" "配置成功！已自动选择新创建的远程: ${RCLONE_REMOTE_NAME}"
                setup_log "自动选择新创建的远程: ${RCLONE_REMOTE_NAME}"
            else
                echocolor "RED" "错误: 未找到配置脚本 ${this_script_dir}/onedrive_setup.sh"
                setup_log "错误: 未找到 ${this_script_dir}/onedrive_setup.sh。"
                exit 1
            fi
        else
            echocolor "RED" "操作已取消"; exit 1
        fi
    elif (( ${#EXISTING_REMOTES[@]} == 1 )); then
        RCLONE_REMOTE_NAME="${EXISTING_REMOTES[0]}"
        echocolor "GREEN" "检测到唯一的 Rclone 远程，已自动选择: ${RCLONE_REMOTE_NAME}"
        setup_log "自动选择唯一远程: ${RCLONE_REMOTE_NAME}"
    else
        echocolor "CYAN" "检测到多个 Rclone 远程，请选择一个用于备份:"
        select choice in "${EXISTING_REMOTES[@]}"; do
            if [[ -n "$choice" ]]; then
                RCLONE_REMOTE_NAME="$choice"
                echocolor "GREEN" "已选择: ${RCLONE_REMOTE_NAME}"; break
            else
                echocolor "RED" "无效选择，请重新输入数字。"
            fi
        done < /dev/tty
        setup_log "用户选择远程: ${RCLONE_REMOTE_NAME}"
    fi

    local RCLONE_BACKUP_DIR
    while true; do
        read -rp "请输入远程备份目录 [默认 wordpress/backups]: " RCLONE_BACKUP_DIR < /dev/tty
        RCLONE_BACKUP_DIR=${RCLONE_BACKUP_DIR:-"wordpress/backups"}
        RCLONE_BACKUP_DIR=$(echo "$RCLONE_BACKUP_DIR" | xargs)
        if [[ -n "$RCLONE_BACKUP_DIR" ]]; then break
        else echocolor "RED" "备份目录不能为空，请重新输入。"; fi
    done
    setup_log "设置远程备份目录: ${RCLONE_BACKUP_DIR}"

    echocolor "CYAN" "\n[3/6] 配置数据库..."
    if [[ -z "${DB_NAME:-}" ]] || [[ -z "${DB_USER:-}" ]] || [[ -z "${DB_PASS:-}" ]]; then
        echocolor "YELLOW" "secure.conf 中缺少数据库凭据，尝试从 wp-config.php 自动检测..."
        setup_log "尝试从 wp-config.php 自动检测数据库凭据。"
        if [[ -f "${WP_DIR}/wp-config.php" ]] && command -v php &>/dev/null; then
            PHP_OUTPUT=$(php -r "error_reporting(0); @include '${WP_DIR}/wp-config.php'; if(defined('DB_NAME') && defined('DB_USER') && defined('DB_PASSWORD')){echo DB_NAME . \"\\n\" . DB_USER . \"\\n\" . DB_PASSWORD;}" 2>&1)
            # shellcheck disable=SC2181
            if [[ $? -eq 0 ]] && [[ -n "$PHP_OUTPUT" ]]; then
                DB_NAME=$(echo "$PHP_OUTPUT" | sed -n '1p')
                DB_USER=$(echo "$PHP_OUTPUT" | sed -n '2p')
                DB_PASS=$(echo "$PHP_OUTPUT" | sed -n '3p')
                echocolor "GREEN" "成功从 wp-config.php 检测到凭据"
                setup_log "成功从 wp-config.php 检测到凭据。"
            else
                echocolor "RED" "自动检测失败，请检查 wp-config.php 或 PHP 环境。"; exit 1
            fi
        else
            echocolor "RED" "自动检测失败，找不到 wp-config.php 或未安装 PHP。"; exit 1
        fi
    else
        echocolor "GREEN" "成功从 secure.conf 加载数据库凭据"
        setup_log "成功从 secure.conf 加载数据库凭据。"
    fi
        
    echocolor "CYAN" "\n[4/6] 配置备份计划..."
    local FREQUENCY DAY_OF_WEEK="*" H M
    read -rp "选择备份频率 (1=每天, 2=每周) [默认 1]: " FREQUENCY < /dev/tty
    if [[ "${FREQUENCY:-1}" == "2" ]]; then
        read -rp "选择每周几执行 (0=周日, 1=周一, ..., 6=周六) [默认 0]: " DAY_OF_WEEK < /dev/tty
        DAY_OF_WEEK=${DAY_OF_WEEK:-0}
    fi
    echocolor "YELLOW" "请注意: 以下时间为北京时间 (UTC+8)。"
    read -rp "备份执行时间 - 小时 (0-23) [默认 4]: " H < /dev/tty; H=${H:-4}
    read -rp "备份执行时间 - 分钟 (0-59) [默认 0]: " M < /dev/tty; M=${M:-0}
    setup_log "设置备份计划：H=${H}, M=${M}, DayOfWeek=${DAY_OF_WEEK}"

    echocolor "CYAN" "\n[5/6] 配置保留策略..."
    local LOCAL_KEEP_COUNT REMOTE_KEEP_COUNT
    read -rp "本地保留备份数量 [默认 10]: " LOCAL_KEEP_COUNT < /dev/tty; LOCAL_KEEP_COUNT=${LOCAL_KEEP_COUNT:-10}
    read -rp "远程保留备份数量 [默认 10]: " REMOTE_KEEP_COUNT < /dev/tty; REMOTE_KEEP_COUNT=${REMOTE_KEEP_COUNT:-10}
    setup_log "设置保留策略：Local=${LOCAL_KEEP_COUNT}, Remote=${REMOTE_KEEP_COUNT}"
    
    echocolor "CYAN" "\n[6/6] 保存配置并设置定时任务..."
    local keys_to_remove=("RCLONE_REMOTE_NAME" "RCLONE_BACKUP_DIR" "LOCAL_KEEP_DAYS" "LOCAL_KEEP_COUNT" "REMOTE_KEEP_COUNT" "DB_NAME" "DB_USER" "DB_PASS")
    local -a sed_args=()
    for key in "${keys_to_remove[@]}"; do
        sed_args+=(-e "/^${key}=/d")
    done
    touch "$SECURE_CONF"
    sed -i "${sed_args[@]}" "$SECURE_CONF" 2>/dev/null || true

    local temp_conf; temp_conf=$(mktemp)
    cat <<EOF > "$temp_conf"
RCLONE_REMOTE_NAME='${RCLONE_REMOTE_NAME}'
RCLONE_BACKUP_DIR='${RCLONE_BACKUP_DIR}'
LOCAL_KEEP_COUNT='${LOCAL_KEEP_COUNT}'
REMOTE_KEEP_COUNT='${REMOTE_KEEP_COUNT}'
DB_NAME='${DB_NAME}'
DB_USER='${DB_USER}'
DB_PASS='${DB_PASS}'
EOF
    cat "$temp_conf" >> "$SECURE_CONF"
    rm "$temp_conf"
    echocolor "GREEN" "  - 配置已保存至 ${SECURE_CONF}"
    setup_log "配置已保存至 ${SECURE_CONF}。"

    local SCHEDULE_TS CRON_H CRON_M
    SCHEDULE_TS=$(TZ='Asia/Shanghai' date -d "today $H:$M" +%s)
    CRON_H=$(date -d "@$SCHEDULE_TS" +%H)
    CRON_M=$(date -d "@$SCHEDULE_TS" +%M)
    local script_abs_path; script_abs_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local CRON_CMD="bash ${script_abs_path} --run"
    local CRON_JOB="${CRON_M} ${CRON_H} * * ${DAY_OF_WEEK} ${CRON_CMD}"
    local CURRENT_CRONTAB
    CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)
    
    local sanitized_cmd; sanitized_cmd=$(echo "$CRON_CMD" | sed 's/[*]/\\*/g' | sed 's|/|\\/|g')
    local cleaned_crontab; cleaned_crontab=$(echo "$CURRENT_CRONTAB" | sed -E "\|${sanitized_cmd}$|d")

    (echo "$cleaned_crontab"; echo "$CRON_JOB") | crontab -
    echocolor "GREEN" "  - 定时任务已设置。"
    setup_log "定时任务已更新。"

    echocolor "GREEN" "\n--- 备份配置完成 ---"
    setup_log "--- 配置向导完成 ---"

    local test_run
    read -rp "是否立即运行一次测试备份? (Y/n): " test_run < /dev/tty
    if [[ "${test_run:-y}" =~ ^[Yy]$ ]]; then
        echocolor "CYAN" "正在启动测试备份... (详情请查看日志: ${LOG_FILE})"
        setup_log "用户选择立即运行测试备份。"
        
        if run_backup; then
            echocolor "GREEN" "测试备份成功完成！"
            setup_log "测试备份成功完成。"
        else
            echocolor "RED" "<<< 操作失败: 备份网站数据 (退出码: $?)。详情请查看对应日志。"
            setup_log "测试备份失败。"
        fi
    fi
}

# ==============================================================================
# 主脚本入口
# ==============================================================================
main() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"

    if [[ "${1:-}" == "--run" ]]; then
        run_backup
    else
        if [[ $EUID -ne 0 ]]; then
            echocolor "RED" "错误: 配置向导必须以 root 权限运行"
            exit 1
        fi
        run_setup
    fi
}

main "$@"
