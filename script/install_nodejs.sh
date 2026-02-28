#!/bin/bash
#
# Node.js 安装与升降级脚本
#
# 描述: 用于在 Debian/Ubuntu 系统上通过 fnm (Fast Node Manager) 安装或升级 Node.js
#       fnm 是 Node.js 官方文档推荐的 Linux 安装方式，由 Rust 编写，速度快且稳定
#       安装完成后将 node/npm/npx 软链到 /usr/local/bin，实现系统全局可用
#
# 安装策略:
#   - fnm 本体安装到 /usr/local/share/fnm（系统级，非用户 $HOME 目录）
#   - Node.js 版本文件存储在 /usr/local/share/fnm/node-versions
#   - 当前激活版本的 node/npm/npx 软链至 /usr/local/bin（所有用户可用）
#   - 写入 /etc/profile.d/fnm.sh 让所有交互式 shell 会话可调用 fnm 命令
#
# 注意事项:
#   - 仅支持 Debian/Ubuntu 系统
#   - 需要 root 权限运行
#   - 脚本使用严格错误处理，遇到错误会立即退出
#

set -Eeuo pipefail

# 调试开关
readonly SCRIPT_DEBUG=${SCRIPT_DEBUG:-false}
if [[ "$SCRIPT_DEBUG" == "true" ]]; then
    set -x
fi

# 配置常量
readonly APP_NAME="Node.js"
readonly LOG_DIR="/var/log/oneserver"
readonly LOG_FILE="$LOG_DIR/install_nodejs.log"

# fnm 系统级安装路径
readonly FNM_INSTALL_DIR="/usr/local/share/fnm"
readonly FNM_BIN="${FNM_INSTALL_DIR}/fnm"
readonly FNM_NODE_VERSIONS_DIR="${FNM_INSTALL_DIR}/node-versions"
readonly FNM_PROFILE="/etc/profile.d/fnm.sh"
readonly NODE_SYMLINK_DIR="/usr/local/bin"

# 支持的 LTS 与 Current 版本（大版本号）
# 维护时更新此列表即可
readonly LTS_VERSIONS=(20 22 24)
readonly CURRENT_VERSION=25

# 终端颜色定义
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ==============================================================================
# 核心函数
# ==============================================================================

log() {
    local color_name="$1" message="$2"
    local color=""
    case "$color_name" in
        "CYAN")   color="$CYAN"   ;;
        "GREEN")  color="$GREEN"  ;;
        "RED")    color="$RED"    ;;
        "YELLOW") color="$YELLOW" ;;
        *)        color="$NC"     ;;
    esac
    echo -e "${color}${message}${NC}"
    printf "%s\n" "$message" | sed 's/\033\[[0-9;]*m//g' >> "$LOG_FILE"
}

debug_log() {
    if [[ "$SCRIPT_DEBUG" == "true" ]]; then
        log "YELLOW" "DEBUG: $1"
    fi
}

run_command() {
    local description="$1"
    shift
    local exit_code=0
    {
        echo "---"
        echo "执行: $description"
        echo "命令: $*"
        env "$@" || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            echo "状态: 成功"
        else
            echo "状态: 失败 (退出码: $exit_code)"
        fi
        echo "---"
    } >> "$LOG_FILE" 2>&1
    if [[ $exit_code -ne 0 ]]; then
        log "RED" "错误: '${description}' 失败。详情请查看日志: ${LOG_FILE}"
        exit $exit_code
    fi
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" hint="[Y/n]"
    if [[ "$default" == "n" ]]; then hint="[y/N]"; fi
    while true; do
        read -rp "$prompt $hint: " answer
        answer=${answer:-$default}
        case "$answer" in [Yy]*) return 0;; [Nn]*) return 1;; esac
    done
}

compare_versions() {
    local v1="$1" v2="$2"
    IFS='.' read -ra v1_parts <<< "$v1"
    IFS='.' read -ra v2_parts <<< "$v2"
    local max_len=$(( ${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]} ))
    for ((i=0; i<max_len; i++)); do
        local p1=${v1_parts[i]:-0} p2=${v2_parts[i]:-0}
        if (( 10#$p1 > 10#$p2 )); then return 1; fi
        if (( 10#$p1 < 10#$p2 )); then return 2; fi
    done
    return 0
}

# ==============================================================================
# fnm 专属函数
# ==============================================================================

# 安装或升级 fnm 本体
install_fnm() {
    log "CYAN" "==> 正在安装/升级 fnm..."

    # 确保依赖工具存在
    local missing_deps=()
    for dep in curl unzip; do
        command -v "$dep" >/dev/null 2>&1 || missing_deps+=("$dep")
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        run_command "安装依赖: ${missing_deps[*]}" \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_deps[@]}"
    fi

    mkdir -p "$FNM_INSTALL_DIR"

    # 下载并安装 fnm 到系统目录（--skip-shell 跳过写入用户 shell 配置）
    local exit_code=0
    {
        echo "--- 下载并安装 fnm ---"
        curl -fsSL https://fnm.vercel.app/install \
            | bash -s -- \
                --install-dir "$FNM_INSTALL_DIR" \
                --skip-shell \
            || exit_code=$?
        echo "exit_code=$exit_code"
        echo "---"
    } >> "$LOG_FILE" 2>&1

    if [[ $exit_code -ne 0 ]]; then
        log "RED" "错误: fnm 下载安装失败。详情请查看日志: ${LOG_FILE}"
        exit $exit_code
    fi

    if [[ ! -x "$FNM_BIN" ]]; then
        log "RED" "错误: fnm 安装后未找到可执行文件: ${FNM_BIN}"
        exit 1
    fi

    # 写入系统级 profile，让所有 shell 会话都能调用 fnm 命令
    cat > "$FNM_PROFILE" << EOF
# fnm (Fast Node Manager) - 由 oneserver 安装，请勿手动修改
export FNM_DIR="${FNM_NODE_VERSIONS_DIR}"
export PATH="${FNM_INSTALL_DIR}:\$PATH"
eval "\$(${FNM_BIN} env --shell bash 2>/dev/null || true)"
EOF
    chmod 644 "$FNM_PROFILE"

    log "GREEN" "fnm 安装完成: $("$FNM_BIN" --version 2>/dev/null || echo '版本未知')"
}

# 将当前激活的 node/npm/npx 软链到 /usr/local/bin（系统全局可用）
update_system_symlinks() {
    local major="$1"
    log "CYAN" "正在更新 /usr/local/bin 软链接..."

    # 通过 fnm exec 在指定版本环境中获取 node 的真实路径
    local node_real_path
    node_real_path=$(
        FNM_DIR="$FNM_NODE_VERSIONS_DIR" \
            "$FNM_BIN" exec --using="$major" -- which node 2>/dev/null || true
    )

    if [[ -z "$node_real_path" || ! -x "$node_real_path" ]]; then
        log "RED" "错误：无法找到 Node.js ${major}.x 的可执行文件路径。"
        exit 1
    fi

    local node_bin_dir; node_bin_dir=$(dirname "$node_real_path")

    for binary in node npm npx; do
        local src="${node_bin_dir}/${binary}"
        local dst="${NODE_SYMLINK_DIR}/${binary}"
        if [[ -x "$src" ]]; then
            ln -sf "$src" "$dst"
            log "CYAN" "  软链更新: ${dst} -> ${src}"
        else
            log "YELLOW" "  跳过: ${binary} 在 Node.js ${major}.x 中不存在"
        fi
    done
}

# 执行 Node.js 版本安装（通过 fnm）
perform_nodejs_installation() {
    local major="$1"

    log "CYAN" "\n==> [1/3] 正在确认 fnm 已安装..."
    if [[ ! -x "$FNM_BIN" ]]; then
        install_fnm
    else
        log "CYAN" "fnm 已就绪: $("$FNM_BIN" --version 2>/dev/null || echo '版本未知')"
    fi

    log "CYAN" "\n==> [2/3] 正在通过 fnm 安装 Node.js ${major}.x..."
    local exit_code=0
    {
        echo "--- fnm install ${major} ---"
        FNM_DIR="$FNM_NODE_VERSIONS_DIR" \
            "$FNM_BIN" install "$major" || exit_code=$?
        echo "exit_code=$exit_code"
        echo "---"
    } >> "$LOG_FILE" 2>&1

    if [[ $exit_code -ne 0 ]]; then
        log "RED" "错误: fnm 安装 Node.js ${major}.x 失败。详情请查看日志: ${LOG_FILE}"
        exit $exit_code
    fi

    # 设置为 fnm 默认版本（新终端自动使用）
    {
        FNM_DIR="$FNM_NODE_VERSIONS_DIR" \
            "$FNM_BIN" default "$major" || true
    } >> "$LOG_FILE" 2>&1

    log "CYAN" "\n==> [3/3] 正在更新系统软链接..."
    update_system_symlinks "$major"

    # 验证软链可用
    if ! "${NODE_SYMLINK_DIR}/node" --version >/dev/null 2>&1; then
        log "RED" "错误：Node.js 安装后验证失败，请检查日志。"
        exit 1
    fi

    NODE_TO_INSTALL="$major"
    log "GREEN" "Node.js ${major}.x 安装完成。"
}

# 从 fnm 中卸载指定大版本
uninstall_nodejs_version() {
    local major="$1"
    log "CYAN" "正在通过 fnm 卸载 Node.js ${major}.x..."
    local exit_code=0
    {
        FNM_DIR="$FNM_NODE_VERSIONS_DIR" \
            "$FNM_BIN" uninstall "$major" || exit_code=$?
    } >> "$LOG_FILE" 2>&1
    if [[ $exit_code -ne 0 ]]; then
        log "YELLOW" "警告: fnm 卸载 Node.js ${major}.x 失败（可能已不存在），继续。"
    else
        log "GREEN" "Node.js ${major}.x 已从 fnm 中移除。"
    fi
}

# 获取当前系统软链（/usr/local/bin/node）指向的大版本号
get_installed_major_version() {
    if [[ -x "${NODE_SYMLINK_DIR}/node" ]]; then
        "${NODE_SYMLINK_DIR}/node" \
            -e "process.stdout.write(process.version.replace('v','').split('.')[0])" \
            2>/dev/null || true
    else
        echo ""
    fi
}

# 获取当前系统软链指向的完整版本号
get_installed_full_version() {
    if [[ -x "${NODE_SYMLINK_DIR}/node" ]]; then
        "${NODE_SYMLINK_DIR}/node" \
            -e "process.stdout.write(process.version.replace('v',''))" \
            2>/dev/null || true
    else
        echo ""
    fi
}

# 获取 fnm 中已安装的所有大版本号（空格分隔）
get_fnm_installed_versions() {
    if [[ ! -x "$FNM_BIN" ]]; then
        echo ""
        return
    fi
    FNM_DIR="$FNM_NODE_VERSIONS_DIR" \
        "$FNM_BIN" list 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
        | sed 's/^v//' \
        | awk -F'.' '{print $1}' \
        | sort -uV \
        | tr '\n' ' ' \
        | xargs \
        || true
}

# 版本切换菜单
handle_nodejs_switch() {
    local current_major="$1"
    log "CYAN" "\n=== Node.js 版本切换操作 ==="

    local all_versions=("${LTS_VERSIONS[@]}" "$CURRENT_VERSION")
    log "CYAN" "可用的 Node.js 主要版本:"

    local i=1
    for major in "${all_versions[@]}"; do
        local label="LTS"
        [[ "$major" == "$CURRENT_VERSION" ]] && label="Current" || true
        local current_tag=""
        [[ "$major" == "$current_major" ]] && current_tag=" (当前版本)" || true
        log "CYAN" "  $i. Node.js ${major}.x (${label})${current_tag}"
        ((i++))
    done

    local selected_index
    while true; do
        read -rp "请选择要切换到的版本 (输入数字 1-$((i-1))): " selected_index
        if [[ "$selected_index" =~ ^[0-9]+$ && "$selected_index" -ge 1 && "$selected_index" -le $((i-1)) ]]; then break; fi
        log "RED" "无效选择，请输入 1 到 $((i-1)) 之间的数字。"
    done

    local target_major="${all_versions[$((selected_index-1))]}"
    if [[ "$current_major" == "$target_major" ]]; then
        log "YELLOW" "选择的版本与当前相同，已取消。"
        return 1
    fi

    if ! ask_yes_no "您即将从 Node.js ${current_major}.x 切换到 Node.js ${target_major}.x。确认吗?" "n"; then
        log "YELLOW" "操作已取消。"
        return 1
    fi

    perform_nodejs_installation "$target_major"

    if ask_yes_no "是否从 fnm 中移除旧版本 Node.js ${current_major}.x?" "n"; then
        uninstall_nodejs_version "$current_major"
    else
        log "CYAN" "旧版本 Node.js ${current_major}.x 已保留（可通过 fnm use ${current_major} 切换）。"
    fi

    log "GREEN" "版本切换完成！"
    return 0
}

# 主逻辑处理（已安装场景）
main_handler() {
    local installed_major="$1" installed_full="$2"
    debug_log "进入 main_handler。已安装大版本: $installed_major, 完整版本: $installed_full"

    local latest_lts_major="${LTS_VERSIONS[-1]}"

    # 直接获取版本比较结果，避免 if 语句干扰返回码
    compare_versions "$installed_major" "$latest_lts_major"
    local comparison_result=$?

    debug_log "版本比较结果: $comparison_result (0=相等, 1=当前>LTS, 2=当前<LTS)"

    case $comparison_result in
        2)
            log "YELLOW" "发现新的 LTS 版本 (Node.js ${latest_lts_major}.x)！"
            if ask_yes_no "是否升级到最新 LTS Node.js ${latest_lts_major}.x?" "y"; then
                perform_nodejs_installation "$latest_lts_major"
                if ask_yes_no "是否从 fnm 中移除旧版本 Node.js ${installed_major}.x?" "n"; then
                    uninstall_nodejs_version "$installed_major"
                else
                    log "CYAN" "旧版本 Node.js ${installed_major}.x 已保留在 fnm 中。"
                fi
            else
                log "CYAN" "您选择了不升级。"
                if ask_yes_no "是否要切换到其他版本?" "n"; then
                    handle_nodejs_switch "$installed_major" || true
                else
                    log "YELLOW" "操作已取消。"
                fi
            fi
            ;;
        1)
            log "GREEN" "您当前使用的版本 (Node.js ${installed_major}.x) 已高于最新 LTS。"
            if ask_yes_no "是否要切换到其他版本?" "n"; then
                handle_nodejs_switch "$installed_major" || true
            else
                log "YELLOW" "操作已取消。"
            fi
            ;;
        0)
            log "GREEN" "您已安装最新 LTS 版本 (Node.js ${installed_major}.x)。"
            if ask_yes_no "是否要切换到其他版本?" "n"; then
                handle_nodejs_switch "$installed_major" || true
            elif ask_yes_no "是否要强制重新安装 Node.js ${installed_major}.x?" "n"; then
                perform_nodejs_installation "$installed_major"
            else
                log "YELLOW" "操作已取消。"
            fi
            ;;
    esac
}

# 版本选择菜单（通过命令替换调用，交互输出定向到 /dev/tty）
select_install_version() {
    local all_versions=("${LTS_VERSIONS[@]}" "$CURRENT_VERSION")
    local i=1

    echo -e "${CYAN}\n请选择要安装的 Node.js 版本:${NC}" > /dev/tty
    for major in "${all_versions[@]}"; do
        local label="LTS"
        [[ "$major" == "$CURRENT_VERSION" ]] && label="Current" || true
        local extra=""
        [[ "$major" == "${LTS_VERSIONS[-1]}" ]] && extra=" (推荐)" || true
        echo -e "${CYAN}  $i. Node.js ${major}.x (${label})${extra}${NC}" > /dev/tty
        ((i++))
    done
    echo -e "${CYAN}  $i. 手动输入版本号${NC}" > /dev/tty

    local selected_index
    while true; do
        read -rp "请选择 (直接回车安装推荐版本 Node.js ${LTS_VERSIONS[-1]}.x): " selected_index < /dev/tty
        if [[ -z "$selected_index" ]]; then
            echo "${LTS_VERSIONS[-1]}"
            return 0
        fi
        if [[ "$selected_index" =~ ^[0-9]+$ && "$selected_index" -ge 1 && "$selected_index" -le $i ]]; then
            if [[ "$selected_index" -eq $i ]]; then
                local manual_version
                read -rp "请输入大版本号 (如 20, 22): " manual_version < /dev/tty
                if [[ "$manual_version" =~ ^[0-9]+$ ]]; then
                    echo "$manual_version"
                    return 0
                else
                    echo -e "${RED}无效的版本号，请输入纯数字。${NC}" > /dev/tty
                fi
            else
                echo "${all_versions[$((selected_index-1))]}"
                return 0
            fi
        else
            echo -e "${RED}无效选择，请重新输入。${NC}" > /dev/tty
        fi
    done
}

# 脚本主入口
main() {
    if ! mkdir -p "$LOG_DIR" || ! chmod 700 "$LOG_DIR"; then
        echo -e "\033[0;31m错误：无法创建日志目录 ${LOG_DIR}，请检查权限。\033[0m" >&2
        exit 1
    fi
    true > "$LOG_FILE"

    if ! [[ -t 0 ]]; then
        log "RED" "错误：此脚本需要在一个交互式终端中运行。"
        exit 1
    fi
    if [[ $EUID -ne 0 ]]; then
        log "RED" "错误：请以 root 用户运行此脚本。"
        exit 1
    fi

    log "CYAN" "--- ${APP_NAME} 安装与更新工具 ---"
    log "CYAN" "安装方式: fnm (Fast Node Manager) — Node.js 官方推荐方案"

    NODE_TO_INSTALL=""

    INSTALLED_MAJOR=$(get_installed_major_version)
    INSTALLED_FULL=$(get_installed_full_version)

    if [[ -z "$INSTALLED_MAJOR" ]]; then
        log "CYAN" "未检测到 Node.js，即将开始全新安装。"
        TARGET_MAJOR=$(select_install_version)
        perform_nodejs_installation "$TARGET_MAJOR"
    else
        log "GREEN" "检测到已安装的 Node.js 版本: v${INSTALLED_FULL} (大版本 ${INSTALLED_MAJOR}.x)"
        log "CYAN" "最新推荐 LTS 大版本: ${LTS_VERSIONS[-1]}.x"
        local fnm_versions
        fnm_versions=$(get_fnm_installed_versions)
        [[ -n "$fnm_versions" ]] && log "CYAN" "fnm 中已安装的版本: ${fnm_versions}" || true
        main_handler "$INSTALLED_MAJOR" "$INSTALLED_FULL"
    fi

    # 输出安装结果摘要
    if [[ -n "$NODE_TO_INSTALL" ]]; then
        log "CYAN" "\n正在获取最终安装信息..."
        local node_full npm_full node_real npm_real
        node_full=$("${NODE_SYMLINK_DIR}/node" -v 2>/dev/null | sed 's/^v//' || echo "未知")
        npm_full=$("${NODE_SYMLINK_DIR}/npm" -v 2>/dev/null || echo "未知")
        node_real=$(readlink -f "${NODE_SYMLINK_DIR}/node" 2>/dev/null || echo "未知")
        npm_real=$(readlink -f "${NODE_SYMLINK_DIR}/npm" 2>/dev/null || echo "未知")

        log "GREEN" "\n--- ${APP_NAME} 操作成功！ ---"
        log "CYAN" "  Node.js 版本:   ${NC}v${node_full}"
        log "CYAN" "  npm 版本:       ${NC}v${npm_full}"
        log "CYAN" "  node 实际路径:  ${NC}${node_real}"
        log "CYAN" "  npm 实际路径:   ${NC}${npm_real}"
        log "CYAN" "  fnm 位置:       ${NC}${FNM_BIN}"
        log "CYAN" "  版本存储目录:   ${NC}${FNM_NODE_VERSIONS_DIR}"
        log "CYAN" "  shell 环境配置: ${NC}${FNM_PROFILE}"
        log "CYAN" "  日志文件:       ${NC}${LOG_FILE}"
        log "YELLOW" "\n  提示: 新终端会话将自动加载 fnm 环境（来自 ${FNM_PROFILE}）。"
        log "YELLOW" "  当前会话如需立即使用 fnm 命令，请执行: source ${FNM_PROFILE}"
    else
        log "CYAN" "\n未执行任何安装或更改操作。"
    fi
}

main "$@"
exit 0
