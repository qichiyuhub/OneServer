# lib/theme.sh —— L0 常量层：主题，纯数据
#
# **只包含变量赋值，禁止出现任何函数、条件、命令调用。**
# 色号在这里，转义序列由 lib/ui.sh 组装；本文件里不出现一个 \033。
#
# 覆盖规则与 defaults.sh 相同，配置文件是 /etc/oneserver/theme.conf，
# key 就是这里的变量名。加载在 bootstrap.sh（L4）。
#
# shellcheck disable=SC2034  # 理由：L0 常量文件的全部变量都由别的模块消费，本文件内必然「未使用」

# --- 配色取向（Q5 已决）---
#
# **只做一套，选在黑底和白底下都可读的颜色。** 不做深色/浅色两套预设：
# 自动切换要靠 OSC 11 查询终端背景色，而 SSH 里很多终端根本不响应，
# 那是一个必然出错的探测；手动切换的入口本来就是 theme.conf，不需要预设。
#
# 由此定下两条，都与规范的示例不同，理由写在各自旁边：
#   * INFO 与菜单编号都用 6 青蓝 —— 深蓝在黑底终端上偏暗，是经典的看不清
#   * HEADING 不给色号，用默认前景色 + 加粗 —— 7 是白/浅灰，白底终端上直接消失

# --- 语义色（8 项）---
# 值是 0–7 的基础色号。ui.sh 负责在 8 色终端降级、在无色终端整体忽略。
# 空串 = 不着色，用终端默认前景色。

OS_THEME_COLOR_SUCCESS='2'
OS_THEME_COLOR_ERROR='1'
OS_THEME_COLOR_WARN='3'
OS_THEME_COLOR_INFO='6'
OS_THEME_COLOR_MUTED='8'
OS_THEME_COLOR_ACCENT='6'
OS_THEME_COLOR_HEADING=''
OS_THEME_COLOR_PLAIN=''

# HEADING 靠加粗而不是靠颜色区分——见上面的配色取向
OS_THEME_HEADING_BOLD=1

# --- 符号（7 组，各带 ASCII 回退）---
# 终端不支持 UTF-8 或 OS_THEME_SHOW_ICONS=0 时，ui.sh 换用 _ASCII 那一组。
#
# **只留有原语真在消费的。** 摆一个没人读的 key 在这里，等于对用户承诺了一个
# 设了也不会有任何效果的开关 —— 那不是兼容性，是把死配置伪装成能用的。

OS_THEME_SYM_OK='✓'
OS_THEME_SYM_OK_ASCII='[OK]'
OS_THEME_SYM_ERR='✗'
OS_THEME_SYM_ERR_ASCII='[!!]'
OS_THEME_SYM_WARN='!'
OS_THEME_SYM_WARN_ASCII='[!]'
OS_THEME_SYM_INFO='·'
OS_THEME_SYM_INFO_ASCII='-'
OS_THEME_SYM_ENTER='⏎'
OS_THEME_SYM_ENTER_ASCII='Enter'
OS_THEME_SYM_SUBMENU='›'
OS_THEME_SYM_SUBMENU_ASCII='>'
# ASK 与 PROMPT 是**一问一答两行的两个行首**，分开是有原因的：一个符号同时表示
# 「这是个问题」和「在这里打字」时，屏幕上一串 ❯ 分不出哪行是工具问的、哪行是
# 自己敲的 —— 长提示折行时尤其明显，两行开头一模一样。
# **PROMPT 只许出现在等待输入的那一行**，别处一律不用它。
OS_THEME_SYM_ASK='?'
OS_THEME_SYM_ASK_ASCII='?'
OS_THEME_SYM_PROMPT='❯'
OS_THEME_SYM_PROMPT_ASCII='>'

# --- 开关（6 项）---
#
# INDENT 是 3 而不是 2：菜单里的内容列 = 左侧引导线 1 格 + 内边距 2 格，落在第 3 列。
# 引导线之外的 kv/table 用同一个缩进，屏幕上才只有一条垂直基准线 —— 总览表格
# 与它下方菜单条目的左边缘对不齐，是"两套缩进"最显眼的表现。
#
# MENU_WIDTH 让菜单**定宽**，不随内容伸缩。宽度取内容最大值的话，每切一屏列位
# 就挪一次；固定之后超宽的说明按显示宽度截断，代价是偶尔少几个字，换来的是
# 切屏时说明列与底部横线纹丝不动。仍受终端实际宽度与 MAX_WIDTH 收口。
#
# ASK_WIDTH 是提问文本补齐到的列宽，作用是让**所有脚本的所有提问**尾注
# （`⏎ 默认值`、`必填`、`[y/N]`）落在同一列，而不是参差地跟在长短不一的问题后面。
# 答案不在这一列上 —— 它永远在下一行的输入符之后。

OS_THEME_SHOW_ICONS=1
OS_THEME_DENSITY='normal'
OS_THEME_INDENT=3
OS_THEME_MAX_WIDTH=100
OS_THEME_MENU_WIDTH=80
OS_THEME_ASK_WIDTH=26
