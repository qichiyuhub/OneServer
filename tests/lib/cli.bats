#!/usr/bin/env bats
#
# CLI 端到端测试 —— 两个前端，以及经它们派发的命令（doctor）
#
# 这两个是前端，文件头里写死了 `/opt/oneserver/lib/...` —— 那是
# **运行期**的绝对路径，改不得。所以这组用例把仓库真的装到 /opt/oneserver 再跑，
# 测的就是用户敲下 `oneserver` 时的那条路径。
#
# **安全阀**：/opt/oneserver 已存在就整组跳过。这些用例只在一次性容器里有意义，
# 误跑在真机上不能去覆盖别人已装好的东西。

setup_file() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    if [[ ${EUID} -ne 0 ]]; then
        return 0
    fi
    # 判据是「那里有没有一份真的安装」，不是「目录存不存在」：probe 的用例会
    # 在同一个容器里落 /opt/oneserver/public/probe.tsv，按目录存在与否判会永远跳过
    if [[ -e /opt/oneserver/lib || -e /opt/oneserver/bin/oneserver ]]; then
        return 0
    fi

    mkdir -p /opt/oneserver
    cp -a "${OS_TEST_REPO_ROOT}/." /opt/oneserver/
    : >/opt/oneserver/.bats-owned
    chmod +x /opt/oneserver/bin/oneserver /opt/oneserver/bin/oneserver-menu
    chmod +x /opt/oneserver/script/manage/ufw_manager.sh
    ln -sf /opt/oneserver/bin/oneserver /opt/oneserver/bin/os

    # 一个只回显参数的假命令：路由对不对由它说了算，
    # 不必去跑真的安装脚本（那会真的装东西）
    cat >/opt/oneserver/script/ops/selftest_echo.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用的假命令
#
# @command      selftest echo
# @name         端到端回显
# @group        toolbox
# @order        900
# @privilege    any
# @requires_lib >= 1.0
# @args         [--flag=<v>]
# @description  回显收到的参数
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

flagval=''
os::ask --arg flag '标志' flagval 'none'
printf 'ECHO:[%s] FLAG:[%s]\n' "${1-}" "${flagval}"
EOF
    chmod +x /opt/oneserver/script/ops/selftest_echo.sh

    # 一个会往 stdout 打字的假命令：--output json 时这些字**一个都不许**出现在
    # stdout 上。os::run 的 desc 曾经就是这么漏出去的
    cat >/opt/oneserver/script/ops/selftest_noise.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用：制造呈现层噪声
#
# @command      selftest noise
# @name         端到端噪声
# @group        toolbox
# @order        910
# @privilege    root
# @requires_lib >= 1.2
# @description  跑一条真命令再输出信封
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

os::section '一个小节'
os::info '进行中'
os::kv '键' '值'
os::run '造点噪声' -- true
os::ok '完成'
os::output 0 note=ok
EOF
    chmod +x /opt/oneserver/script/ops/selftest_noise.sh

    # 自己给自己发 INT 的假命令：等价于用户在这条命令跑到一半时按 Ctrl-C
    cat >/opt/oneserver/script/ops/selftest_sig.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用：自中断
#
# @command      selftest sig
# @name         端到端中断
# @group        toolbox
# @order        930
# @privilege    any
# @requires_lib >= 1.0
# @description  自己给自己发 INT，验证菜单不复述用户自己的中断
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

printf 'SIG-RAN\n'
kill -INT $$
sleep 5
EOF
    chmod +x /opt/oneserver/script/ops/selftest_sig.sh

    # 独占一个分组的**叶子**命令：菜单对单成员分组会自动跳过那一层，而跳过之后
    # 拿到的是 `r:`（执行）还是 `c:`（下潜）两条路完全不同。已有的单成员分组
    # （容器那两个）成员都是有下级的父命令，走不到 `r:` 那条路。
    # 分组 order 取 950 让它排在全部分组之后，免得把其余各屏的编号整体推后。
    printf 'solo | 独占分组 | 950 | sys\n' >>/opt/oneserver/templates/groups.conf
    cat >/opt/oneserver/script/ops/selftest_solo.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用：独占一个分组的叶子命令
#
# @command      selftest solo
# @name         端到端独占
# @group        solo
# @order        920
# @privilege    any
# @requires_lib >= 1.0
# @description  证明单成员分组能派发到叶子命令
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

printf 'SOLO-RAN\n'
EOF
    chmod +x /opt/oneserver/script/ops/selftest_solo.sh

    # 同样是单成员分组，但**写了说明**（groups.conf 第五列）。这一对夹具压的是
    # 主屏说明列取谁：写了说明取分组的（这一栏覆盖什么），没写才回落到成员脚本的
    # @description（那一条命令干什么）—— 上面的 solo 没写第五列，正好留着覆盖回落。
    printf 'blurb | 有说明分组 | 960 | sys | 分组自己的说明\n' >>/opt/oneserver/templates/groups.conf
    cat >/opt/oneserver/script/ops/selftest_blurb.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用：分组写了说明时，主屏说明列不该取这条命令的 @description
#
# @command      selftest blurb
# @name         端到端说明
# @group        blurb
# @order        925
# @privilege    any
# @requires_lib >= 1.0
# @description  成员命令自己的说明
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

printf 'BLURB-RAN\n'
EOF
    chmod +x /opt/oneserver/script/ops/selftest_blurb.sh

    # 有下级的命令：它在上一层用 @name，在**自己那一屏**的第一项用 @self_name。
    # 一个名字答不了两个问题，共用的话标题与第一项会逐字重复
    cat >/opt/oneserver/script/ops/selftest_parent.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用：有下级的父命令
#
# @command      selfparent
# @name         父命令外层名
# @self_name    父命令本项名
# @group        toolbox
# @order        930
# @privilege    any
# @requires_lib >= 1.0
# @description  验证父项标签取 @self_name
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

printf 'PARENT-RAN\n'
EOF
    chmod +x /opt/oneserver/script/ops/selftest_parent.sh

    cat >/opt/oneserver/script/ops/selftest_kid.sh <<'EOF'
#!/bin/bash
#
# 端到端测试用：上面那条命令的下级
#
# @command      selfparent kid
# @name         子命令
# @group        toolbox
# @order        940
# @privilege    any
# @requires_lib >= 1.0
# @description  让父命令有下级，菜单才会为它单开一屏
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

printf 'KID-RAN\n'
EOF
    chmod +x /opt/oneserver/script/ops/selftest_kid.sh
}

teardown_file() {
    # 只删自己建的那份，标记文件是唯一凭据
    if [[ -f /opt/oneserver/.bats-owned ]]; then
        rm -rf /opt/oneserver
    fi
}

setup() {
    if [[ ! -f /opt/oneserver/.bats-owned ]]; then
        skip '需要 root 且 /opt/oneserver 未被占用（在一次性容器里跑）'
    fi
}

# menu_screen <输入>   跑一次菜单，回显去掉 ANSI 之后的整屏
menu_screen() {
    printf "${1}" | /opt/oneserver/bin/oneserver menu 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}

# menu_num <整屏文本> <条目名>   这一屏里该条目的编号
#
# **编号一律现查，不写死。** `@requires` 让条目随机器上装了什么而增减，
# 写死的编号会在任何一台装了组件的机器上错位 —— 而这类失败看起来像功能坏了，
# 实际只是夹具选错了行。
menu_num() {
    sed -n "s/^[^0-9]*\([0-9]\{1,\}\)[[:space:]]\{1,\}${2}\([[:space:]]\|\$\).*/\1/p" <<<"${1}" | head -1
}

# --- 帮助与版本 ---

@test "oneserver --help 列出注册表里的命令" {
    run /opt/oneserver/bin/oneserver --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"firewall"* ]]
    [[ "${output}" == *"selftest echo"* ]]
    # 分组显示名来自 groups.conf
    [[ "${output}" == *"工具箱"* ]]
}

@test "oneserver --version 同时给出项目版本与 lib API 版本" {
    run /opt/oneserver/bin/oneserver --version
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"$(< /opt/oneserver/VERSION)"* ]]
    [[ "${output}" == *"lib API"* ]]
}

# --- 路由 ---

@test "路由到脚本，位置参数与选项都原样传下去" {
    run /opt/oneserver/bin/oneserver selftest echo --flag=1 位置参数
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ECHO:[位置参数]"* ]]
    [[ "${output}" == *"FLAG:[1]"* ]]
}

@test "--help 跟在具体命令后面时属于那条命令，前端不许吃掉" {
    run /opt/oneserver/bin/oneserver firewall --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"UFW"* ]]
    [[ "${output}" == *"--dry-run"* ]]
}

@test "未知命令以退出码 2 结束并给出同首词的建议" {
    run /opt/oneserver/bin/oneserver selftest nosuch
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"未知命令"* ]]
    [[ "${output}" == *"selftest echo"* ]]
}

@test "os 是 oneserver 的符号链接，行为完全一致（Q3）" {
    run /opt/oneserver/bin/os selftest echo hi
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ECHO:[hi]"* ]]
}

# --- 前端模式的安全阀---

@test "OS_BOOT_MODE 从环境继承时以退出码 4 拒绝" {
    run env OS_BOOT_MODE=frontend /opt/oneserver/script/ops/selftest_echo.sh
    [ "${status}" -eq 4 ]
    [[ "${output}" == *"OS_BOOT_MODE"* ]]
}

@test "前端不取锁：别人持着全局锁时 oneserver --help 照常出结果" {
    # 前端若取锁，这条会等到超时后以退出码 5 失败
    run bash -c 'mkdir -p /run/oneserver
        ( flock 9 && /opt/oneserver/bin/oneserver --help ) 9>>/run/oneserver/oneserver.lock'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"用法"* ]]
}

# --- 菜单 ---

@test "无参数进菜单，菜单由注册表生成，编号按屏重排 1..N" {
    run bash -c '/opt/oneserver/bin/oneserver </dev/null'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"OneServer"* ]]
    # 端到端回显挂在 toolbox 组，它收纳进了 sys（groups.conf 里 toolbox 的
    # parent），顶层只显示收纳后的虚拟项「工具箱」。摘要可以列出成员，
    # 但端到端回显不能作为主屏的可选条目出现。
    [[ "${output}" == *"工具箱"* ]]
    ! grep -qE '^[[:space:]│]*[0-9]+[[:space:]]+端到端回显([[:space:]]|$)' <<<"${output}"
    # @order 只管排序，不再上屏：900 是夹具的 @order，屏幕上不该有它
    [[ "${output}" != *"900"* ]]
}

@test "单成员分组的成员是叶子命令时直接派发" {
    local solo
    solo=$(menu_num "$(menu_screen '\n')" '独占分组')
    [ -n "${solo}" ]
    run bash -c "printf '${solo}\n' | /opt/oneserver/bin/oneserver menu"
    [ "${status}" -eq 0 ]
    # 曾经的表现：`r:` 被压进栈，下一圈 menu_screen 认不出它（只认 g:/c:），
    # 画出一屏空菜单后连分组一起弹掉 —— 主屏又出现一次，那条命令永远选不中
    [[ "${output}" == *"SOLO-RAN"* ]]
}

@test "单成员分组的说明列取分组说明，不取成员命令的 @description" {
    local screen
    screen=$(menu_screen '\n')
    # 成员只剩一条几乎总是因为别的成员被 @requires 隐掉了 —— 那时把成员脚本的
    # @description 顶上去，读起来像这一栏只有那一条命令
    [[ "${screen}" == *"分组自己的说明"* ]]
    [[ "${screen}" != *"成员命令自己的说明"* ]]
}

@test "分组没写说明时，说明列回落到成员命令的 @description" {
    local screen
    screen=$(menu_screen '\n')
    # groups.conf 第五列是可选的：没写就保持原来的行为，不让分组一行没写说明
    # 就在主屏留一片空白。只匹配开头 —— 说明列窄了会被渲染层截成 `…`，
    # 而这条用例问的是「取了谁的文案」，不是「有没有被截断」
    [[ "${screen}" == *"证明单成员分组"* ]]
}

@test "单成员分组派发完返回菜单，回到主屏而不是再跑一次同一条命令" {
    local solo
    solo=$(menu_num "$(menu_screen '\n')" '独占分组')
    [ -n "${solo}" ]
    # 第二个换行是在「⏎ 返回菜单」处按回车，让菜单走到 exec 那条路上
    run bash -c "printf '${solo}\n\n' | /opt/oneserver/bin/oneserver menu"
    [ "${status}" -eq 0 ]
    # 分组节点必须在派发前弹出栈：exec 之后 menu_stack_restore 恢复出的栈顶
    # 若还是这个分组，自动跳过那段会再派发一次，用户回不到上一层
    [ "$(grep -c 'SOLO-RAN' <<<"${output}" || true)" -eq 1 ]
}

@test "菜单状态面板只标注不是实时的数据" {
    run bash -c '/opt/oneserver/bin/oneserver menu </dev/null'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"已装"* ]]
    # 每行都缀一个「（实时）」是同一句话说六遍。这条规则防的是把缓存当实时读，
    # 因此实时的一个字不标，非实时的逐项标注（「缓存 · 3分钟前」）
    [[ "${output}" != *"（实时）"* ]]
}

@test "菜单状态面板把 CPU 型号放在第二项" {
    local screen system_line cpu_line uptime_line
    screen=$(menu_screen '\n')
    system_line=$(grep -n '系统' <<<"${screen}" | head -1)
    cpu_line=$(grep -n 'CPU' <<<"${screen}" | head -1)
    uptime_line=$(grep -n '已运行' <<<"${screen}" | head -1)
    [ -n "${system_line}" ]
    [ -n "${cpu_line}" ]
    [ -n "${uptime_line}" ]
    [ "${system_line%%:*}" -lt "${cpu_line%%:*}" ]
    [ "${cpu_line%%:*}" -lt "${uptime_line%%:*}" ]
}

@test "菜单按编号派发" {
    # 两层的编号都按各自屏幕从 1 数起，900 是夹具的 @order，绝不能当输入编号
    local tb echo_n
    tb=$(menu_num "$(menu_screen '\n')" '工具箱')
    [ -n "${tb}" ]
    echo_n=$(menu_num "$(menu_screen "${tb}\n")" '端到端回显')
    [ -n "${echo_n}" ]
    run bash -c "printf '${tb}\n${echo_n}\n' | /opt/oneserver/bin/oneserver menu"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ECHO:"* ]]
}

@test "clean overview 是只读的：跑完什么都没少" {
    [ -d /opt/oneserver ] || skip '需要装好的 /opt/oneserver'
    mkdir -p /opt/oneserver/tmp
    printf 'x\n' >/opt/oneserver/tmp/leftover
    run bash -c '/opt/oneserver/bin/oneserver clean --action=overview --non-interactive'
    [ "${status}" -eq 0 ]
    # 默认动作只报告。它要是动了手，这个文件就没了
    [ -f /opt/oneserver/tmp/leftover ]
    [[ "${output}" == *'可以直接清'* ]]
    [[ "${output}" == *'只报告，不在这里删'* ]]
    rm -rf /opt/oneserver/tmp
}

@test "clean 的 json 信封字段齐全" {
    [ -d /opt/oneserver ] || skip '需要装好的 /opt/oneserver'
    run bash -c '/opt/oneserver/bin/oneserver clean --action=overview --non-interactive --output=json'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"safe_kb"'* ]]
    [[ "${output}" == *'"orphan_archives"'* ]]
}

@test "菜单不复述用户自己的中断" {
    local tb sig
    tb=$(menu_num "$(menu_screen '\n')" '工具箱')
    [ -n "${tb}" ]
    sig=$(menu_num "$(menu_screen "${tb}\n")" '端到端中断')
    [ -n "${sig}" ]
    run bash -c "printf '${tb}\n${sig}\n\n' | /opt/oneserver/bin/oneserver menu"
    [[ "${output}" == *"SIG-RAN"* ]]
    # errors.sh 已经在屏幕上打过「被 INT 打断，已停止执行」，菜单再说一遍是
    # 第三次 —— 而它用的是 os::warn，那一遍会被当成异常送进面板
    [[ "${output}" != *"上一条命令以退出码"* ]]
}

@test "菜单收纳：虚拟分组展开后显示其成员" {
    local tb
    tb=$(menu_num "$(menu_screen '\n')" '工具箱')
    [ -n "${tb}" ]
    run bash -c "printf '${tb}\n\n' | /opt/oneserver/bin/oneserver menu"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"工具箱"* ]]
    [[ "${output}" == *"端到端回显"* ]]
}

@test "有下级的命令在自己那一屏用 @self_name，不重复上一层的名字" {
    local tb screen p inner
    tb=$(menu_num "$(menu_screen '\n')" '工具箱')
    [ -n "${tb}" ]

    # 上一层用 @name
    screen=$(menu_screen "${tb}\n")
    [[ "${screen}" == *"父命令外层名"* ]]
    [[ "${screen}" != *"父命令本项名"* ]]

    p=$(menu_num "${screen}" '父命令外层名')
    [ -n "${p}" ]

    # 进去之后，父条目自己那一项换成 @self_name —— 标题栏这时已经写着
    # 「… › 父命令外层名」，第一项再叫一次就是同一个词说两遍
    inner=$(menu_screen "${tb}\n${p}\n")
    [[ "${inner}" == *"父命令本项名"* ]]
    [[ "${inner}" == *"子命令"* ]]
}

@test "菜单里输入不存在的编号，三次后以退出码 2 结束" {
    run bash -c 'printf "777\n777\n777\n" | /opt/oneserver/bin/oneserver menu'
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"这一屏没有编号 777"* ]]
    [[ "${output}" == *"连续三次没有给出这一屏存在的编号"* ]]
}

@test "菜单里直接回车即退出，退出码 0" {
    run bash -c 'printf "\n" | /opt/oneserver/bin/oneserver menu'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"已退出"* ]]
}

# --- 前端零外观代码 ---

@test "前端源码里没有 ANSI 序列、边框字符与 ui:: 调用" {
    local f
    for f in /opt/oneserver/bin/oneserver /opt/oneserver/bin/oneserver-menu; do
        run grep -nE '\\033\[|\\e\[|tput setaf|ui::' "${f}"
        [ "${status}" -ne 0 ]
    done
}

# --- doctor---

@test "doctor 跑得起来，各小节都在" {
    run /opt/oneserver/bin/oneserver doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"本工具"* ]]
    [[ "${output}" == *"系统"* ]]
    [[ "${output}" == *"已装组件"* ]]
    [[ "${output}" == *"网络与安全"* ]]
}

@test "doctor 逐项标注数据来源" {
    run /opt/oneserver/bin/oneserver doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"（实时）"* ]]
    [[ "${output}" == *"（本地）"* ]]
}

@test "doctor 里没有一处直调 systemctl / df / free / dpkg-query / ss" {
    # 排除注释：文件开头那段说明里就写着这几个名字，而「说明自己不用它们」
    # 恰恰是要保住的东西。这条检查针对的是代码（计划规范的验收线）
    run bash -c "grep -v '^[[:space:]]*#' /opt/oneserver/script/ops/doctor.sh \
        | grep -nE '(^|[^a-z_.-])(systemctl|dpkg-query|dpkg |df |free |ss )'"
    [ "${status}" -ne 0 ]
}

@test "doctor --output json 的 stdout 是一个能被解析的 JSON，且带 items" {
    run bash -c "/opt/oneserver/bin/oneserver doctor --output json 2>/dev/null | python3 -m json.tool"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"schema"'* ]]
    [[ "${output}" == *'"items"'* ]]
    [[ "${output}" == *'"id": "self.version"'* ]]
}

@test "doctor --bundle 打出可直接贴 issue 的文本" {
    run /opt/oneserver/bin/oneserver doctor --bundle
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"诊断打包"* ]]
    [[ "${output}" == *"最近日志"* ]]
}

@test "doctor --bundle --output json 时 stdout 仍是合法 JSON" {
    run bash -c "/opt/oneserver/bin/oneserver doctor --bundle --output json 2>/dev/null | python3 -m json.tool"
    [ "${status}" -eq 0 ]
}

# --- --output json 时呈现层整层静默 ---

@test "json 模式下 os::run 与 os::info 的字一个都不上 stdout" {
    run bash -c "/opt/oneserver/bin/oneserver selftest noise --output json 2>/dev/null | python3 -m json.tool"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"note": "ok"'* ]]
    [[ "${output}" != *"造点噪声"* ]]
    [[ "${output}" != *"进行中"* ]]
}

@test "secure get 的 JSON stdout 只有信封，凭据值在 data 里" {
    printf '%s\n' "global.test='quoted-\"secret\\\\value'" >/opt/oneserver/secure.conf
    chmod 0600 /opt/oneserver/secure.conf
    run bash -c "/opt/oneserver/bin/oneserver secure get global.test --output json 2>/dev/null | python3 -c \"import json,sys; data=json.load(sys.stdin); assert data['data']['key'] == 'global.test'; assert data['data']['value'] == 'quoted-\\\"secret' + chr(92) + 'value'; print('ok')\""
    [ "${status}" -eq 0 ]
    [ "${output}" = 'ok' ]
}

@test "text 模式下那些字照常出现" {
    run /opt/oneserver/bin/oneserver selftest noise
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"造点噪声"* ]]
    [[ "${output}" == *"进行中"* ]]
}

@test "--output 值非法时以退出码 2 拒绝" {
    run /opt/oneserver/bin/oneserver doctor --output yaml
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"只支持 text 或 json"* ]]
}

@test "doctor 分得清「装了没跑」与「根本没装」" {
    # `systemctl is-active` 对这两种情形都说 inactive，只看退出码会把
    # 「装了没跑」写成「没装」—— 而这正是 doctor 最该说清的一行
    mkdir -p /opt/oneserver/state
    printf 'demo\tversion\t1\ndemo\tunit\text:systemd-journald.service\ndemo\tunit\text:no-such-unit.service\n' \
        >/opt/oneserver/state/components.tsv
    run /opt/oneserver/bin/oneserver doctor
    rm -f /opt/oneserver/state/components.tsv
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"systemd-journald.service"* ]]
    [[ "${output}" == *"运行中"* ]]
    [[ "${output}" == *"no-such-unit.service"* ]]
    [[ "${output}" == *"未安装"* ]]
}

# --- ui preview---

@test "ui preview 一屏展示全部语义元素" {
    run bash -c '/opt/oneserver/bin/oneserver ui preview </dev/null'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"消息"* ]]
    [[ "${output}" == *"键值"* ]]
    [[ "${output}" == *"表格"* ]]
    [[ "${output}" == *"菜单"* ]]
    [[ "${output}" == *"强调块"* ]]
    [[ "${output}" == *"错误块"* ]]
    [[ "${output}" == *"进度"* ]]
    [[ "${output}" == *"确认提示"* ]]
    # 菜单那节要摆全真实主屏的元素，否则「看到的即是真的」名不副实
    [[ "${output}" == *"已装"* ]]
    [[ "${output}" == *"›"* ]]
    [[ "${output}" == *"编号或命令名直达"* ]]
}

@test "ui preview 的确认提示是真的 os::confirm，问句在" {
    run bash -c '/opt/oneserver/bin/oneserver ui preview </dev/null'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"选什么都不会有副作用"* ]]
    [[ "${output}" == *"[y/N]"* ]]
}

@test "ui preview 自己是零外观代码" {
    run bash -c "grep -nE '\\033\[|\\e\[|tput setaf|ui::|OS_THEME_|─|│|┌' \
        /opt/oneserver/script/ops/ui_preview.sh"
    [ "${status}" -ne 0 ]
}

@test "ui preview --no-color 下不出现任何 ANSI 序列" {
    run bash -c '/opt/oneserver/bin/oneserver ui preview --no-color </dev/null | grep -c $'"'"'\033'"'"' || true'
    [[ "${output}" == *"0"* ]]
}

# --- shell 补全---

@test "__complete 无输入时给出顶层命令词，且去重" {
    run /opt/oneserver/bin/oneserver __complete
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"firewall"* ]]
    [[ "${output}" == *"doctor"* ]]
    [[ "${output}" == *"menu"* ]]
    [[ "${output}" == *"completion"* ]]
    # selftest echo 与 selftest noise 共享首词，只能出现一次
    [ "$(printf '%s\n' "${output}" | grep -cx 'selftest')" -eq 1 ]
}

@test "__complete 给出下一个命令词，不给整条命令" {
    run /opt/oneserver/bin/oneserver __complete selftest
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"echo"* ]]
    [[ "${output}" == *"noise"* ]]
    [[ "${output}" != *"selftest echo"* ]]
}

@test "__complete 在完整命令之后补该命令的 @args 与全局参数" {
    run /opt/oneserver/bin/oneserver __complete doctor
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--bundle"* ]]
    [[ "${output}" == *"--dry-run"* ]]
    [[ "${output}" == *"--output"* ]]
}

@test "__complete 忽略已输入的选项，仍按命令路径补" {
    run /opt/oneserver/bin/oneserver __complete firewall --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--ports"* ]]
}

@test "__complete 认得两个词的命令（ui preview）" {
    run /opt/oneserver/bin/oneserver __complete ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"preview"* ]]
}

@test "completion bash 打出的脚本本身语法正确且能挂上 os" {
    run bash -c '/opt/oneserver/bin/oneserver completion bash > /tmp/comp.bash && bash -n /tmp/comp.bash'
    [ "${status}" -eq 0 ]
    run grep -c 'complete -F _oneserver_complete oneserver os' /tmp/comp.bash
    [[ "${output}" == *"1"* ]]
}

@test "completion 的候选真能被 compgen 按前缀筛出来" {
    run bash -c 'PATH=/opt/oneserver/bin:$PATH
        source /tmp/comp.bash
        COMP_WORDS=(oneserver doc)
        COMP_CWORD=1
        _oneserver_complete
        printf "%s\n" "${COMPREPLY[@]}"'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"doctor"* ]]
    [[ "${output}" != *"firewall"* ]]
}

@test "completion 参数非法以退出码 2 拒绝" {
    run /opt/oneserver/bin/oneserver completion fish
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"bash|zsh"* ]]
}
