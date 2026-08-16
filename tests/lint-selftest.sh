#!/usr/bin/env bash
#
# lint 的反例自检：**证明那些检查真的会红**
#
# 为什么需要它：本项目出过一条「看起来一直在跑、实际从未拦下任何东西」的检查 ——
# 接口变更与 `lib/API_VERSION` 的比对拿工作区跟 HEAD 比，而 CI 检出之后工作区
# 就是 HEAD，于是每一次已提交的接口增删都被报成「接口无变动」。它绿了很久。
#
# 光有正例（跑一遍 lint 全通过）证明不了检查还活着 —— 一条 `return 0` 也能让
# 全部通过。**只有反例能**：给它一段确定违规的代码，它必须红。
#
# 做法：把工作区**复制**到临时目录再注入违规，不碰真文件。副本里没有 .git，
# lint 会走 find 分支收集候选 —— 代价是依赖 git 的两项（可执行位、API 版本）
# 在副本里自动跳过，所以 API 版本那条单独在真实仓库里测，且只读不写。
#
# 用法：bash tests/lint-selftest.sh

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

fail_count=0
work=''

# 收尾写在 trap 里而不是拆成函数：shellcheck 看不出 trap 会调用它（SC2329），
# 而为这个加一条 disable，恰恰是 disable 棘轮要防的那种「凑合一下」。
# 末尾的 `:` 不能省 —— EXIT trap 的最后一条命令决定脚本的退出码。
trap '[[ -n ${work} ]] && rm -rf -- "${work}"; :' EXIT

pass() { printf '  ok   %s\n' "$*"; }

fail() {
    printf '  FAIL %s\n' "$*" >&2
    fail_count=$((fail_count + 1))
}

# expect_red <说明> <期望在输出里出现的片段>
#
# 副本已被调用方改成违规状态，这里跑 lint 并要求它以非零退出、且报出那条具体
# 的消息。**只看退出码不够**：注入 A 违规却因为 B 报红，说明 A 那条已经死了。
expect_red() {
    local what=${1} want=${2} out=''
    local -i rc=0
    out=$(cd "${work}" && bash tests/lint.sh 2>&1) || rc=$?
    if ((rc == 0)); then
        fail "${what}：lint 居然全通过了"
        return 0
    fi
    if [[ ${out} != *"${want}"* ]]; then
        fail "${what}：lint 红了，但不是因为这一条（找不到「${want}」）"
        return 0
    fi
    pass "${what}"
    return 0
}

# 每个反例都从一份干净的副本开始：注入是累加的，同一份副本上测第二条时，
# 第一条的违规还在，报错混在一起就分不清是谁触发的
fresh_copy() {
    [[ -n ${work} && -d ${work} ]] && rm -rf -- "${work}"
    work=$(mktemp -d)
    # 排除 .git：副本里没有它，lint 自动退回 find 分支
    (cd "${REPO_ROOT}" && tar --exclude=.git --exclude=tests/.tmp -cf - .) \
        | (cd "${work}" && tar -xf -)
    return 0
}

printf '=== lint 反例自检 ===\n'

# --- 1. root-nolock 不得往持久路径写 ---
#
# 真出过：采集器用 os::install_file 把面板历史刷到盘上，一个不持锁的进程
# 在写持久文件，而当时这个接口不在黑名单里，检查全程绿灯。
fresh_copy
printf '\nos::install_file --mode 0640 /tmp/a /tmp/b\n' >>"${work}/script/ops/web_collect.sh"
expect_red 'root-nolock 调 os::install_file' 'root-nolock 不得调用 os::install_file'
# 黑名单之外的原生命令与重定向同样必须红，证明检查不只认识 os::*。
fresh_copy
printf '\ntouch /opt/oneserver/data/lint-selftest\n' >>"${work}/script/ops/web_collect.sh"
expect_red 'root-nolock 裸调 touch' '不得裸调外部写命令'

fresh_copy
printf "\n: >\"\${OS_DATA_DIR}/lint-selftest\"\n" >>"${work}/script/ops/web_collect.sh"
expect_red 'root-nolock 重定向持久路径' '不得向持久路径直接重定向'

# 脚本即使用 os::run 包着 apt-get，也仍然绕过了唯一包接口。
fresh_copy
printf "\nos::run '反例' -- apt-get upgrade -y\n" >>"${work}/script/ops/safe_updates.sh"
expect_red '脚本直接调用 apt-get' '包管理必须经 lib/ 的包接口'

# 无 @command 的 systemd 步骤也会读 @requires_lib，不能跳过版本检查。
fresh_copy
sed -i 's/@requires_lib >= 4.0/@requires_lib >= 99.0/' "${work}/script/ops/web_collect.sh"
expect_red '内部步骤脚本要求未来 API' '要求 lib API >= 99.0'

# `sh -c "…${值}…"` 是 eval 的另一种写法：外层展开后拼进内层 shell 的脚本
# 文本。真实后果是恢复流程曾把远端目录名拼进去 —— 能往备份桶里写东西的人
# 因此能在恢复机上以 root 执行命令。反例用的正是那条被修掉的形状。
fresh_copy
printf "\nos::query --timeout 10 -- sh -c \"ls -1 '\${OS_ARCHIVE_DIR}' | sort\"\n" \
    >>"${work}/script/ops/backup.sh"
expect_red 'sh -c 里拼接变量展开' '拼进了 sh -c 的脚本文本'

# 位置参数那条正确写法**不能被误伤**：`$1` 是内层 shell 的参数，值经 argv
# 传入。probe.sh 全是这个形状，检查若连它一起报红就只能被整条关掉。
#
# **判据看的是「我这条规则有没有报出来」，不是 lint 的整体退出码。** 注入的
# 那行单引号里带 `$1`，shellcheck 必然报 SC2016（真实代码在这种地方配一条
# 带理由的 disable，而副本里加 disable 又会顶破棘轮）—— 拿整体退出码当判据
# 会把那次无关的红算到本规则头上，这条控制用例第一版就是这么假红的。
fresh_copy
printf "\nos::query --timeout 10 -- sh -c 'du -sk -- \"\$1\"' sh \"\${OS_LOG_DIR}\"\n" \
    >>"${work}/script/ops/backup.sh"
shc_out=$(cd "${work}" && bash tests/lint.sh 2>&1 || true)
if [[ ${shc_out} == *'拼进了 sh -c 的脚本文本'* ]]; then
    fail 'sh -c 走位置参数被误报成违规 —— 这条检查会逼人把它整个关掉'
else
    pass 'sh -c 走位置参数不被误伤'
fi

# --- 2. 运行时路径不得硬编码（含根卸载器与 OS_ROOT 之外的系统落点）---
fresh_copy
printf "\nLINT_SELFTEST='/usr/local/bin'\n" >>"${work}/uninstall.sh"
expect_red '根卸载器硬编码 /usr/local/bin' '硬编码了运行时路径'

# --- 3. .shellcheckrc 的全局禁用必须先进允许列表 ---
#
# 往那个文件里加一行 disable= 曾经是全项目最省事、也最不会被发现的消警告手段。
fresh_copy
printf 'disable=SC2034\n' >>"${work}/.shellcheckrc"
expect_red '新增未经审议的全局 disable' '全局禁用了 SC2034'

# --- 4. 前端不得有副作用 ---
fresh_copy
printf "\nos::run '反例' -- true\n" >>"${work}/bin/oneserver"
expect_red '前端出现 os::run' '前端只做路由/渲染/探测'

# --- 5. 脚本文件头四件套（含不带 @command 的内部步骤脚本）---
fresh_copy
sed -i '/^umask 027$/d' "${work}/script/ops/web_persist.sh"
expect_red '内部步骤脚本缺 umask 027' "缺 'umask 027'"

# --- 6. 接口变更必须动 lib/API_VERSION ---
#
# **在真实仓库里测，且只读**：这一条依赖 git，而副本里没有 .git。
# 拿一个历史提交当基准，把当时的版本号喂回去，它必须发现接口多了而版本没动。
printf '\n'
api_base=$(git -C "${REPO_ROOT}" rev-parse --verify 'HEAD~8^{commit}' 2>/dev/null || printf '')
if [[ -z ${api_base} ]]; then
    printf '  skip 接口变更未升版（仓库历史不足 8 个提交）\n'
else
    base_ver=$(git -C "${REPO_ROOT}" show "${api_base}:lib/API_VERSION" 2>/dev/null || printf '')
    now_ver=$(cat "${REPO_ROOT}/lib/API_VERSION" 2>/dev/null || printf '')
    if [[ -z ${base_ver} || ${base_ver} == "${now_ver}" ]]; then
        printf '  skip 接口变更未升版（基准与当前版本号相同，构造不出反例）\n'
    else
        # 副本用来放被压回旧版本号的 API_VERSION，真实仓库一个字节都不动；
        # lint 读 REPO_ROOT 是靠 BASH_SOURCE 推的，所以从副本里跑它
        fresh_copy
        printf '%s\n' "${base_ver}" >"${work}/lib/API_VERSION"
        cp -r -- "${REPO_ROOT}/.git" "${work}/.git"
        out=''
        rc=0
        out=$(cd "${work}" && OS_LINT_API_BASE="${api_base}" bash tests/lint.sh 2>&1) || rc=$?
        if ((rc == 0)); then
            fail '接口变更未升版：lint 居然全通过了'
        elif [[ ${out} != *'但 lib/API_VERSION 仍是'* ]]; then
            fail '接口变更未升版：lint 红了，但不是因为这一条'
        else
            pass '接口变更未升版'
        fi
    fi
fi

# --- 7. 分组说明：塞得进说明列，且写在用得到的地方 ---
#
# 反例按显示宽度构造：25 个中文字 = 50 格，刚过 48。
fresh_copy
printf 'wide | 超宽分组 | 940 | sys | 这一列写成一整句话的结果是菜单里每条都以省略号收尾\n' \
    >>"${work}/templates/groups.conf"
expect_red '分组说明超过说明列宽' '说明宽 50 格'

# 顶层分组的说明一个字都不会显示，而写的人拿不到任何反馈。
fresh_copy
printf 'orphan | 顶层分组 | 941 | | 写在这儿的字一个都不会上屏\n' \
    >>"${work}/templates/groups.conf"
expect_red '顶层分组写了不会显示的说明' '只是分区标题'

printf '\n=== 结论 ===\n'
if ((fail_count == 0)); then
    printf '全部反例都被拦下\n'
    exit 0
fi
printf '%d 条检查没能拦下它该拦的东西\n' "${fail_count}" >&2
exit 1
