#!/bin/bash
#
# UFW Firewall Manager
#

# --- 样式定义 ---
readonly LOG_FILE="/var/log/oneserver/safe.log"
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREY='\033[0;90m'
readonly NC='\033[0m'

# --- 核心执行函数 ---

run_cmd() {
    local desc="$1"
    local cmd="$2"
    local mode="$3"
    local output
    output=$(bash -c "LC_ALL=C $cmd" 2>&1)
    local exit_code=$?

    # 日志留痕
    echo "[$(date +'%F %T')] Mode: $mode | Cmd: $cmd | Code: $exit_code | Out: $output" >> "$LOG_FILE"

    # --- 结果判定逻辑 ---
    
    if [[ "$mode" == "delete" ]]; then
        # [删除模式]: 必须严格检查输出文本
        if [[ "$output" == *"Rule deleted"* ]]; then
            echo -e "  -> [OK] ${GREEN}成功${NC}: $desc"
        elif [[ "$output" == *"Could not delete"* || "$output" == *"not found"* || "$output" == *"non-existent"* ]]; then
            # 只有这里才会显示跳过
            echo -e "  -> [!]  ${YELLOW}跳过${NC}: $desc (规则不存在)"
        else
            # 其他未知错误 (如语法错误)
            echo -e "  -> [X]  ${RED}失败${NC}: $desc"
            echo -e "     ${GREY}原因: $output${NC}"
        fi
    else
        # [添加模式]: 依赖退出码，因为 UFW 添加已存在的规则也是 exit 0
        if [[ $exit_code -eq 0 ]]; then
            if [[ "$output" == *"Skipping"* ]]; then
                echo -e "  -> [OK] ${GREEN}成功${NC}: $desc (已存在)"
            else
                echo -e "  -> [OK] ${GREEN}成功${NC}: $desc"
            fi
        else
            echo -e "  -> [X]  ${RED}失败${NC}: $desc"
            echo -e "     ${GREY}原因: $output${NC}"
        fi
    fi
}

ask_yn() {
    local prompt="[y/N]"; [[ "$2" == "y" ]] && prompt="[Y/n]"
    read -r -p "$(echo -e "$1 ${prompt}: ")" answer
    [[ "${answer:-$2}" =~ ^[yY] ]]
}

# --- 主逻辑 ---

ufw_manager() {
    # 0. Root 检查
    [[ $EUID -ne 0 ]] && { echo -e "${RED}[Error] 需要 root 权限${NC}"; return 1; }
    
    # 自动安装 UFW
    command -v ufw >/dev/null || apt-get install -y -qq ufw >/dev/null
    mkdir -p "$(dirname "$LOG_FILE")"

    # 1. 获取 SSH 端口 (高强度正则匹配)
    # 逻辑: 忽略注释行，匹配 Port 关键字，提取数字。若失败则默认为 22。
    local ssh_port
    ssh_port=$(grep -E "^[[:space:]]*Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config 2>/dev/null | head -n 1 | awk '{print $2}')
    ssh_port=${ssh_port:-22}

    while true; do
        clear
        echo -e "${CYAN}========================================${NC}"
        echo -e "${CYAN}       UFW 防火墙管理       ${NC}"
        echo -e "${CYAN}========================================${NC}"
        
        # 状态显示
        local raw_status; raw_status=$(ufw status | head -n 1 | awk '{print $2}')
        if [[ "$raw_status" == "active" ]]; then
            echo -e " [*] 运行状态: ${GREEN}已激活 (Active)${NC}"
        else
            echo -e " [*] 运行状态: ${RED}未运行 (Inactive)${NC}"
        fi
        echo "----------------------------------------"
        echo -e " [1] 查看规则 (Status)"
        echo -e " [2] ${GREEN}添加规则 (Add)    [+]${NC}"
        echo -e " [3] ${RED}删除规则 (Delete) [-]${NC}"
        echo -e " [4] ${YELLOW}重载配置 (Reload) [!]${NC}"
        echo -e " [0] ${GREY}返回主菜单 (Exit)${NC}"
        echo "----------------------------------------"
        
        echo -ne "${YELLOW}>>> 请输入选项: ${NC}"
        read -r choice
        
        local ufw_prefix=""
        local action_name=""
        local theme_color=""
        local op_mode=""
        local action_verb=""
        
        case "$choice" in
            0) return ;;
            1) 
                echo -e "\n${CYAN}--- 详细规则列表 ---${NC}"
                ufw status numbered
                echo -e "\n${GREY}[按任意键返回菜单]${NC}"
                read -r -n 1 -s
                continue 
                ;;
            2) 
                ufw_prefix="ufw allow"
                action_name="添加"
                theme_color="$GREEN"
                op_mode="allow"
                action_verb="启用"
                ;;
            3) 
                ufw_prefix="ufw delete allow"
                action_name="删除" 
                theme_color="$RED"
                op_mode="delete"
                action_verb="删除"
                
                clear
                echo -e "${RED}========================================${NC}"
                echo -e "${RED}       删除模式 (DANGER ZONE)       ${NC}"
                echo -e "${RED}========================================${NC}"
                ufw status numbered
                echo "----------------------------------------"
                echo -e "${YELLOW}[!] 提示: 输入【端口号】(如 80) 进行删除。${NC}"
                ;; 
            4) 
                echo ""
                # 重载也使用 LC_ALL=C 保证一致性
                bash -c "LC_ALL=C ufw reload" >/dev/null && echo -e "  -> [OK] ${GREEN}重载成功${NC}"
                read -r -n 1 -s -p "按任意键继续..."
                continue 
                ;;
            *) echo "输入无效"; sleep 0.5; continue ;;
        esac

        # 2. 获取端口输入
        echo -ne "\n${theme_color}>>> 请输入要${action_name}的端口 (多端口空格或逗号间隔，留空回车取消): ${NC}"
        read -r ports_input
        
        if [[ -z "$ports_input" ]]; then
            echo -e "${GREY}<-- 已取消操作。${NC}"
            sleep 0.5
            continue
        fi
        
        read -r -a ports <<< "${ports_input//,/ }"

        # 3. 选择策略
        echo -e "\n${CYAN}--- 协议策略 ---${NC}"
        echo " 1. TCP + UDP (双栈/标准)"
        echo " 2. 仅 TCP"
        echo " 3. 仅 UDP"
        echo " 4. 专家模式 (自定义 IP/协议)"
        echo -ne "${theme_color}>>> 选择 [1-4] (默认 1): ${NC}"
        read -r mode
        mode=${mode:-1}

        # 删除操作的二次确认
        if [[ "$op_mode" == "delete" ]]; then
            echo -e "\n${RED}[!] 警告${NC}"
            echo -e "即将删除端口: [ ${ports[*]} ]"
            if ! ask_yn "${RED}[?] 确认执行?${NC}" "n"; then
                echo "<-- 操作已撤销。"
                sleep 1
                continue
            fi
        fi

        echo -e "\n--- 正在执行 ---"
        for raw_port in "${ports[@]}"; do
            # 端口清洗：只保留数字部分，去除 /tcp 等后缀
            local port="${raw_port%%/*}"

            # ==========================================
            # 🛡️ 核心安全检查：SSH 端口保护
            # ==========================================
            if [[ "$op_mode" == "delete" ]]; then
                # 字符串精确比对，防止误删
                if [[ "$port" == "$ssh_port" ]]; then
                    echo -e "  -> [SAFE] ${RED}保护触发${NC}: 端口 $port 是 SSH 管理端口，已强制拦截！"
                    continue
                fi
            fi
            # ==========================================

            case "$mode" in
                1) # 标准双栈
                   run_cmd "$port (TCP)" "$ufw_prefix $port/tcp" "$op_mode"
                   run_cmd "$port (UDP)" "$ufw_prefix $port/udp" "$op_mode"
                   
                   # [深度清理逻辑]
                   # 只有当 output 明确包含 "Rule deleted" 时，才提示清理成功
                   if [[ "$op_mode" == "delete" ]]; then
                        local clean_out
                        clean_out=$(bash -c "LC_ALL=C $ufw_prefix $port" 2>&1)
                        if [[ "$clean_out" == *"Rule deleted"* ]]; then
                            echo -e "  -> [CLEAN] ${GREEN}清理${NC}: $port (通用规则)"
                        fi
                   fi
                   ;;
                2) run_cmd "$port (TCP)" "$ufw_prefix $port/tcp" "$op_mode" ;;
                3) run_cmd "$port (UDP)" "$ufw_prefix $port/udp" "$op_mode" ;;
                4) # 专家模式
                   echo -e "${CYAN}[IPv4]${NC}"
                   if ask_yn "${theme_color}处理 IPv4?${NC}" "y"; then
                       ask_yn " - ${action_verb} TCP?" "y" && run_cmd "$port (v4-TCP)" "$ufw_prefix proto tcp from 0.0.0.0/0 to any port $port" "$op_mode"
                       ask_yn " - ${action_verb} UDP?" "y" && run_cmd "$port (v4-UDP)" "$ufw_prefix proto udp from 0.0.0.0/0 to any port $port" "$op_mode"
                   fi
                   echo -e "${CYAN}[IPv6]${NC}"
                   if ask_yn "${theme_color}处理 IPv6?${NC}" "y"; then
                       ask_yn " - ${action_verb} TCP?" "y" && run_cmd "$port (v6-TCP)" "$ufw_prefix proto tcp from ::/0 to any port $port" "$op_mode"
                       ask_yn " - ${action_verb} UDP?" "y" && run_cmd "$port (v6-UDP)" "$ufw_prefix proto udp from ::/0 to any port $port" "$op_mode"
                   fi
                   ;;
                *) echo "跳过: 无效策略" ;;
            esac
        done
        
        echo -e "\n[OK] 操作完成"
        # 静默重载刷新
        bash -c "ufw reload" >/dev/null 2>&1
        
        if [[ "$op_mode" == "delete" ]]; then
             echo -e "${GREY}[按任意键返回主菜单]${NC}"
             read -r -n 1 -s
        else
             sleep 0.8
        fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ufw_manager
fi