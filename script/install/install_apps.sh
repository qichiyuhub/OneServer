#!/bin/bash
#
# 可安装的应用一览
#
# @command      install
# @name         安装应用
# @self_name    全部应用与状态
# @group        app
# @order        10
# @privilege    any
# @requires_lib >= 1.26
# @args         无
# @description  列出本工具能装的应用与各自的安装状态
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 它只回答一个问题：这台机器还能装什么、已经装了什么
# ==================================================================
#
# 存在的理由是**给七个 install 子命令一个父条目**。没有它，「应用」那一屏是
# 七个安装项加卸载平铺在一起，装的和卸的混在一处；有了它，那一屏就是
# 「安装应用 · 卸载应用」两项，进去才展开具体装什么。
#
# **它自己不装任何东西**，一行副作用都没有。真正的安装逻辑在
# `install_*.sh` 里，各装各的。
#
# --- 清单从哪来 ---
#
# 从各安装脚本自己声明的 `@provides` 现扫，不手写第二份（D179 的教训：
# 手写清单与实际脚本迟早对不上，而且对不上的方向是「新加的装不了」）。
# 类型名就是命令的最后一个词（`@provides caddy` ↔ `install caddy`），
# 所以列出类型即列出了该敲什么，不必再解析 `@name`。
#
# 带实例占位符的（`php:<version>`、`nodejs:<major>`）只取类型部分：
# 那是「能装哪几种」，具体装了哪些实例是 `oneserver state` 的问题。

readonly INSTALL_DIR="${OS_SCRIPT_DIR}/install"

# 占位符的写法。`@provides php:<version>` 里的 `<` 是标记而不是内容
readonly ANY_INSTANCE_HINT='<'

APP_TYPES=()

# load_types   扫 install 目录的 @provides，去重排序后填 APP_TYPES
#
# 排序在 grep 之后就地做掉：目录遍历顺序既不是字母序也不是菜单序，直接列出来
# 是一份看着像随机排列的清单。**按类型名排而不是按 @order**：这一屏是拿来查
# 「有没有我要的那个」的，字母序最好找；@order 是产品排序，那归菜单管。
load_types() {
    APP_TYPES=()
    # 模式与目录经位置参数进内层 shell，不拼进脚本文本（规范 §10）
    os::query --timeout 10 -- sh -c \
        "grep -rhE \"\$1\" \"\$2\" | sort -u" \
        sh '^#[[:space:]]*@provides[[:space:]]' "${INSTALL_DIR}" || return 0

    local line type seen=''
    local IFS=$'\n'
    for line in ${OS_RUN_OUTPUT}; do
        type=${line##*[[:space:]]}
        type=${type%%:*}
        [[ -n ${type} ]] || continue
        [[ ${type} == *"${ANY_INSTANCE_HINT}"* ]] && continue
        [[ ${seen} == *"|${type}|"* ]] && continue
        seen+="|${type}|"
        APP_TYPES+=("${type}")
    done
    return 0
}

main() {
    load_types
    if [[ ${#APP_TYPES[@]} -eq 0 ]]; then
        os::die 1 "没能从 ${INSTALL_DIR} 里读出任何 @provides 声明"
    fi

    local type ver state
    local -i installed=0
    # 攒成一次 os::kv：逐对调用时每对各自算宽度，列就对不齐了
    local -a rows=()

    os::section '可安装的应用'
    for type in "${APP_TYPES[@]}"; do
        # 装没装以**探测**为准，不问 state：用户自己 apt 装的那份确实在跑，
        # 而这一屏要回答的是「这台机器上有没有」，不是「本工具装过没有」
        probe::component_version "${type}"
        ver=${OS_PROBE_VALUE%%$'\n'*}
        ver=${ver%% *}
        ver=${ver#v}
        if [[ -n ${ver} ]]; then
            # 已装的**不隐藏**：安装脚本是幂等的，重跑一次就是更新到当前源里的
            # 版本，那是升级单个应用的唯一路径。藏起来等于把这条路也藏了
            state="已装 ${ver} —— 再次执行会更新"
            installed+=1
        else
            state="未安装 —— oneserver install ${type}"
        fi
        rows+=("${type}" "${state}")
        os::output_item type="${type}" version="${ver}" \
            installed="$([[ -n ${ver} ]] && printf yes || printf no)"
    done
    os::kv "${rows[@]}"

    os::info "已装 ${installed} / ${#APP_TYPES[@]} —— 装过的重跑一次是幂等的，可用来修复或升级"
    os::output 0 total="${#APP_TYPES[@]}" installed="${installed}"
    return 0
}

main "$@"
