#!/bin/bash
#
# OneServer 脚本更新
#
# 功能：自动从远程仓库下载并更新 OneServer 脚本文件
#

set -Eeuo pipefail

# ==============================================================================
# 配置参数
# ==============================================================================
readonly CORE_DIR="/opt/oneserver"
readonly SCRIPT_DIR="${CORE_DIR}/script"
readonly BASE_URL="https://raw.githubusercontent.com/qichiyuhub/OneServer/refs/heads/main/script"
readonly SCRIPT_LIST_URL="${BASE_URL}/script_list.txt"
readonly MAX_CONCURRENT_DOWNLOADS=10
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="$LOG_DIR/script_update.log"

# 颜色定义
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
# 初始化设置
# ==============================================================================
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT INT TERM

# ==============================================================================
# 函数定义
# ==============================================================================

# 终端输出函数
color_echo() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# 日志记录函数
log() {
    local color_name="$1" message="$2"
    
    case "${color_name^^}" in
        "GREEN")  color_echo "$GREEN" "$message" ;;
        "RED")    color_echo "$RED" "$message" ;;
        "YELLOW") color_echo "$YELLOW" "$message" ;;
        *)        echo "$message" ;;
    esac
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# 交互式确认函数
ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    
    while true; do
        read -rp "$(echo -e "${YELLOW}${prompt} ${hint}: ${NC}")" answer
        answer=${answer:-$default}
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "请输入 y 或 n" ;;
        esac
    done
}

# 版本比较函数
# 返回值: 0-相等, 1-v1>v2, 2-v1<v2
compare_versions() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 0
    
    local result
    result=$(printf "%s\n%s\n" "$v1" "$v2" | sort -V | head -n1)
    
    [[ "$result" == "$v1" ]] && return 2
    return 1
}

# 单个脚本下载函数
download_one_script() {
    local script_name="$1" download_dir="$2" base_url="$3" fail_dir="$4" log_file="$5"
    local max_retries=5 attempt
    local tmp_path="${download_dir}/${script_name}.part"
    local final_path="${download_dir}/${script_name}"

    printf "下载中: %s\n" "$script_name" >> "$log_file"
    
    for attempt in $(seq 1 "$max_retries"); do
        if curl -sL --fail --connect-timeout 15 -o "$tmp_path" "${base_url}/${script_name}"; then
            if [[ -s "$tmp_path" ]]; then
                mv -f "$tmp_path" "$final_path"
                printf "成功: %s\n" "$script_name" >> "$log_file"
                return 0
            fi
        fi
        [[ "$attempt" -lt "$max_retries" ]] && sleep 2
    done
    
    printf "失败: %s\n" "$script_name" >> "$log_file"
    rm -f -- "$tmp_path" 2>/dev/null || true
    touch -- "${fail_dir}/${script_name}.fail"
    return 0
}
export -f download_one_script

# 执行脚本更新主函数
perform_script_update() {
    local DOWNLOAD_DIR="${TMP_DIR}/new_scripts"
    local FAIL_DIR="${DOWNLOAD_DIR}/failures"
    mkdir -p "$DOWNLOAD_DIR" "$FAIL_DIR"

    log "GREEN" "正在下载并安装更新，请稍候..."
    
    local script_list_content
    script_list_content=$(curl -sL --fail --retry 5 "$SCRIPT_LIST_URL") || {
        log "RED" "错误: 无法获取脚本列表"
        exit 1
    }

    script_list_content=${script_list_content//$'\r'/}
    local -a SCRIPTS_TO_DOWNLOAD
    mapfile -t SCRIPTS_TO_DOWNLOAD < <(printf '%s' "$script_list_content" | grep .)

    if (( ${#SCRIPTS_TO_DOWNLOAD[@]} == 0 )); then
        log "RED" "错误: 远程脚本列表为空，已中止更新。"
        exit 1
    fi

    printf "%s\n" "${SCRIPTS_TO_DOWNLOAD[@]}" | \
    xargs -P "$MAX_CONCURRENT_DOWNLOADS" -I {} \
        bash -c 'download_one_script "$@"' _ {} "$DOWNLOAD_DIR" "$BASE_URL" "$FAIL_DIR" "$LOG_FILE"

    if find "$FAIL_DIR" -mindepth 1 -print -quit | grep -q .; then
        log "RED" "错误: 以下脚本下载失败，更新已中止："
        find "$FAIL_DIR" -type f -name "*.fail" -exec basename {} .fail \; | while read -r failed_script; do
            log "RED" " - ${failed_script}"
        done
        exit 1
    fi
    
    log "GREEN" "所有脚本下载成功，正在安装..."
    for script in "${SCRIPTS_TO_DOWNLOAD[@]}"; do
        install -m 750 -o root -g root "${DOWNLOAD_DIR}/${script}" "${SCRIPT_DIR}/"
    done
}

# ==============================================================================
# 主程序
# ==============================================================================
main() {
    if [[ "$EUID" -ne 0 ]]; then
        color_echo "$RED" "错误: 需要 root 权限"
        exit 1
    fi

    log "GREEN" "--- oneserver 脚本更新工具 ---"

    if ! curl -sL --fail --retry 5 --connect-timeout 10 -o "$TMP_DIR/menu.sh.remote" "${BASE_URL}/menu.sh"; then
        log "RED" "错误: 无法连接更新服务器或下载 menu.sh 文件"
        exit 1
    fi
    
    local LATEST_VERSION
    LATEST_VERSION=$(awk '/^# 版本:/ {print $3; exit}' "$TMP_DIR/menu.sh.remote")
    if [[ -z "$LATEST_VERSION" ]]; then
        log "RED" "错误: 无法从远程 menu.sh 解析版本号"
        exit 1
    fi

    if [[ ! -f "$SCRIPT_DIR/menu.sh" ]]; then
        log "GREEN" "脚本尚未安装，即将开始全新安装"
        perform_script_update
    else
        local CURRENT_VERSION
        CURRENT_VERSION=$(awk '/^# 版本:/ {print $3; exit}' "$SCRIPT_DIR/menu.sh")
        log "GREEN" "检测到当前脚本版本: ${CURRENT_VERSION:-'未知'}"
        log "GREEN" "最新可用版本: ${LATEST_VERSION}"
        
        local compare_result
        if compare_versions "${CURRENT_VERSION:-0}" "$LATEST_VERSION"; then
            compare_result=0
        else
            compare_result=$?
        fi

        case $compare_result in
            2)  # 发现新版本
                log "YELLOW" "发现新版本！"
                ask_yes_no "是否从 ${CURRENT_VERSION} 更新到 ${LATEST_VERSION}?" "y" || {
                    log "YELLOW" "操作已取消"
                    exit 0
                }
                ;;
            0)  # 版本相同
                log "GREEN" "您已是最新版"
                ask_yes_no "是否要强制重新安装?" "n" || {
                    log "YELLOW" "操作已取消"
                    exit 0
                }
                ;;
            1)  # 本地版本更高
                log "YELLOW" "本地版本 (${CURRENT_VERSION}) 高于远程版本 (${LATEST_VERSION})"
                ask_yes_no "是否要强制降级?" "n" || {
                    log "YELLOW" "操作已取消"
                    exit 0
                }
                ;;
        esac
        
        perform_script_update
    fi

    if [[ -f "${SCRIPT_DIR}/menu.sh" ]]; then
        local NEW_VERSION
        NEW_VERSION=$(awk '/^# 版本:/ {print $3; exit}' "${SCRIPT_DIR}/menu.sh")
        log "GREEN" "脚本更新成功完成"
        log "GREEN" "当前版本: ${NEW_VERSION}"
    else
        log "RED" "更新后严重错误：主脚本 menu.sh 缺失！"
        exit 1
    fi
}

main "$@"
