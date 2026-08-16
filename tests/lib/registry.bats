#!/usr/bin/env bats
#
# lib/registry.sh 的单元测试
#
# 注册表是 CLI 与菜单共同的真相源，它错一个字的后果是「命令不存在」或者
# 「敲 A 跑了 B」。重点压这三处：
#
#   * **最长前缀匹配**（D73）：`firewall allow` 里 allow 是位置参数，
#     `install php` 里两个词都是命令 —— 区别只有注册表知道
#   * **IFS 是 $'\n\t'**：脚本头都这么设，而 `${arr[*]}` 用 IFS 首字符连接。
#     不在 resolve 里锁死 IFS=' '，拼出来的 key 用换行连，永远匹配不上
#   * **@requires 不满足要隐藏**：菜单里点得到一条注定失败的命令，
#     比它不出现更糟
#
# registry.sh 不能被单独 source，因此每条用例都造一个
# 真的前端脚本来跑 —— 与 bootstrap.bats 同样的路子，也顺便测了规范的文件头。

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    OS_FIX="${BATS_TEST_TMPDIR}/script"
    mkdir -p "${OS_FIX}/install" "${OS_FIX}/manage"

    OS_GROUPS="${BATS_TEST_TMPDIR}/groups.conf"
    cat >"${OS_GROUPS}" <<'EOF'
# id | 显示名 | order | parent
env | 环境与安装 | 10 |
service | 服务与应用 | 20 |
system | 系统与维护 | 30 |
other | 其他 | 40 | system
EOF
}

# make_cmd <相对路径> <@command> <@group> <@order> [@requires] [@provides]
make_cmd() {
    local rel=${1} cmd=${2} group=${3} order=${4} requires=${5-} provides=${6-}
    local f="${OS_FIX}/${rel}"
    mkdir -p "$(dirname "${f}")"
    {
        printf '#!/bin/bash\n#\n# 测试脚本\n#\n'
        printf '# @command      %s\n' "${cmd}"
        printf '# @name         名字-%s\n' "${order}"
        printf '# @group        %s\n' "${group}"
        printf '# @order        %s\n' "${order}"
        printf '# @privilege    root\n'
        printf '# @requires_lib >= 1.0\n'
        [[ -n ${requires} ]] && printf '# @requires     %s\n' "${requires}"
        [[ -n ${provides} ]] && printf '# @provides     %s\n' "${provides}"
        printf '# @description  说明-%s\n#\n' "${order}"
        printf 'echo "ran %s $*"\n' "${cmd}"
    } >"${f}"
    chmod +x "${f}"
    printf '%s' "${f}"
}

# 造一个规范的前端，正文由参数给出
make_frontend() {
    local body=${1}
    local f="${BATS_TEST_TMPDIR}/front-${RANDOM}${RANDOM}.sh"
    cat >"${f}" <<EOF
#!/bin/bash

set -Eeuo pipefail
IFS=\$'\n\t'
umask 027

OS_BOOT_MODE=frontend
source "${OS_TEST_REPO_ROOT}/lib/bootstrap.sh"

# 落点全部挪进临时目录，别动真机
OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
OS_LOG_MAIN="\${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="\${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="\${OS_LOG_DIR}/audit.log"
OS_STATE_DIR="${BATS_TEST_TMPDIR}/state"
OS_STATE_FILE="\${OS_STATE_DIR}/components.tsv"
OS_STATE_BAK="\${OS_STATE_FILE}.bak"
OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
OS_PROBE_SNAPSHOT="\${OS_PUBLIC_DIR}/probe.tsv"
OS_SCRIPT_DIR="${OS_FIX}"
OS_GROUPS_CONF="${OS_GROUPS}"
log::init test

source "${OS_TEST_REPO_ROOT}/lib/registry.sh"

${body}
EOF
    printf '%s' "${f}"
}

# --- 扫描 ---

@test "scan 收全两层目录下带 @command 的脚本" {
    make_cmd install/a.sh 'install php' env 30 >/dev/null
    make_cmd manage/b.sh 'firewall' system 160 >/dev/null
    printf '#!/bin/bash\n# 没有元数据\n' >"${OS_FIX}/loose.sh"

    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
echo "count=${OS_REG_COUNT}"
echo "max=${OS_REG_MAXWORDS}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"count=2"* ]]
    [[ "${output}" == *"max=2"* ]]
}

@test "scan 保留 @provides 给菜单消费者派生已装程序" {
    make_cmd install/a.sh 'install php' env 30 '' 'php:<version>' >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
printf "provides=[%s]\\n" "${OS_REG_PROVIDES[0]}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"provides=[php:<version>]"* ]]
}

@test "未声明 @provides 的脚本不会继承上一个条目的值" {
    make_cmd install/a.sh 'install php' env 30 '' 'php:<version>' >/dev/null
    make_cmd install/b.sh 'install caddy' env 40 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
printf "first=[%s] second=[%s]\\n" "${OS_REG_PROVIDES[0]}" "${OS_REG_PROVIDES[1]}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"first=[php:<version>] second=[]"* ]]
}

@test "@command 内部多余空白归一成单个空格" {
    make_cmd install/a.sh 'install    php' env 30 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
printf "cmd=[%s]\n" "${OS_REG_COMMAND[0]}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cmd=[install php]"* ]]
}

@test "@command 重复时保留先扫到的并告警" {
    make_cmd install/a.sh 'install php' env 30 >/dev/null
    make_cmd install/b.sh 'install php' env 40 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
echo "count=${OS_REG_COUNT}"
echo "file=${OS_REG_FILE[0]##*/}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"count=1"* ]]
    [[ "${output}" == *"file=a.sh"* ]]
    [[ "${output}" == *"重复"* ]]
}

# --- 路由 ---

@test "resolve 走最长前缀：install php 吃两个词" {
    make_cmd install/a.sh 'install php' env 30 >/dev/null
    make_cmd install/b.sh 'install' env 10 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::resolve install php --version=8.3
echo "cmd=[${OS_REG_COMMAND[OS_REG_MATCH]}] words=${OS_REG_MATCH_WORDS}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cmd=[install php] words=2"* ]]
}

@test "resolve 认得出位置参数：firewall allow 只吃一个词（D73）" {
    make_cmd manage/b.sh 'firewall' system 160 >/dev/null
    make_cmd install/a.sh 'install php' env 30 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::resolve firewall allow --ports=80
echo "cmd=[${OS_REG_COMMAND[OS_REG_MATCH]}] words=${OS_REG_MATCH_WORDS}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cmd=[firewall] words=1"* ]]
}

@test "resolve 在第一个 - 开头的参数处停下" {
    make_cmd manage/b.sh 'firewall' system 160 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::resolve firewall --ports=80 allow
echo "words=${OS_REG_MATCH_WORDS}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"words=1"* ]]
}

@test "resolve 未知命令返回 1，且不留下上一次的匹配" {
    make_cmd install/a.sh 'install php' env 30 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::resolve install php
registry::resolve nosuch thing || echo "miss"
echo "match=${OS_REG_MATCH} words=${OS_REG_MATCH_WORDS}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"miss"* ]]
    [[ "${output}" == *"match=-1 words=0"* ]]
}

@test "IFS 是 \$'\\n\\t' 时多词命令照样匹配得上" {
    make_cmd install/a.sh 'ui preview' env 20 >/dev/null
    local f
    f=$(make_frontend '
[[ "${IFS}" == $'"'"'\n\t'"'"' ]] || { echo "IFS 被改了，这条用例就不成立了"; exit 9; }
registry::groups_load
registry::scan
registry::resolve ui preview
echo "words=${OS_REG_MATCH_WORDS}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"words=2"* ]]
}

# --- 排序与分组 ---

@test "sort 先按分组序再按 @order" {
    make_cmd manage/b.sh 'firewall' system 160 >/dev/null
    make_cmd install/c.sh 'install redis' env 60 >/dev/null
    make_cmd install/a.sh 'install caddy' env 10 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::sort
for i in "${OS_REG_SORTED[@]}"; do
    printf "%s|" "${OS_REG_ORDER[i]}"
done
echo
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"10|60|160|"* ]]
}

@test "@self_name 解析出来单独存放，没写的留空由消费者回落" {
    local f dir
    dir="${OS_FIX}/install"
    mkdir -p "${dir}"
    # 带 @self_name 的：有下级的命令在自己那一屏要用另一个标签
    {
        printf '#!/bin/bash\n#\n# 测试脚本\n#\n'
        printf '# @command      install\n'
        printf '# @name         安装应用\n'
        printf '# @self_name    全部应用与状态\n'
        printf '# @group        env\n'
        printf '# @order        10\n'
        printf '# @privilege    root\n'
        printf '# @requires_lib >= 1.0\n'
        printf '# @description  说明\n#\n'
    } >"${dir}/parent.sh"
    chmod +x "${dir}/parent.sh"
    make_cmd install/child.sh 'install caddy' env 20 >/dev/null

    f=$(make_frontend '
registry::scan
for ((i = 0; i < OS_REG_COUNT; i++)); do
    printf "%s|name=%s|self=%s\n" "${OS_REG_COMMAND[i]}" "${OS_REG_NAME[i]}" "${OS_REG_SELF_NAME[i]}"
done
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    # @name 不受影响，@self_name 单独存放
    [[ "${output}" == *"install|name=安装应用|self=全部应用与状态"* ]]
    # 没写 @self_name 的留空 —— 回落是消费者（菜单）的事，注册表不替它决定
    [[ "${output}" == *"install caddy|name=名字-20|self="* ]]
}

@test "分组显示名来自 groups.conf，未声明的分组回落成 id" {
    make_cmd install/a.sh 'install caddy' env 10 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
echo "name=[$(registry::group_name env)]"
echo "unknown=[$(registry::group_name nosuch)]"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"name=[环境与安装]"* ]]
    [[ "${output}" == *"unknown=[nosuch]"* ]]
}

@test "分组说明来自 groups.conf 第五列，没写的留空" {
    printf 'blurbed | 有说明的分组 | 60 | system | 这一栏管什么，说得清清楚楚\n' >>"${OS_GROUPS}"
    local f
    f=$(make_frontend '
registry::groups_load
printf "desc=[%s]\\n" "$(registry::group_desc blurbed)"
printf "empty=[%s]\\n" "$(registry::group_desc env)"
printf "unknown=[%s]\\n" "$(registry::group_desc nosuch)"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"desc=[这一栏管什么，说得清清楚楚]"* ]]
    # 没写第五列的分组留空，菜单据此决定要不要回落到成员脚本的 @description
    [[ "${output}" == *"empty=[]"* ]]
    [[ "${output}" == *"unknown=[]"* ]]
}

@test "分组说明含空格与全角标点不被切碎" {
    printf 'spaced | 带空格 | 70 | system | Web 服务、数据库 和 缓存\n' >>"${OS_GROUPS}"
    local f
    f=$(make_frontend '
registry::groups_load
printf "desc=[%s]\\n" "$(registry::group_desc spaced)"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    # 只去两端空白，中间原样保留 —— 分隔符是 `|` 不是空白，正为此
    [[ "${output}" == *"desc=[Web 服务、数据库 和 缓存]"* ]]
}

@test "分组可声明父分组，供菜单收纳低频条目" {
    local f
    f=$(make_frontend '
registry::groups_load
printf "parent=[%s]\\n" "$(registry::group_parent other)"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"parent=[system]"* ]]
}

@test "父分组不存在时回落顶层并告警" {
    printf 'orphan | 临时分组 | 50 | missing\n' >>"${OS_GROUPS}"
    local f
    f=$(make_frontend '
registry::groups_load
printf "parent=[%s]\\n" "$(registry::group_parent orphan)"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"parent=[]"* ]]
    [[ "${output}" == *"父分组不存在"* ]]
}

@test "groups.conf 缺失时告警但不炸" {
    make_cmd install/a.sh 'install caddy' env 10 >/dev/null
    local f
    f=$(make_frontend '
OS_GROUPS_CONF="/nonexistent/groups.conf"
registry::groups_load
registry::scan
registry::sort
echo "count=${OS_REG_COUNT}"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"count=1"* ]]
}

# --- @requires 可见性 ---

@test "@requires 不满足时 requires_met 返回 1" {
    make_cmd install/a.sh 'deploy wordpress' service 90 'mariadb,php' >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::requires_met 0 && echo "met" || echo "unmet"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"unmet"* ]]
}

@test "@requires 满足时返回 0，版本约束按 os::version_cmp 判" {
    make_cmd install/a.sh 'deploy wordpress' service 90 'caddy>=2.7' >/dev/null
    local f
    f=$(make_frontend '
mkdir -p "${OS_STATE_DIR}"
os::state_set caddy version=2.6.4 method=apt
registry::groups_load
registry::scan
registry::requires_met 0 && echo "低版本=met" || echo "低版本=unmet"
os::state_set caddy version=2.8.0 method=apt
registry::requires_met 0 && echo "高版本=met" || echo "高版本=unmet"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"低版本=unmet"* ]]
    [[ "${output}" == *"高版本=met"* ]]
}

@test "@requires 带实例：php:8.3 装了 php:8.1 不算满足" {
    make_cmd install/a.sh 'deploy wordpress' service 90 'php:8.3' >/dev/null
    local f
    f=$(make_frontend '
mkdir -p "${OS_STATE_DIR}"
os::state_set "php:8.1" version=8.1.2 method=apt
registry::groups_load
registry::scan
registry::requires_met 0 && echo "met" || echo "unmet"
os::state_set "php:8.3" version=8.3.11 method=apt
registry::requires_met 0 && echo "met2" || echo "unmet2"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"unmet"* ]]
    [[ "${output}" == *"met2"* ]]
}

@test "@requires 在 state 里没有时回退到探测（D138）" {
    [ "$(id -u)" -eq 0 ] || skip '要写 /etc/php'
    [ ! -d /etc/php ] || skip '本机已装 PHP，不动它'
    make_cmd manage/a.sh 'php config' service 90 'php' >/dev/null

    mkdir -p /etc/php/8.3/fpm
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::requires_met 0 && echo "探测=met" || echo "探测=unmet"
')
    run bash "${f}"
    rm -rf /etc/php

    [ "${status}" -eq 0 ]
    # state 里一条 php 都没有，但机器上确实装着。只查 state 的后果比命令侧
    # 更隐蔽 —— 命令跑起来至少会报「缺少依赖组件」，菜单是直接把条目藏掉
    # 且不给任何提示，用户只看到「怎么没有这一项」
    [[ "${output}" == *"探测=met"* ]]
}

@test "@requires 带实例时不回退探测：探测答不出哪个实例是本工具装的" {
    [ "$(id -u)" -eq 0 ] || skip '要写 /etc/php'
    [ ! -d /etc/php ] || skip '本机已装 PHP，不动它'
    make_cmd manage/a.sh 'php config' service 90 'php:8.3' >/dev/null

    mkdir -p /etc/php/8.3/fpm
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::requires_met 0 && echo "met" || echo "unmet"
')
    run bash "${f}"
    rm -rf /etc/php

    [ "${status}" -eq 0 ]
    # 机器上确实有 8.3，但 `php:8.3` 问的是「**本工具装的**那个实例在不在」，
    # 探测答不了这个问题 —— 拿它当答案比没有答案更糟（D138）
    [[ "${output}" == *"unmet"* ]]
}

@test "无 @requires 的条目一律可见" {
    make_cmd install/a.sh 'install caddy' env 10 >/dev/null
    local f
    f=$(make_frontend '
registry::groups_load
registry::scan
registry::requires_met 0 && echo "met" || echo "unmet"
')
    run bash "${f}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"met"* ]]
}
