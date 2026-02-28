#!/bin/bash
#
# OneServer 引导脚本
#
# 功能：初始化 OneServer 环境，包括下载必要脚本、配置目录和权限，并启动主菜单。
#

set -euo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

# 配置常量
readonly CORE_DIR="/opt/oneserver"
readonly SCRIPT_DIR="${CORE_DIR}/script"
readonly CONFIG_DIR="${CORE_DIR}/config"
readonly SECURE_CONF="/opt/oneserver/secure.conf"
readonly REPO_BASE_URL="https://raw.githubusercontent.com/qichiyuhub/OneServer/refs/heads/main"
readonly SCRIPT_BASE_URL="${REPO_BASE_URL}/script"
readonly SCRIPT_LIST_URL="${SCRIPT_BASE_URL}/script_list.txt"
readonly LOG_FILE="/var/log/oneserver/installer.log"
readonly MENU_COMMAND="os"  # 可自定义的菜单调出命令

# 终端颜色定义
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# 日志函数
log_error() {
    echo -e "${RED}错误: $1${NC}"
    echo -e "${RED}详情请查看日志: ${LOG_FILE}${NC}"
}

# 初始化安全配置文件
init_secure_conf() {
    mkdir -p "$(dirname "$SECURE_CONF")"
    if [[ ! -s "$SECURE_CONF" ]]; then
        echo "# Sensitive config file, created on $(date)" > "$SECURE_CONF"
    fi
    chown root:root "$SECURE_CONF"
    chmod 600 "$SECURE_CONF"
}

# 下载单个脚本函数
download_one_script() {
    local script_name="$1"
    local download_dir="$2"
    local base_url="$3"
    local fail_dir="$4"
    local max_retries=5
    local attempt
    local tmp_path="${download_dir}/${script_name}.part"
    local final_path="${download_dir}/${script_name}"

    for attempt in $(seq 1 "$max_retries"); do
        if curl -sL --fail --connect-timeout 15 -o "$tmp_path" "${base_url}/${script_name}"; then
            if [[ -s "$tmp_path" ]]; then
                mv -f "$tmp_path" "$final_path"
                return 0
            fi
        fi
        [[ "$attempt" -lt "$max_retries" ]] && sleep 2
    done
    rm -f "$tmp_path" || true
    # 如果下载最终失败，则创建一个失败标记文件
    touch "${fail_dir}/${script_name}.fail"
    return 1
}

# 运行初始化过程
run_initialization() {
    mkdir -p "$SCRIPT_DIR" "$CONFIG_DIR" "/var/backups/oneserver"
    chown -R root:root "$CORE_DIR"
    chmod 750 "$CORE_DIR" "$SCRIPT_DIR" "$CONFIG_DIR"

    if ! systemctl restart systemd-timesyncd.service >/dev/null 2>&1; then
        echo "警告: 无法重启 systemd-timesyncd.service，时间同步可能受影响。" >&2
    fi
    
    if ! command -v curl >/dev/null 2>&1 || ! command -v pigz >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends curl pigz ca-certificates jq
    fi

    local DOWNLOAD_DIR
    DOWNLOAD_DIR=$(mktemp -d)
    trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

    local script_list_content
    if ! script_list_content=$(curl -sL --fail --retry 5 --connect-timeout 10 "$SCRIPT_LIST_URL"); then
        echo "错误: 无法获取脚本列表！" >&2
        exit 1
    fi

    script_list_content=${script_list_content//$'\r'/}
    local -a SCRIPTS_TO_DOWNLOAD
    mapfile -t SCRIPTS_TO_DOWNLOAD <<< "$script_list_content"

    if [[ ${#SCRIPTS_TO_DOWNLOAD[@]} -eq 0 ]]; then
        echo "错误: 获取到的远程脚本列表为空，无法继续。" >&2
        exit 1
    fi

    # --- 并行下载 ---
    local FAIL_DIR="${DOWNLOAD_DIR}/failures"
    mkdir -p "$FAIL_DIR"

    export -f download_one_script
    printf "%s\n" "${SCRIPTS_TO_DOWNLOAD[@]}" | xargs -P 8 -I {} \
        bash -c "download_one_script \"\$1\" \"\$2\" \"\$3\" \"\$4\"" _ {} "$DOWNLOAD_DIR" "$SCRIPT_BASE_URL" "$FAIL_DIR"

    if find "$FAIL_DIR" -mindepth 1 -print -quit | grep -q .; then
        echo "错误: 以下脚本下载失败：" >&2
        find "$FAIL_DIR" -type f -name "*.fail" -exec basename {} .fail \; >&2
        exit 1
    fi

    for script in "${SCRIPTS_TO_DOWNLOAD[@]}"; do
        if [[ ! -s "${DOWNLOAD_DIR}/${script}" ]]; then
            echo "错误: 核心脚本 ${script} 未下载成功或为空文件。" >&2
            exit 1
        fi
    done

    for script in "${SCRIPTS_TO_DOWNLOAD[@]}"; do
        install -m 750 -o root -g root "${DOWNLOAD_DIR}/${script}" "${SCRIPT_DIR}/"
    done

    ln -sfn /var/log/oneserver "${CORE_DIR}/logs" 2>/dev/null || echo "警告: 无法创建 logs 符号链接。" >&2
    ln -sfn /var/backups/oneserver "${CORE_DIR}/backups" 2>/dev/null || echo "警告: 无法创建 backups 符号链接。" >&2
    ln -sf /etc/caddy/Caddyfile "${CONFIG_DIR}/Caddyfile" 2>/dev/null || echo "警告: 无法创建 Caddyfile 符号链接。" >&2

    # 使用变量创建菜单命令
    printf '%s\n' '#!/bin/bash' 'exec /bin/bash /opt/oneserver/script/menu.sh "$@"' > "/usr/local/bin/${MENU_COMMAND}"
    chmod +x "/usr/local/bin/${MENU_COMMAND}"

    touch "${CORE_DIR}/.initialized"
}

# 主函数
main() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误: 请以 root 用户运行此脚本。${NC}"
        exit 1
    fi

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE" 2>/dev/null; then
        echo -e "${RED}错误: 无法创建或写入日志文件 ${LOG_FILE}。${NC}"
        exit 1
    fi

    if [[ ! -f "${CORE_DIR}/.initialized" ]]; then
        echo -e "${GREEN}--- 正在初始化 oneserver 环境，请稍候... ---${NC}"
        
        if ! {
            init_secure_conf
            run_initialization
        } >> "$LOG_FILE" 2>&1; then
            log_error "初始化失败。"
            exit 1
        fi
        
        echo -e "${GREEN}--- 初始化完成！正在启动主菜单... ---\n${NC}"
    fi

    local menu_script="${SCRIPT_DIR}/menu.sh"
    if [[ -x "$menu_script" ]]; then
        exec /bin/bash "$menu_script" "$@"
    else
        log_error "主菜单脚本 ${menu_script} 缺失或不可执行。"
        exit 1
    fi
}

main "$@"
