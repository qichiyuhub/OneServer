#!/bin/bash
#
# 服务器安全加固脚本
#

set -Eeuo pipefail

# --- 全局配置与样式 ---
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/safe.log"
readonly SSH_CONFIG_FILE="/etc/ssh/sshd_config"

# shellcheck disable=SC2034
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

CURRENT_SSH_PORT="22"

# --- 核心框架函数 ---

log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    
    echo -e "${color}${message}${NC}" > /dev/tty
    # 为日志文件剥离颜色代码
    printf "%b\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

run_command() {
    local description="$1"
    local command_str="$2"
    local allow_failure="${3:-false}"

    # 执行命令并记录日志
    {
        echo "---"
        echo "任务: $description"
        echo "命令: $command_str"
    } >> "$LOG_FILE" 2>&1
    
    # 在子shell中执行命令，将输出追加到日志
    local exit_code=0
    bash -c "$command_str" >> "$LOG_FILE" 2>&1
    exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo "状态: 成功" >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"
        return 0
    else
        echo "状态: 失败 (退出码: $exit_code)" >> "$LOG_FILE"
        echo "---" >> "$LOG_FILE"
        if [[ "$allow_failure" == "true" ]]; then
            echo "警告: 任务失败但允许继续" >> "$LOG_FILE"
            return 1
        else
            log "RED" "错误: 任务 '${description}' 执行失败。详情请查看日志: ${LOG_FILE}"
            exit "$exit_code"
        fi
    fi
}

ask_yes_no() {
    local question="$1"
    local default_answer="$2"
    local prompt="[y/N]"
    [[ "$default_answer" == "y" ]] && prompt="[Y/n]"
    
    local answer
    while true; do
        echo -n -e "${question} ${prompt}: " > /dev/tty
        read -r answer < /dev/tty
        answer="${answer:-$default_answer}"
        case "${answer,,}" in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "输入无效, 请输入 'y' 或 'n'。" > /dev/tty ;;
        esac
    done
}

# --- SSH 服务管理辅助函数 ---
get_ssh_service_name() {
    # 返回正确的SSH服务名称 (ssh 或 sshd)
    if systemctl list-unit-files 2>/dev/null | grep -qE "^ssh\.service"; then
        echo "ssh"
    elif systemctl list-unit-files 2>/dev/null | grep -qE "^sshd\.service"; then
        echo "sshd"
    else
        echo "ssh"  # 默认返回 ssh
    fi
}

disable_ssh_socket() {
    # 禁用 ssh.socket 以确保自定义端口生效
    if ! systemctl list-unit-files 2>/dev/null | grep -qE "^ssh\.socket"; then
        return 0  # ssh.socket 不存在，无需处理
    fi
    
    log "YELLOW" "检测到 ssh.socket，正在禁用以确保端口配置生效..."
    
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        run_command "停止 ssh.socket" "systemctl stop ssh.socket" "true"
    fi
    
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        run_command "禁用 ssh.socket" "systemctl disable ssh.socket" "true"
    fi
    
    run_command "重新加载 systemd 配置" "systemctl daemon-reload" "true"
}

verify_ssh_port_listening() {
    # 验证SSH是否在指定端口监听
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port}.*sshd" || netstat -tlnp 2>/dev/null | grep -q ":${port}.*sshd"; then
        return 0
    else
        return 1
    fi
}

update_ssh_config_option() {
    # 更新SSH配置文件中的选项
    # 参数: $1=选项名, $2=选项值, $3=正则模式(可选)
    local option_name="$1"
    local option_value="$2"
    local pattern="${3:-[a-zA-Z-]+}"
    
    if ! grep -qE "^[#[:space:]]*${option_name}" "$SSH_CONFIG_FILE"; then
        echo "${option_name} ${option_value}" >> "$SSH_CONFIG_FILE"
    else
        sed -i.bak -E "s/^[#[:space:]]*${option_name}[[:space:]]+${pattern}$/${option_name} ${option_value}/" "$SSH_CONFIG_FILE"
    fi
}

# --- UFW 防火墙转发设置 ---
configure_ufw_forwarding() {
    log "CYAN" "--- [步骤 4/5] 正在检查 UFW 防火墙转发设置 ---"
    
    # 检查 ufw 命令是否存在且可执行
    if ! command -v ufw &> /dev/null; then
        log "YELLOW" "系统未安装 UFW 防火墙，跳过此步骤。"
        return
    fi
    
    # 检查 ufw 是否启用
    if ! ufw status | grep -qw "active"; then
        log "YELLOW" "UFW 防火墙当前未启用，跳过此步骤。"
        return
    fi
    
    local ufw_config_file="/etc/default/ufw"
    
    # 检查当前转发策略是否已为 ACCEPT
    if grep -qE '^[[:space:]]*DEFAULT_FORWARD_POLICY[[:space:]]*=[[:space:]]*"ACCEPT"' "$ufw_config_file"; then
        log "GREEN" "UFW 转发策略已正确配置为 'ACCEPT'，容器端口映射可正常工作。"
        return
    fi

    log "YELLOW" "警告：检测到您的 UFW 防火墙会阻止容器的端口映射！"
    log "YELLOW" "为了通过主机 IP 正常访问容器服务，需要开启 UFW 的转发功能。"
    
    if ask_yes_no "是否要自动修改配置开启 UFW 转发功能? (本地使用请开启，否则端口映射无效)" "n"; then
        log "CYAN" "正在修改 UFW 配置文件: ${ufw_config_file}..."
        # 使用 sed 精确替换，避免意外修改
        if sed -i 's/^\(DEFAULT_FORWARD_POLICY[[:space:]]*=[[:space:]]*\).*/\1"ACCEPT"/' "$ufw_config_file"; then
            log "GREEN" "配置文件修改成功。"
            log "CYAN" "正在重新加载 UFW 以应用新配置..."
            if ufw reload >> "$LOG_FILE" 2>&1; then
                log "GREEN" "UFW 已成功重载。端口转发现已永久开启。"
            else
                log "RED" "错误：UFW 重载失败。请稍后手动执行 'sudo ufw reload'。"
            fi
        else
            log "RED" "错误：修改 UFW 配置文件失败。请检查文件权限。"
        fi
    else
        log "YELLOW" "操作已取消。请注意：您将无法从外部网络访问此主机上容器的映射端口。"
    fi
}

# --- 主逻辑区 ---

main() {
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}错误: 此脚本必须以root权限运行。${NC}"
       exit 1
    fi
    mkdir -p "$LOG_DIR"
    truncate -s 0 "$LOG_FILE"

    log "CYAN" "--- 服务器安全加固脚本已启动 ---"

    # --- 模块 1: 系统更新 ---
    log "CYAN" "\n[1/3] 更新系统软件包..."
    run_command "更新软件包列表" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq"
    if ask_yes_no "是否要升级已安装的软件包? (此操作可能需要较长时间)" "y"; then
        run_command "升级已安装的软件包" "export DEBIAN_FRONTEND=noninteractive; apt-get upgrade -y -qq"
    else
        log "YELLOW" "已跳过软件包升级步骤。"
    fi
    
    # --- 模块 2: SSH 服务加固 ---
    log "CYAN" "\n[2/3] 配置 SSH 服务..."
    local ssh_service_needs_restart=false
    # 更可靠地获取当前用户，避免多行或换行符问题
    local target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" ]]; then
        # 尝试从 who am i 获取，只取第一行的第一个字段
        target_user=$(who am i 2>/dev/null | head -n 1 | awk '{print $1}' || echo "")
    fi
    # 如果还是为空，尝试使用 logname 或默认为 root
    if [[ -z "$target_user" ]]; then
        target_user=$(logname 2>/dev/null || echo "root")
    fi
    # 清理可能的换行符、回车符和多余空白字符
    target_user=$(echo "$target_user" | tr -d '\n\r' | xargs)
    # 验证用户名是否有效（只包含字母、数字、下划线、连字符）
    if [[ ! "$target_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "RED" "错误: 无法正确识别当前用户，用户名包含非法字符: '${target_user}'"
        target_user="root"
        log "YELLOW" "已默认设置为 root 用户"
    fi

    # 修改 SSH 端口
    if ask_yes_no "是否需要更改默认的SSH端口(22)?" "n"; then
        local new_port
        while true; do
            echo -n "请输入新的SSH端口号 (1024-65535): " > /dev/tty
            read -r new_port < /dev/tty
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -gt 1023 ] && [ "$new_port" -le 65535 ]; then
                # 修改SSH端口配置
                if grep -qE "^[#[:space:]]*Port[[:space:]]+" "$SSH_CONFIG_FILE"; then
                    sed -i.bak -E "s/^[#[:space:]]*Port[[:space:]]+[0-9]+$/Port ${new_port}/" "$SSH_CONFIG_FILE"
                    log "GREEN" "SSH端口配置已修改。"
                else
                    echo "Port ${new_port}" >> "$SSH_CONFIG_FILE"
                    log "GREEN" "SSH端口配置已添加。"
                fi
                
                # 验证配置文件语法
                log "CYAN" "正在验证 SSH 配置文件语法..."
                if sshd -t >> "$LOG_FILE" 2>&1; then
                    log "GREEN" "SSH 配置文件语法正确。"
                else
                    log "RED" "错误: SSH 配置文件语法有误，请检查。"
                    exit 1
                fi
                
                # Ubuntu/Debian 兼容性修复: 立即处理 systemd socket activation
                # 必须在修改端口后立即禁用 ssh.socket，否则端口配置不会生效
                disable_ssh_socket
                
                # 确保 ssh.service 已启用
                local ssh_service_name
                ssh_service_name=$(get_ssh_service_name)
                
                if ! systemctl is-enabled --quiet "${ssh_service_name}.service" 2>/dev/null; then
                    log "CYAN" "正在启用 ${ssh_service_name}.service..."
                    run_command "启用 ${ssh_service_name}.service" "systemctl enable ${ssh_service_name}.service"
                    log "GREEN" "${ssh_service_name}.service 已启用。"
                else
                    log "GREEN" "${ssh_service_name}.service 已经是启用状态。"
                fi
                
                log "GREEN" "SSH端口已修改为: ${new_port}"
                CURRENT_SSH_PORT="$new_port"
                ssh_service_needs_restart=true
                break
            else
                log "RED" "输入无效, 请输入一个 1024 到 65535 之间的数字。"
            fi
        done
    fi

    # 启用密钥认证模式
    if ask_yes_no "是否启用密钥认证模式? (推荐、将禁用所有密码登录)" "n"; then
        {
            echo -e "\n${YELLOW}--- SSH 密钥生成指南 ---${NC}"
            echo -e "在您本地的电脑终端上运行: ${GREEN}ssh-keygen -t ed25519${NC}"
            echo -e "然后, 复制公钥文件的内容: ${GREEN}cat ~/.ssh/id_ed25519.pub${NC}"
            echo -e "${YELLOW}--------------------------${NC}\n"
        } > /dev/tty
        
        local public_key=""
        local key_confirmed=false
        
        # 循环输入公钥直到确认或取消
        while [[ "$key_confirmed" == false ]]; do
            echo -n "请粘贴您的公钥内容用于登录授权: " > /dev/tty
            read -r public_key < /dev/tty
            
            if [[ -z "$public_key" ]]; then
                log "RED" "未输入公钥内容。跳过 SSH 密钥配置。"
                log "YELLOW" "密码登录方式将保持启用状态。"
                break
            fi
            
            # 验证公钥格式并获取指纹
            local key_fingerprint
            key_fingerprint=$(echo "$public_key" | ssh-keygen -l -f /dev/stdin 2>/dev/null)
            
            if [[ -z "$key_fingerprint" ]]; then
                log "RED" "公钥格式无效或不完整。"
                if ask_yes_no "是否要重新输入公钥?" "y"; then
                    continue
                else
                    log "YELLOW" "密码登录方式将保持启用状态。"
                    public_key=""
                    break
                fi
            fi
            
            # 显示公钥信息供用户确认
            {
                echo -e "\n${CYAN}检测到的公钥信息:${NC}"
                echo -e "${GREEN}${key_fingerprint}${NC}"
                echo -e "${YELLOW}公钥类型和长度: $(echo "$public_key" | awk '{print $1, length($2), "字符"}')${NC}"
            } > /dev/tty
            
            if ask_yes_no "确认这是正确的公钥吗?" "y"; then
                key_confirmed=true
            else
                log "YELLOW" "已取消，请重新输入。"
            fi
        done
        
        if [[ -n "$public_key" && "$key_confirmed" == true ]]; then
            log "YELLOW" "此公钥将被添加给用户: '${target_user}'"
            if ! ask_yes_no "确认是此用户吗?" "y"; then
                echo -n "请输入目标用户名: " > /dev/tty
                read -r target_user_input < /dev/tty
                if ! id "$target_user_input" &>/dev/null; then
                    log "RED" "用户 '${target_user_input}' 不存在。中止密钥添加操作。"
                    public_key=""
                else
                    target_user="$target_user_input"
                    log "CYAN" "目标用户已指定为: ${target_user}"
                fi
            fi
            
            if [[ -n "$public_key" ]]; then
                local target_home
                target_home=$(getent passwd "$target_user" | cut -d: -f6)
                
                # 验证home目录是否有效
                if [[ -z "$target_home" ]]; then
                    log "RED" "错误: 无法获取用户 '${target_user}' 的home目录。"
                    log "RED" "密钥添加操作已中止。"
                    ssh_service_needs_restart=false
                elif [[ ! -d "$target_home" ]]; then
                    log "RED" "错误: 用户 '${target_user}' 的home目录不存在: ${target_home}"
                    log "RED" "密钥添加操作已中止。"
                    ssh_service_needs_restart=false
                else
                    local target_ssh_dir="$target_home/.ssh"
                    local authorized_keys_file="$target_ssh_dir/authorized_keys"

                    run_command "为用户 ${target_user} 创建 .ssh 目录" "mkdir -p \"$target_ssh_dir\""
                    run_command "设置 .ssh 目录权限为 700" "chmod 700 \"$target_ssh_dir\""
                    run_command "添加公钥到 authorized_keys" "echo \"$public_key\" >> \"$authorized_keys_file\""
                    run_command "设置 authorized_keys 文件权限为 600" "chmod 600 \"$authorized_keys_file\""
                    run_command "设置 .ssh 目录的所有权" "chown -R \"$target_user:$target_user\" \"$target_ssh_dir\""
                    
                    log "CYAN" "正在应用 SSH 安全配置..."
                    
                    # 使用辅助函数更新SSH配置项
                    update_ssh_config_option "PubkeyAuthentication" "yes"
                    update_ssh_config_option "PasswordAuthentication" "no"
                    update_ssh_config_option "PermitRootLogin" "prohibit-password"
                    
                    log "GREEN" "SSH 安全配置已应用。"

                    local sshd_config_dir="/etc/ssh/sshd_config.d"
                    if [ -d "$sshd_config_dir" ]; then
                        log "YELLOW" "正在检查并修改 ${sshd_config_dir} 目录下的配置文件..."
                        while IFS= read -r -d '' conf_file; do
                            log "CYAN" "  -> 正在处理文件: ${conf_file}"
                            if grep -qE "^[#[:space:]]*PasswordAuthentication" "$conf_file"; then
                                sed -i.bak -E 's/^[#[:space:]]*PasswordAuthentication[[:space:]]+[a-zA-Z]+$/PasswordAuthentication no/' "$conf_file"
                            fi
                        done < <(find "$sshd_config_dir" -type f -name "*.conf" -print0 2>/dev/null)
                    fi

                    log "GREEN" "密钥认证已成功启用。"
                    ssh_service_needs_restart=true
                fi
            fi
        fi
    fi

    if [ "$ssh_service_needs_restart" = true ]; then
        log "CYAN" "正在重启 SSH 服务以应用配置..."
        
        # 确定正确的 SSH 服务名
        local ssh_service_name
        ssh_service_name=$(get_ssh_service_name)
        log "CYAN" "使用服务名: ${ssh_service_name}"
        
        # 再次确认 ssh.socket 已被禁用 (双重保险)
        disable_ssh_socket
        
        # 重启 SSH 服务（使用允许失败模式避免脚本意外退出）
        run_command "重启 SSH 服务" "systemctl restart ${ssh_service_name}" "true"
        local restart_status=$?
        
        if [ $restart_status -eq 0 ]; then
            log "GREEN" "SSH 服务已成功重启。"
            
            # 验证端口是否正确监听 (额外的安全检查)
            sleep 3
            if verify_ssh_port_listening "$CURRENT_SSH_PORT"; then
                log "GREEN" "确认: SSH 服务正在监听端口 ${CURRENT_SSH_PORT}。"
            else
                log "YELLOW" "警告: 无法确认 SSH 是否在监听端口 ${CURRENT_SSH_PORT}，正在尝试修复..."
                
                # 尝试修复: 再次确保禁用 socket 并重启
                log "CYAN" "执行修复步骤..."
                disable_ssh_socket
                run_command "启用 SSH 服务" "systemctl enable ${ssh_service_name}" "true"
                run_command "再次重启 SSH 服务" "systemctl restart ${ssh_service_name}" "true"
                
                # 再次验证
                sleep 3
                if verify_ssh_port_listening "$CURRENT_SSH_PORT"; then
                    log "GREEN" "修复成功: SSH 服务现在正在监听端口 ${CURRENT_SSH_PORT}。"
                else
                    log "RED" "自动修复失败，请手动检查。"
                    log "YELLOW" "运行 'sudo ss -tlnp | grep sshd' 查看当前监听端口。"
                    log "YELLOW" "如果仍然是22端口，请手动执行以下命令:"
                    log "YELLOW" "  sudo systemctl stop ssh.socket"
                    log "YELLOW" "  sudo systemctl disable ssh.socket"
                    log "YELLOW" "  sudo systemctl enable ${ssh_service_name}"
                    log "YELLOW" "  sudo systemctl restart ${ssh_service_name}"
                fi
            fi
            
            {
                echo -e "\n${YELLOW}重要提示:${NC} 请不要关闭当前的 SSH 会话!"
                echo -e "请打开一个新的终端窗口, 使用以下命令测试新连接:"
                echo -e "${GREEN}ssh -p ${CURRENT_SSH_PORT} ${target_user}@<您的服务器IP>${NC}"
                echo -e "确认新连接成功后, 再关闭此窗口。"
            } > /dev/tty
        else
            log "RED" "SSH 服务重启失败! 请手动检查配置文件。"
            log "RED" "可以尝试运行以下命令进行修复:"
            log "RED" "  sudo sshd -t  # 测试配置文件"
            log "RED" "  sudo systemctl stop ssh.socket; sudo systemctl disable ssh.socket"
            log "RED" "  sudo systemctl daemon-reload"
            log "RED" "  sudo systemctl enable ${ssh_service_name}; sudo systemctl restart ${ssh_service_name}"
            log "RED" "当前 SSH 会话保持打开，请另开终端进行修复。"
        fi
    fi

    # --- 模块 3: UFW 防火墙配置 ---
    log "CYAN" "\n[3/3] 配置 UFW 防火墙..."
    
    if ! command -v ufw &>/dev/null; then
      log "CYAN" "检测到 UFW 未安装, 正在自动安装..."
      run_command "安装 UFW" "apt-get install -y -qq ufw"
    fi

    local allowed_ports=("$CURRENT_SSH_PORT" "80" "443")
    
    log "CYAN" "默认将放行的 TCP 端口: ${allowed_ports[*]}"
    echo -n "请输入需要额外放行的 TCP 端口 (多个端口请用空格分隔，直接回车跳过): " > /dev/tty
    read -r extra_ports_input < /dev/tty
    
    # 将输入字符串转换为数组（处理空格）
    if [[ -n "${extra_ports_input// /}" ]]; then
        local extra_ports=()
        read -r -a extra_ports <<< "$extra_ports_input"
        for port in "${extra_ports[@]}"; do
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                allowed_ports+=("$port")
            else
                log "YELLOW" "已跳过无效的端口输入: ${port}"
            fi
        done
    fi
    
    local unique_ports=()
    while IFS= read -r line; do
        unique_ports+=("$line")
    done < <(printf "%s\n" "${allowed_ports[@]}" | sort -nu)

    if ufw status | grep -q "Status: active"; then
      log "YELLOW" "UFW 防火墙当前已激活。"
      if ask_yes_no "是否需要重置所有现有的防火墙规则?" "y"; then
        run_command "重置 UFW 规则" "ufw --force reset"
      fi
    fi

    run_command "设置默认入站策略为 '拒绝'" "ufw default deny incoming"
    run_command "设置默认出站策略为 '允许'" "ufw default allow outgoing"

    log "CYAN" "正在为以下 TCP 端口添加入站规则: ${unique_ports[*]}"
    for port in "${unique_ports[@]}"; do
        run_command "允许 TCP 端口 ${port}" "ufw allow $port/tcp"
    done
    run_command "允许 UDP 端口 443 (用于 HTTP/3)" "ufw allow 443/udp"

    log "GREEN" "防火墙规则配置完毕。"

    if ask_yes_no "是否立即启用 UFW 防火墙?" "y"; then
      run_command "启用 UFW" "ufw --force enable"
      log "GREEN" "防火墙已启用, 并已设置为开机自启动。"
    else
      log "YELLOW" "防火墙规则已配置, 但未启用。"
    fi

    log "CYAN" "\n--- 防火墙最终状态 ---"
    ufw status verbose > /dev/tty

    log "CYAN" "\n--- 配置UFW转发策略 ---"
    configure_ufw_forwarding

    log "GREEN" "\n--- 服务器安全加固脚本执行完毕 ---"
}

main "$@"
