# lib/ui.sh —— L1 呈现层：渲染逻辑
#
# 三层里的中间那层。上面是语义层 os::*（脚本唯一可见），
# 下面是主题层 theme.sh（纯数据）。
#
# 本文件只依赖 L0（paths.sh / defaults.sh / theme.sh），禁止依赖同层与上层。
# `ui::*` **不对脚本暴露**，脚本只用 `os::*`。
#
# 两条自我约束：
#   * **无色值字面量。** 色号一律来自 OS_THEME_COLOR_*，
#     整个文件只有 OS_UI__ESC 一处出现 \033 字面量，别处一律引用它
#   * **所有对齐、截断、引导线长度必须经 ui::width。** printf 的 %-20s 按字节计宽，
#     一个中文字符 3 字节显示 2 格，界面是中文而不处理就全歪
#
# set -e 安全：本文件的函数会被 `set -Eeuo pipefail` 的脚本调用，
# 因此不用 `[[ ... ]] && cmd` 收尾（条件为假时函数返回 1 会直接带走调用者）。

# --- 能力探测结果（ui::init 填写，之后只读）---

OS_UI_STDOUT_TTY=0
OS_UI_STDERR_TTY=0
OS_UI_COLOR_CAPABLE=0
OS_UI_COLOR_DEPTH=0
OS_UI_UTF8=0
OS_UI_WIDTH=80

# 回车键符号是唯一有渲染层之外消费者的符号：bootstrap 的几处提示文案要在句子里
# 嵌它（「⏎ 放弃」）。放在公开这一组，因为「它长什么样」仍由 UTF-8 探测与
# OS_THEME_SHOW_ICONS 决定 —— 调用方拿到的是探测结果，不是自己拼的字面量。
OS_UI_SYM_ENTER=''

# --- 整层静默---
#
# `--output json` 时「规范的呈现层整层静默」。开关必须落在这一层：
# 决定格式的 OS_OUTPUT 归 bootstrap（L4）所有，而 exec.sh（L2）与 lock.sh（L2）
# 也会直接调 ui::，它们按分层不许去读 L4 的变量。把闸门放在渲染层，
# 一处生效，谁都不用记得判断。
#
# **只静默 stdout。** JSON 消费者读的是 stdout；错误与警告照旧走 stderr
# ，否则出了事就成了「无声退出」——那正是 K8。
OS_UI_QUIET=0

# --- 内部状态（双下划线前缀，不对外）---

OS_UI__SGR=''
# 全文件唯一一处 ESC 字面量，别处一律引用它
OS_UI__ESC=$'\033'
OS_UI__RESET=${OS_UI__ESC}'[0m'
OS_UI__W=0
OS_UI__CUT=-1
OS_UI__PLAIN=''
OS_UI__PAD=''
OS_UI__TRUNC=''
OS_UI__COLORED=''
OS_UI__C=''
OS_UI__B=0
OS_UI__SYM=''
OS_UI__SYM_OK=''
OS_UI__SYM_ERR=''
OS_UI__SYM_WARN=''
OS_UI__SYM_INFO=''
OS_UI__SYM_SUBMENU=''
OS_UI__SYM_ASK=''
OS_UI__SYM_PROMPT=''
OS_UI__ELLIPSIS=''
OS_UI__TREE_STEM=''
OS_UI__TREE_BRANCH=''
OS_UI__TREE_TOP=''
OS_UI__TREE_BOTTOM=''
OS_UI__TREE_H=''
OS_UI__PFX=''
OS_UI__FRAME=0
# ui::_width 的记忆表，键是原串、值分别是显示宽度与剥掉 ANSI 之后的串。
#
# **必须是 `-gA`**：本文件由 bootstrap 在文件作用域 source，但测试的装配入口是
# 一个函数（tests/helper/load.sh 的 os_load_lib）——`declare -A` 在函数里执行
# 就成了那个函数的局部变量，函数一返回表就没了，之后每次引用都是未定义。
declare -gA OS_UI__WMEMO_W=()
declare -gA OS_UI__WMEMO_P=()
OS_UI__WMEMO_MAX=128
OS_UI__PROGRESS_LAST=-1
OS_UI__SHIFT=0

# ==================================================================
# 初始化 ——规范的四件事，探测一次并缓存
# ==================================================================

ui::init() {
    # 1) TTY：stdout 与 stderr 分别判断。
    #    只判其一的话，`cmd > file` 时错误信息仍带色，管道里满屏 \033[0;31m。
    if [[ -t 1 ]]; then OS_UI_STDOUT_TTY=1; else OS_UI_STDOUT_TTY=0; fi
    if [[ -t 2 ]]; then OS_UI_STDERR_TTY=1; else OS_UI_STDERR_TTY=0; fi

    # 2) 色深：TERM / COLORTERM
    #
    # **非 256 的那一档是 16 而不是 8。** 亮色（SGR 90–97）属于 16 色 ANSI，
    # 不是 256 色扩展：TERM=xterm、screen、linux 控制台全都认它。把它们一律
    # 当成 8 色的后果是 MUTED（8 = 亮黑）整条路径不着色 —— 菜单说明列、kv 的键、
    # 导航行于是与正文同色，屏幕上分不出主次，而那正是它们存在的理由。
    local term=${TERM:-}
    case ${term} in
        '' | dumb) OS_UI_COLOR_DEPTH=0 ;;
        *-256color | *-direct) OS_UI_COLOR_DEPTH=256 ;;
        *) OS_UI_COLOR_DEPTH=16 ;;
    esac
    if [[ -n ${COLORTERM:-} ]]; then
        OS_UI_COLOR_DEPTH=256
    fi

    # 3) NO_COLOR：**只要存在就关**，不看值。空串也算存在——这是该标准的原文规定，
    #    按 `-n "$NO_COLOR"` 判断是最常见的误实现。
    if [[ -n ${NO_COLOR+x} ]]; then
        OS_UI_COLOR_CAPABLE=0
    elif [[ ${OS_UI_COLOR_DEPTH} -eq 0 ]]; then
        OS_UI_COLOR_CAPABLE=0
    else
        OS_UI_COLOR_CAPABLE=1
    fi

    # 4) UTF-8：决定用真符号还是 ASCII 回退集
    local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
    case ${loc} in
        *UTF-8* | *utf8* | *UTF8* | *utf-8*) OS_UI_UTF8=1 ;;
        *) OS_UI_UTF8=0 ;;
    esac

    # 5) 终端宽度：tput 失败（非 TTY、TERM 未设）回退 80，再按主题上限收口
    local cols=''
    if [[ ${OS_UI_STDOUT_TTY} -eq 1 ]] && command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null) || cols=''
    fi
    if [[ ! ${cols} =~ ^[0-9]+$ ]] || [[ ${cols} -lt 20 ]]; then
        cols=80
    fi
    if [[ ${cols} -gt ${OS_THEME_MAX_WIDTH} ]]; then
        cols=${OS_THEME_MAX_WIDTH}
    fi
    OS_UI_WIDTH=${cols}

    ui::_load_symbols
    ui::_load_tree_symbols
    return 0
}

# 只解析当前有原语在用的符号。箭头/项目符号/提示符等到有人用时再加 ——
# 摆一堆没人引用的变量，shellcheck 会全部报未使用，而那些告警是对的。
ui::_load_symbols() {
    if [[ ${OS_UI_UTF8} -eq 1 && ${OS_THEME_SHOW_ICONS} -eq 1 ]]; then
        OS_UI__SYM_OK=${OS_THEME_SYM_OK}
        OS_UI__SYM_ERR=${OS_THEME_SYM_ERR}
        OS_UI__SYM_WARN=${OS_THEME_SYM_WARN}
        OS_UI__SYM_INFO=${OS_THEME_SYM_INFO}
        OS_UI_SYM_ENTER=${OS_THEME_SYM_ENTER}
        OS_UI__SYM_SUBMENU=${OS_THEME_SYM_SUBMENU}
        OS_UI__SYM_ASK=${OS_THEME_SYM_ASK}
        OS_UI__SYM_PROMPT=${OS_THEME_SYM_PROMPT}
        OS_UI__ELLIPSIS='…'
    else
        OS_UI__SYM_OK=${OS_THEME_SYM_OK_ASCII}
        OS_UI__SYM_ERR=${OS_THEME_SYM_ERR_ASCII}
        OS_UI__SYM_WARN=${OS_THEME_SYM_WARN_ASCII}
        OS_UI__SYM_INFO=${OS_THEME_SYM_INFO_ASCII}
        OS_UI_SYM_ENTER=${OS_THEME_SYM_ENTER_ASCII}
        OS_UI__SYM_SUBMENU=${OS_THEME_SYM_SUBMENU_ASCII}
        OS_UI__SYM_ASK=${OS_THEME_SYM_ASK_ASCII}
        OS_UI__SYM_PROMPT=${OS_THEME_SYM_PROMPT_ASCII}
        OS_UI__ELLIPSIS='...'
    fi
    return 0
}

# 引导线符号不进 theme.sh：它承担的是「谁在谁下面」这一层语义，换成别的字符层级
# 就读不出来，不是可调外观。UTF-8 不可用时换一格宽的 ASCII，宽度不变，列位不动。
ui::_load_tree_symbols() {
    if [[ ${OS_UI_UTF8} -eq 1 ]]; then
        OS_UI__TREE_STEM='│'
        OS_UI__TREE_BRANCH='├'
        OS_UI__TREE_TOP='╭'
        OS_UI__TREE_BOTTOM='╰'
        OS_UI__TREE_H='─'
    else
        OS_UI__TREE_STEM='|'
        OS_UI__TREE_BRANCH='+'
        OS_UI__TREE_TOP='+'
        OS_UI__TREE_BOTTOM='+'
        OS_UI__TREE_H='-'
    fi
    return 0
}

# ui::_tree_pfx <fd> <正文缩进>   左侧引导线及缩进写进 OS_UI__PFX。
ui::_tree_pfx() {
    local -i fd=${1:-1} indent=${2:-0} pad_width=0
    pad_width=$((indent - 1))
    if ((pad_width < 1)); then
        pad_width=1
    fi
    local pad=''
    printf -v pad '%*s' "${pad_width}" ''
    ui::_style muted
    ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__TREE_STEM}"
    OS_UI__PFX=${OS_UI__COLORED}${pad}
    return 0
}

# ui::_tree_heading <top|branch> <样式> <已截断的标题> [fd]
ui::_tree_heading() {
    local kind=${1:-branch} style=${2:-heading} text=${3-} marker=${OS_UI__TREE_BRANCH}
    local -i fd=${4:-1}
    if [[ ${kind} == top ]]; then
        marker=${OS_UI__TREE_TOP}
    fi
    ui::_style muted
    ui::_colorize "${fd}" "${OS_UI__C}" 0 "${marker}"
    local lead=${OS_UI__COLORED}
    ui::_style "${style}"
    ui::_colorize "${fd}" "${OS_UI__C}" "${OS_UI__B}" "${text}"
    printf -v OS_UI__L '%s %s' "${lead}" "${OS_UI__COLORED}"
    ui::_emit "${fd}" "${OS_UI__L}"
    return 0
}

# ui::_tree_spacer [fd]   仅输出一格延续引导线，形成紧凑的标题与正文间距。
ui::_tree_spacer() {
    local -i fd=${1:-1}
    ui::_tree_pfx "${fd}" 0
    ui::_emit "${fd}" "${OS_UI__PFX%"${OS_UI__PFX##*[![:space:]]}"}"
    return 0
}

# ui::_tree_bottom_rule <宽度> [fd]   在导航前将左侧引导折成一段自适应横线。
ui::_tree_bottom_rule() {
    local -i width=${1:-${OS_UI_WIDTH}} fd=${2:-1} i
    if ((width < 2)); then
        width=2
    fi
    local bar=''
    for ((i = 1; i < width; i++)); do
        bar+="${OS_UI__TREE_H}"
    done
    ui::_style muted
    ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__TREE_BOTTOM}${bar}"
    ui::_emit "${fd}" "${OS_UI__COLORED}"
    return 0
}

# ui::disable_color   给装配层的 --no-color 用（等价 NO_COLOR）
#
# 同 log::set_level：变量归本模块所有，改它就走本模块的入口。
ui::disable_color() {
    OS_UI_COLOR_CAPABLE=0
    return 0
}

# ui::set_quiet [0|1]   给装配层的 --output json 用
ui::set_quiet() {
    OS_UI_QUIET=${1:-1}
    return 0
}

# ui::clear_screen [fd]   仅在目标流真连着终端时清屏；管道、日志、JSON 一律不动。
ui::clear_screen() {
    local -i fd=${1:-1}
    if ui::_silent "${fd}"; then
        return 0
    fi
    if [[ ${fd} -eq 2 ]]; then
        [[ -t 2 ]] || return 0
    else
        [[ -t 1 ]] || return 0
    fi
    printf '%s[2J%s[H' "${OS_UI__ESC}" "${OS_UI__ESC}" >&"${fd}"
    return 0
}

# ui::_silent <fd>   该不该把这次输出咽下去
ui::_silent() {
    [[ ${OS_UI_QUIET} -eq 1 && ${1} -eq 1 ]]
}

# ==================================================================
# 整帧缓冲 —— 只有 ui::menu 打开它
# ==================================================================
#
# 一屏菜单是几十次 printf，也就是几十次 write。终端按到达顺序画，于是慢链路上
# 看得见半张菜单先出来再补齐；配上「先清屏再逐行画」，每次重画都闪一下。攒成
# 一帧一次写出，中间态就不存在了。
#
# **不装 trap 兜底。** trap 是 shell 级状态，在这里装 EXIT/ERR 会盖掉 bootstrap
# 已经装好的收尾（日志、probe 快照）。代价是缓冲区间内若有命令非零退出，
# 攒着的整屏一个字都出不来 —— 所以那段里只准有 printf、算术与字符串操作，
# 且**不得有 return**：中途退出把整屏咽掉，比画一半更糟（K8）。
#
# 缓冲之外的调用方（ui::screen_heading、ui::frame_begin）照旧立刻输出，
# 它们与菜单的先后顺序因此不变。
OS_UI__BUF=''
OS_UI__BUFFERING=0
# 缓冲期间每行的行尾补丁：重画整屏时是「清到行尾」，其余情况为空
OS_UI__BUF_EOL=''
# ui::_emit 的行缓冲：调用点在渲染热路径上，不为每行新建一个局部量
OS_UI__L=''

# ui::_emit <fd> <行>   缓冲开着就攒起来，否则立刻写
ui::_emit() {
    if ((OS_UI__BUFFERING == 1)); then
        OS_UI__BUF+="${2}${OS_UI__BUF_EOL}"$'\n'
        return 0
    fi
    printf '%s\n' "${2}" >&"${1}"
    return 0
}

# ui::_fd_tty <fd>   这个流是不是真连着终端
ui::_fd_tty() {
    if [[ ${1} -eq 2 ]]; then
        [[ -t 2 ]]
    else
        [[ -t 1 ]]
    fi
}

# ==================================================================
# 显示宽度 ——规范的核心，七个必须有对抗性测试的函数之一
# ==================================================================

# ui::_width <字符串> [限宽]   宽度写进 OS_UI__W；给了限宽时切点写进 OS_UI__CUT
#
# 不用命令替换：内部调用点很多（每个表格单元格一次），$( ) 每次都 fork。
#
# **宽度与切点必须出自同一次扫描。** 从前 _truncate 自己用 ${s:i:1} 逐字符切，
# 而那个下标在非 UTF-8 locale 下按**字节**走 —— LANG 没设（SSH 进服务器的常态）
# 时它把中文切成半个字符，屏幕上是个 �，宽度还比目标多出 2 格，于是框和表格
# 当场歪掉。两份 UTF-8 解码迟早漂移，所以只留这一份，切点由它顺带算出。
#
# 实现要点：
#   * `local LC_ALL=C` 让 ${#s} 与 ${s:i:1} 按**字节**工作，与调用者的 locale 无关。
#     不这么做的话，同一段代码在 LANG=C 与 LANG=C.UTF-8 下算出的宽度不同。
#     bash 在给 LC_ALL 赋值时会重新 setlocale，函数返回时自动还原。
#   * 手工解 UTF-8，然后按 UAX #11 的近似分类判宽。之所以是近似：
#     完整的东亚宽度表有数百个区段且随 Unicode 版本变化，写死在这里迟早过期；
#     下面覆盖的是中日韩 + 全角标点 + 主流 emoji，即本项目实际会显示的字符。
#   * 先剥 ANSI：带色的单元格若按含转义序列的长度补齐，表格必歪。
#     **OS_UI__CUT 因此是剥掉 ANSI 之后的字节偏移**，切的必须是同一个串 ——
#     调用点一律「先截断、后着色」，含转义序列的输入本来就不该进来。
ui::_width() {
    local LC_ALL=C
    local s=${1-}
    local -i limit=${2:--1}

    # 同一个字符串一屏要被量三四遍（_truncate 内部两次、_pad 再一次），而这里是
    # 逐字节解 UTF-8 的循环。**只记不带限宽的那种调用**：带限宽时还要按限宽回写
    # OS_UI__CUT，短路会拿上一次的切点去切这一次的宽度，中文当场被切成半个字。
    local __key=''
    if ((limit < 0)); then
        # 键带前缀：bash 的关联数组不接受空下标，而空串是合法输入
        __key="w${s}"
        if [[ -n ${OS_UI__WMEMO_W[${__key}]+x} ]]; then
            OS_UI__W=${OS_UI__WMEMO_W[${__key}]}
            OS_UI__PLAIN=${OS_UI__WMEMO_P[${__key}]}
            OS_UI__CUT=-1
            return 0
        fi
    fi

    local esc=${OS_UI__ESC}
    while [[ ${s} == *"${esc}["* ]]; do
        local head=${s%%"${esc}["*}
        local rest=${s#*"${esc}["}
        local tail=${rest#*[a-zA-Z]}
        if [[ ${tail} == "${rest}" ]]; then
            # 没有结束字母，是个残缺序列，整段丢掉免得死循环
            s=${head}
            break
        fi
        s=${head}${tail}
    done
    OS_UI__PLAIN=${s}
    OS_UI__CUT=-1

    local -i i=0 n=${#s} w=0 b=0 cp=0 len=1 k=0 at=0 cw=1
    while ((i < n)); do
        at=${i}
        printf -v b '%d' "'${s:i:1}"
        if ((b < 0x80)); then
            cp=${b}
            len=1
        elif ((b < 0xC0)); then
            # 落单的续字节：输入不是合法 UTF-8，当一格宽跳过，不要跟着乱
            cp=${b}
            len=1
        elif ((b < 0xE0)); then
            cp=$((b & 0x1F))
            len=2
        elif ((b < 0xF0)); then
            cp=$((b & 0x0F))
            len=3
        else
            cp=$((b & 0x07))
            len=4
        fi
        # 非法 UTF-8 的首字节会声称一个够不着的长度，先按剩余字节数收口，
        # 否则 ${s:i+k:1} 取到空串，printf '%d' "'" 会报 invalid number
        if ((i + len > n)); then
            len=$((n - i))
        fi
        for ((k = 1; k < len; k++)); do
            printf -v b '%d' "'${s:i+k:1}"
            cp=$(((cp << 6) | (b & 0x3F)))
        done
        i+=len

        # 零宽：组合附加符、方向控制、变体选择符、零宽连接符
        if ((cp >= 0x0300 && cp <= 0x036F)) \
            || ((cp >= 0x200B && cp <= 0x200F)) \
            || ((cp >= 0x20D0 && cp <= 0x20FF)) \
            || ((cp >= 0x2060 && cp <= 0x206F)) \
            || ((cp >= 0xFE00 && cp <= 0xFE0F)); then
            continue
        fi

        # 双宽：中日韩、谚文、全角形式、主流 emoji
        if ((cp >= 0x1100 && cp <= 0x115F)) \
            || ((cp >= 0x2E80 && cp <= 0x303E)) \
            || ((cp >= 0x3041 && cp <= 0x33FF)) \
            || ((cp >= 0x3400 && cp <= 0x4DBF)) \
            || ((cp >= 0x4E00 && cp <= 0x9FFF)) \
            || ((cp >= 0xA000 && cp <= 0xA4CF)) \
            || ((cp >= 0xAC00 && cp <= 0xD7A3)) \
            || ((cp >= 0xF900 && cp <= 0xFAFF)) \
            || ((cp >= 0xFE10 && cp <= 0xFE19)) \
            || ((cp >= 0xFE30 && cp <= 0xFE6F)) \
            || ((cp >= 0xFF00 && cp <= 0xFF60)) \
            || ((cp >= 0xFFE0 && cp <= 0xFFE6)) \
            || ((cp >= 0x1F300 && cp <= 0x1F9FF)) \
            || ((cp >= 0x20000 && cp <= 0x3FFFD)); then
            cw=2
        else
            cw=1
        fi

        # 切点 = 加上本字符就超限的那个字符的起始字节。零宽字符不会触发它，
        # 它们跟着前一个字符走，单独切开会留下一个孤立的组合符
        if ((limit >= 0 && OS_UI__CUT < 0 && w + cw > limit)); then
            OS_UI__CUT=${at}
        fi
        w+=cw
    done

    if ((limit >= 0 && OS_UI__CUT < 0)); then
        OS_UI__CUT=${n}
    fi
    OS_UI__W=${w}

    if [[ -n ${__key} ]]; then
        # 满了就整表清空，不做淘汰：这张表服务的是「一屏之内同一个串被量很多遍」，
        # 屏与屏之间本来就该换一批。ui.sh 也被打几千行的长跑脚本用（backup 的
        # 逐行输出），没有上限它会一直涨。
        if ((${#OS_UI__WMEMO_W[@]} >= OS_UI__WMEMO_MAX)); then
            OS_UI__WMEMO_W=()
            OS_UI__WMEMO_P=()
        fi
        OS_UI__WMEMO_W[${__key}]=${w}
        OS_UI__WMEMO_P[${__key}]=${OS_UI__PLAIN}
    fi
    return 0
}

# ui::width <字符串>   打印显示宽度。给 ui.sh 之外的消费者用
ui::width() {
    ui::_width "${1-}"
    printf '%d\n' "${OS_UI__W}"
}

# ui::_pad <字符串> <目标宽度> [left|right]   结果写进 OS_UI__PAD
ui::_pad() {
    local s=${1-} target=${2:-0} align=${3:-left}
    ui::_width "${s}"
    local -i fill=$((target - OS_UI__W))
    if ((fill <= 0)); then
        OS_UI__PAD=${s}
        return 0
    fi
    local spaces=''
    printf -v spaces '%*s' "${fill}" ''
    if [[ ${align} == right ]]; then
        OS_UI__PAD=${spaces}${s}
    else
        OS_UI__PAD=${s}${spaces}
    fi
    return 0
}

# ui::_truncate <字符串> <最大宽度>   结果写进 OS_UI__TRUNC
#
# 切点由 ui::_width 在算宽度时一并给出（见那里的注释），本函数只做减法与拼接：
# 自己再解一遍 UTF-8 就是第二份会漂移的实现，而按 ${s:i:1} 切则依赖调用方的
# locale 恰好是 UTF-8。
ui::_truncate() {
    local s=${1-} max=${2:-0}
    ui::_width "${s}"
    if ((OS_UI__W <= max)); then
        OS_UI__TRUNC=${s}
        return 0
    fi
    ui::_width "${OS_UI__ELLIPSIS}"
    local -i budget=$((max - OS_UI__W))
    if ((budget < 1)); then
        OS_UI__TRUNC=${OS_UI__ELLIPSIS}
        return 0
    fi
    local LC_ALL=C
    ui::_width "${s}" "${budget}"
    OS_UI__TRUNC=${OS_UI__PLAIN:0:OS_UI__CUT}${OS_UI__ELLIPSIS}
    return 0
}

# ==================================================================
# 着色 —— 色号来自 OS_THEME_COLOR_*，转义序列在这里组装
# ==================================================================

# ui::_sgr <色号> [加粗]   结果写进 OS_UI__SGR。色号为空 = 不着色
ui::_sgr() {
    local color=${1-} bold=${2:-0}
    OS_UI__SGR=''
    local parts=''
    if [[ ${bold} -eq 1 ]]; then
        parts='1'
    fi
    # **色深降级**：8 及以上要用 90–97 那组亮色，它属于 16 色 ANSI，因此门槛是
    # 16 而不是 256。真正认不出这组序列的只剩 TERM 为空或 dumb 的场景，那时
    # OS_UI_COLOR_CAPABLE 已经是 0，一个字节的转义都不会发出来。
    # 加粗不受色深影响，它在任何终端下都生效
    if [[ -n ${color} ]] && ((color < 8 || OS_UI_COLOR_DEPTH >= 16)); then
        local -i code
        if ((color < 8)); then
            code=$((30 + color))
        else
            code=$((90 + color - 8))
        fi
        if [[ -n ${parts} ]]; then
            parts="${parts};${code}"
        else
            parts="${code}"
        fi
    fi
    if [[ -n ${parts} ]]; then
        OS_UI__SGR=${OS_UI__ESC}'['${parts}'m'
    fi
    return 0
}

# ui::_colorize <fd> <色号> <加粗> <文本>   结果写进 OS_UI__COLORED
# fd 决定看哪个流的 TTY 状态 ——规范要求 stdout / stderr 分别判断
ui::_colorize() {
    local fd=${1} color=${2-} bold=${3:-0} text=${4-}
    local tty=${OS_UI_STDOUT_TTY}
    if [[ ${fd} -eq 2 ]]; then
        tty=${OS_UI_STDERR_TTY}
    fi
    if [[ ${OS_UI_COLOR_CAPABLE} -eq 0 || ${tty} -eq 0 ]]; then
        OS_UI__COLORED=${text}
        return 0
    fi
    ui::_sgr "${color}" "${bold}"
    if [[ -z ${OS_UI__SGR} ]]; then
        OS_UI__COLORED=${text}
        return 0
    fi
    OS_UI__COLORED=${OS_UI__SGR}${text}${OS_UI__RESET}
    return 0
}

# ui::_style <样式名>   把样式解析成 OS_UI__C（色号）· OS_UI__B（加粗）· OS_UI__SYM（符号）
ui::_style() {
    case ${1} in
        success)
            OS_UI__C=${OS_THEME_COLOR_SUCCESS}
            OS_UI__SYM=${OS_UI__SYM_OK}
            OS_UI__B=0
            ;;
        error)
            OS_UI__C=${OS_THEME_COLOR_ERROR}
            OS_UI__SYM=${OS_UI__SYM_ERR}
            OS_UI__B=0
            ;;
        warn)
            OS_UI__C=${OS_THEME_COLOR_WARN}
            OS_UI__SYM=${OS_UI__SYM_WARN}
            OS_UI__B=0
            ;;
        info)
            OS_UI__C=${OS_THEME_COLOR_INFO}
            OS_UI__SYM=${OS_UI__SYM_INFO}
            OS_UI__B=0
            ;;
        muted)
            OS_UI__C=${OS_THEME_COLOR_MUTED}
            OS_UI__SYM=''
            OS_UI__B=0
            ;;
        heading)
            OS_UI__C=${OS_THEME_COLOR_HEADING}
            OS_UI__SYM=''
            OS_UI__B=${OS_THEME_HEADING_BOLD}
            ;;
        accent)
            OS_UI__C=${OS_THEME_COLOR_ACCENT}
            OS_UI__SYM=''
            OS_UI__B=0
            ;;
        *)
            OS_UI__C=${OS_THEME_COLOR_PLAIN}
            OS_UI__SYM=''
            OS_UI__B=0
            ;;
    esac
    return 0
}

# ==================================================================
# 输出原语
# ==================================================================

# ui::line [--out|--err] [--indent] <样式> <文本>
#
# **去向由样式决定，不由调用方决定**：warn 与 error 默认走 stderr，其余走 stdout。
# 规范（错误与警告到 stderr）是整份规范里最容易被违反的一条，而「每个调用点
# 都记得加 >&2」是靠不住的。把它做进渲染层，忘记加就不再是一种可能。
# --out / --err 是显式覆盖，留给确实要反着来的场合。
#
# `--indent` 让这一行落在 kv / table / box 用的同一列上。为什么那三个都表达不了
# 这件事：kv 要一个键（帮助页的正文没有键）、box 会按宽度截断（而 `--help` 里的
# 用法行是要照抄的命令，截了就没法用），而 line 本身不缩进。手写空格也不行 ——
# 改 INDENT 时它不会跟着动，屏幕上就是差一格。
ui::line() {
    local fd=0
    local -i indent=0
    while :; do
        case ${1-} in
            --out)
                fd=1
                shift
                ;;
            --err)
                fd=2
                shift
                ;;
            --indent)
                indent=${OS_THEME_INDENT}
                shift
                ;;
            *) break ;;
        esac
    done
    local style=${1-plain} text=${2-}
    if [[ ${fd} -eq 0 ]]; then
        case ${style} in
            warn | error) fd=2 ;;
            *) fd=1 ;;
        esac
    fi
    if ui::_silent "${fd}"; then
        return 0
    fi
    # 前缀**必须先取**：ui::_pfx 自己也要着色，会覆盖 OS_UI__COLORED。
    # 反过来写的结果是正文被前缀顶掉，屏幕上只剩一条引导线。
    ui::_pfx "${fd}" "${indent}"
    local pfx=${OS_UI__PFX}
    ui::_style "${style}"
    local body=${text}
    if [[ -n ${OS_UI__SYM} ]]; then
        body="${OS_UI__SYM} ${text}"
    fi
    ui::_colorize "${fd}" "${OS_UI__C}" "${OS_UI__B}" "${body}"
    printf '%s%s\n' "${pfx}" "${OS_UI__COLORED}" >&"${fd}"
    return 0
}

# ui::prompt <文本> [固定列宽] [尾注] [说明]
#
# 一次问答固定长这样，**三行的构成不随文本长短变化**：
#
#   ? <文本 补齐到列宽>  <尾注>      ← 有文本时才有这行
#     <说明>                        ← 有说明时才有这行
#   ❯                               ← 永远有，光标停在它后面
#
# **输入永远独占新的一行，`❯` 只出现在这一行上。** 从前问题与输入共用一个 `❯`，
# 短提示时答案跟在问题后面、长提示时折行再打一个一模一样的 `❯` —— 屏幕上一串
# 相同的符号，分不出哪行是工具问的、哪行是自己敲的。一个符号只表达一件事之后，
# 每行的第一个字符就说明了这行的身份：`?` 问题 · `❯` 你的输入 · `·` 执行步骤。
#
# 尾注（`⏎ 默认值` / `必填` / `[y/N]`）单独传而不是由调用方拼进文本：拼进去
# 就没法把它对齐到固定列，一连串问答的尾注会跟着问题长短忽左忽右。
# 长提示不为对齐而截断（问题是要读的），这时尾注紧跟其后，只是不成列。
#
# 说明（怎样才算合法）夹在问题与输入之间，是它唯一说得通的位置：在问题之前
# 是在解释一个还没问出口的东西，在输入之后就来不及了。
#
# **一律 stderr**，同 ui::activity：提问不是命令的输出，`$(os::run_out …)`
# 的调用方不该收到它。因此也不受 --output json 的静默影响（那只管 stdout）。
ui::prompt() {
    if ui::_silent 2; then
        return 0
    fi
    local text=${1-} tip=${3-} hint=${4-}
    local -i width=${2:-${OS_THEME_ASK_WIDTH}}

    if [[ -n ${text} ]]; then
        ui::_width "${text}"
        if ((width > 0 && OS_UI__W <= width)); then
            ui::_pad "${text}" "${width}" left
            text=${OS_UI__PAD}
        fi
        ui::_style heading
        ui::_colorize 2 "${OS_UI__C}" "${OS_UI__B}" "${text}"
        local body=${OS_UI__COLORED}
        if [[ -n ${tip} ]]; then
            ui::_style muted
            ui::_colorize 2 "${OS_UI__C}" 0 "${tip}"
            body+="  ${OS_UI__COLORED}"
        fi
        ui::_style accent
        ui::_colorize 2 "${OS_UI__C}" 0 "${OS_UI__SYM_ASK}"
        printf '%s %s\n' "${OS_UI__COLORED}" "${body}" >&2
    fi

    if [[ -n ${hint} ]]; then
        # 缩进到内容列，不带符号 —— `·` 是「正在执行的步骤」，借给说明用会让
        # 提问区和安装进度长得一模一样
        ui::_style muted
        ui::_colorize 2 "${OS_UI__C}" 0 "${hint}"
        printf '%*s%s\n' "${OS_THEME_INDENT}" '' "${OS_UI__COLORED}" >&2
    fi

    ui::_style accent
    ui::_colorize 2 "${OS_UI__C}" 0 "${OS_UI__SYM_PROMPT}"
    printf '%s ' "${OS_UI__COLORED}" >&2
    return 0
}

# ui::heading <标题>
ui::heading() {
    if ui::_silent 1; then
        return 0
    fi
    ui::_pfx 1 0
    local pfx=${OS_UI__PFX}
    if [[ ${OS_THEME_DENSITY} != compact ]]; then
        # 同 ui::spacer：空行只留引导线，不拖着内边距那两个空格
        printf '%s\n' "${pfx%"${pfx##*[![:space:]]}"}"
    fi
    ui::_style heading
    ui::_colorize 1 "${OS_UI__C}" "${OS_UI__B}" "${1-}"
    printf '%s%s\n' "${pfx}" "${OS_UI__COLORED}"
    return 0
}

# ui::screen_heading <标题>   管理屏总览的起始标题，不额外留空行。
#
# 独立屏只显示标题；frame 内则接到左侧树状引导线，和下方总览保持一个层级。
ui::screen_heading() {
    if ui::_silent 1; then
        return 0
    fi
    if ((OS_UI__FRAME == 1)); then
        ui::_truncate "${1-}" $((OS_UI_WIDTH - 2))
        ui::_tree_heading branch heading "${OS_UI__TRUNC}"
        return 0
    fi
    ui::_style heading
    ui::_colorize 1 "${OS_UI__C}" "${OS_UI__B}" "${1-}"
    printf '%s\n' "${OS_UI__COLORED}"
    return 0
}

# ui::spacer   一行语义留白，保持 --output json 的呈现层静默约定。
ui::spacer() {
    if ui::_silent 1; then
        return 0
    fi
    # 空行只留引导线，把前缀里的内边距剪掉 —— 否则每一行留白都拖着两个空格
    ui::_pfx 1 0
    printf '%s\n' "${OS_UI__PFX%"${OS_UI__PFX##*[![:space:]]}"}"
    return 0
}

# ui::kv <键> <值> [<键> <值> ...]   键按显示宽度右侧对齐
ui::kv() {
    if ui::_silent 1; then
        return 0
    fi
    local -a keys=() vals=()
    while [[ $# -ge 2 ]]; do
        keys+=("${1}")
        vals+=("${2}")
        shift 2
    done
    if [[ ${#keys[@]} -eq 0 ]]; then
        return 0
    fi

    local -i kw=0 i
    for ((i = 0; i < ${#keys[@]}; i++)); do
        ui::_width "${keys[i]}"
        if ((OS_UI__W > kw)); then
            kw=${OS_UI__W}
        fi
    done

    ui::_pfx 1 "${OS_THEME_INDENT}"
    local indent=${OS_UI__PFX}
    for ((i = 0; i < ${#keys[@]}; i++)); do
        ui::_pad "${keys[i]}" "${kw}" left
        ui::_style muted
        ui::_colorize 1 "${OS_UI__C}" 0 "${OS_UI__PAD}"
        printf '%s%s  %s\n' "${indent}" "${OS_UI__COLORED}" "${vals[i]}"
    done
    return 0
}

# ui::table <表头...> -- <单元格...>
# 单元格按行优先铺，列数 = 表头个数。列间留白承担分隔职责，不画横线。
ui::table() {
    if ui::_silent 1; then
        return 0
    fi
    local -a head=()
    while [[ $# -gt 0 && ${1} != -- ]]; do
        head+=("${1}")
        shift
    done
    if [[ ${1-} == -- ]]; then
        shift
    fi
    local -i cols=${#head[@]}
    if ((cols == 0)); then
        return 0
    fi
    local -a cells=("$@")

    local -i i c
    local -a wide=()
    for ((c = 0; c < cols; c++)); do
        ui::_width "${head[c]}"
        wide[c]=${OS_UI__W}
    done
    for ((i = 0; i < ${#cells[@]}; i++)); do
        c=$((i % cols))
        ui::_width "${cells[i]}"
        if ((OS_UI__W > wide[c])); then
            wide[c]=${OS_UI__W}
        fi
    done

    ui::_pfx 1 "${OS_THEME_INDENT}"
    local indent=${OS_UI__PFX}
    local row='' sep=''
    for ((c = 0; c < cols; c++)); do
        ui::_pad "${head[c]}" "${wide[c]}" left
        row+=${sep}${OS_UI__PAD}
        sep='  '
    done
    row=${row%"${row##*[![:space:]]}"}
    ui::_style heading
    ui::_colorize 1 "${OS_UI__C}" "${OS_UI__B}" "${row}"
    printf '%s%s\n' "${indent}" "${OS_UI__COLORED}"

    row=''
    sep=''
    for ((i = 0; i < ${#cells[@]}; i++)); do
        c=$((i % cols))
        ui::_pad "${cells[i]}" "${wide[c]}" left
        row+=${sep}${OS_UI__PAD}
        sep='  '
        if ((c == cols - 1)); then
            printf '%s%s\n' "${indent}" "${row%"${row##*[![:space:]]}"}"
            row=''
            sep=''
        fi
    done
    if [[ -n ${row} ]]; then
        printf '%s%s\n' "${indent}" "${row%"${row##*[![:space:]]}"}"
    fi
    return 0
}

# ui::box <标题> -- <行...>   强调块：标题一行，内容按缩进列出
#
# 不画四边框：边线本身占宽，窄终端上内容会顶着它折行，折行之后框就散了。
# 靠标题与缩进分层，宽度只由内容决定。
ui::box() {
    if ui::_silent 1; then
        return 0
    fi
    local title=${1-}
    shift || true
    if [[ ${1-} == -- ]]; then
        shift
    fi
    local -a lines=("$@")
    local -i max_width=$((OS_UI_WIDTH - OS_THEME_INDENT)) i
    if ((max_width < 8)); then
        max_width=8
    fi

    if [[ -n ${title} ]]; then
        ui::_truncate "${title}" "${OS_UI_WIDTH}"
        ui::_style heading
        ui::_colorize 1 "${OS_UI__C}" "${OS_UI__B}" "${OS_UI__TRUNC}"
        printf '%s\n' "${OS_UI__COLORED}"
    fi
    ui::_pfx 1 "${OS_THEME_INDENT}"
    local indent=${OS_UI__PFX}
    for ((i = 0; i < ${#lines[@]}; i++)); do
        ui::_truncate "${lines[i]}" "${max_width}"
        printf '%s%s\n' "${indent}" "${OS_UI__TRUNC}"
    done
    return 0
}

# ui::_shift_by <想移动几个> <还剩几个>   结果写进 OS_UI__SHIFT
# `shift n` 在 n > $# 时返回非零，会被调用者的 set -e 直接带走。参数缺一个就崩，
# 而缺参数本身是调用方的笔误，不该表现成整个脚本退出。
ui::_shift_by() {
    local -i want=${1} left=${2}
    if ((want > left)); then
        OS_UI__SHIFT=${left}
    else
        OS_UI__SHIFT=${want}
    fi
    return 0
}

# ui::_pfx <fd> <框外缩进>   行首前缀写进 OS_UI__PFX
#
# frame 内仅保留一格左侧树状引导线；正文仍落在与框外缩进相同的列上。
ui::_pfx() {
    local -i fd=${1:-1} outer=${2:-0}
    if ((OS_UI__FRAME == 1)); then
        ui::_tree_pfx "${fd}" "${outer}"
    else
        printf -v OS_UI__PFX '%*s' "${outer}" ''
    fi
    return 0
}

# ui::frame_begin <标题> [元信息]
#
# action_menu 的组合起点：只画树的起始角，不画外框或底边。
ui::frame_begin() {
    if ui::_silent 1; then
        return 0
    fi
    local title=${1-} meta=${2-} text=${1-}
    if [[ -n ${meta} ]]; then
        text+=" · ${meta}"
    fi
    ui::_truncate "${text}" $((OS_UI_WIDTH - 2))
    ui::_tree_heading top heading "${OS_UI__TRUNC}"
    ui::_tree_spacer
    OS_UI__FRAME=1
    return 0
}

# ui::frame_end   结束组合布局，不产生可见边线。
ui::frame_end() {
    OS_UI__FRAME=0
    return 0
}

# ui::_menu_pairs <fd> <行首前缀> <可用宽度>   渲染 OS_UI__PAIR_K / _V 两列
#
# 键右对齐成一列、值跟在后面；值为空的那条只打键（用作小标题）。
# 菜单里有两处要这个形状——顶部的系统总览与底部的操作说明，位置相反而长相相同。
# 走一对**文件级暂存数组**而不是参数：bash 传不了数组，而两个消费者都在
# ui::menu 里，一进一出即用即弃。
OS_UI__PAIR_K=()
OS_UI__PAIR_V=()

ui::_menu_pairs() {
    local fd=${1} pfx=${2}
    local -i avail=${3}
    local -i n=${#OS_UI__PAIR_K[@]}
    ((n > 0)) || return 0

    local -i i kw=0
    for ((i = 0; i < n; i++)); do
        ui::_width "${OS_UI__PAIR_K[i]}"
        if ((OS_UI__W > kw)); then kw=${OS_UI__W}; fi
    done
    local -i key_cap=$((avail - 10))
    if ((key_cap < 4)); then key_cap=4; fi
    if ((kw > key_cap)); then kw=${key_cap}; fi
    local -i value_width=$((avail - kw - 2))

    local key_text
    for ((i = 0; i < n; i++)); do
        if [[ -z ${OS_UI__PAIR_V[i]-} ]]; then
            ui::_style muted
            ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__PAIR_K[i]}"
            printf -v OS_UI__L '%s%s' "${pfx}" "${OS_UI__COLORED}"
            ui::_emit "${fd}" "${OS_UI__L}"
            continue
        fi
        ui::_truncate "${OS_UI__PAIR_K[i]}" "${kw}"
        ui::_pad "${OS_UI__TRUNC}" "${kw}" left
        ui::_style muted
        ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__PAD}"
        key_text=${OS_UI__COLORED}
        ui::_truncate "${OS_UI__PAIR_V[i]}" "${value_width}"
        printf -v OS_UI__L '%s%s  %s' "${pfx}" "${key_text}" "${OS_UI__TRUNC}"
        ui::_emit "${fd}" "${OS_UI__L}"
    done
    return 0
}

# ui::menu [--err] [--keep-screen] [--title <标题>] [--meta <元信息>] [--notice <提示>]
#          [--status <键> <值>] [--hint <键> <值>] [--group <组名>] [--nav root|submenu|back|exit]
#          [--item <编号> <条目> [<说明>]] [--subitem <编号> <条目> [<说明>]] ...
#
# 整个项目的菜单外观只在这里定义。左侧一条树状引导线（╭、├、│）承担层级，
# 有导航提示时折成一段横线（╰──）把它隔开；不画右边框与闭合底边，
# 窄终端中每行均按可用显示宽度截断。
#
# 编号原样打印，不做连续重排；编号列固定两格，令个位和两位编号的标签对齐。
# `--subitem` 以 `›` 标记仍会进入下一层菜单，`--item` 则直接执行。
# `<说明>` 为可选的第二列；为保持简洁，其首词不可为 `--`。
#
# **`--err` 把整屏改写到 stderr**，同 ui::line 的 --err：命令自身的提问不是它的
# 输出，`$(os::run_out …)` 的调用方不该收到。由本函数认这个开关而不是让调用方
# 加 `>&2`，是因为静默判据与 TTY 判据都得知道字究竟落在哪个流上 —— 从前调用方
# 在外面重定向，函数里仍按 stdout 判断，于是 `--output json` 下菜单被咽掉、
# 屏幕上只剩一个没有选项的提示符，用户只能瞎猜。
ui::menu() {
    local -a nums=() labels=() descs=() marks=() status_keys=() status_vals=()
    local -a hint_keys=() hint_vals=()
    local title='' meta='' notice='' nav=''
    local -a seq_kind=() seq_val=()
    local -i keep_screen=0 fd=1

    while [[ $# -gt 0 ]]; do
        case ${1} in
            --err)
                fd=2
                shift
                ;;
            --keep-screen)
                keep_screen=1
                shift
                ;;
            --title)
                title=${2-}
                ui::_shift_by 2 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --meta)
                meta=${2-}
                ui::_shift_by 2 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --notice)
                notice=${2-}
                ui::_shift_by 2 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --nav)
                nav=${2-}
                ui::_shift_by 2 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --status)
                status_keys+=("${2-}")
                status_vals+=("${3-}")
                ui::_shift_by 3 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --hint)
                hint_keys+=("${2-}")
                hint_vals+=("${3-}")
                ui::_shift_by 3 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --group)
                seq_kind+=(group)
                seq_val+=("${2-}")
                ui::_shift_by 2 $#
                shift "${OS_UI__SHIFT}"
                ;;
            --item | --subitem)
                if [[ ${1} == --subitem ]]; then marks+=(1); else marks+=(0); fi
                seq_kind+=(item)
                seq_val+=('')
                nums+=("${2-}")
                labels+=("${3-}")
                if [[ $# -ge 4 && ${4-} != --* ]]; then
                    descs+=("${4}")
                    ui::_shift_by 4 $#
                else
                    descs+=('')
                    ui::_shift_by 3 $#
                fi
                shift "${OS_UI__SHIFT}"
                ;;
            *) shift ;;
        esac
    done
    if ui::_silent "${fd}"; then
        return 0
    fi

    # --- 整帧缓冲开始。到函数末尾一次写出，**这中间不得有 return** ---
    #
    # 重画整屏时不再走 `[2J`：那会先把屏幕清成空白再逐行画，肉眼就是闪一下。
    # 改成「光标归位 → 铺新帧（每行自带清到行尾）→ 清掉尾部残留」，屏幕上
    # 任何一刻都是一张完整的菜单。前一屏比这一屏长时，多出来的部分由末尾的
    # 清除收掉。
    #
    # 已在 frame 中的调用必须保留上方总览，即使调用方漏传 --keep-screen；
    # 非终端（管道、日志、JSON）一个转义字节都不发，输出与从前逐字节相同。
    local -i redraw=0
    if ((keep_screen == 0 && OS_UI__FRAME == 0)) && ui::_fd_tty "${fd}"; then
        redraw=1
    fi
    OS_UI__BUF=''
    OS_UI__BUF_EOL=''
    if ((redraw == 1)); then
        OS_UI__BUF_EOL="${OS_UI__ESC}[K"
    fi
    OS_UI__BUFFERING=1

    local -i fw=${OS_UI_WIDTH}
    if ((fw > OS_THEME_MENU_WIDTH)); then
        fw=${OS_THEME_MENU_WIDTH}
    fi
    local -i ind=${OS_THEME_INDENT} in_frame=${OS_UI__FRAME}
    local indent=''
    printf -v indent '%*s' "${ind}" ''
    ui::_tree_pfx "${fd}" "${ind}"
    local content_pfx=${OS_UI__PFX}
    local title_text=${title:-请选择操作}
    if [[ -n ${meta} ]]; then title_text+=" · ${meta}"; fi
    ui::_truncate "${title_text}" $((fw - 2))
    if ((in_frame == 1)); then
        ui::_tree_heading branch heading "${OS_UI__TRUNC}" "${fd}"
    else
        ui::_tree_heading top heading "${OS_UI__TRUNC}" "${fd}"
        ui::_tree_spacer "${fd}"
    fi

    local -i i
    if [[ -n ${notice} ]]; then
        ui::_truncate "${notice}" $((fw - ind - 2))
        ui::_style error
        ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__SYM_ERR} ${OS_UI__TRUNC}"
        printf -v OS_UI__L '%s%s' "${content_pfx}" "${OS_UI__COLORED}"
        ui::_emit "${fd}" "${OS_UI__L}"
    fi
    OS_UI__PAIR_K=(${status_keys[@]+"${status_keys[@]}"})
    OS_UI__PAIR_V=(${status_vals[@]+"${status_vals[@]}"})
    ui::_menu_pairs "${fd}" "${content_pfx}" $((fw - ind))
    # 状态总览与第一个可选分组是两层信息；用一格延续线隔开，不拉开整行留白。
    if [[ -n ${notice} ]] || ((${#status_keys[@]} > 0)); then
        ui::_tree_spacer "${fd}"
    fi

    local -i has_desc=0 has_mark=0 lw=0
    for ((i = 0; i < ${#labels[@]}; i++)); do
        [[ -n ${descs[i]} ]] && has_desc=1
        if ((marks[i] == 1)); then has_mark=1; fi
        ui::_width "${labels[i]}"
        if ((OS_UI__W > lw)); then lw=${OS_UI__W}; fi
    done
    # 项目前缀为「缩进 + 编号两格 + 两空格」；说明至少留八格可读空间。
    #
    # **说明列放不下时，为它预留的宽度必须一并退还。** 先按「有说明」试算，发现
    # 说明列不足八格就整屏不显示说明 —— 这时若还按预留的十格去截标签，窄终端上
    # 标签少了六个字，腾出来的位置却一个字都没填。
    local -i label_at=$((ind + 4)) label_reserve=2 label_cap=0 desc_width=0 lw_raw=${lw}
    if ((has_desc == 1)); then
        label_cap=$((fw - label_at - 10))
        if ((label_cap < 4)); then label_cap=4; fi
        if ((lw > label_cap)); then lw=${label_cap}; fi
        desc_width=$((fw - label_at - lw - 5))
        if ((desc_width < 8)); then has_desc=0; fi
    fi
    if ((has_desc == 0)); then
        if ((has_mark == 1)); then label_reserve=4; fi
        label_cap=$((fw - label_at - label_reserve))
        if ((label_cap < 4)); then label_cap=4; fi
        lw=${lw_raw}
        if ((lw > label_cap)); then lw=${label_cap}; fi
    fi

    local -i item_i=0 j
    for ((j = 0; j < ${#seq_kind[@]}; j++)); do
        if [[ ${seq_kind[j]} == group ]]; then
            ui::_truncate "${seq_val[j]}" $((fw - 2))
            ui::_tree_heading branch heading "${OS_UI__TRUNC}" "${fd}"
            continue
        fi

        ui::_pad "${nums[item_i]}" 2 right
        ui::_style accent
        ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__PAD}"
        local number_text=${OS_UI__COLORED}
        ui::_truncate "${labels[item_i]}" "${lw}"
        local label=${OS_UI__TRUNC} mark=''
        if ((marks[item_i] == 1)); then
            ui::_style muted
            ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__SYM_SUBMENU}"
            mark=${OS_UI__COLORED}
        fi
        if ((has_desc == 1)) && [[ -n ${descs[item_i]} ]]; then
            ui::_pad "${label}" "${lw}" left
            ui::_truncate "${descs[item_i]}" "${desc_width}"
            ui::_style muted
            ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__TRUNC}"
            printf -v OS_UI__L '%s%s  %s %s  %s' "${content_pfx}" "${number_text}" "${OS_UI__PAD}" "${mark:- }" "${OS_UI__COLORED}"
            ui::_emit "${fd}" "${OS_UI__L}"
        elif [[ -n ${mark} ]]; then
            # 带说明的条目把标签补齐到 lw，这里也补：一屏里混着有说明和没说明的
            # 下潜项时，`›` 必须落在同一列，否则它会忽左忽右
            ui::_pad "${label}" "${lw}" left
            printf -v OS_UI__L '%s%s  %s %s' "${content_pfx}" "${number_text}" "${OS_UI__PAD}" "${mark}"
            ui::_emit "${fd}" "${OS_UI__L}"
        else
            printf -v OS_UI__L '%s%s  %s' "${content_pfx}" "${number_text}" "${label}"
            ui::_emit "${fd}" "${OS_UI__L}"
        fi
        item_i+=1
    done

    # 操作说明排在条目**之后**：读完十行选项，眼睛已经落到底部，那时才需要
    # 知道怎么输。摆在清单之前的话，用户读它的时候还不知道有什么可选，
    # 等挑完了再往回翻 —— 与 --status 的系统总览相反，那个必须在最上面。
    if ((${#hint_keys[@]} > 0)); then
        ui::_tree_spacer "${fd}"
        OS_UI__PAIR_K=("${hint_keys[@]}")
        OS_UI__PAIR_V=(${hint_vals[@]+"${hint_vals[@]}"})
        ui::_menu_pairs "${fd}" "${content_pfx}" $((fw - ind))
    fi

    OS_UI__FRAME=0
    # 三种导航语境，措辞在这里定死一次。**只有菜单前端的两种提「命令名直达」**：
    # os::select 里敲的是选项值，在那儿写直达就是在说谎。而直达在菜单的每一层都
    # 有效，所以 submenu 也要提 —— 只在主屏说的话，进了二级菜单的人就不知道了
    local nav_text=''
    case ${nav} in
        root) nav_text="编号或命令名直达 · ${OS_UI_SYM_ENTER} 退出" ;;
        # 二级往下才提 ^C：主屏回车就是退出，再写一个退出键是噪音；
        # 而深处那几屏「怎么直接出去」恰恰是问得最多的
        submenu) nav_text="编号或命令名直达 · ${OS_UI_SYM_ENTER} 返回上一层 · ^C 退出" ;;
        back) nav_text="${OS_UI_SYM_ENTER} 返回上一层 · ^C 退出" ;;
    esac
    if [[ -n ${nav_text} ]]; then
        ui::_tree_bottom_rule "${fw}" "${fd}"
        ui::_truncate "${nav_text}" $((fw - ind))
        ui::_style muted
        ui::_colorize "${fd}" "${OS_UI__C}" 0 "${OS_UI__TRUNC}"
        printf -v OS_UI__L '%s%s' "${indent}" "${OS_UI__COLORED}"
        ui::_emit "${fd}" "${OS_UI__L}"
    fi

    # --- 整帧缓冲结束：一次写出 ---
    OS_UI__BUFFERING=0
    OS_UI__BUF_EOL=''
    if ((redraw == 1)); then
        printf '%s[H%s%s[J' "${OS_UI__ESC}" "${OS_UI__BUF}" "${OS_UI__ESC}" >&"${fd}"
    else
        printf '%s' "${OS_UI__BUF}" >&"${fd}"
    fi
    OS_UI__BUF=''
    return 0
}

# ui::progress <当前> <总数> [标签]
#
# 非 TTY 下降级为按比例打行：管道与 cron 里 \r 重绘会变成一坨拼在一起的垃圾。
ui::progress() {
    if ui::_silent 1; then
        return 0
    fi
    local -i cur=${1:-0} total=${2:-0}
    local label=${3-}
    if ((total <= 0)); then
        return 0
    fi
    local -i pct=$((cur * 100 / total))

    if [[ ${OS_UI_STDOUT_TTY} -eq 0 ]]; then
        local -i decile=$((pct / 10))
        if ((decile == OS_UI__PROGRESS_LAST)); then
            return 0
        fi
        OS_UI__PROGRESS_LAST=${decile}
        printf '%3d%% %s\n' "${pct}" "${label}"
        return 0
    fi

    ui::_style accent
    ui::_colorize 1 "${OS_UI__C}" 0 "${pct}% ${label}"
    printf '\r%s' "${OS_UI__COLORED}"
    if ((cur >= total)); then
        printf '\n'
        OS_UI__PROGRESS_LAST=-1
    fi
    return 0
}

# ==================================================================
# 活动指示 —— 总量未知的长命令
# ==================================================================
#
# `ui::progress` 要求知道总数。而本项目里最花时间的几件事都给不出总数：
# apt 装包、按需构建 Caddy、下载几十 MB 的二进制。它们的输出按规范
# 全进日志，屏幕上于是几十秒到几分钟毫无动静 —— 用户分不清是在跑还是卡死了，
# 而「分不清就按 Ctrl-C」恰恰会在包管理事务中途打断。
#
# 只在 TTY 上转圈：管道、cron、CI 里 `\r` 重绘会糊成一坨。
#
# **一律写 stderr**，与 ui::progress 不同。`os::run_out` 的 stdout 是返回值通道
# ，往那里写一个字节，调用方 `$(os::run_out ...)` 拿到的就是转圈的
# 残渣。stderr 也是 curl、wget、apt 放进度的地方，符合惯例。

OS_UI__ACTIVITY_PID=''

# ui::activity_start <标签>   转起来返回 0，没转返回 1（调用方据此决定要不要直接打行）
ui::activity_start() {
    OS_UI__ACTIVITY_PID=''
    # --output json 下呈现层必须静默，转圈也算呈现
    if [[ ${OS_UI_QUIET} -eq 1 || ${OS_UI_STDERR_TTY} -eq 0 ]]; then
        return 1
    fi
    local label=${1-}
    # 子 shell 里不能用 local —— 那不是函数体，bash 会报错
    (
        n=0
        # 反斜杠单独写成 $'\\'，直接放进 '|/-\' 会被 shellcheck 当成想转义单引号
        frames='|/-'$'\\'
        while :; do
            printf '\r%s %s… %ds ' "${frames:n%4:1}" "${label}" "${n}" >&2
            n=$((n + 1))
            sleep 1
        done
    ) &
    OS_UI__ACTIVITY_PID=$!
    return 0
}

# ui::activity_stop   停掉转圈并把那一行擦干净
ui::activity_stop() {
    [[ -n ${OS_UI__ACTIVITY_PID} ]] || return 0
    kill "${OS_UI__ACTIVITY_PID}" 2>/dev/null || true
    # wait 收尸，否则 shell 会在稍后打一行「Terminated」到屏幕上
    wait "${OS_UI__ACTIVITY_PID}" 2>/dev/null || true
    OS_UI__ACTIVITY_PID=''
    # 用空格覆盖整行再回行首：只回车不覆盖的话，上一帧比新内容长的那截会留在屏幕上
    printf '\r%*s\r' "${OS_UI_WIDTH:-80}" '' >&2
    return 0
}

# 源入即探测一次。bootstrap.sh 装配完 L0 覆盖后可以再调一次 ui::init 刷新。
ui::init
