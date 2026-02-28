#!/bin/bash
#
# ==============================================================================
#  Podman安装与升级脚本
# ==============================================================================
#  功能：
#  - 自动检测 Podman 安装状态。
#  - 首次安装：安装 Podman, podman-docker, 和 podman-compose。
#  - 自动配置容器镜像仓库。
# ==============================================================================

set -Eeuo pipefail

# --- 全局配置 ---
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/install_podman.log"
readonly KEY_PACKAGE="podman"

# --- 待安装/升级的软件包列表 ---
readonly PACKAGES=(
    "podman"
    "podman-docker"
    "podman-compose"
)

# --- 容器配置 ---
readonly REGISTRIES_CONF="/etc/containers/registries.conf"
readonly REGISTRY_CONFIG_LINE='unqualified-search-registries = ["docker.io"]'

# --- 颜色定义 ---
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
#  核心工具函数
# ==============================================================================

init() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

log() {
    local color_name="$1" message="$2"
    local color
    case "${color_name^^}" in
        CYAN)   color="$CYAN"   ;; GREEN)  color="$GREEN"  ;;
        RED)    color="$RED"    ;; YELLOW) color="$YELLOW" ;;
        *)      color="$NC"     ;;
    esac
    echo -e "${color}${message}${NC}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log "RED" "错误：此脚本需要以 root 权限运行。"
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer hint="[Y/n]"
    if [[ "$default" == "n" ]]; then hint="[y/N]"; fi
    while true; do
        read -rp "$(echo -e "${CYAN}${prompt} ${YELLOW}${hint}${CYAN}:${NC} ")" answer
        answer=${answer:-$default}
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

# ==============================================================================
#  主安装逻辑函数
# ==============================================================================

update_system_repo() {
    log "CYAN" "--- [步骤 1/4] 正在更新系统软件包列表 ---"
    log "YELLOW" "这可能需要一些时间..."
    if apt-get update -y >> "$LOG_FILE" 2>&1; then
        log "GREEN" "软件包列表更新成功。"
    else
        log "RED" "错误：软件包列表更新失败。请检查网络和 apt 源配置。"
        exit 1
    fi
}

install_or_upgrade_packages() {
    local operation_mode="$1"
    local operation_text="操作"
    case "$operation_mode" in
        install) operation_text="安装" ;;
        upgrade) operation_text="升级" ;;
        reinstall) operation_text="重新安装" ;;
    esac

    log "CYAN" "--- [步骤 2/4] 正在${operation_text} Podman 相关软件包 ---"
    log "CYAN" "目标软件包: ${PACKAGES[*]}"
    log "YELLOW" "执行中... "
    
    if apt-get install --reinstall -y "${PACKAGES[@]}" >> "$LOG_FILE" 2>&1; then
        log "GREEN" "软件包 ${operation_text} 成功。"
    else
        log "RED" "错误：软件包 ${operation_text} 失败。请查看日志文件获取详细信息。"
        exit 1
    fi
}

configure_registries() {
    log "CYAN" "--- [步骤 3/4] 正在配置容器镜像仓库 ---"
    if [[ ! -f "$REGISTRIES_CONF" ]]; then touch "$REGISTRIES_CONF"; fi
    if grep -qF -- "$REGISTRY_CONFIG_LINE" "$REGISTRIES_CONF"; then return; fi
    log "YELLOW" "正在将 Docker Hub 设置为默认的非限定镜像搜索仓库..."
    if grep -q '^\s*#\s*unqualified-search-registries' "$REGISTRIES_CONF"; then
        sed -i -E "s|^\s*#\s*unqualified-search-registries.*|${REGISTRY_CONFIG_LINE}|" "$REGISTRIES_CONF"
    else
        echo -e "\n${REGISTRY_CONFIG_LINE}" >> "$REGISTRIES_CONF"
    fi
    log "GREEN" "镜像仓库配置已成功更新。"
}

verify_installation() {
    log "CYAN" "--- [步骤 4/4] 正在验证安装结果 ---"
    local success=true
    if command -v podman &> /dev/null; then log "GREEN" "Podman 命令可用。版本信息: $(podman --version)"; else log "RED" "验证失败：'podman' 命令未找到。"; success=false; fi
    if command -v docker &> /dev/null; then local docker_version_output; docker_version_output=$(docker --version 2>&1); log "GREEN" "'docker' 命令别名可用。版本信息: $(echo "$docker_version_output" | head -n1)"; if echo "$docker_version_output" | grep -qiw "Podman"; then log "GREEN" "确认 'docker' 命令由 Podman 提供支持。"; else log "RED" "警告：'docker' 命令存在，但其版本信息不包含 'Podman'。"; success=false; fi; else log "RED" "验证失败：'docker' 命令别名未找到。"; success=false; fi
    if [[ "$success" == true ]]; then log "GREEN" "========================================\n Podman 已成功安装/升级并配置完毕！\n========================================"; else log "RED" "安装过程出现问题，请检查上面的红色错误信息和日志文件。"; fi
}

# ==============================================================================
#  主执行逻辑
# ==============================================================================
main() {
    init
    check_root
    
    log "CYAN" "=================================================\n     Podman 自动化安装与升级脚本\n================================================="

    if ! dpkg -s "$KEY_PACKAGE" >/dev/null 2>&1; then
        log "CYAN" "检测到 Podman 未安装，将执行全新安装流程。"
        update_system_repo
        install_or_upgrade_packages "install"
    else
        local current_version
        current_version=$(dpkg-query -W -f='${Version}' "$KEY_PACKAGE" 2>/dev/null)
        log "GREEN" "检测到 Podman 已安装，当前版本: ${current_version}"
        
        update_system_repo
        
        local candidate_version
        candidate_version=$(apt-cache policy "$KEY_PACKAGE" | grep 'Candidate:' | awk '{print $2}')
        
        if [[ -z "$candidate_version" || "$candidate_version" == "(none)" ]]; then
            log "YELLOW" "警告：无法获取最新的可用版本信息。"
            if ask_yes_no "是否要强制重新安装所有 Podman 相关软件包?" "n"; then
                install_or_upgrade_packages "reinstall"
            else
                log "YELLOW" "操作已取消。"
                exit 0
            fi
        else
            log "CYAN" "最新的可用版本为: ${candidate_version}"
            
            if dpkg --compare-versions "$current_version" "lt" "$candidate_version"; then
                if ask_yes_no "发现新版本！是否从 ${current_version} 升级到 ${candidate_version}?"; then
                    install_or_upgrade_packages "upgrade"
                else
                    log "YELLOW" "升级操作已由用户取消。"
                    exit 0
                fi
            else
                log "GREEN" "您当前已是最新版本。"
                if ask_yes_no "是否需要强制重新安装所有相关软件包?" "n"; then
                    install_or_upgrade_packages "reinstall"
                else
                    log "YELLOW" "操作已取消。"
                    exit 0
                fi
            fi
        fi
    fi

    configure_registries
    verify_installation

    log "GREEN" "脚本执行完毕。"
}

# --- 脚本入口 ---
trap 'echo -e "${NC}"; exit' INT TERM
main "$@"
