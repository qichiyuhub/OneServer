#!/bin/bash
#
# Redis 安装与配置管理脚本
# 
# 功能描述：
#   - 支持 Redis 的全新安装和版本升级
#   - 自动配置内存限制和访问密码
#
# 使用说明：
#   1. 直接运行脚本即可开始安装或升级
#   2. 首次安装时需要输入内存限制和密码
#   3. 升级时会保留现有配置
#
# 注意事项：
#   - 会修改系统 Redis 配置文件
#   - 密码会保存在 /opt/oneserver/secure.conf 中供其他脚本调用
#

set -Eeuo pipefail

# ==============================================================================
# 配置参数
# ==============================================================================
readonly APP_NAME="Redis"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="${LOG_DIR}/install_redis.log"
readonly SECURE_CONF="/opt/oneserver/secure.conf"
readonly CONF_FILE="/etc/redis/redis.conf"

# 颜色定义
# shellcheck disable=SC2034
readonly CYAN='\033[0;36m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
# 日志与命令执行框架
# ==============================================================================
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
true > "$LOG_FILE"

log() {
    local color_name="$1"
    local message="$2"
    local color_var_name="${color_name^^}"
    local color="${!color_var_name}"
    echo -e "${color}${message}${NC}"
    printf "%b\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

run_command() {
    local command_str="$1"
    local description="$2"
    
    {
        echo "---"
        echo "执行: $description"
        echo "命令: $command_str"
        
        if eval "$command_str"; then
            echo "状态: 成功"
        else
            exit_code=$?
            echo "状态: 失败 (退出码: $exit_code)"
            log "RED" "错误: '${description}' 失败。详情请查看日志: ${LOG_FILE}"
            exit $exit_code
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
}

# ==============================================================================
# 功能函数
# ==============================================================================
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

compare_versions() {
    local v1="$1" v2="$2"
    IFS='.' read -ra v1_parts <<< "$v1"
    IFS='.' read -ra v2_parts <<< "$v2"
    
    local max_len=$(( ${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]} ))
    
    for ((i = 0; i < max_len; i++)); do
        local p1=${v1_parts[i]:-0}
        local p2=${v2_parts[i]:-0}
        
        if (( 10#$p1 > 10#$p2 )); then
            return 1
        elif (( 10#$p1 < 10#$p2 )); then
            return 2
        fi
    done
    
    return 0
}

# 将Redis内存配置转换为MB
redis_memory_to_mb() {
    local memory_value="$1"
    
    # 如果已经是数字，直接返回
    if [[ "$memory_value" =~ ^[0-9]+$ ]]; then
        echo $((memory_value / 1024 / 1024))
        return
    fi
    
    # 处理带单位的值
    local num=${memory_value//[^0-9]/}
    local unit=${memory_value//[0-9]/}
    
    case "${unit,,}" in
        kb|k) echo $((num / 1024)) ;;
        mb|m) echo "$num" ;;
        gb|g) echo $((num * 1024)) ;;
        tb|t) echo $((num * 1024 * 1024)) ;;
        *) echo "$num" ;;
    esac
}

perform_redis_installation() {
    local maxmemory="$1"
    local password="$2"
    
    log "CYAN" "\n==> [1/3] 正在安装/升级 Redis 软件包..."
    run_command "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq" "更新软件包列表"
    run_command "apt-get install -y -qq redis-server" "安装 Redis 核心包"

    local redis_version
    redis_version=$(redis-server --version | grep -oP 'v=\K[0-9.]+' || echo "未知")
    log "GREEN" "Redis 安装/升级成功，当前版本: ${redis_version}"

    log "CYAN" "\n==> [2/3] 正在配置 Redis..."
    
    # 创建配置文件备份
    local backup_file
    backup_file="${CONF_FILE}.bak.oneserver.$(date +%Y%m%d_%H%M%S)"
    cp "$CONF_FILE" "$backup_file" 2>> "$LOG_FILE" || {
        log "RED" "创建配置文件备份失败"
        exit 1
    }
    log "GREEN" "已创建配置文件备份: ${backup_file}"

    # 清理旧配置
    sed -i "/^# --- oneserver CONFIG START ---/,/^# --- oneserver CONFIG END ---/d" "$CONF_FILE" 2>> "$LOG_FILE"
    
    # 添加新配置
    cat <<EOF | tee -a "$CONF_FILE" > /dev/null
# --- oneserver CONFIG START ---
supervised systemd
maxmemory ${maxmemory}mb
maxmemory-policy allkeys-lru
requirepass ${password}
# --- oneserver CONFIG END ---
EOF
    
    printf "oneserver config block written to %s\n" "$CONF_FILE" >> "$LOG_FILE"
    log "GREEN" "Redis 配置文件更新完成。"
    
    # 保存密码到安全配置文件
    run_command "mkdir -p \"$(dirname "$SECURE_CONF")\"" "创建安全配置目录"
    run_command "sed -i '/^REDIS_PASS=/d' '$SECURE_CONF' 2>/dev/null || true" "清理旧密码"
    printf "REDIS_PASS='%s'\n" "${password}" | tee -a "$SECURE_CONF" > /dev/null
    run_command "chmod 600 '$SECURE_CONF'" "设置密码文件权限"
    log "GREEN" "Redis 密码已保存到 ${SECURE_CONF}。"

    log "CYAN" "\n==> [3/3] 正在启动并验证服务..."
    run_command "systemctl restart redis-server" "重启 Redis 服务"
    
    if ! systemctl is-active --quiet redis-server; then
        log "RED" "错误：Redis 服务启动失败！尝试恢复配置..."
        cp "$backup_file" "$CONF_FILE" 2>> "$LOG_FILE" || log "RED" "配置恢复也失败了！"
        systemctl restart redis-server 2>> "$LOG_FILE" || true
        log "RED" "  请运行 'systemctl status redis-server' 查看日志。"
        exit 1
    fi
    
    run_command "systemctl enable redis-server >/dev/null 2>&1" "设置 Redis 开机自启"
    log "GREEN" "Redis 服务已启动并设为开机自启。"
}

get_existing_redis_config() {
    # 从安全配置文件读取密码
    local pass
    pass=$(grep '^REDIS_PASS=' "$SECURE_CONF" 2>/dev/null | cut -d= -f2- | tr -d "'" || echo "")
    
    if [[ -z "$pass" ]]; then
        log "RED" "错误：无法从 ${SECURE_CONF} 读取现有密码。"
        exit 1
    fi
    
    # 尝试获取当前内存配置
    local mem_config="256mb"
    if systemctl is-active --quiet redis-server; then
        export REDISCLI_AUTH="$pass"
        mem_config=$(redis-cli CONFIG GET maxmemory | tail -n 1 2>/dev/null || echo "256mb")
        unset REDISCLI_AUTH
    else
        log "YELLOW" "Redis 服务当前未运行，尝试从配置文件中读取内存配置..."
        mem_config=$(grep -E "^maxmemory\s+" "$CONF_FILE" 2>/dev/null | awk '{print $2}' || echo "256mb")
    fi
    
    # 转换为 MB
    local mem_mb
    mem_mb=$(redis_memory_to_mb "$mem_config")
    
    [[ $mem_mb -eq 0 ]] && mem_mb=256
    
    echo "$mem_mb $pass"
}

# ==============================================================================
# 主脚本逻辑
# ==============================================================================
log "CYAN" "--- ${APP_NAME} 安装与更新工具 ---"

if ! command -v redis-server >/dev/null 2>&1; then
    log "CYAN" "${APP_NAME} 未安装，即将开始全新安装..."
    
    redis_maxmemory=""
    while true; do
        read -rp "请输入 Redis 最大内存限制 (MB) [默认 256]: " redis_maxmemory
        redis_maxmemory=${redis_maxmemory:-256}
        
        [[ "$redis_maxmemory" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "${RED}请输入一个有效的正整数。${NC}"
    done

    redis_pass=""
    redis_pass_confirm=""
    while true; do
        read -r -s -p "请输入 Redis 密码 (输入时不可见): " redis_pass
        echo
        
        [[ -z "$redis_pass" ]] && {
            echo -e "${YELLOW}密码不能为空，请重试。${NC}"
            continue
        }
        
        read -r -s -p "请再次输入以确认: " redis_pass_confirm
        echo
        
        [[ "$redis_pass" == "$redis_pass_confirm" ]] && break
        echo -e "${RED}两次输入的密码不一致，请重试。${NC}"
    done
    
    perform_redis_installation "$redis_maxmemory" "$redis_pass"
else
    CURRENT_VERSION=$(redis-server --version | grep -oP 'v=\K[0-9.]+' || echo "未知")
    log "GREEN" "检测到 ${APP_NAME} 已安装，当前版本: ${CURRENT_VERSION}"
    
    log "CYAN" "==> 正在检查最新版本..."
    run_command "apt-get update -qq" "更新软件包列表"
    LATEST_VERSION=$(apt-cache policy redis-server | grep "Candidate:" | awk '{print $2}' | cut -d: -f2 | cut -d'-' -f1)

    if [[ -z "$LATEST_VERSION" ]]; then
        log "YELLOW" "警告: 无法获取最新版本信息。"
        
        ask_yes_no "是否要强制重新安装?" "n" || {
            log "YELLOW" "操作已取消。"
            exit 0
        }
        
        read -r mem_mb pass <<< "$(get_existing_redis_config)"
        perform_redis_installation "$mem_mb" "$pass"
    else
        log "CYAN" "最新可用版本: ${LATEST_VERSION}"
        compare_versions "$CURRENT_VERSION" "$LATEST_VERSION"
        
        case $? in
            2)
                log "YELLOW" "发现新版本！"
                
                ask_yes_no "是否从 ${CURRENT_VERSION} 升级到 ${LATEST_VERSION}?" "y" || {
                    log "YELLOW" "操作已取消。"
                    exit 0
                }
                
                read -r mem_mb pass <<< "$(get_existing_redis_config)"
                perform_redis_installation "$mem_mb" "$pass"
                ;;
            *)
                log "GREEN" "您已是最新版。"
                
                ask_yes_no "是否要强制重新安装?" "n" || {
                    log "YELLOW" "操作已取消。"
                    exit 0
                }
                
                read -r mem_mb pass <<< "$(get_existing_redis_config)"
                perform_redis_installation "$mem_mb" "$pass"
                ;;
        esac
    fi
fi

# ==============================================================================
# 最终验证
# ==============================================================================
log "CYAN" "\n正在执行最终连接验证..."

# 从安全配置文件读取密码
REDIS_PASS=$(grep '^REDIS_PASS=' "$SECURE_CONF" | cut -d= -f2- | tr -d "'" 2>/dev/null || echo "")

if [[ -z "$REDIS_PASS" ]]; then
    log "RED" "\n--- 验证失败 ---"
    log "RED" "无法从 ${SECURE_CONF} 读取密码！"
    exit 1
fi

export REDISCLI_AUTH="$REDIS_PASS"

if ! redis-cli PING >/dev/null 2>&1; then
    unset REDISCLI_AUTH
    log "RED" "\n--- 验证失败 ---"
    log "RED" "无法使用 ${SECURE_CONF} 中的密码连接到数据库！"
    exit 1
fi

RUNNING_VERSION=$(redis-server --version | grep -oP 'v=\K[0-9.]+')
MEM_BYTES=$(redis-cli CONFIG GET maxmemory | tail -n 1)
MEM_MB=$(redis_memory_to_mb "$MEM_BYTES")
POLICY_VAL=$(redis-cli CONFIG GET maxmemory-policy | tail -n 1)
PASS_FILE_PATH="${SECURE_CONF}"
unset REDISCLI_AUTH

log "GREEN" "\n--- ${APP_NAME} 安装/升级成功！ ---"
log "CYAN" "  运行版本:      ${NC}${RUNNING_VERSION}"
log "CYAN" "  最大内存:      ${NC}${MEM_MB} MB"
log "CYAN" "  淘汰策略:      ${NC}${POLICY_VAL}"
log "CYAN" "  密码文件:      ${NC}${PASS_FILE_PATH}"
