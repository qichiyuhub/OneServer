#!/bin/bash
#
# OneServer综合管理脚本
# 版本: 1.0.0
# 功能：提供交互式菜单界面，用于执行各种 OneServer 系统的部署和管理任务。
#

set -euo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

# 配置常量
readonly CORE_DIR="/opt/oneserver"
readonly SCRIPT_DIR="${CORE_DIR}/script"
readonly LOG_FILE="/var/log/oneserver/menu.log"

# 终端颜色定义
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# 初始化日志目录
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# 日志记录函数
log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name:-}"
    if [[ "$color_name" == "RED" || "$color_name" == "CYAN" ]]; then
        echo -e "${color}${message}${NC}" >&2
    else
        echo -e "${color}${message}${NC}"
    fi
    
    # 输出到日志文件
    printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$message" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE"
}

# 运行子脚本函数
run_script() {
    local msg="$1"
    local script_name="$2"
    local script_file="${SCRIPT_DIR}/${script_name}"

    log "CYAN" ">>> 正在执行: ${msg}..."
    
    if [[ ! -x "$script_file" ]]; then
        log "RED" "错误: 脚本缺失或不可执行: $script_name"
        return 1
    fi

    if /bin/bash -- "$script_file"; then
        log "GREEN" "<<< 操作成功: ${msg}"
        return 0
    else
        local script_exit_code=$? 
        log "RED" "<<< 操作失败: ${msg} (退出码: $script_exit_code)。详情请查看对应日志。"
        return 1
    fi
}

# ==============================================================================
#  主菜单与执行逻辑
# ==============================================================================

# 显示主菜单
show_menu() {
    clear
    echo -e "\n${CYAN}================= OneServer综合管理面板 =================${NC}" >&2
    
    # --- 环境与安装 ---
    echo -e "${YELLOW}--- 环境与安装 ---${NC}" >&2
    echo -e "${GREEN} 1. 服务器安全设置${NC}"
    echo -e "${GREEN} 2. 安装/升级 Caddy${NC}"
    echo -e "${GREEN} 3. 安装/升级 PHP${NC}"
    echo -e "${GREEN} 4. 安装/升级 Node.js${NC}"
    echo -e "${GREEN} 5. 安装/升级 MariaDB${NC}"
    echo -e "${GREEN} 6. 安装/升级 Redis${NC}"
    echo -e "${GREEN} 7. 安装/升级 Podman${NC}"
    
    # --- 服务与应用 ---
    echo -e "${YELLOW}--- 服务与应用 ---${NC}" >&2
    echo -e "${GREEN} 8. WordPress 部署${NC}"
    echo -e "${GREEN} 9. Caddy 管理${NC}"
    echo -e "${GREEN}10. PHP 配置${NC}"
    echo -e "${GREEN}11. MariaDB 数据库管理${NC}"
    echo -e "${GREEN}12. Podman 容器管理${NC}"

    # --- 系统与维护 ---
    echo -e "${YELLOW}--- 系统与维护 ---${NC}" >&2
    echo -e "${GREEN}13. 备份网站数据${NC}"
    echo -e "${GREEN}14. 恢复网站数据${NC}"
    echo -e "${GREEN}15. 更新管理脚本${NC}"
    echo -e "${GREEN}16. UFW管理${NC}"
    
    echo -e "${CYAN}=========================================================${NC}" >&2
    echo -e "${GREEN} 0. 退出脚本（菜单唤出键 os）${NC}"
}

# 处理用户选择
handle_choice() {
    local choice
    
    # 提示用户有效的输入范围
    read -rp "请选择操作 [0-16]: " choice
    
    case "$choice" in
        # --- 环境与安装 ---
        1) run_script "服务器安全设置" "safe.sh" ;;
        2) run_script "安装/升级 Caddy" "install_caddy.sh" ;;
        3) run_script "安装/升级 PHP" "install_php.sh" ;;
        4) run_script "安装/升级 Node.js" "install_nodejs.sh" ;;
        5) run_script "安装/升级 MariaDB" "install_mariadb.sh" ;;
        6) run_script "安装/升级 Redis" "install_redis.sh" ;;
        7) run_script "安装/升级 Podman" "install_podman.sh" ;;
        
        # --- 服务与应用 ---
        8) run_script "WordPress 部署" "deploy_wordpress.sh" ;;
        9) run_script "Caddy 管理" "caddy-manager.sh" ;;
        10) run_script "PHP 配置" "update_phpconf.sh" ;;
        11) run_script "MariaDB 数据库管理" "db_manager.sh" ;;
        12) run_script "Podman 容器管理" "podman_manager.sh" ;;
        
        # --- 系统与维护 ---
        13) run_script "备份网站数据" "backup.sh" ;;
        14) run_script "恢复网站数据" "restore.sh" ;;
        15) run_script "更新管理脚本" "script_update.sh" ;;
        16) run_script "UFW管理" "ufw_manager.sh" ;;

        # --- 退出 ---
        0) echo -e "\n${CYAN}正在退出...${NC}" >&2; exit 0 ;;
        
        # --- 错误处理 ---
        *) log "RED" "无效选择，请输入 0-16 之间的数字。" ;;
    esac
    
    # 除退出外，所有操作后等待用户按键
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo
}

# 主函数
main() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}错误: 请以 root 用户运行此脚本。${NC}" >&2
        exit 1
    fi
    
    while true; do
        show_menu
        handle_choice
    done
}

main "$@"
