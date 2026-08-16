#!/usr/bin/env bats
#
# lib/ui.sh 的单元测试
#
# ui::width 处理 Unicode、ANSI 与 locale，是必须保留对抗性用例的边界函数。
# 必测输入：中英混排 · emoji · 全角标点。下面在此之上补了 ANSI、组合附加符、
# 非法 UTF-8、外部 locale 干扰 —— 前三类是真实会遇到的，最后一类是这个实现
# 最容易悄悄退化的地方（换个 locale 结果就变，而没有任何报错）。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui
    os_test_no_tty
}

# --- ui::width 基本 ---

@test "width: 纯 ASCII 等于字符数" {
    [ "$(ui::width 'hello')" -eq 5 ]
}

@test "width: 空串为 0" {
    [ "$(ui::width '')" -eq 0 ]
}

@test "width: 无参数为 0" {
    [ "$(ui::width)" -eq 0 ]
}

# --- 对抗性输入 ---

@test "width: 中英混排（V2 必测）" {
    # 中=2 a=1 文=2
    [ "$(ui::width '中a文')" -eq 5 ]
    # 安装=4 /=1 升级=4 空格=1 Caddy=5
    [ "$(ui::width '安装/升级 Caddy')" -eq 15 ]
}

@test "width: 全角标点（V2 必测）" {
    # ，。（） 各 2 格
    [ "$(ui::width '，。（）')" -eq 8 ]
    # 全角字母 Ａ 也是 2 格
    [ "$(ui::width 'Ａ')" -eq 2 ]
}

@test "width: emoji（V2 必测）" {
    [ "$(ui::width '🚀')" -eq 2 ]
    [ "$(ui::width '✅')" -eq 1 ]
    [ "$(ui::width 'a🚀b')" -eq 4 ]
}

@test "width: 带变体选择符的 emoji 不重复计宽" {
    # U+2764 U+FE0F —— FE0F 是零宽变体选择符
    [ "$(ui::width $'\u2764\ufe0f')" -eq 1 ]
}

@test "width: 组合附加符不占格" {
    # e + U+0301 组合锐音符
    [ "$(ui::width $'e\u0301')" -eq 1 ]
}

@test "width: 剥掉 ANSI 转义序列" {
    local red=$'\033[0;31m' rst=$'\033[0m'
    [ "$(ui::width "${red}中文${rst}")" -eq 4 ]
    [ "$(ui::width "${red}${rst}")" -eq 0 ]
}

@test "width: 残缺的 ANSI 序列不死循环" {
    run ui::width $'abc\033['
    [ "${status}" -eq 0 ]
}

@test "width: 非法 UTF-8 字节不致命" {
    run ui::width $'\xff\xfe'
    [ "${status}" -eq 0 ]
    # 只要求「不崩、返回一个整数」—— 非法输入没有正确宽度可言
    [ "${output}" -ge 0 ]
}

@test "width: 长串" {
    local s=''
    local i
    for ((i = 0; i < 200; i++)); do s+='中'; done
    [ "$(ui::width "${s}")" -eq 400 ]
}

# --- 最容易悄悄退化的一条 ---

@test "width: 结果与调用方 locale 无关" {
    local a b
    a=$(LC_ALL=C ui::width '中a文')
    b=$(LC_ALL=C.UTF-8 ui::width '中a文')
    [ "${a}" -eq 5 ]
    [ "${b}" -eq 5 ]
}

# --- 对齐 ---

@test "pad: 中文按显示宽度补齐，不按字节" {
    ui::_pad '中文' 10 left
    [ "$(ui::width "${OS_UI__PAD}")" -eq 10 ]
    ui::_pad 'abc' 10 right
    [ "$(ui::width "${OS_UI__PAD}")" -eq 10 ]
    [ "${OS_UI__PAD}" = '       abc' ]
}

@test "pad: 内容超宽时原样返回，不截断" {
    ui::_pad '中文中文' 3 left
    [ "${OS_UI__PAD}" = '中文中文' ]
}

@test "truncate: 按显示宽度截断并加省略号" {
    ui::_truncate '中文中文中文' 7
    [ "$(ui::width "${OS_UI__TRUNC}")" -le 7 ]
    ui::_truncate 'abc' 10
    [ "${OS_UI__TRUNC}" = 'abc' ]
}

# 从前 _truncate 自己用 ${s:i:1} 逐字符切，而那个下标在非 UTF-8 locale 下按
# 字节走：LANG 没设（SSH 进服务器的常态）时它把中文切成半个字符，宽度还超出
# 目标，框和表格当场歪掉。切点现在由 ui::_width 一并算出，与 locale 无关。
@test "truncate: 结果与调用方 locale 无关，且绝不超宽" {
    local a b m
    for m in 20 10 7 5 2; do
        a=$(LC_ALL=C ui::_truncate '重启 php8.3-fpm 使配置生效？' "${m}"; printf '%s' "${OS_UI__TRUNC}")
        b=$(LC_ALL=C.UTF-8 ui::_truncate '重启 php8.3-fpm 使配置生效？' "${m}"; printf '%s' "${OS_UI__TRUNC}")
        [ "${a}" = "${b}" ]
    done
}

@test "truncate: 截出来的仍是完整字符，宽度不超过上限" {
    local m
    for m in 20 10 7 5 3; do
        LC_ALL=C ui::_truncate '中文中文中文中文' "${m}"
        [ "$(ui::width "${OS_UI__TRUNC}")" -le "${m}" ]
        # 半个 UTF-8 字符会让 ${#} 与显示宽度对不上；用宽度反查一遍就够
        [ -n "${OS_UI__TRUNC}" ]
    done
}

# --- ui::prompt ---

# 一次问答的形状是固定的：问题一行、输入符另起一行、光标停在输入符后面。
# 它不随文本长短变化 —— 从前短提示同行、长提示折行，屏幕上两种形态。
@test "prompt: 输入符独占最后一行，光标停在它后面" {
    local out
    out=$(ui::prompt '数据库名称' 2>&1)
    [[ "${out}" == *'数据库名称'* ]]
    [[ "${out}" == *$'\n'* ]]
    [[ "${out}" == *"${OS_UI__SYM_PROMPT} " ]]
}

# `❯` 只许出现在等待输入的那一行。问题行用的是另一个符号，
# 两者混用时屏幕上分不出哪行是工具问的、哪行是自己敲的。
@test "prompt: 问题行不带输入符" {
    local out first
    out=$(ui::prompt '数据库名称' 2>&1)
    first=${out%%$'\n'*}
    [[ "${first}" != *"${OS_UI__SYM_PROMPT}"* ]]
    [[ "${first}" == *"${OS_UI__SYM_ASK}"* ]]
}

@test "prompt: 文本为空时只有输入符那一行" {
    local out
    out=$(ui::prompt '' 0 2>&1)
    [[ "${out}" != *$'\n'* ]]
    [[ "${out}" == *"${OS_UI__SYM_PROMPT} " ]]
}

@test "prompt: 一律走 stderr，不污染命令的返回值通道" {
    local out
    out=$(ui::prompt '问题' 2>/dev/null)
    [ -z "${out}" ]
}

@test "prompt: 尾注补齐到固定列宽，多个提问的尾注对齐" {
    local a b
    a=$(ui::prompt '短' 20 '⏎ 默认' 2>&1)
    b=$(ui::prompt '长一点的问题' 20 '⏎ 默认' 2>&1)
    a=${a%%$'\n'*}
    b=${b%%$'\n'*}
    [ "$(ui::width "${a}")" -eq "$(ui::width "${b}")" ]
}

@test "prompt: 说明夹在问题与输入符之间" {
    local out
    out=$(ui::prompt '问题' 0 '' '怎样才算合法' 2>&1)
    [[ "${out}" == *$'问题\n'*'怎样才算合法'*$'\n'*"${OS_UI__SYM_PROMPT} " ]]
}

# --- 能力探测 ---


# 长提示不为对齐而截断：问题是要读的，少几个字就问不清楚了。
@test "prompt: 超固定列宽时完整显示，不截断" {
    local out
    out=$(ui::prompt '粘贴完整的 run 命令（带反斜杠换行可整段粘贴）' 12 2>&1)
    [[ "${out}" == *'粘贴完整的 run 命令（带反斜杠换行可整段粘贴）'* ]]
    [[ "${out}" != *'…'* ]]
    [[ "${out}" == *$'\n'*"${OS_UI__SYM_PROMPT} " ]]
}

# --- ui::menu 的两处键值块 ---

# 系统总览在上、操作说明在下：读完清单才需要知道怎么输，
# 而系统总览是读清单之前的前提。
@test "menu: --status 在条目之前，--hint 在条目之后" {
    local out
    out=$(ui::menu --keep-screen --title '选' \
        --status '系统' 'Debian 13' \
        --item 1 '第一项' \
        --hint 'none' '都不要' 2>&1)
    [[ "${out}" == *'Debian 13'*'第一项'*'都不要'* ]]
}

@test "init: NO_COLOR 存在即关色，空串也算" {
    NO_COLOR='' TERM=xterm-256color ui::init
    [ "${OS_UI_COLOR_CAPABLE}" -eq 0 ]
}

@test "init: TERM=dumb 无色" {
    unset NO_COLOR
    TERM=dumb ui::init
    [ "${OS_UI_COLOR_CAPABLE}" -eq 0 ]
}

@test "init: 非 TTY 下宽度回退 80" {
    ui::init
    [ "${OS_UI_WIDTH}" -eq 80 ]
}

@test "init: 非 UTF-8 locale 用 ASCII 符号与树状引导" {
    LC_ALL=C ui::init
    [ "${OS_UI_UTF8}" -eq 0 ]
    [ "${OS_UI__SYM_OK}" = "${OS_THEME_SYM_OK_ASCII}" ]
    [ "${OS_UI__TREE_STEM}" = '|' ]
    [ "${OS_UI__TREE_BRANCH}" = '+' ]
    [ "${OS_UI__TREE_BOTTOM}" = '+' ]
}

@test "非 TTY 时所有原语都不输出 ANSI" {
    local out
    out=$(
        ui::line success '成功'
        ui::line info '进行中'
        ui::heading '标题'
        ui::kv '版本' '1.0' '监听地址' '127.0.0.1'
        ui::table '名称' '状态' -- 'caddy' '运行中' 'mariadb' '已停止'
        ui::box '面板' -- '第一行' 'line two'
        ui::menu --title '主菜单' --group '环境与安装' --item 10 '安装 Caddy' --item 130 '备份'
        ui::progress 3 10 '下载中'
    )
    [[ "${out}" != *$'\033'* ]]
}

@test "line: 警告与错误默认就走 stderr，不用调用方记得加 >&2" {
    local out err
    out=$(ui::line warn '注意' 2>/dev/null)
    [ -z "${out}" ]
    err=$(ui::line warn '注意' 2>&1 >/dev/null)
    [[ "${err}" == *'注意'* ]]

    out=$(ui::line error '炸了' 2>/dev/null)
    [ -z "${out}" ]

    # 正常消息仍走 stdout
    out=$(ui::line success '好了' 2>/dev/null)
    [[ "${out}" == *'好了'* ]]
}

@test "line: --out / --err 可显式覆盖默认去向" {
    local out err
    out=$(ui::line --out warn '注意' 2>/dev/null)
    [[ "${out}" == *'注意'* ]]
    err=$(ui::line --err success '好了' 2>&1 >/dev/null)
    [[ "${err}" == *'好了'* ]]
}

@test "table: 中文列按显示宽度对齐，无分隔线且不留行尾空白" {
    local out line
    local -a lines=()
    out=$(ui::table '组件' '状态' -- 'caddy' '运行中' '数据库服务' '停')
    while IFS= read -r line; do
        lines+=("${line}")
    done <<<"${out}"
    [ "${#lines[@]}" -eq 3 ]
    [ "$(ui::width "${lines[0]%%状态*}")" -eq "$(ui::width "${lines[1]%%运行中*}")" ]
    [ "$(ui::width "${lines[1]%%运行中*}")" -eq "$(ui::width "${lines[2]%%停*}")" ]
    for line in "${lines[@]}"; do
        [[ ${line} != *' ' ]]
        [[ ${line} != *'─'* ]]
    done
}

@test "box: 标题与缩进内容分层，不输出边框" {
    local out line
    out=$(ui::box '状态面板' -- 'Caddy 运行中' 'a' '很长很长很长的一行中文内容')
    [[ "${out}" == *'状态面板'* ]]
    [[ "${out}" == *'Caddy 运行中'* ]]
    while IFS= read -r line; do
        [[ ${line} != *'╭'* && ${line} != *'╮'* && ${line} != *'╰'* && ${line} != *'╯'* ]]
        [[ ${line} != *'│'* && ${line} != *'─'* ]]
        [[ ${line} != *' ' ]]
    done <<<"${out}"
}

@test "menu: 渲染层原样打印编号，重排归菜单前端（D32）" {
    local out
    out=$(ui::menu --group '环境与安装' --item 10 'Caddy' --item 30 'PHP' --item 60 'Redis')
    [[ "${out}" == *'10'* ]]
    [[ "${out}" == *'30'* ]]
    [[ "${out}" == *'60'* ]]
    [[ "${out}" != *' 1  Caddy'* ]]
}

@test "menu: 导航提示不占用菜单编号" {
    local out
    out=$(ui::menu --title '操作' --item 1 '执行' --nav back)
    [[ "${out}" == *'返回上一层'* ]]
    [[ "${out}" != *'0  返回'* ]]
}

# --- 菜单布局：窄屏截断、缩进与留白分层 ---


@test "menu: 导航前以自适应横线收住引导，提示行不带竖线" {
    local out nav_line rule_line
    out=$(ui::menu --title '操作' --item 1 '执行' --nav root)
    rule_line=$(printf '%s\n' "${out}" | grep -F '╰')
    nav_line=$(printf '%s\n' "${out}" | grep -F '退出')
    [[ "${rule_line}" == ╰* ]]
    [ "$(ui::width "${rule_line}")" -eq "${OS_UI_WIDTH}" ]
    [[ "${nav_line}" != *'│'* ]]
}

@test "menu: 使用非包围式树状引导线分层" {
    local out line
    out=$(ui::menu --title '主菜单' --group '环境与安装' --item 1 'Caddy' --group '维护' --item 10 '备份')
    [[ "${out}" == *$'╭ 主菜单\n│\n├ 环境与安装\n│ '* ]]
    [[ "${out}" == *$'\n├ 维护\n│ '* ]]
    while IFS= read -r line; do
        [[ ${line} != *'╮'* && ${line} != *'╰'* && ${line} != *'╯'* ]]
        [[ ${line} != *'─'* && ${line} != *'┤'* ]]
    done <<<"${out}"
}

@test "menu: 任何一行都没有行尾空白" {
    local out line
    # 混排：有说明的、只有标记的、两样都没有的，三种行走三条不同的分支
    out=$(ui::menu --title '主菜单' --status '键' '值' --status '空值键' '' \
        --group '组' \
        --item 1 '短' \
        --subitem 2 '带标记' \
        --item 3 '带说明' '这是说明')
    while IFS= read -r line; do
        [[ "${line}" != *' ' ]]
    done <<<"${out}"
}

@test "menu: 编号列定宽，个位数与两位数的标签落在同一列" {
    local out one ten
    out=$(ui::menu --item 1 'A' --item 10 'B')
    one=$(printf '%s\n' "${out}" | grep -F ' 1  A')
    ten=$(printf '%s\n' "${out}" | grep -F '10  B')
    [ "$(ui::width "${one%A}")" -eq "$(ui::width "${ten%B}")" ]
}

@test "menu: subitem 画下潜标记，item 不画" {
    local out
    local marked plain
    out=$(ui::menu --subitem 1 '有下级' --item 2 '直接执行')
    marked=$(printf '%s
' "${out}" | grep -F '有下级')
    plain=$(printf '%s
' "${out}" | grep -F '直接执行')
    [[ "${marked}" == *'›'* ]]
    [[ "${plain}" != *'›'* ]]
}

@test "menu: 提示在标题后、条目前显示，并接入树状引导" {
    local out
    out=$(ui::menu --title '选择' --notice '没有编号 9' --item 1 'A')
    [[ "${out}" == *'没有编号 9'* ]]
    [[ "${out%%A*}" == *'没有编号 9'* ]]
    [[ "${out}" == *$'\n│ '* ]]
    [[ "${out}" != *'─'* && "${out}" != *'╯'* ]]
}

@test "menu: 状态总览与第一个分组之间保留一格延续线" {
    local out
    out=$(ui::menu --title '主菜单' --status 'Docker' '1 / 1 容器运行中' \
        --status 'docker 命令' '真 Docker' --group '服务' --item 1 '数据库管理')
    [[ "${out}" == *$'docker 命令  真 Docker\n│\n├ 服务'* ]]
}

@test "frame: 总览与菜单共用树状引导，菜单负责结束布局状态" {
    local out
    out=$(
        ui::frame_begin '容器管理' 'oneserver podman'
        ui::screen_heading '当前容器'
        ui::table '名称' '状态' -- web 运行中 db 已停止
        ui::kv '共计' '2 个'
        ui::line info '一行提示'
        ui::spacer
        ui::menu --keep-screen --title '请选择操作' --item 1 '刷新' list --nav back
        ui::line info '菜单之后'
    )
    [[ "${out}" == *$'╭ 容器管理 · oneserver podman\n│\n├ 当前容器\n│ '* ]]
    [[ "${out}" == *$'\n├ 请选择操作\n│ '* ]]
    [[ "${out}" == *'刷新'* && "${out}" == *'返回上一层'* ]]
    [[ "${out}" == *'╰'* ]]
    [[ "${out}" != *'╮'* && "${out}" != *'╯'* ]]
    # 「菜单负责结束布局状态」要在**子 shell 里**验证：菜单之后的输出不再带引导线。
    # 在外面读 OS_UI__FRAME 读到的是外层那份，它本来就是 0，那样断言等于没断言
    [[ "${out}" == *$'\n· 菜单之后'* ]]
}

@test "frame: 框内文本使用左侧引导，不出现闭合边框或行尾空白" {
    local out line
    out=$(
        ui::frame_begin '标题'
        ui::kv '键' '值'
        ui::spacer
        ui::line info '提示'
        ui::frame_end
    )
    [[ "${out}" == *$'╭ 标题\n│\n│ '* ]]
    while IFS= read -r line; do
        [[ "${line}" != *'╮'* && "${line}" != *'╰'* && "${line}" != *'╯'* && "${line}" != *'─'* ]]
        [[ "${line}" != *' ' ]]
    done <<<"${out}"
}

@test "frame: 框内外正文落在同一列" {
    local inside outside
    outside=$(ui::kv '键' '值')
    inside=$(
        ui::frame_begin '标题'
        ui::kv '键' '值'
        ui::frame_end
    )
    inside=$(printf '%s\n' "${inside}" | sed -n '3p')
    [ "$(ui::width "${inside%%值*}")" -eq "$(ui::width "${outside%%值*}")" ]
}

@test "frame: 独立菜单使用不封闭的树状布局" {
    local out
    out=$(ui::menu --title '独立菜单' --item 1 'A')
    [[ "${out}" == *$'╭ 独立菜单\n│\n│ '* ]]
    [[ "${out}" != *'╮'* && "${out}" != *'╰'* && "${out}" != *'╯'* && "${out}" != *'─'* ]]
}

@test "menu: 超宽说明被截断，不折行" {
    local out line
    out=$(ui::menu --item 1 'x' "$(printf 'a%.0s' {1..300})")
    while IFS= read -r line; do
        [ "$(ui::width "${line}")" -le 100 ]
    done <<<"${out}"
}

@test "menu: 窄终端中每行按可用宽度截断" {
    local out line old_width=${OS_UI_WIDTH}
    OS_UI_WIDTH=20
    out=$(ui::menu --title '这是一个很长的菜单标题' --status '很长的状态键' '很长的状态值' \
        --item 1 '这是一个很长的条目名称' --subitem 10 '另一个很长的条目名称' --nav root)
    OS_UI_WIDTH=${old_width}
    while IFS= read -r line; do
        [ "$(ui::width "${line}")" -le 20 ]
    done <<<"${out}"
}

@test "menu: 参数缺斤少两不会带走调用者" {
    run ui::menu --item 10
    [ "${status}" -eq 0 ]
    run ui::menu --title
    [ "${status}" -eq 0 ]
}

@test "progress: 非 TTY 按比例打行，不用 \\r 重绘" {
    local out
    out=$(
        ui::progress 1 10 '下载'
        ui::progress 5 10 '下载'
        ui::progress 10 10 '下载'
    )
    [[ "${out}" != *$'\r'* ]]
    [ "$(printf '%s\n' "${out}" | wc -l)" -eq 3 ]
}

# --- 整层静默---

@test "quiet: stdout 原语一律静音" {
    ui::set_quiet 1
    local out
    out=$(
        ui::line info '进行中'
        ui::heading '标题'
        ui::kv '键' '值'
        ui::table '列' -- '格'
        ui::menu --title '菜单' --item 10 '条目'
        ui::rule
        ui::box '盒' -- '行'
        ui::progress 1 2 '干活'
    )
    [ -z "${out}" ]
}

@test "quiet: 警告与错误照旧走 stderr" {
    ui::set_quiet 1
    local err
    err=$(
        ui::line warn '注意' 2>&1 1>/dev/null
        ui::line error '出错' 2>&1 1>/dev/null
    )
    [[ "${err}" == *"注意"* ]]
    [[ "${err}" == *"出错"* ]]
}

@test "quiet: --err 显式覆盖的输出也不被静音" {
    ui::set_quiet 1
    local err
    err=$(ui::line --err muted '明细' 2>&1 1>/dev/null)
    [[ "${err}" == *"明细"* ]]
}

@test "quiet: 关掉之后一切照旧" {
    ui::set_quiet 1
    ui::set_quiet 0
    local out
    out=$(ui::line info '进行中')
    [[ "${out}" == *"进行中"* ]]
}

# --- 分层 ---

@test "ui.sh 不 source 任何东西（装配只在 bootstrap 一处）" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/ui.sh"
    [ "${status}" -ne 0 ]
}

@test "转义序列字面量全文件只有一处（OS_UI__ESC）" {
    local n
    n=$(grep -v '^[[:space:]]*#' "${OS_TEST_REPO_ROOT}/lib/ui.sh" | grep -c '\\033' || true)
    [ "${n}" -eq 1 ]
}

@test "ui.sh 里没有色值字面量（颜色只来自 OS_THEME_COLOR_*）" {
    # 排除注释：注释里举例说明 \\033[0;31m 长什么样是允许的，代码里写死才是问题
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/ui.sh' \
        | grep -nE \"\\[[0-9]+;[0-9]+m|'[0-9];[0-9]+m'\""
    [ "${status}" -ne 0 ]
}

# --- ui::_width 的记忆表 ---
#
# 记忆表只对不带限宽的调用生效。危险的是两种调用交替：同一个串先被量过宽度，
# 再拿去按某个限宽截断 —— 切点（OS_UI__CUT）随限宽变，若被记忆表短路掉，
# 截出来的就是上一次的切点，中文当场被切成半个字。

@test "width: 记忆命中后带限宽的调用仍然真算切点" {
    os_test_no_tty
    local s='中文abc中文'
    ui::_width "${s}"
    local w1=${OS_UI__W}
    ui::_width "${s}"
    [ "${OS_UI__W}" -eq "${w1}" ]
    [ "${OS_UI__CUT}" -eq -1 ]

    # 同一个串按不同限宽截断，各自都要正确
    ui::_truncate "${s}" 6
    local a=${OS_UI__TRUNC}
    ui::_truncate "${s}" 9
    local b=${OS_UI__TRUNC}
    [ "${a}" != "${b}" ]
    ui::_width "${a}"
    [ "${OS_UI__W}" -le 6 ]
    ui::_width "${b}"
    [ "${OS_UI__W}" -le 9 ]
}

@test "width: 空串与带 ANSI 的串都能进记忆表且结果不串" {
    os_test_no_tty
    ui::_width ''
    [ "${OS_UI__W}" -eq 0 ]
    ui::_width ''
    [ "${OS_UI__W}" -eq 0 ]
    [ -z "${OS_UI__PLAIN}" ]

    local colored
    printf -v colored '\033[31m中文\033[0m'
    ui::_width "${colored}"
    [ "${OS_UI__W}" -eq 4 ]
    [ "${OS_UI__PLAIN}" = '中文' ]
    ui::_width "${colored}"
    [ "${OS_UI__W}" -eq 4 ]
    [ "${OS_UI__PLAIN}" = '中文' ]
}

@test "width: 记忆表满了整表清空，之后结果照旧正确" {
    os_test_no_tty
    local -i i
    for ((i = 0; i < OS_UI__WMEMO_MAX + 5; i++)); do
        ui::_width "串${i}"
    done
    [ "${#OS_UI__WMEMO_W[@]}" -le "${OS_UI__WMEMO_MAX}" ]
    ui::_width '中文abc'
    [ "${OS_UI__W}" -eq 7 ]
}
