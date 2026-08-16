#!/usr/bin/env bats
#
# lib/bootstrap.sh 的单元测试
#
# 这是脚本唯一的接入点，几乎每条都得在**真进程**里测：它要装 trap、要取锁、
# 要按 @privilege 校验 EUID，同进程调函数一样也测不出来。
#
# 重点在两处最容易做错的地方：
#   * --non-interactive 缺参数时必须以退出码 2 停下，**不能替用户做选择**（K2 的教训）
#   * --yes 对不可逆操作**不生效**

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    OS_TEST_ROOT="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${OS_TEST_ROOT}"
}

# 造一个符合规范的脚本，正文由参数给出
make_script() {
    local body=${1} meta=${2-}
    local f="${BATS_TEST_TMPDIR}/case-${RANDOM}${RANDOM}.sh"
    cat >"${f}" <<EOF
#!/bin/bash
#
# 测试用脚本
#
# @command      test case
# @name         测试用例
# @group        env
# @order        10
# @privilege    any
# @requires_lib >= 1.0
# @args         [--flag] --value=<v>
# @description  一句话说明
${meta}
#

set -Eeuo pipefail
IFS=\$'\n\t'
umask 027

# 把落点全部挪进临时目录，别动真机
OS_TEST_TMP="${BATS_TEST_TMPDIR}"
source "${OS_TEST_REPO_ROOT}/lib/bootstrap.sh"
OS_LOG_DIR="\${OS_TEST_TMP}/log"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
OS_STATE_DIR="\${OS_TEST_TMP}/state"
OS_STATE_FILE="\${OS_STATE_DIR}/components.tsv"
OS_PUBLIC_DIR="\${OS_TEST_TMP}/public"
OS_PROBE_SNAPSHOT="\${OS_PUBLIC_DIR}/probe.tsv"
log::init test

${body}
EOF
    printf '%s' "${f}"
}

# --- 装配 ---

@test "source 之后 L0–L3 全部就位" {
    local f
    f=$(make_script '
declare -F ui::width  >/dev/null || exit 21
declare -F log::write >/dev/null || exit 22
declare -F os::run    >/dev/null || exit 23
declare -F os::defer  >/dev/null || exit 24
declare -F os::lock_acquire >/dev/null || exit 25
declare -F os::secure_get   >/dev/null || exit 26
declare -F os::state_set    >/dev/null || exit 27
declare -F os::sql_ident    >/dev/null || exit 28
declare -F os::systemd_enable >/dev/null || exit 29
declare -F probe::os_id     >/dev/null || exit 30
echo assembled
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *assembled* ]]
}

@test "平台边界接受全部 Debian 与 Ubuntu 版本" {
    local f
    f=$(make_script '
os::__platform_supported debian 8
os::__platform_supported debian 13
os::__platform_supported ubuntu 18.04
os::__platform_supported ubuntu 24.04
! os::__platform_supported rhel 9
! os::__platform_supported "" ""
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
}

@test "普通用户首次运行没有快照时仍能从公开系统身份完成平台检查" {
    local f
    f=$(make_script '
probe::os_id() { OS_PROBE_VALUE=""; OS_PROBE_STATUS=unavailable; }
os::__check_distro
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
}

@test "呈现语义函数都在" {
    local f
    f=$(make_script '
for fn in os::info os::ok os::warn os::err os::debug os::die os::section \
          os::screen_heading os::kv os::table os::menu_render os::progress os::spacer \
          os::prompt; do
    declare -F "$fn" >/dev/null || { echo "missing $fn"; exit 1; }
done
echo ok
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
}

# 用户输入永远另起一行，且那一行的符号只属于它。同一个符号既当问题行首
# 又当输入行首时，屏幕上一串一模一样的开头，分不出哪行是工具问的。
@test "prompt: 问题一行、输入符另起一行，且一律走 stderr" {
    local f
    # bats 的 run 默认把 stderr 并进 output，所以分流要在被测脚本里做
    # stdout 上一个字都不该有 —— 那是 os::run_out 的返回值通道
    f=$(make_script 'os::prompt "库名" 0 2>/dev/null; printf "\n"')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'库名'* ]]

    f=$(make_script 'os::prompt "库名" 0; printf "\n"')
    run bash "${f}"
    [[ "${output}" == *$'库名\n'* ]]
}

@test "元数据被解析出来" {
    local f
    f=$(make_script '
[ "${OS_META_COMMAND}" = "test case" ] || exit 21
[ "${OS_META_PRIVILEGE}" = "any" ]     || exit 22
[ -n "${OS_META_DESCRIPTION}" ]        || exit 23
echo parsed
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
}

# --- 全局参数---

@test "--help 输出后以 0 退出" {
    local f
    f=$(make_script 'echo should-not-reach')
    run bash "${f}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" != *should-not-reach* ]]
    [[ "${output}" == *'--dry-run'* ]]
}

@test "--dry-run 置位且真的不执行副作用" {
    local marker="${BATS_TEST_TMPDIR}/dry-marker"
    local f
    f=$(make_script "
[ \"\${OS_DRYRUN}\" -eq 1 ] || exit 21
os::run '建文件' -- touch '${marker}'
echo done
")
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    [ ! -e "${marker}" ]
}

@test "--verbose 打开 debug 级别" {
    local f
    f=$(make_script '[ "${OS_LOG_LEVEL}" = debug ] || exit 21; echo ok')
    run bash "${f}" --verbose
    [ "${status}" -eq 0 ]
}

@test "脚本自己的 @args 被收进 OS_ARG_MAP，位置参数原样还给脚本" {
    local f
    f=$(make_script '
[ "${OS_ARG_MAP[value]}" = "8.3" ] || exit 21
[ "${OS_ARG_MAP[flag]}"  = "1" ]   || exit 22
[ "$#" -eq 2 ] || exit 23
[ "$1" = "alpha" ] || exit 24
[ "$2" = "beta" ]  || exit 25
echo ok
')
    run bash "${f}" --value=8.3 --flag alpha beta
    [ "${status}" -eq 0 ]
}

# --- 交互（规范）---

@test "ask: 命令行给了参数就用它，不提示" {
    local f
    f=$(make_script '
os::ask --arg value "监听地址" addr "127.0.0.1"
[ "${addr}" = "0.0.0.0" ] || exit 21
echo ok
')
    run bash "${f}" --value=0.0.0.0 --non-interactive
    [ "${status}" -eq 0 ]
}

@test "ask: --non-interactive 且无参数时取默认值" {
    local f
    f=$(make_script '
os::ask --arg value "监听地址" addr "127.0.0.1"
[ "${addr}" = "127.0.0.1" ] || exit 21
echo ok
')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 0 ]
}

@test "ask: --non-interactive 无参数也无默认值时以退出码 2 停下" {
    # 这条是 K2 的教训：宁可停下，也不能替用户做他没同意的选择
    local f
    f=$(make_script '
os::ask --arg value "必须给个值" v
echo should-not-reach
')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 2 ]
    [[ "${output}" != *should-not-reach* ]]
    [[ "${output}" == *'--value'* ]]
}

# 终端里复制路径会连着引号一起带出来（"/root/x/"）。要用户每次自己删，
# 是把工具的毛病转嫁给人
@test "ask: 交互输入整个被引号包住时剥掉引号" {
    local f
    f=$(make_script '
os::ask --match "^/" --hint "要绝对路径" --arg path "目录" p
[ "${p}" = "/root/oneserver-src/" ] || exit 21
echo ok
')
    run bash "${f}" <<< '"/root/oneserver-src/"'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *ok* ]]
}

@test "ask: 命令行参数带引号同样剥掉" {
    local f
    f=$(make_script '
os::ask --match "^/" --arg path "目录" p
[ "${p}" = "/srv/data" ] || exit 21
echo ok
')
    run bash "${f}" --path='"/srv/data"' --non-interactive
    [ "${status}" -eq 0 ]
}

@test "ask: 单引号也认" {
    local f
    f=$(make_script '
os::ask --match "^/" --arg path "目录" p
[ "${p}" = "/srv/data" ] || exit 21
echo ok
')
    run bash "${f}" --path="'/srv/data'" --non-interactive
    [ "${status}" -eq 0 ]
}

# 现实里的 docker run 基本都是带 `\` 换行的多行格式。不支持的后果不是
# 「只读到第一行」那么轻：剩下几行留在 stdin 里，会被后面几个 os::ask 依次读走
@test "ask --multiline: 行尾反斜杠续行，按 shell 规则拼接" {
    local f
    f=$(make_script '
os::ask --multiline --arg value "命令" v
[ "${v}" = "docker run -d --name web -p 3001:3001 xream/sub-store" ] || { printf "got=[%s]\n" "${v}"; exit 21; }
echo ok
')
    run bash "${f}" <<'IN'
docker run -d \
--name web \
-p 3001:3001 \
xream/sub-store
IN
    [ "${status}" -eq 0 ]
    [[ "${output}" == *ok* ]]
}

# 拼接不补空格：shell 里 `\` 加换行等于什么都没有，补了就与用户在终端里
# 敲同一条命令的结果不一致
@test "ask --multiline: 反斜杠前没有空格时不补空格" {
    local f
    f=$(make_script '
os::ask --multiline --arg value "命令" v
[ "${v}" = "abcdef" ] || { printf "got=[%s]\n" "${v}"; exit 21; }
echo ok
')
    run bash "${f}" <<'IN'
abc\
def
IN
    [ "${status}" -eq 0 ]
}

# 没给 --multiline 的调用点行为必须一个字都不变
@test "ask: 不给 --multiline 时行尾反斜杠原样留着" {
    local f
    f=$(make_script '
os::ask --arg value "命令" v
[ "${v}" = "abc\\" ] || { printf "got=[%s]\n" "${v}"; exit 21; }
echo ok
')
    run bash "${f}" <<'IN'
abc\
def
IN
    [ "${status}" -eq 0 ]
}

# 粘到一半断掉：stdin 到头就停，把那个反斜杠留给 --validate 拒绝，
# 不能在这里空转等一个永远不来的下一行
@test "ask --multiline: stdin 到头即停，不挂起" {
    local f
    f=$(make_script '
os::ask --multiline --arg value "命令" v
[ "${v}" = "abc" ] || { printf "got=[%s]\n" "${v}"; exit 21; }
echo ok
')
    run bash "${f}" <<'IN'
abc\
IN
    [ "${status}" -eq 0 ]
}

# 值中间的引号是内容的一部分，剥它就是篡改用户输入
@test "ask: 只剥整体包裹的引号，值中间的一个不动" {
    local f
    f=$(make_script '
os::ask --arg value "排除" v
[ "${v}" = "a\"b" ] || exit 21
echo ok
')
    run bash "${f}" --value='a"b' --non-interactive
    [ "${status}" -eq 0 ]
}

@test "ask: 漏写 --arg 直接以退出码 2 拒绝" {
    local f
    f=$(make_script 'os::ask "没有 arg" v; echo should-not-reach')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 2 ]
}

@test "confirm: --yes 让普通确认点通过" {
    local f
    f=$(make_script 'os::confirm --arg flag "继续?" n && echo yes || echo no')
    run bash "${f}" --yes
    [[ "${output}" == *yes* ]]
}

@test "confirm: --non-interactive 取默认值，降安全的默认必须是 n" {
    local f
    f=$(make_script 'os::confirm --arg flag "开到公网?" n && echo yes || echo no')
    run bash "${f}" --non-interactive
    [[ "${output}" == *no* ]]

    f=$(make_script 'os::confirm --arg flag "继续?" y && echo yes || echo no')
    run bash "${f}" --non-interactive
    [[ "${output}" == *yes* ]]
}

@test "confirm: 命令行参数优先于 --yes 与默认值" {
    local f
    f=$(make_script 'os::confirm --arg flag "继续?" y && echo yes || echo no')
    run bash "${f}" --flag=no --non-interactive
    [[ "${output}" == *no* ]]
}

@test "ask: 默认值是空串也算「有默认值」" {
    # `os::ask --arg from '限制来源（留空表示不限制）' from ''` —— 默认值就是空串。
    # 按「default 是不是空」判的话，它与「根本没给默认值」无法区分，
    # --non-interactive 会以退出码 2 拒绝一条完全合法的调用。试点的 --from 就是这么卡住的
    local f
    f=$(make_script '
v=unset
os::ask --arg value "随便填" v ""
echo "v=[${v}] rc=$?"
')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"v=[]"* ]]
}

@test "ask: 真的没给默认值时仍以退出码 2 停下（K2 的教训不能松）" {
    local f
    f=$(make_script '
os::ask --arg value "必须填" v
echo "不该走到这里"
')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"缺少必需参数 --value"* ]]
}

@test "confirm: 提示语必须真的打出来" {
    # 曾经不是这样：`--arg` 分支 shift 2 之后循环尾又 shift 了一次，
    # 提示语被白白吃掉，屏幕上只剩一个光秃秃的 [y/N]。
    # 一个没有问题的确认提示，用户按 y 是在同意什么？
    local f
    f=$(make_script 'os::confirm --arg flag "要继续吗" n || true')
    run bash "${f}" </dev/null
    [[ "${output}" == *"要继续吗"* ]]
    [[ "${output}" == *"[y/N]"* ]]
}

@test "confirm: 默认值 y 时提示语与 [Y/n] 都在" {
    local f
    f=$(make_script 'os::confirm --arg flag "要继续吗" y || true')
    run bash "${f}" </dev/null
    [[ "${output}" == *"要继续吗"* ]]
    [[ "${output}" == *"[Y/n]"* ]]
}

# --- 不可逆操作---

@test "destroy_confirm: --yes **不生效**" {
    local f
    f=$(make_script '
if os::destroy_confirm --arg force-destroy "blog" -- "/var/www/blog  1.2 GB" "数据库 wp_blog"; then
    echo DELETED
else
    echo KEPT
fi
')
    run bash "${f}" --yes --non-interactive
    # 没给 --force-destroy，必须以退出码 2 停下，而不是删
    [ "${status}" -eq 2 ]
    [[ "${output}" != *DELETED* ]]
    [[ "${output}" == *'--force-destroy'* ]]
}

@test "destroy_confirm: --force-destroy 才放行" {
    local f
    f=$(make_script '
if os::destroy_confirm --arg force-destroy "blog" -- "/var/www/blog"; then
    echo DELETED
else
    echo KEPT
fi
')
    run bash "${f}" --force-destroy --non-interactive
    [[ "${output}" == *DELETED* ]]
}

@test "destroy_confirm: 打印完整清单，不是概括" {
    local f
    f=$(make_script '
os::destroy_confirm --arg force-destroy "blog" -- "/var/www/blog  1.2 GB  8432 个文件" "数据库 wp_blog  142 MB" || true
')
    run bash "${f}" --force-destroy --non-interactive
    [[ "${output}" == *'/var/www/blog  1.2 GB  8432 个文件'* ]]
    [[ "${output}" == *'数据库 wp_blog  142 MB'* ]]
}

@test "destroy_confirm: dry-run 打清单但不放行" {
    local f
    f=$(make_script '
if os::destroy_confirm --arg force-destroy "blog" -- "/var/www/blog"; then
    echo DELETED
else
    echo KEPT
fi
')
    run bash "${f}" --dry-run --force-destroy --non-interactive
    [[ "${output}" == *'/var/www/blog'* ]]
    [[ "${output}" == *KEPT* ]]
    [[ "${output}" != *DELETED* ]]
}

# --- JSON 信封---

@test "--output json: 呈现层整层静默，stdout 只有信封" {
    local f
    f=$(make_script '
os::info "这行不该出现在 stdout"
os::ok "这行也是"
os::section "标题"
os::kv a b
os::output 0 version=8.3 method=apt
')
    run bash "${f}" --output json
    [ "${status}" -eq 0 ]
    # stdout 必须**只有**信封：第一个字符是 {，最后一个是 }，中间不夹别的行。
    # （文案本身会出现在 messages 里，那是对的 —— 所以不能拿「文案没出现」当断言）
    [ "${#lines[@]}" -eq 1 ]
    [[ "${output}" == '{'*'}' ]]
    run bash -c "bash '${f}' --output json | python3 -c '
import json,sys
e = json.load(sys.stdin)
assert e[\"schema\"] == 1, e
assert e[\"command\"] == \"test case\", e
assert e[\"ok\"] is True, e
assert e[\"exit_code\"] == 0, e
assert e[\"data\"][\"version\"] == \"8.3\", e
assert e[\"data\"][\"method\"] == \"apt\", e
assert any(m[\"text\"].startswith(\"这行不该\") for m in e[\"messages\"]), e
print(\"ok\")
'"
    [ "${output}" = 'ok' ]
}

@test "--output json: 信封里的特殊字符仍是合法 JSON" {
    local f
    f=$(make_script '
os::warn "带\"引号\"、反斜杠 \\ 与换行"
os::output 1 note="a\"b"
')
    run bash -c "bash '${f}' --output json | python3 -c 'import json,sys; json.load(sys.stdin); print(\"ok\")'"
    [ "${output}" = 'ok' ]
}

# --- 前置检查---

@test "privilege root 且非 root 执行时以退出码 4 终止" {
    [ "$(id -u)" -eq 0 ] || skip '当前不是 root，无法降权构造反例'
    command -v setpriv >/dev/null 2>&1 || skip '没有 setpriv'
    # 放 /tmp 根下而不是 BATS_TEST_TMPDIR：后者的**父目录**是 0700，
    # chmod -R 改不到，nobody 连穿过去都做不到，测出来的就成了「找不到文件」。
    #
    # **lib 也得跟着搬过来。** 只搬脚本、仍从仓库里 source 的话，这条用例就
    # 取决于仓库放在哪：容器里是 /src（人人可穿），而测试机上是 /root/oneserver-src
    # —— /root 是 0700，nobody 穿不过去，bash 在 source 那行就以退出码 1 死掉，
    # 断言看到的是 1 不是 4。**它测的于是变成了「路径可达吗」，不是「权限校验对吗」**。
    # CI 环境下这条断言就是这么红的，GitHub 的 runner 上同理。
    local d="/tmp/os-priv-${RANDOM}${RANDOM}"
    mkdir -p "${d}"
    cp -a "${OS_TEST_REPO_ROOT}/lib" "${d}/lib"
    chmod -R a+rX "${d}"
    local f="${d}/case.sh"
    cat >"${f}" <<EOF
#!/bin/bash
#
# @command      test priv
# @privilege    root
# @requires_lib >= 1.0
# @description  x
#
set -Eeuo pipefail
source "${d}/lib/bootstrap.sh"
echo should-not-reach
EOF
    chmod 0755 "${f}"
    run setpriv --reuid=nobody --regid=nogroup --clear-groups bash "${f}"
    rm -rf "${d}"
    [ "${status}" -eq 4 ]
    [[ "${output}" != *should-not-reach* ]]
    [[ "${output}" == *root* ]]
}

@test "@requires 缺组件时以退出码 3 终止并指明缺哪个" {
    local f
    f=$(make_script 'echo should-not-reach')
    # 组件名要**确定装不上**，不能借用 caddy：下一条用例要的正是「caddy 装着」，
    # 两条对同一个组件提相反的环境要求，在任何装过东西的机器上必有一条红
    sed -i 's|^# @requires_lib >= 1.0$|# @requires     nosuch-component\n# @requires_lib >= 1.0|' "${f}"
    run bash "${f}"
    [ "${status}" -eq 3 ]
    [[ "${output}" == *nosuch-component* ]]
}

# 计划 6.1：state 记的是「本工具装过什么」，而机器上的东西不一定是本工具装的。
# 只查 state 的话，`@requires caddy` 会在一台**装着 caddy** 的机器上报「缺少依赖
# 组件」—— 那正是 D93 / D138 当初绕开 @requires、改用 probe 判断的原因。
# 这里用一个必然装着的 apt 包（dpkg 本身）来守住这条回退。
@test "@requires 在 state 里没有时回退到探测，装着就放行（计划 6.1）" {
    [ "$(id -u)" -eq 0 ] || skip '非 root：探测走缓存，测不到实时路径'
    local f
    f=$(make_script 'echo reached')
    sed -i 's|^# @requires_lib >= 1.0$|# @requires     dpkg\n# @requires_lib >= 1.0|' "${f}"
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *reached* ]]
}

@test "@requires 带实例时不回退探测（问的是某一个实例，探测答不了）" {
    local f
    f=$(make_script 'echo should-not-reach')
    sed -i 's|^# @requires_lib >= 1.0$|# @requires     dpkg:9.9\n# @requires_lib >= 1.0|' "${f}"
    run bash "${f}"
    [ "${status}" -eq 3 ]
    [[ "${output}" != *should-not-reach* ]]
}

@test "@requires_lib 高于当前 API 版本时以退出码 4 终止" {
    local f
    f=$(make_script 'echo should-not-reach')
    sed -i 's|^# @requires_lib >= 1.0$|# @requires_lib >= 99.0|' "${f}"
    run bash "${f}"
    [ "${status}" -eq 4 ]
}

@test "errors 的 trap 装上了：失败会打三段报告" {
    local f
    f=$(make_script 'os::record_change "装了个包"; false')
    run bash "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *'执行失败'* ]]
    [[ "${output}" == *'装了个包'* ]]
    [[ "${output}" == *'oneserver doctor --bundle'* ]]
}

# --- 配置文件覆盖（D51 D53）---

# conf 的加载发生在 source bootstrap.sh 的那一刻，比脚本正文更早，
# 所以没法像别的用例那样「source 完再把路径改到临时目录」。
#
# 也**不该**为此让 paths.sh 认环境变量：D25 砍掉 paths.conf 就是不想让
# root 进程的路径可被外部左右，换成环境变量是同一件事换个入口。
# 正确做法是写真的 /etc/oneserver/ —— 容器本来就是一次性的，这正是它的用途。

# **判据函数与 skip 必须分开。**
#
# 原来这两个 skip 写在 conf_setup 里，而调用点是 `conf=$(conf_setup)` ——
# 命令替换是子 shell，bats 的 skip 只退出那个子 shell，测试正文照跑，
# 拿到的是空的 ${conf}，于是 `>""` 报「No such file or directory」。
# **本该跳过的用例变成了失败**，而且是在容器外才暴露：
# CI 环境（容器外）下这 5 条全红。
#
# 所以判据只返回真假，skip 一律写在测试正文里。
conf_supported() {
    [ "$(id -u)" -eq 0 ] || return 1
    # GitHub 托管的 runner 是一次性 VM，与一次性容器同样安全 ——
    # 认 GITHUB_ACTIONS 而不是 CI=true：后者谁都能在自己机器上设，
    # 而这几条用例会写真的 /etc/oneserver。
    [ -n "${container:-}" ] || [ -f /.dockerenv ] || [ "${GITHUB_ACTIONS:-}" = 'true' ] || return 1
    return 0
}

conf_setup() {
    mkdir -p /etc/oneserver
    printf '%s' '/etc/oneserver/oneserver.conf'
}

conf_teardown() {
    rm -f /etc/oneserver/oneserver.conf 2>/dev/null || true
}

make_conf_script() {
    local f="${BATS_TEST_TMPDIR}/conf-${RANDOM}${RANDOM}.sh"
    cat >"${f}" <<EOF
#!/bin/bash
#
# @command      test conf
# @privilege    any
# @requires_lib >= 1.0
# @description  x
#
set -Eeuo pipefail
source "${OS_TEST_REPO_ROOT}/lib/bootstrap.sh"
${1}
EOF
    printf '%s' "${f}"
}

@test "conf: 已知 key 生效" {
    conf_supported || skip '需要 root，且只在一次性环境里跑（会写真的 /etc/oneserver）'
    local conf
    conf=$(conf_setup)
    printf '# 注释
OS_DEFAULT_DOWNLOAD_RETRIES=9
' >"${conf}"
    chmod 0644 "${conf}"
    local f
    f=$(make_conf_script 'printf "retries=%s
" "${OS_DEFAULT_DOWNLOAD_RETRIES}"')
    run bash "${f}"
    conf_teardown
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'retries=9'* ]]
}

@test "conf: 严格解析，配置里的命令替换不会被执行（K12）" {
    conf_supported || skip '需要 root，且只在一次性环境里跑（会写真的 /etc/oneserver）'
    local conf
    conf=$(conf_setup)
    printf 'OS_DEFAULT_DOWNLOAD_RETRIES=$(touch %s/pwned)
' "${BATS_TEST_TMPDIR}" >"${conf}"
    chmod 0644 "${conf}"
    local f
    f=$(make_conf_script 'printf "retries=%s
" "${OS_DEFAULT_DOWNLOAD_RETRIES}"')
    run bash "${f}"
    conf_teardown
    [ ! -f "${BATS_TEST_TMPDIR}/pwned" ]
    # 值原样存进去，不求值
    [[ "${output}" == *'touch'* ]]
}

@test "conf: 数组下标语法的 key 被拒绝，不触发算术求值里的命令替换" {
    conf_supported || skip '需要 root，且只在一次性环境里跑（会写真的 /etc/oneserver）'
    local conf
    conf=$(conf_setup)
    # `[[ -v key ]]` 与 `printf -v key` 在 key 形如 NAME[subscript] 时会对
    # subscript 做算术求值，而算术求值会展开命令替换——这是比 K12 那条
    # 更隐蔽的一条注入路径，不写死值只是把命令替换搬进了下标里
    printf 'OS_DEFAULT_DOWNLOAD_RETRIES[$(touch %s/pwned)]=1\n' "${BATS_TEST_TMPDIR}" >"${conf}"
    chmod 0644 "${conf}"
    local f
    f=$(make_conf_script 'printf "retries=%s\n" "${OS_DEFAULT_DOWNLOAD_RETRIES}"')
    run bash "${f}"
    conf_teardown
    [ ! -f "${BATS_TEST_TMPDIR}/pwned" ]
    [[ "${output}" == *'不是合法的标识符'* ]]
    # 没被污染：仍是 defaults.sh 里的默认值
    [[ "${output}" == *'retries=5'* ]]
}

@test "conf: 未知 key 忽略并告警，不静默吞掉" {
    conf_supported || skip '需要 root，且只在一次性环境里跑（会写真的 /etc/oneserver）'
    local conf
    conf=$(conf_setup)
    printf 'OS_DEFAULT_NO_SUCH_OPTION=1
' >"${conf}"
    chmod 0644 "${conf}"
    local f
    f=$(make_conf_script 'echo reached')
    run bash "${f}"
    conf_teardown
    [[ "${output}" == *reached* ]]
    [[ "${output}" == *'不是已知配置项'* ]]
}

@test "conf: 权限过宽时拒绝加载，且用回默认值" {
    conf_supported || skip '需要 root，且只在一次性环境里跑（会写真的 /etc/oneserver）'
    local conf
    conf=$(conf_setup)
    printf 'OS_DEFAULT_DOWNLOAD_RETRIES=9
' >"${conf}"
    chmod 0666 "${conf}"
    local f
    f=$(make_conf_script 'printf "retries=%s
" "${OS_DEFAULT_DOWNLOAD_RETRIES}"')
    run bash "${f}"
    conf_teardown
    [[ "${output}" == *'权限'* ]]
    # 没被污染：仍是 defaults.sh 里的 5
    [[ "${output}" == *'retries=5'* ]]
}

@test "conf: 属主不是 root 时拒绝加载" {
    conf_supported || skip '需要 root，且只在一次性环境里跑（会写真的 /etc/oneserver）'
    local conf
    conf=$(conf_setup)
    printf 'OS_DEFAULT_DOWNLOAD_RETRIES=9
' >"${conf}"
    chmod 0644 "${conf}"
    chown nobody "${conf}" 2>/dev/null || { conf_teardown; skip '无法改属主'; }
    local f
    f=$(make_conf_script 'printf "retries=%s
" "${OS_DEFAULT_DOWNLOAD_RETRIES}"')
    run bash "${f}"
    conf_teardown
    [[ "${output}" == *'属主'* ]]
    [[ "${output}" == *'retries=5'* ]]
}

# --- 分层 ---

@test "bootstrap 是全项目唯一的装配点" {
    # 除 bootstrap.sh 与测试 helper 外，lib/ 里不该有 source
    run bash -c "grep -lE '^[[:space:]]*(source|\.)[[:space:]]' '${OS_TEST_REPO_ROOT}'/lib/*.sh \
        | grep -v bootstrap.sh"
    [ "${status}" -ne 0 ]
}

# --- 包管理---

@test "pkg_install: 已装的包一条命令都不跑（幂等）" {
    local f
    f=$(make_script 'os::pkg_install bash coreutils; printf "done\n"')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'done'* ]]
    # 装包会打 desc「安装软件包」，跳过时不该出现
    [[ "${output}" != *'安装软件包'* ]]
}

@test "pkg_install: dry-run 只打算装的那几个，不碰系统" {
    local f
    f=$(make_script 'os::pkg_install bash this-package-does-not-exist')
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    # 已装的 bash 被滤掉，只剩不存在的那个进命令行
    [[ "${output}" == *'this-package-does-not-exist'* ]]
    [[ "${output}" != *'apt-get install -y -qq --no-install-recommends bash '* ]]
    [[ "${output}" == *'[dry-run]'* ]]
}

@test "pkg_install: 源里没有的包以退出码 3 终止，压根不跑 apt" {
    [ "$(id -u)" -eq 0 ] || skip '非 root 时探测拿不到候选版本，走的是降级路径'
    local f
    # 探到「源里没有」是 Ubuntu 才去开 universe，这里固定成 debian，
    # 免得在 Ubuntu 上跑测试真去动那台机器的 apt 源
    f=$(make_script '
probe::os_id() { OS_PROBE_VALUE=debian; }
os::pkg_install this-package-does-not-exist
printf "不该到这行
"')
    run bash "${f}"
    [ "${status}" -eq 3 ]
    [[ "${output}" != *'不该到这行'* ]]
    [[ "${output}" != *'安装软件包'* ]]
    [[ "${output}" == *'this-package-does-not-exist'* ]]
}

# 事前记账的老写法在这里会留一条「apt 安装了 X」，
# 让人去人工处置一件根本没发生的事
@test "pkg_install: apt 失败且一个包都没装上时，变更清单里不留假账" {
    local f
    f=$(make_script '
probe::package_candidate() { OS_PROBE_STATUS=ok; OS_PROBE_VALUE=9.9; }
os::run() { OS_RUN_SKIPPED=0; return 100; }
os::pkg_install this-package-does-not-exist || true
printf "changes=%s
" "${#OS_ERR__CHANGES[@]}"')
    run bash "${f}"
    [[ "${output}" == *'changes=0'* ]]
}

# 反过来那一半：装到一半炸了，真装上的那几个必须登记，
# 否则卸载时它们成了谁也管不到的孤儿
@test "pkg_install: apt 装了一半失败，真装上的仍要登记" {
    local f
    f=$(make_script '
probe::package_candidate() { OS_PROBE_STATUS=ok; OS_PROBE_VALUE=9.9; }
probe::package_installed() {
    if [[ -f ${OS_TEST_TMP}/apt-ran && ${1} == pkg-a ]]; then
        OS_PROBE_VALUE=yes
    else
        OS_PROBE_VALUE=no
    fi
}
os::run() { : >"${OS_TEST_TMP}/apt-ran"; OS_RUN_SKIPPED=0; return 100; }
os::pkg_install pkg-a pkg-b || true
printf "names=[%s]
" "$(os::pkg_installed_names | tr "
" " ")"')
    run bash "${f}"
    [[ "${output}" == *'names=[pkg-a ]'* ]]
}

@test "pkg_install: 空参数是空操作" {
    local f
    f=$(make_script 'os::pkg_install; printf "ok\n"')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'ok'* ]]
}

# 裸文件名会被 apt 当成包名拿去源里搜，而报错里看不出是路径写法的问题
@test "pkg_install_deb: 不含斜杠的文件名补成 ./，交给 apt 的是文件" {
    local f
    f=$(make_script '
cd "${OS_TEST_TMP}" || exit 9
: >x.deb
os::run() { printf "cmd=%s\n" "${*: -1}"; OS_RUN_SKIPPED=0; return 0; }
os::pkg_install_deb x.deb')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'cmd=./x.deb'* ]]
}

@test "pkg_install_deb: 文件不存在时以 1 终止，不跑 apt" {
    local f
    f=$(make_script '
os::pkg_install_deb "${OS_TEST_TMP}/nope.deb"
printf "不该到这行\n"')
    run bash "${f}"
    [ "${status}" -eq 1 ]
    [[ "${output}" != *'不该到这行'* ]]
    [[ "${output}" != *'安装本地软件包'* ]]
}

# dry-run 下下载没真跑，文件本就不存在 —— 这时报错是拿预演当失败
@test "pkg_install_deb: dry-run 不因文件不存在而失败，也不装" {
    local f
    f=$(make_script 'os::pkg_install_deb "${OS_TEST_TMP}/nope.deb"; printf "ok\n"')
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'[dry-run]'* ]]
    [[ "${output}" == *'ok'* ]]
}

@test "pkg_install_deb: apt 失败时变更清单里不留假账" {
    local f
    f=$(make_script '
cd "${OS_TEST_TMP}" || exit 9
: >x.deb
os::run() { OS_RUN_SKIPPED=0; return 100; }
os::pkg_install_deb x.deb || true
printf "changes=%s\n" "${#OS_ERR__CHANGES[@]}"')
    run bash "${f}"
    [[ "${output}" == *'changes=0'* ]]
}

# --- os::ask_secret---

@test "ask_secret: 从 stdin 读，不回显，值进变量" {
    local f
    f=$(make_script '
os::ask_secret "请输入密码" pw
[ "${pw}" = "hunter2hunter2" ] || exit 21
echo ok
')
    run bash "${f}" <<< 'hunter2hunter2'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *ok* ]]
    # 回显是 read -rs 的事，这里守的是「密码没有被原样打回屏幕」
    [[ "${output}" != *hunter2hunter2* ]]
}

@test "ask_secret: --confirm 两次不一致会重问" {
    local f
    f=$(make_script '
os::ask_secret --confirm "请输入密码" pw
[ "${pw}" = "secondsecond" ] || exit 21
echo ok
')
    run bash "${f}" <<< $'firstfirst\nmismatchmm\nsecondsecond\nsecondsecond'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'两次输入不一致'* ]]
}

@test "ask_secret: 连续三次空值以退出码 2 停下" {
    local f
    f=$(make_script 'os::ask_secret "请输入密码" pw; echo should-not-reach')
    run bash "${f}" <<< $'\n\n\n'
    [ "${status}" -eq 2 ]
    [[ "${output}" != *should-not-reach* ]]
}

@test "ask_secret: --non-interactive 下以退出码 2 停下（凭据没有默认值）" {
    local f
    f=$(make_script 'os::ask_secret "请输入密码" pw; echo should-not-reach')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 2 ]
    [[ "${output}" != *should-not-reach* ]]
}

@test "ask_secret: 不认命令行取值 —— 凭据禁止进 argv" {
    # --value 是 @args 里声明过的参数，os::ask 会认它；ask_secret 必须不认，
    # 否则「密码可以写在命令行上」这条路就又通了
    local f
    f=$(make_script '
os::ask_secret "请输入密码" pw
[ "${pw}" = "fromstdin1" ] || exit 21
echo ok
')
    run bash "${f}" --value=fromargv1 <<< 'fromstdin1'
    [ "${status}" -eq 0 ]
}

# --- 变量名撞上函数内部的局部名（db_manager 的容器验收撞出来的）---

@test "ask: 目标变量叫 name 也能拿到值（不被函数内部的局部变量吃掉）" {
    local f
    f=$(make_script '
os::ask --arg value "库名" name ""
[ "${name}" = "blog" ] || exit 21
echo ok
')
    # 原来 os::ask 内部有个 `local name` 存 --arg 的名字，printf -v "name"
    # 于是写进了那个局部变量 —— 调用方一个字都没拿到，而且不报错
    run bash "${f}" --value=blog --non-interactive
    [ "${status}" -eq 0 ]
}

@test "ask: 目标变量叫 default / prompt / varname 同样不受影响" {
    local f v
    for v in default prompt varname reply hint; do
        f=$(make_script "
os::ask --arg value '随便' ${v} ''
[ \"\${${v}}\" = 'X' ] || exit 21
echo ok
")
        run bash "${f}" --value=X --non-interactive
        [ "${status}" -eq 0 ]
    done
}

@test "select: 目标变量叫 name 也能拿到值" {
    local f
    f=$(make_script '
os::select --arg value "选一个" name alpha beta
[ "${name}" = "beta" ] || exit 21
echo ok
')
    run bash "${f}" --value=beta --non-interactive
    [ "${status}" -eq 0 ]
}

# 上一条走的是「命令行给了值」的分支，在渲染菜单之前就返回了 —— 交互分支
# 曾经带着一句 `local -__os_i` 上线，语法检查与 shellcheck 都看不见它，
# 而用户看到的是任何一条要选动作的菜单当场报 `local: invalid option`
@test "select: 交互分支按序号取值" {
    local f
    f=$(make_script '
os::select --arg value "选一个" name alpha beta gamma
[ "${name}" = "gamma" ] || exit 21
echo ok
')
    run bash "${f}" <<<'3'
    [ "${status}" -eq 0 ]
}

@test "select: 内部控制值不显示但仍按序号返回" {
    local f
    f=$(make_script '
os::select --arg value "选择" picked "__pick_db__=本机其他数据库（下一步选择）"
[ "${picked}" = "__pick_db__" ] || exit 21
echo ok
')
    run bash "${f}" <<<'1'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'本机其他数据库（下一步选择）'* ]]
    [[ "${output}" != *'__pick_db__'* ]]
}

@test "select: 返回提示由回车触发且不显示 0 号菜单项" {
    local f
    f=$(make_script '
os::select --return back --arg value "操作" choice "run=执行"
[ "${choice}" = "back" ] || exit 21
echo ok
')
    run bash "${f}" <<<$'\n'
    [ "${status}" -eq 0 ]
    # 措辞归渲染层（--nav back），调用方只给「要不要有返回项」这个语义
    [[ "${output}" == *'返回上一层'* ]]
    [[ "${output}" != *'0  返回'* ]]
}

@test "select: 布尔选项显示 Yes/No，并接受选项值与显示值" {
    local f
    f=$(make_script '
os::select --arg value "第一个" first y n
os::select --arg value "第二个" second y n
[ "${first}" = "n" ] || exit 21
[ "${second}" = "y" ] || exit 22
echo ok
')
    run bash "${f}" <<<$'n\nYES'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'Yes'* ]]
    [[ "${output}" == *'No'* ]]
}

@test "select: 输入无效时重问，而非静默回退到第一个选项" {
    local f
    f=$(make_script '
os::select --arg value "选一个" name alpha beta
[ "${name}" = "beta" ] || exit 21
echo ok
')
    run bash "${f}" <<<$'99\n2'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'没有编号或选项为「99」'* ]]
}

@test "select: 连续三次无效输入时以退出码 2 停下" {
    local f
    f=$(make_script 'os::select --arg value "选一个" name alpha beta; echo should-not-reach')
    run bash "${f}" <<<$'wrong\nwrong\nwrong'
    [ "${status}" -eq 2 ]
    [[ "${output}" != *should-not-reach* ]]
}

@test "ask: 有默认值时提示里明说回车会得到什么" {
    # 只打一个 `[8.4]` 的话，屏幕上是一行没有任何动作指示的文字，
    # 用户以为命令卡住了，下一步就是 Ctrl-C —— 而那可能正打在装包中途
    local f
    f=$(make_script 'os::ask --arg value "PHP 版本" v "8.4"; echo "v=${v}"')
    run bash "${f}" <<<''
    [ "${status}" -eq 0 ]
    # 提示末尾那截现在是「⏎ 8.4」——符号归渲染层，这里只认默认值本身
    [[ "${output}" == *'8.4'* ]]
    [[ "${output}" == *'v=8.4'* ]]
}

@test "ask: 没有默认值时标「必填」，空输入重问而不是带着空值往下跑" {
    local f
    f=$(make_script 'os::ask --arg value "端口" v; echo "v=[${v}]"')
    run bash "${f}" <<<$'\n\n2222'
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'必填'* ]]
    [[ "${output}" == *'v=[2222]'* ]]
}

@test "ask: 没有默认值且连续三次空输入时以退出码 2 停下" {
    local f
    f=$(make_script 'os::ask --arg value "端口" v; echo "不该走到这里"')
    run bash "${f}" <<<$'\n\n\n'
    [ "${status}" -eq 2 ]
    [[ "${output}" != *不该走到这里* ]]
}

# --- 多选 ---
#
# 三条拒绝规则各有一条用例，它们都对着一次会**静默**做错事的输入：
# 少打一个 `+` 清空整份清单、把序号写进命令行、序号既挑又排。

@test "multiselect: 非交互且没给参数时全选" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
[ "${got}" = "a,b,c" ] || exit 21
echo ok
')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 0 ]
}

@test "multiselect: 说明列不进结果，值原样返回" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got "a=第一个" "b=第二个"
[ "${got}" = "a,b" ] || exit 21
echo ok
')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 0 ]
}

@test "multiselect: 命令行裸名字 = 完全替换" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
[ "${got}" = "x,y" ] || exit 21
echo ok
')
    run bash "${f}" --pick=y,x --non-interactive
    [ "${status}" -eq 0 ]
}

@test "multiselect: 命令行增删以清单为基线，减按末段匹配" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got ns/a ns/b ns/c
[ "${got}" = "ns/a,ns/c,other/d" ] || exit 21
echo ok
')
    run bash "${f}" --pick=+other/d,-b --non-interactive
    [ "${status}" -eq 0 ]
}

@test "multiselect: none 得到空集" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b
[ -z "${got}" ] || exit 21
echo ok
')
    run bash "${f}" --pick=none --non-interactive
    [ "${status}" -eq 0 ]
}

@test "multiselect: 结果排序去重，输入顺序不影响幂等" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b
[ "${got}" = "a,b" ] || exit 21
echo ok
')
    run bash "${f}" --pick=+b,+a --non-interactive
    [ "${status}" -eq 0 ]
}

@test "multiselect: 裸名字与 +/- 混用以退出码 2 拒绝" {
    # 少打一个 `+` 从前会**静默清空**整份默认清单，到签证书失败那天才发现
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
echo "不该走到这里"
')
    run bash "${f}" --pick=+x,y --non-interactive
    [ "${status}" -eq 2 ]
    [[ "${output}" != *不该走到这里* ]]
    [[ "${output}" == *完全替换* ]]
}

@test "multiselect: 命令行里的序号以退出码 2 拒绝" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
echo "不该走到这里"
')
    run bash "${f}" --pick=1,3 --non-interactive
    [ "${status}" -eq 2 ]
    [[ "${output}" != *不该走到这里* ]]
}

@test "multiselect: 减不掉的项打警告而不是静默忽略" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b
[ "${got}" = "a,b" ] || exit 21
echo ok
')
    run bash "${f}" --pick=-nope --non-interactive
    [ "${status}" -eq 0 ]
    [[ "${output}" == *nope* ]]
}

@test "multiselect: 交互按序号挑选" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c d
[ "${got}" = "a,c" ] || exit 21
echo ok
')
    run bash "${f}" <<<'1,3'
    [ "${status}" -eq 0 ]
}

@test "multiselect: 交互按序号排除" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c d
[ "${got}" = "a,c" ] || exit 21
echo ok
')
    run bash "${f}" <<<'-2,-4'
    [ "${status}" -eq 0 ]
}

@test "multiselect: 交互回车 = 全选" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
[ "${got}" = "a,b,c" ] || exit 21
echo ok
')
    run bash "${f}" <<<''
    [ "${status}" -eq 0 ]
}

@test "multiselect: 交互里序号与 +清单外的名字可以共存" {
    # 「只要 1、3，再加一个清单里没有的」—— 序号引用清单内，+ 引入清单外，
    # 两者语义不冲突。禁掉它就只能把三条全路径手敲一遍，正是要消灭的那件事
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
[ "${got}" = "a,c,zz" ] || exit 21
echo ok
')
    run bash "${f}" <<<'1,3,+zz'
    [ "${status}" -eq 0 ]
}

@test "multiselect: 序号同时用于挑选与排除时以退出码 2 拒绝" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c
echo "不该走到这里"
')
    run bash "${f}" <<<'1,-3'
    [ "${status}" -eq 2 ]
    [[ "${output}" != *不该走到这里* ]]
}

@test "multiselect: 序号越界以退出码 2 拒绝" {
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b
echo "不该走到这里"
')
    run bash "${f}" <<<'5'
    [ "${status}" -eq 2 ]
    [[ "${output}" != *不该走到这里* ]]
}

@test "multiselect: 前导零的序号不会被当成八进制" {
    # `local -i x; x=08` 在算术里直接报 value too great for base
    local f
    f=$(make_script '
os::multiselect --arg pick "选" got a b c d e f g h i
[ "${got}" = "h" ] || exit 21
echo ok
')
    run bash "${f}" <<<'08'
    [ "${status}" -eq 0 ]
}

@test "multiselect: 漏写 --arg 以退出码 2 拒绝" {
    local f
    f=$(make_script 'os::multiselect "没有 arg" got a b; echo "不该走到这里"')
    run bash "${f}" --non-interactive
    [ "${status}" -eq 2 ]
}

@test "ask_secret: 目标变量叫 prompt 也能拿到值" {
    local f
    f=$(make_script '
os::ask_secret "输入" prompt
[ "${prompt}" = "s3cr3tvalue" ] || exit 21
echo ok
')
    run bash "${f}" <<< 's3cr3tvalue'
    [ "${status}" -eq 0 ]
}

# --- 纯开关 ---

@test "flag: 命令行给了开关就是真，没给就是假" {
    local f
    f=$(make_script '
if os::flag --arg flag; then echo given; else echo absent; fi
')
    run bash "${f}" --flag
    [ "${status}" -eq 0 ]
    [[ "${output}" == *given* ]]

    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *absent* ]]
}

# --yes 与 --non-interactive 对它都没有影响：没给就是没给。
# 否则 `--yes` 会把 `--bundle` 这类开关一并打开，而用户从没要过
@test "flag: --yes 不会把没给的开关变成真" {
    local f
    f=$(make_script '
if os::flag --arg flag; then echo given; else echo absent; fi
')
    run bash "${f}" --yes --non-interactive
    [ "${status}" -eq 0 ]
    [[ "${output}" == *absent* ]]
}

@test "flag: 显式给假值就是假" {
    local f
    f=$(make_script '
if os::flag --arg value; then echo given; else echo absent; fi
')
    run bash "${f}" --value=no
    [[ "${output}" == *absent* ]]
    run bash "${f}" --value=0
    [[ "${output}" == *absent* ]]
    run bash "${f}" --value=1
    [[ "${output}" == *given* ]]
}

@test "flag: 忘了 --arg 是用法错误，以 2 停下" {
    local f
    f=$(make_script 'os::flag; echo should-not-reach')
    run bash "${f}"
    [ "${status}" -eq 2 ]
    [[ "${output}" != *should-not-reach* ]]
}

# --- 依赖检查 ---

@test "require_cmd: 命令齐全就放行，缺了以退出码 3 停下并点名" {
    local f
    f=$(make_script 'os::require_cmd sh cat; echo ok')
    run bash "${f}"
    [ "${status}" -eq 0 ]

    f=$(make_script 'os::require_cmd sh os-no-such-cmd another-missing-cmd; echo should-not-reach')
    run bash "${f}"
    # 3 = 依赖缺失，不是 1：调用方据此区分「环境不满足」与「跑失败了」
    [ "${status}" -eq 3 ]
    [[ "${output}" == *os-no-such-cmd* ]]
    [[ "${output}" == *another-missing-cmd* ]]
    [[ "${output}" != *should-not-reach* ]]
}

# --- json 模式下的静默 ---
#
# 信封之外的任何一个字都会让 stdout 不再是合法 JSON，而消费者拿到的是
# 「解析失败」——不是「少了一个字段」。装饰性输出必须整层闭嘴。

@test "box: text 模式下有输出，json 模式下一个字都没有" {
    local f
    f=$(make_script '
os::box "标题" -- "正文一行"
os::output 0
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *标题* ]]

    run bash "${f}" --output=json
    [ "${status}" -eq 0 ]
    [[ "${output}" != *标题* ]]
    [[ "${output}" != *正文一行* ]]
}

# 失败路径的 stdout 若是空的，消费者分不清「命令失败了」和「命令根本没跑起来」——
# 而 ok / exit_code / messages 三个字段正是为回答这件事设计的。
@test "json: 失败路径也发信封，不是空 stdout" {
    local f
    f=$(make_script 'os::die 2 "参数不对"')
    run bash "${f}" --output=json
    [ "${status}" -eq 2 ]
    [[ "${output}" == '{'*'}' ]]
    [[ "${output}" == *'"ok":false'* ]]
    [[ "${output}" == *'"exit_code":2'* ]]
    [[ "${output}" == *参数不对* ]]
}

# 两个对象首尾相接就不再是合法 JSON，而消费者报的是「解析失败」
@test "json: 一次运行只发一个信封" {
    local f
    f=$(make_script '
os::output 0 first=yes
os::output 0 second=yes
')
    run bash "${f}" --output=json
    [ "${status}" -eq 0 ]
    [ "$(printf '%s\n' "${output}" | grep -c '"schema"')" -eq 1 ]
    [[ "${output}" == *first* ]]
    [[ "${output}" != *second* ]]
}

@test "json: text 模式下失败路径不吐 JSON" {
    local f
    f=$(make_script 'os::die 2 "参数不对"')
    run bash "${f}"
    [ "${status}" -eq 2 ]
    [[ "${output}" != *'"exit_code"'* ]]
    [[ "${output}" == *参数不对* ]]
}

@test "output_item: json 下进 items 数组，text 下什么都不做" {
    local f
    f=$(make_script '
os::output_item name=alpha role=db
os::output_item name=beta role=web
os::output 0 count=2
')
    run bash "${f}" --output=json
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"items"'* ]]
    [[ "${output}" == *'"name":"alpha"'* ]]
    [[ "${output}" == *'"role":"web"'* ]]

    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *alpha* ]]
}

@test "output_item: 值里的引号与反斜杠被转义，信封仍是合法 JSON" {
    local f
    f=$(make_script '
os::output_item name="a\"b" path="c\d"
os::output 0
')
    run bash "${f}" --output=json
    [ "${status}" -eq 0 ]
    command -v python3 >/dev/null 2>&1 || skip '没有 python3 当 JSON 裁判'
    printf '%s' "${output}" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

# --- 二级菜单 ---

@test "action_menu: 命令行给了动作就直接派发，不进交互循环" {
    local f
    f=$(make_script '
dispatch() { echo "dispatched=${1}"; }
os::action_menu --arg value "请选择" dispatch "run=执行" "check=检查"
')
    run bash "${f}" --value=run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *dispatched=run* ]]
}

@test "action_menu: 命令行给动作时不执行交互总览" {
    local f
    f=$(make_script '
overview() { echo "overview"; }
dispatch() { echo "dispatched=${1}"; }
os::action_menu --overview overview --arg value "请选择" dispatch "run=执行" "check=检查"
')
    run bash "${f}" --value=run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *dispatched=run* ]]
    [[ "${output}" != *overview* ]]
}

@test "action_menu: 指定不存在的总览函数以 2 拒绝" {
    local f
    f=$(make_script '
dispatch() { :; }
os::action_menu --overview no_such_overview --arg value "请选择" dispatch "run=执行"
')
    run bash "${f}" --value=run
    [ "${status}" -eq 2 ]
}

@test "action_menu: 分发函数不存在时以 2 拒绝，不是跑到一半才发现" {
    local f
    f=$(make_script '
os::action_menu --arg value "请选择" no_such_dispatch "run=执行"
')
    run bash "${f}" --value=run
    [ "${status}" -eq 2 ]
}

@test "action_menu: 缺参数是用法错误" {
    local f
    f=$(make_script '
dispatch() { :; }
os::action_menu "请选择" dispatch "run=执行"
')
    run bash "${f}" --value=run
    [ "${status}" -eq 2 ]
}

# --- 包管理 ---

@test "pkg_purge: 没装的包一个都不传给 apt（幂等）" {
    local f
    f=$(make_script '
os::pkg_purge this-package-does-not-exist another-missing-package
echo returned=$?
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *returned=0* ]]
    # 一次 apt 事务都不该发生 —— 「反正 apt 会说 not installed」也要拿 dpkg 锁
    [[ "${output}" != *'卸载软件包'* ]]
}

@test "pkg_refresh/pkg_purge: dry-run 下不碰 apt" {
    local f
    f=$(make_script '
os::pkg_refresh
os::pkg_purge bash
echo done
')
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *done* ]]
    [[ "${output}" == *'[dry-run]'* ]]
}

@test "pkg_upgrade: dry-run 走统一包边界且不执行 apt" {
    local f
    f=$(make_script '
os::pkg_upgrade
echo skipped=${OS_RUN_SKIPPED}
')
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'升级已安装的软件包'* ]]
    [[ "${output}" == *'skipped=1'* ]]
    [[ "${output}" == *'[dry-run]'* ]]
}

# reinstall 与 install 的幂等方向**相反**：install 见装了就跳过，
# reinstall 要的正是「装着但文件被动过，请 apt 再放一遍」。唯一现实用途是
# dpkg-divert --rename 把包自带的二进制挪走之后，让 apt 补一份回原位。
@test "pkg_reinstall: 没装的包一个都不传给 apt" {
    local f
    f=$(make_script '
os::pkg_reinstall this-package-does-not-exist
echo returned=$?
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *returned=0* ]]
    [[ "${output}" != *'重装软件包'* ]]
}

@test "pkg_reinstall: 已装的包确实交给 apt（与 install 的幂等方向相反）" {
    local f
    f=$(make_script '
os::pkg_reinstall bash
echo done
')
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'重装软件包'* ]]
    [[ "${output}" == *'--reinstall'* ]]
}

@test "pkg_clean: dry-run 下不真清缓存" {
    local f
    f=$(make_script '
os::pkg_clean
echo done
')
    run bash "${f}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *done* ]]
    [[ "${output}" == *'[dry-run]'* ]]
    [[ "${output}" == *'清理 APT 包缓存'* ]]
}

# OS_FROM_MENU 来自环境，而框架拿它拼 OS_MENU_BACK_FLAG 再 `: >` 截断。
# 原样代入的话 `OS_FROM_MENU=../../etc/xxx` 就是一条穿出 /run/oneserver 的
# 路径穿越，被截断的是攻击者点名的那个文件。
@test "OS_FROM_MENU 里的非数字被剔掉，标记路径穿不出 OS_RUN_DIR" {
    run env OS_FROM_MENU='../../tmp/pwned' bash -c "
        source '${OS_TEST_REPO_ROOT}/lib/paths.sh'
        printf '%s\n' \"\${OS_MENU_BACK_FLAG}\""
    [ "${status}" -eq 0 ]
    [[ "${output}" != *'..'* ]]
    [[ "${output}" == "${OS_RUN_DIR:-/run/oneserver}/.menu-back."* ]]
}
