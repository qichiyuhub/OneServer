#!/usr/bin/env bash
#
# Caddy Server 安装与升级脚本 (内置 Cloudflare DNS 插件)
#
# 功能描述:
#   1. 检测系统中是否已安装 Caddy
#   2. 支持官方 API 和备用 GitHub 仓库两种下载源
#   3. 自动验证二进制文件完整性和插件功能
#   4. 自动配置系统服务和防火墙检测

set -Eeuo pipefail

# ==============================================================================
# 配置参数
# ==============================================================================
readonly APP_NAME="Caddy"
readonly OFFICIAL_API_URL_BASE="https://caddyserver.com/api/download"
readonly OFFICIAL_OS="linux"
readonly OFFICIAL_ARCH="amd64"
readonly OFFICIAL_PLUGINS="github.com/caddy-dns/cloudflare"
readonly BACKUP_REPO="qichiyuhub/caddy-cloudflare"
readonly FILE_PATTERN="caddy-.*-linux-amd64.tar.gz$"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="$LOG_DIR/install_caddy.log"

# ==============================================================================
# 输出颜色定义
# ==============================================================================
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
# 初始化设置
# ==============================================================================
mkdir -p "$LOG_DIR"
true > "$LOG_FILE"
TMP_DIR=$(mktemp -d)
VALIDATION_LOG="$TMP_DIR/modules.log"
trap 'rm -rf "$TMP_DIR"' EXIT

# ==============================================================================
# 功能函数定义
# ==============================================================================

# 日志记录函数
log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    
    echo -e "${color}${message}${NC}"
    printf "%s\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

# 命令执行函数
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

# 用户确认提示
ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer
    local hint="[Y/n]"
    
    [[ "$default" == "n" ]] && hint="[y/N]"
    
    while true; do
        read -rp "$prompt $hint: " answer
        answer=${answer:-$default}
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

# 获取最新版本号
get_latest_version() {
    curl -s "https://api.github.com/repos/caddyserver/caddy/releases/latest" | \
        grep -oP '"tag_name":\s*"\K[^"]+' 2>/dev/null || echo ""
}

# 版本比较函数
compare_versions() {
    local ver1="${1#v}" ver2="${2#v}"
    
    if [[ "$ver1" == "$ver2" ]]; then
        return 0
    fi
    
    if [[ "$(printf '%s\n' "$ver1" "$ver2" | sort -V | head -n1)" == "$ver1" ]]; then
        return 2  # 版本1 < 版本2
    else
        return 1  # 版本1 > 版本2
    fi
}

# 下载和验证函数
download_and_verify() {
    local source_name="$1"
    local download_cmd="$2"

    log "CYAN" "\n[2/7] 尝试从 ${source_name} 下载 Caddy 二进制文件..."
    cd "$TMP_DIR"
    run_command "清理临时目录" find . -mindepth 1 -delete

    if ! bash -c "$download_cmd" >> "$LOG_FILE" 2>&1; then
        log "YELLOW" "警告: 从 ${source_name} 下载失败。"
        return 1
    fi
    
    log "GREEN" "从 ${source_name} 下载成功。"
    log "CYAN" "\n[3/7] 解压并检查文件..."
    
    local CADDY_BIN=""
    if [[ -f "caddy" ]]; then
        CADDY_BIN="./caddy"
    elif [[ -f "caddy.tar.gz" ]]; then
        run_command "解压 caddy.tar.gz" tar -xzf caddy.tar.gz
        CADDY_BIN="./caddy"
    else
        log "RED" "错误: 下载目录中未找到 'caddy' 或 'caddy.tar.gz'。"
        return 1
    fi
    
    run_command "为 caddy 添加执行权限" chmod +x "$CADDY_BIN"
    log "CYAN" "\n[4/7] 验证二进制文件..."
    
    if ! "$CADDY_BIN" version >/dev/null 2>&1; then
        log "RED" "错误: 下载的二进制文件无效或已损坏。"
        return 1
    fi

    "$CADDY_BIN" list-modules > "$VALIDATION_LOG"
    if grep -Fq 'dns.providers.cloudflare' "$VALIDATION_LOG"; then
        log "GREEN" "插件验证通过 ('dns.providers.cloudflare' 已包含)。"
        return 0
    else
        log "RED" "验证失败！二进制文件中不包含 'dns.providers.cloudflare' 插件。"
        return 1
    fi
}

# ==============================================================================
# 主执行逻辑
# ==============================================================================
log "CYAN" "--- ${APP_NAME} 安装与更新工具 ---"
log "CYAN" "==> 准备系统环境，确保依赖已安装..."
run_command "更新软件包列表" sudo apt-get update -qq
run_command "安装依赖包" sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gpg wget tar jq

# 检查现有安装
if ! command -v caddy >/dev/null 2>&1; then
    log "CYAN" "${APP_NAME} 未安装，即将开始全新安装..."
else
    CURRENT_VERSION=$(caddy version 2>/dev/null | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
    log "GREEN" "检测到 ${APP_NAME} 已安装，当前版本: ${CURRENT_VERSION}"
    
    log "CYAN" "==> 正在检查最新版本..."
    LATEST_VERSION=$(get_latest_version)

    if [[ -z "$LATEST_VERSION" ]]; then
        log "YELLOW" "警告: 无法获取最新版本信息。"
        if ! ask_yes_no "是否要强制重新安装?" "n"; then
            log "YELLOW" "操作已取消。" && exit 0
        fi
    else
        log "CYAN" "最新可用版本: ${LATEST_VERSION}"
        compare_versions "$CURRENT_VERSION" "$LATEST_VERSION" && cmp_result=0 || cmp_result=$?
        
        case $cmp_result in
            2)
                log "YELLOW" "发现新版本！"
                if ! ask_yes_no "是否从 ${CURRENT_VERSION} 升级到 ${LATEST_VERSION}?" "y"; then
                    log "YELLOW" "操作已取消。" && exit 0
                fi
                ;;
            *)
                log "GREEN" "您已是最新版 (或更新的测试版)。"
                if ! ask_yes_no "是否要强制重新安装?" "n"; then
                    log "YELLOW" "操作已取消。" && exit 0
                fi
                ;;
        esac
    fi
fi

# 安装 Caddy 官方框架
log "CYAN" "\n[1/7] 准备系统环境并安装 Caddy 官方框架..."

# 添加 Caddy GPG 密钥
run_command "删除旧的 GPG 密钥文件（如果存在）" sudo rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
run_command "添加 Caddy GPG 密钥" sudo bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"

# 添加 Caddy APT 源
run_command "删除旧的 APT 源文件（如果存在）" sudo rm -f /etc/apt/sources.list.d/caddy-stable.list
run_command "添加 Caddy APT 源" sudo bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null"

run_command "设置密钥权限" sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
run_command "设置源文件权限" sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
run_command "再次更新软件包列表" sudo apt-get update -qq
run_command "安装 Caddy 官方框架" sudo apt-get install -y -qq caddy
log "GREEN" "Caddy 官方框架安装完成。"

# 下载和验证二进制文件
official_download_url="${OFFICIAL_API_URL_BASE}?os=${OFFICIAL_OS}&arch=${OFFICIAL_ARCH}&p=${OFFICIAL_PLUGINS}"
official_download_command="wget -q -O caddy '$official_download_url'"

if download_and_verify "Caddy 官网 API" "$official_download_command"; then
    log "GREEN" "使用官方 Caddy 二进制文件。"
else
    log "YELLOW" "\n--- 官方渠道失败，切换到备用方案 ---"
    LATEST_TAR=$(curl -s "https://api.github.com/repos/${BACKUP_REPO}/releases/latest" | \
        jq -r ".assets[] | select(.name | test(\"${FILE_PATTERN}\")) | .browser_download_url")

    if [[ -z "$LATEST_TAR" ]]; then
        log "RED" "错误: 在备用仓库 ${BACKUP_REPO} 中也未找到匹配的二进制文件。"
        exit 1
    fi

    backup_download_command="wget -q -O caddy.tar.gz '$LATEST_TAR'"
    if ! download_and_verify "备用 GitHub 仓库" "$backup_download_command"; then
        log "RED" "错误: 所有下载和验证尝试均失败。请检查网络和仓库配置。"
        exit 1
    fi
    log "GREEN" "使用备用 GitHub 仓库的 Caddy 二进制文件。"
fi

# 替换二进制文件并重启服务
log "CYAN" "\n[5/7] 替换系统二进制并重启服务..."
run_command "停止 Caddy 服务" sudo systemctl stop caddy

backup_date=$(date +%F_%H-%M-%S)
backup_path="/usr/bin/caddy.bak.${backup_date}"
[[ -f /usr/bin/caddy ]] && run_command "备份旧的 Caddy 二进制文件" sudo mv /usr/bin/caddy "$backup_path"
run_command "安装新的 Caddy 二进制文件" sudo install -m 755 "$TMP_DIR/caddy" /usr/bin/caddy
run_command "为 Caddy 设置网络权限" sudo setcap cap_net_bind_service=+ep /usr/bin/caddy

# 处理 AppArmor（Ubuntu 特有，Debian 默认不启用）
# apt 安装的 caddy 会创建 AppArmor profile，替换为第三方二进制后需要设为 complain 模式
if command -v apparmor_parser >/dev/null 2>&1 && systemctl is-active --quiet apparmor 2>/dev/null; then
    log "CYAN" "检测到 AppArmor 正在运行，正在调整 Caddy 的 AppArmor 策略..."
    if [[ -f /etc/apparmor.d/usr.bin.caddy ]]; then
        run_command "将 Caddy AppArmor 策略设为 complain 模式" sudo aa-complain /usr/bin/caddy
    fi
fi

run_command "重新加载 systemd 守护进程" sudo systemctl daemon-reload
run_command "启动 Caddy 服务" sudo systemctl start caddy

sleep 2
if ! systemctl is-active --quiet caddy; then
    log "RED" "错误: Caddy 服务启动失败。请检查日志:"
    sudo journalctl -u caddy --no-pager | tail -n20
    exit 1
fi

run_command "设置 Caddy 开机自启" sudo systemctl enable caddy
log "GREEN" "Caddy 服务已成功启动并设置开机自启。"

# 环境检查
log "CYAN" "\n[6/7] 环境检查..."
firewall_ok=true

if command -v ufw >/dev/null && sudo ufw status | grep -q "Status: active"; then
    if ! sudo ufw status | grep -E -q "^80(/tcp)?[[:space:]]+ALLOW" || \
       ! sudo ufw status | grep -E -q "^443(/tcp)?[[:space:]]+ALLOW" || \
       ! sudo ufw status | grep -E -q "^443/udp[[:space:]]+ALLOW"; then
        firewall_ok=false
    fi
elif command -v firewall-cmd >/dev/null && sudo systemctl is-active --quiet firewalld; then
    http_enabled=$(sudo firewall-cmd --list-services | grep -qw "http")
    https_enabled=$(sudo firewall-cmd --list-services | grep -qw "https")
    tcp80_open=$(sudo firewall-cmd --list-ports | grep -qw "80/tcp")
    tcp443_open=$(sudo firewall-cmd --list-ports | grep -qw "443/tcp")
    udp443_open=$(sudo firewall-cmd --list-ports | grep -qw "443/udp")
    
    if ! $http_enabled && ! $tcp80_open; then firewall_ok=false; fi
    if ! $https_enabled && ! $tcp443_open; then firewall_ok=false; fi
    if ! $udp443_open; then firewall_ok=false; fi
fi

if [[ "$firewall_ok" = true ]]; then
    log "GREEN" "防火墙状态: 端口 80/tcp、443/tcp、443/udp 已正确配置。"
else
    log "YELLOW" "防火墙警告: 某些端口未放行(需开放 80/tcp、443/tcp、443/udp)"
fi

# 安装完成
log "CYAN" "\n[7/7] 安装结束..."
log "GREEN" "--- ${APP_NAME} 安装/升级成功！ ---"

CURRENT_VERSION_INFO=$(/usr/bin/caddy version | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+')
CONFIG_FILE_PATH="/etc/caddy/Caddyfile"
STATUS_COMMAND="systemctl status caddy"

log "CYAN" "  当前版本:   ${NC}${CURRENT_VERSION_INFO}"
log "CYAN" "  配置文件:   ${NC}${CONFIG_FILE_PATH}"
log "CYAN" "  查看状态:   ${NC}${STATUS_COMMAND}"
