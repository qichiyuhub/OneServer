#!/bin/bash
# ==============================================================================
#
# Caddy 管理脚本
#
# 描述:
#   用于简化 Caddy Web 服务器的管理。
#
# ==============================================================================

# --- 脚本严格模式 ---
set -euo pipefail

# --- 配置常量 ---
readonly APP_NAME="Caddy 管理脚本"
readonly CADDY_SERVICE="caddy"
readonly CADDY_CONF_DIR="/etc/caddy"
readonly CADDYFILE_PATH="${CADDY_CONF_DIR}/Caddyfile"
readonly oneserver_DIR="/opt/oneserver"
readonly SECURE_CONF="${oneserver_DIR}/secure.conf"
readonly SYSTEMD_ENV_DIR="/etc/systemd/system/${CADDY_SERVICE}.service.d"
readonly SYSTEMD_ENV_FILE="${SYSTEMD_ENV_DIR}/oneserver-token.conf"
readonly DEFAULT_CADDYFILE_REPO="https://raw.githubusercontent.com/qichiyuhub/OneServer/refs/heads/main/config/Caddyfile"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/caddy-manager.log"

# --- 终端颜色定义 ---
# shellcheck disable=SC2034
readonly CYAN='\033[0;36m'   GREEN='\033[0;32m'
readonly RED='\033[0;31m'    YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
#  全局初始化与清理
# ==============================================================================
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

_check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 此脚本需要 root 权限运行。${NC}"
        exit 1
    fi
}

_check_optional_deps() {
    if ! command -v bat &>/dev/null; then
        log "YELLOW" "提示: 安装 'bat' 可获得更好的代码高亮体验 (例如: 'apt install bat' 或 'yum install bat')."
    fi
}

init() {
    _check_root
    mkdir -p "$LOG_DIR" "$CADDY_CONF_DIR" "$oneserver_DIR" "$SYSTEMD_ENV_DIR"
    touch "$LOG_FILE"
    _check_optional_deps
}

# ==============================================================================
#  核心工具函数
# ==============================================================================
log() {
    local color_name="${1^^}"
    local message="$2"
    local color_var_name="${color_name}"
    local color="${!color_var_name:-$NC}"
    echo -e "${color}${message}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

press_enter_to_continue() {
    read -rp $'\n\033[1;33m按 Enter 键返回主菜单...\033[0m'
}

confirm_action() {
    local prompt="$1"
    local response
    read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" response
    response=${response:-}
    response=${response,,}
    [[ -z "$response" || "$response" =~ ^y ]]
}

# shellcheck disable=SC1090
_source_token() {
    [[ -f "$SECURE_CONF" ]] && source "$SECURE_CONF"
}

# ==============================================================================
#  菜单功能实现
# ==============================================================================
_ensure_caddy_permissions() {
    log "CYAN" "-> 正在检查并修复 Caddy核心目录及日志文件权限..."
    # --- 配置项 ---
    local caddy_user="caddy"
    local caddy_group="caddy"
    local caddy_log_dir="/var/log/caddy"
    local caddy_data_dir="/var/lib/caddy"

    # --- 1. 设置核心目录权限 ---
    if ! mkdir -p "$caddy_log_dir"; then
        log "RED" "  - 错误: 无法创建日志目录 ${caddy_log_dir}。"
        return 1
    fi
    if ! chown "${caddy_user}:${caddy_group}" "$caddy_log_dir" || ! chmod 755 "$caddy_log_dir"; then
        log "RED" "  - 错误: 无法设置日志目录 ${caddy_log_dir} 权限。"
        return 1
    else
        log "GREEN" "  - 日志目录 (${caddy_log_dir}) 权限已设置。"
    fi

    if ! mkdir -p "$caddy_data_dir"; then
        log "RED" "  - 错误: 无法创建数据目录 ${caddy_data_dir}。"
        return 1
    fi
    if ! chown -R "${caddy_user}:${caddy_group}" "$caddy_data_dir"; then
        log "RED" "  - 错误: 无法设置数据目录 ${caddy_data_dir} 权限。"
        return 1
    else
        log "GREEN" "  - 数据目录 (${caddy_data_dir}) 权限已设置。"
    fi

    # --- 2. 动态查找并设置日志文件权限 ---
    log "CYAN" "-> 正在从 Caddyfile 中动态查找日志文件..."
    
    if ! command -v jq &>/dev/null; then
        log "YELLOW" "  - 警告: 'jq' 命令未找到, 无法动态解析日志文件。请安装 'jq' (e.g., 'apt install jq') 以启用此功能。"
        log "YELLOW" "  - 跳过日志文件权限检查。仅目录权限已设置。"
        return 0
    fi
    
    if [[ ! -f "$CADDYFILE_PATH" ]]; then
        log "YELLOW" "  - 警告: Caddyfile 未找到于 ${CADDYFILE_PATH}，跳过日志文件权限检查。"
        return 0
    fi
    local log_files
    log_files=$(caddy adapt --config "$CADDYFILE_PATH" 2>/dev/null | \
                jq -r --arg log_dir "$caddy_log_dir/" '.. | .filename? // empty | select(startswith($log_dir))' | \
                sort -u)

    if [[ -z "$log_files" ]]; then
        log "GREEN" "  - 在 Caddyfile 中未找到位于 ${caddy_log_dir}/ 下的日志文件配置，无需操作。"
        return 0
    fi
    
    local has_error=0
    echo "$log_files" | while read -r log_file; do
        if [[ -f "$log_file" ]]; then
            if chown "${caddy_user}:${caddy_group}" "$log_file"; then
                log "GREEN" "  - 已设置日志文件权限: $log_file"
            else
                log "RED" "  - 错误: 无法设置日志文件权限: $log_file"
                has_error=1
            fi
        else
            log "CYAN" "  - 日志文件尚未创建，跳过: $log_file (Caddy将在写入时创建)"
        fi
    done
    if [[ "$has_error" -eq 1 ]]; then
        return 1
    fi
    return 0
}

_apply_config_and_restart() {
    if ! _ensure_caddy_permissions; then
        log "RED" "因权限设置失败，已中止重启操作！"
        return 1
    fi
    log "YELLOW" "为了确保新配置生效，将执行重启操作..."
    restart_service
}

view_config() {
    log "CYAN" "--- 查看 Caddyfile 配置 ---"
    if [[ ! -f "$CADDYFILE_PATH" ]]; then
        log "RED" "配置文件不存在: ${CADDYFILE_PATH}"
        return
    fi
    echo -e "${YELLOW}路径: ${CADDYFILE_PATH}${NC}\n"
    if command -v bat &>/dev/null; then
        bat --color=always --paging=never --language=caddyfile "$CADDYFILE_PATH"
    else
        cat "$CADDYFILE_PATH"
    fi
}

_validate_and_apply() {
    log "CYAN" "--- 正在验证 Caddyfile ---"
    local validation_output
    _source_token
    if ! validation_output=$(CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" caddy validate --config "$CADDYFILE_PATH" --adapter caddyfile 2>&1); then
        log "RED" "配置验证失败！未执行操作。详情如下:"
        echo -e "${NC}${validation_output}"
        return 1
    else
        log "GREEN" "配置验证通过。"
        if confirm_action "是否立即应用此配置 (将重启 Caddy) ？"; then
            _apply_config_and_restart
        fi
    fi
}

edit_config() {
    log "CYAN" "--- 编辑 Caddyfile ---"
    if [[ ! -f "$CADDYFILE_PATH" ]]; then
        touch "$CADDYFILE_PATH"
        log "YELLOW" "配置文件不存在，已创建新文件。"
    fi
    
    ${EDITOR:-nano} "$CADDYFILE_PATH"
    log "GREEN" "编辑完成。"
    
    _validate_and_apply
}

rollback_config() {
    log "CYAN" "--- 回滚到上一个备份 ---"
    local last_backup
    last_backup=$(find "$CADDY_CONF_DIR" -type f -name "Caddyfile.bak.*" | sort -r | head -n 1)
    
    if [[ -z "$last_backup" ]]; then
        log "RED" "未找到任何备份文件。"
        return
    fi

    log "YELLOW" "找到最新的备份文件: ${last_backup}"
    if confirm_action "确定要用此备份覆盖当前 Caddyfile 吗 ？"; then
        cp "$last_backup" "$CADDYFILE_PATH"
        log "GREEN" "回滚成功！当前配置已恢复。"
        if confirm_action "是否立即应用恢复的配置 (将重启 Caddy) ？"; then
            _apply_config_and_restart
        fi
    else
        log "CYAN" "操作已取消。"
    fi
}

manage_backups() {
    while true; do
        clear
        log "CYAN" "--- 备份管理 ---"
        local backups=()
        while IFS= read -r -d $'\0'; do
            backups+=("$REPLY")
        done < <(find "$CADDY_CONF_DIR" -maxdepth 1 -type f -name "Caddyfile.bak.*" -print0)
        
        echo -e "  [1] 列出所有备份 (${#backups[@]} 个)"
        echo -e "  [2] ${RED}清理所有备份${NC}"
        echo -e "  [0] 返回上级菜单"
        read -rp "请输入选项 [0-2]: " choice

        case "$choice" in
            1)
                log "YELLOW" "\n备份文件列表:"
                if [[ ${#backups[@]} -gt 0 ]]; then
                    ls -lh "${backups[@]}"
                else
                    log "GREEN" "没有找到备份文件。"
                fi
                press_enter_to_continue
                ;;
            2)
                if [[ ${#backups[@]} -gt 0 ]] && confirm_action "确定要删除所有 ${#backups[@]} 个备份文件吗 ？此操作不可逆！"; then
                    rm -f "${backups[@]}"
                    log "GREEN" "\n所有备份文件已清理。"
                else
                    log "CYAN" "\n操作已取消或没有备份文件。"
                fi
                press_enter_to_continue
                ;;
            0) break ;;
            *) log "RED" "无效输入！"; sleep 1 ;;
        esac
    done
}

_handle_cf_token() {
    log "CYAN" "-> 正在处理 Cloudflare API Token..."
    touch "$SECURE_CONF"; chmod 600 "$SECURE_CONF"
    _source_token
    
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        read -rp "请输入Cloudflare API Token: " user_token
        if [[ -z "$user_token" ]]; then
            log "RED" "未输入Token，中止。"
            return 1
        fi
        CLOUDFLARE_API_TOKEN="$user_token"
        
        if grep -q "^CLOUDFLARE_API_TOKEN=" "$SECURE_CONF"; then
            sed -i "s|^CLOUDFLARE_API_TOKEN=.*|CLOUDFLARE_API_TOKEN='${CLOUDFLARE_API_TOKEN}'|" "$SECURE_CONF"
        else
            printf "CLOUDFLARE_API_TOKEN='%s'\n" "$CLOUDFLARE_API_TOKEN" >> "$SECURE_CONF"
        fi
        log "GREEN" "Token已保存至 ${SECURE_CONF}"
    else
        log "GREEN" "Token已从 ${SECURE_CONF} 加载。"
    fi
    
    echo -e "[Service]\nEnvironment=\"CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}\"" > "$SYSTEMD_ENV_FILE"
    systemctl daemon-reload
    log "GREEN" "Systemd环境已更新。"
}

_get_caddyfile_content() {
    log "CYAN" "-> 请选择 Caddyfile 获取方式: [1] URL下载 (默认) | [2] 粘贴内容"
    read -rp "输入选项 [1-2]: " choice
    choice=${choice:-1}
    case "$choice" in
        1)
            read -rp "输入URL [默认: ${DEFAULT_CADDYFILE_REPO}]: " url
            url=${url:-$DEFAULT_CADDYFILE_REPO}
            log "YELLOW" "正在从 ${url} 下载..."
            if ! curl -fsSL "$url" -o "$TMP_FILE"; then
                log "RED" "下载失败!"
                return 1
            fi
            log "GREEN" "下载成功。"
            ;;
        2)
            log "YELLOW" "请粘贴内容, 按 Ctrl+D 结束:"
            cat > "$TMP_FILE"
            log "GREEN" "内容已接收。"
            ;;
        *) 
            log "RED" "无效选项!"
            return 1 
            ;;
    esac
}

update_caddyfile() {
    clear
    log "CYAN" "--- 启动 Caddyfile 更新流程 ---"
    if ! _handle_cf_token; then return 1; fi
    if ! _get_caddyfile_content; then return 1; fi

    log "CYAN" "-> 正在验证新配置..."
    if ! grep -q '[^[:space:]]' "$TMP_FILE"; then
        log "RED" "配置内容为空!"
        return 1
    fi
    caddy fmt --overwrite "$TMP_FILE" &>/dev/null
    
    local validation_output
    _source_token
    if ! validation_output=$(CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}" caddy validate --config "$TMP_FILE" --adapter caddyfile 2>&1); then
        log "RED" "新配置验证失败！详情如下:"
        echo -e "${NC}${validation_output}"
        log "YELLOW" "您的新配置内容仍保留在临时文件: ${TMP_FILE}"
        trap - EXIT
        return 1
    fi

    log "GREEN" "新配置验证通过。"
    [[ -f "$CADDYFILE_PATH" ]] && cp "$CADDYFILE_PATH" "${CADDYFILE_PATH}.bak.$(date +%F_%H-%M-%S)"
    
    if mv "$TMP_FILE" "$CADDYFILE_PATH"; then
        chown root:caddy "$CADDYFILE_PATH"; chmod 644 "$CADDYFILE_PATH"
        log "GREEN" "Caddyfile 已成功更新并备份旧配置。"
        TMP_FILE=$(mktemp)
        if confirm_action "是否立即应用新配置 (将重启 Caddy) ？"; then
            _apply_config_and_restart
        fi
    else
        log "RED" "致命错误：无法将新配置移动到 ${CADDYFILE_PATH}！"
        log "YELLOW" "您的新配置内容仍保留在临时文件: ${TMP_FILE}"
        trap - EXIT
        return 1
    fi
}

_control_service() {
    local action="$1" verb_past="$2"
    if systemctl "$action" "$CADDY_SERVICE"; then
        log "GREEN" "Caddy 服务${verb_past}。"
    else
        log "RED" "执行 '${action}' 操作失败！请检查日志。"
    fi
}
stop_service()    { _control_service "stop" "已停止"; }
start_service()   { _control_service "start" "已启动"; }
restart_service() { _control_service "restart" "已重启"; }
reload_service()  { _control_service "reload" "配置已重载"; }

check_status() {
    log "CYAN" "--- Caddy 服务状态 ---"
    systemctl status "$CADDY_SERVICE" --no-pager || true
}

view_logs() {
    log "CYAN" "--- 查看 Caddy 日志 (进入后按 'F' 可实时跟踪) ---"
    log "NC"   "     提示: 可以随时用上下箭头/PgUp/PgDn滚动查看历史"
    journalctl -u "$CADDY_SERVICE" -n 200 --no-pager | less -R -P "--- 日志 (可滚动) | 按 F 实时跟踪 | 按 q 退出 ---"
    log "YELLOW" "\n--- 已退出日志查看，返回主菜单 ---"
}


list_certs() {
    log "CYAN" "--- 已管理的 TLS 证书列表 ---"
    log "YELLOW" "--- 新增域名，尝试清理所有证书，重启 ---"

    local cert_dir="/var/lib/caddy/.local/share/caddy/certificates"
    local found=0
    local now_ts
    now_ts=$(date +%s)

    local cert_path filename domain_name
    local start_date_str end_date_str
    local formatted_start_date formatted_end_date
    local end_ts remaining_days
    local status_color status_text

    if [[ ! -d "$cert_dir" ]]; then
        log "YELLOW" "证书目录尚未创建，这是正常现象。"
        log "YELLOW" "Caddy 会在服务启动后自动向 Let's Encrypt 申请 TLS 证书，请耐心等待约 5 分钟。"
        log "CYAN"   "如需排查进度，可通过菜单 [11] 查看 Caddy 实时日志。"
        return 0
    fi

    while IFS= read -r -d '' cert_path; do
        ((found++))

        filename=${cert_path##*/}
        domain_name=${filename%.crt}
        domain_name=${domain_name/#wildcard_./*.}

        start_date_str=$(openssl x509 -in "$cert_path" -noout -startdate | cut -d= -f2)
        end_date_str=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
        
        formatted_start_date=$(date -d "$start_date_str" +"%Y年%m月%d日")
        formatted_end_date=$(date -d "$end_date_str" +"%Y年%m月%d日")
        
        end_ts=$(date -d "$end_date_str" +%s)
        remaining_days=$(( (end_ts - now_ts) / 86400 ))

        if (( remaining_days < 0 )); then
            status_color="RED"
            status_text="已过期 ${remaining_days#-} 天"
        elif (( remaining_days <= 30 )); then
            status_color="YELLOW"
            status_text="剩余 ${remaining_days} 天 (即将过期)"
        else
            status_color="GREEN"
            status_text="剩余 ${remaining_days} 天"
        fi
        
        log "WHITE" "\n 域名: ${domain_name}"
        log "NC"    "  生效时间: ${formatted_start_date}"
        log "NC"    "  过期时间: ${formatted_end_date}"
        log "${status_color}" "  证书状态: ${status_text}"
        log "GRAY"  "  证书路径: ${cert_path}"

    done < <(find "$cert_dir" -type f -name "*.crt" -print0) || true

    if [[ $found -eq 0 ]]; then
        log "GREEN" "\n在目录 ${cert_dir} 中未发现任何证书文件。"
    else
        echo
    fi
}

clear_certs() {
    log "CYAN" "--- 清理所有 TLS 证书 ---"

    local cert_dir="/var/lib/caddy/.local/share/caddy/certificates"

    if [[ ! -d "$cert_dir" ]]; then
        log "YELLOW" "证书目录尚未创建，无证书可清理。"
        return 0
    fi

    local files_count
    files_count=$(find "$cert_dir" -type f | wc -l)

    if [[ "$files_count" -eq 0 ]]; then
        log "GREEN" "未找到证书文件，目录为空。"
        return 0
    fi

    if ! confirm_action "确定要删除目录 ${cert_dir} 下的所有证书文件吗？此操作不可逆！"; then
        log "CYAN" "操作已取消。"
        return 0
    fi

    if find "$cert_dir" -type f -exec rm -f {} +; then
        log "GREEN" "已删除 ${files_count} 个证书文件。"
        return 0
    else
        log "RED" "删除证书文件时发生错误。"
        return 1
    fi
}

# ==============================================================================
#  主菜单与程序入口
# ==============================================================================
_get_service_status_display() {
    if systemctl is-active --quiet "$CADDY_SERVICE"; then
        echo -e "${GREEN}● Active${NC}"
    else
        echo -e "${RED}● Inactive${NC}"
    fi
}
show_menu() {
    clear
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}                   ${APP_NAME}${NC}"
    echo -e "${YELLOW}   状态 | Caddy 服务: $(_get_service_status_display)${NC}"
    echo -e "${CYAN}============================================================${NC}"
    
    echo -e "${YELLOW} [ 配置管理 ]${NC}"
    echo -e "   [1] 更新 Caddyfile     [2] 查看 Caddyfile"
    echo -e "   [3] 编辑 Caddyfile     [4] 回滚配置"
    echo -e "   [5] 管理备份"
    echo
    echo -e "${YELLOW} [ 服务控制 ]${NC}"
    echo -e "   [6] 启动 Caddy         [7] 停止 Caddy"
    echo -e "   [8] 重启 Caddy         [9] 重载 Caddy"
    echo
    echo -e "${YELLOW} [ 状态与诊断 ]${NC}"
    echo -e "  [10] 查看服务状态     [11] 查看实时日志"
    echo -e "  [12] 查看证书列表     [13] 清理所有证书"
    echo
    
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${RED}   [0] 退出脚本${NC}"
    echo -e "${CYAN}============================================================${NC}"
}

main() {
    init
    while true; do
        show_menu
        read -rp "请输入您的选择 [0-13]: " choice

        local auto_continue_options="1 2 3 4 6 7 8 9 10 12 13"

        clear
        case "$choice" in
            1) update_caddyfile ;; 2) view_config ;;
            3) edit_config ;;      4) rollback_config ;;
            5) manage_backups ;;   6) start_service ;;
            7) stop_service ;;     8) restart_service ;;
            9) reload_service ;;   10) check_status ;;
            11) view_logs ;;       12) list_certs ;;
            13) clear_certs ;;
            0) log "GREEN" "感谢使用，脚本已退出。"; exit 0 ;;
            *) log "RED" "无效输入！"; sleep 1; continue ;;
        esac
        
        if [[ $auto_continue_options == *"$choice"* ]]; then
            press_enter_to_continue
        fi
    done
}

# --- 脚本执行入口 ---
main "$@"
