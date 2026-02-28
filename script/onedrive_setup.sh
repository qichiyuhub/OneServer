#!/bin/bash
#
# Rclone OneDrive 配置助手
# 功能：自动化配置 Rclone 连接 OneDrive 云存储
#
# 主要步骤：
# 1. 检查并自动安装 Rclone（如未安装）
# 2. 指导用户在本地生成 Rclone 配置文件
# 3. 接收并验证用户粘贴的配置内容
# 4. 保存配置并测试连接有效性
# 5. 更新主配置文件供备份脚本使用
#
# 注意事项：
# - 需要用户在本地电脑预先完成 Rclone 配置
#

set -Eeuo pipefail

# ==================== 配置参数 ====================
readonly SECURE_CONF="/opt/oneserver/secure.conf"
readonly RCLONE_CONF_DIR="$HOME/.config/rclone"
readonly RCLONE_CONF_FILE="${RCLONE_CONF_DIR}/rclone.conf"
readonly LOG_DIR="/var/log/oneserver"
LOG_FILE="${LOG_DIR}/onedrive_setup_$(date +%F_%H-%M-%S).log" 
readonly LOG_FILE

# ==================== 输出样式定义 ====================
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# ==================== 功能函数 ====================

# 日志记录函数：同时输出到控制台和日志文件
log_and_echo() {
    local message="$1"
    echo -e "$message"
    echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# 安全读取输入内容
safe_read_input() {
    local input_content
    if ! input_content=$(cat); then
        log_and_echo "${RED}错误: 读取输入失败${NC}"
        return 1
    fi
    if [[ -z "$input_content" ]]; then
        log_and_echo "${RED}错误: 未接收到任何配置内容${NC}"
        return 1
    fi
    echo "$input_content"
}

# ==================== 主程序开始 ====================

# 创建日志目录和文件
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

log_and_echo "${CYAN}--- Rclone OneDrive 配置助手 ---${NC}"

# 步骤 1: 检查 Rclone 依赖
log_and_echo "\n${CYAN}[1/4] 检查依赖环境...${NC}"
if ! command -v rclone &>/dev/null; then
    log_and_echo "${YELLOW}  - Rclone 未安装，正在自动安装...${NC}"
    if ! curl -fsSL https://rclone.org/install.sh | bash >> "$LOG_FILE" 2>&1; then
        log_and_echo "${RED}错误: Rclone 自动安装失败，请手动安装${NC}"
        exit 1
    fi
fi
log_and_echo "${GREEN}  - Rclone 已就绪${NC}"

# 步骤 2: 指导用户准备配置
log_and_echo "\n${CYAN}[2/4] 准备接收 Rclone 配置${NC}"
log_and_echo "请在本地电脑完成以下操作, 可直接使用自己备份的配置："
log_and_echo "  1. 运行 ${GREEN}rclone config${NC} 完成 OneDrive 配置"
log_and_echo "  2. 运行 ${GREEN}rclone config file${NC} 查看配置文件路径"
log_and_echo "  3. 打开配置文件，复制 ${YELLOW}全部内容${NC} 到剪贴板"

# 步骤 3: 接收并保存配置
log_and_echo "\n${CYAN}[3/4] 请粘贴 Rclone 配置内容${NC}"
log_and_echo "${YELLOW}粘贴完成后按 Ctrl+D 结束输入${NC}"

CONFIG_CONTENT=$(safe_read_input) || exit 1

# 记录接收到的配置内容（日志中）
{
    echo "--- 接收到的配置内容 ---"
    echo "$CONFIG_CONTENT"
    echo "--- 配置内容结束 ---"
} >> "$LOG_FILE"

# 提取远程名称
REMOTE_NAME=$(echo "$CONFIG_CONTENT" | grep -E '^\[.*\]$' | head -n1 | sed 's/\[\(.*\)\]/\1/')
if [[ -z "$REMOTE_NAME" ]]; then
    log_and_echo "${RED}错误: 无法提取远程名称，请确保配置包含 [name] 格式的段落${NC}"
    exit 1
fi
log_and_echo "${GREEN}  - 成功识别远程名称: ${REMOTE_NAME}${NC}"

# 保存配置文件
mkdir -p "$RCLONE_CONF_DIR"
echo "$CONFIG_CONTENT" > "$RCLONE_CONF_FILE"
chmod 600 "$RCLONE_CONF_FILE"
log_and_echo "${GREEN}  - 配置文件已保存至: ${RCLONE_CONF_FILE}${NC}"

# 步骤 4: 验证配置并更新系统配置
log_and_echo "\n${CYAN}[4/4] 验证并保存配置${NC}"
log_and_echo "${YELLOW}  - 正在验证远程 '${REMOTE_NAME}' 的连接性...${NC}"

# 临时禁用错误退出以处理连接测试结果
set +e
rclone about "${REMOTE_NAME}:" >/dev/null 2>&1
connection_result=$?
set -e

if [[ $connection_result -eq 0 ]]; then
    log_and_echo "${GREEN}  - 远程 '${REMOTE_NAME}' 连接成功${NC}"
    echo "RCLONE_REMOTE_NAME='${REMOTE_NAME}'" >> "$SECURE_CONF"
    log_and_echo "${GREEN}  - 配置已保存至 ${SECURE_CONF}${NC}"
else
    log_and_echo "${RED}错误: 无法连接到远程 '${REMOTE_NAME}'，请检查配置内容${NC}"
    rm -f "$RCLONE_CONF_FILE"
    exit 1
fi

log_and_echo "\n${GREEN}--- Rclone 配置完成！---${NC}"
