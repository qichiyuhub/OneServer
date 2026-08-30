#!/usr/bin/env bash
#
# OneServer 静态检查（F0.4）
#
# 二十一项：
#   1. shellcheck 零告警；zsh 补全另用 `zsh -n` 查语法（同一件事，换个工具）
#   2. shfmt 格式一致（规则见 .editorconfig，shfmt 原生读取它）
#   3. disable 审计 —— 文件内每条必须带理由且总数守棘轮，
#      .shellcheckrc 的全局禁用另走精确允许列表
#      （零告警不能靠满屏 disable 伪造，更不能靠往 .shellcheckrc 里加一行）
#   4. 前端零副作用
#   5. 可执行位与 git 索引一致：该可执行的是 100755，不该的是 100644
#   6. `os::run` 等的 desc 是固定字符串，不含变量展开
#   7. 更新切换器自包含
#   8. 脚本层只调允许的前缀，不碰私有函数
#   9. docs/API.md 与 lib/ 一致，且没有接口缺签名行
#  10. 变更流水注释不超阈值（棘轮，只降不升）
#  11. 新增或删除公开接口时 lib/API_VERSION 必须跟着动
#  12. 规范的目录与实际小节一致
#  13. 二级菜单与 dispatch 分支一一对应（双向）
#  14. @privilege root-nolock 的脚本零系统副作用
#  15. 运行时路径不得硬编码，只出自 lib/paths.sh
#  16. `eval` 全项目零使用，且 `sh -c` 的脚本文本里不出现 `${` 展开
#  17. lib 分层与装配：L0 只有赋值、模块之间不 source、不依赖 jq/python/perl
#  18. 脚本文件头四件套齐全（script/** 全部，加根卸载器）
#  19. 脚本元数据与菜单分组数据静态可判定的部分自洽
#  20. 公开接口的测试覆盖不倒退（棘轮，只降不升）
#  21. 出参函数的局部变量带 `__` 前缀，回写不被同名局部变量吃掉（棘轮，只降不升）
#
# 候选范围 = git 跟踪的全部 bash 脚本（`*.sh` `*.bash` `bin/*`），没有豁免名单。
# 但**各项自有适用面**，写在各自的注释里：`desc`、脚本层前缀这类条款本就只约束
# `script/**` 与 `bin/**`；分层只问 `lib/**`；`eval` 不查 tests/（检查器自己必然
# 要写出那个词）；接口覆盖只搜 `tests/lib/`（lint 的注释里就有接口名）。
# 两个自包含例外（install.sh 与切换器）不适用「source bootstrap」与路径单一来源，
# 理由是它们根本 source 不了 lib/ —— 这是规范写明的，不是给它们开的口子。
#
# 用法：bash tests/lint.sh

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# 文件内 `# shellcheck disable=` 的棘轮上限。**只降不升**，与下面两个同义：
# 它记的是「还欠多少」，不是「允许多少」。零告警不能靠满屏 disable 伪造。
readonly MAX_DISABLES=21

# `.shellcheckrc` 里的全局 disable 用精确允许列表，不用阈值：一条全局禁用
# 关掉的是**所有文件**的那条规则，与逐处豁免不是一回事，混进同一个计数会让
# 「清掉一条文件内 disable」和「删掉一条全局禁用」看起来等价。
# 要加一条就得先改这里，而改这里必然被 review 看见 —— 这就是审议的执行点。
readonly ALLOWED_GLOBAL_DISABLES='SC1091'

# 变更流水注释的棘轮上限。**只降不升**：清理一批就把这个数往下调，
# 它记录的是「还欠多少」，不是「允许多少」。
readonly MAX_CHANGELOG_COMMENTS=0

# 没有任何 bats 用例提到的公开接口条数。同样是棘轮，含义同上 ——
# 「改 lib/ 必须补 bats 测试」这条规则在此之前没有执行者，欠账一度到 26。
# 现在是 0：新增接口不带用例当场红。
readonly MAX_UNCOVERED_API=0

# 出参函数里没带 `__` 前缀的局部变量条数。棘轮，含义同上 —— 记的是「还欠多少」。
# 这条规则本身是恢复流程那个 bug 换来的：`local` 与调用方传进来的变量名同名时，
# 回写静默失效，调用方拿到空串（详见第 21 项）。
readonly MAX_UNPREFIXED_OUTVAR_LOCALS=31

# CI 钉死的 shellcheck 版本，**这里是唯一来源**（.github/workflows/lint.yml
# 从本文件读它）。不同版本对同一份代码的判断不同（0.9 报 SC2015，0.11 不报），
# 版本一漂，「本地绿」就不再等价于「CI 绿」。
readonly EXPECT_SHELLCHECK_VERSION='0.11.0'

# CI 下载的那个发布包的 SHA256。**门禁自己的获取方式也得满足 §11。**
# 从前 CI 是 `curl … | tar -xJ` 直接管道进解包再 install 到 /usr/local/bin ——
# 无校验地下载并执行的，恰好是**执行本仓库全部安全门禁的那个二进制**。
# 版本与哈希放在一起，换版本时两个一起改，漏一个 CI 当场红。
readonly EXPECT_SHELLCHECK_SHA256='8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198'

# 运行时路径的字面量。单一来源是 lib/paths.sh（规范 §4.2），
# 出现在别处就意味着「改一个目录要改两个地方」，而第二处不会有人记得改。
#
# 后三个是落在 OS_ROOT **之外**的系统落点。它们曾经不在这张表里，代价是
# 卸载器把 /usr/local/bin 与两个 /etc 落点又各写了一份字面量 —— 而它明明
# source 了 bootstrap，paths.sh 里的常量就在手边。漏掉的原因是这张表按
# 「带 oneserver 字样的目录」攒的，而这三个不带。
readonly RUNTIME_PATHS='/opt/oneserver|/etc/oneserver|/var/log/oneserver|/var/backups/oneserver|/run/oneserver|/var/tmp/oneserver|/usr/local/bin|/etc/bash_completion.d|/etc/logrotate.d'

cd "${REPO_ROOT}"

fail_count=0

die() {
    printf 'lint: 错误: %s\n' "$*" >&2
    exit 1
}

section() {
    printf '\n=== %s ===\n' "$*"
}

report_fail() {
    printf 'lint: 不通过: %s\n' "$*" >&2
    fail_count=$((fail_count + 1))
}

require() {
    command -v "${1}" >/dev/null 2>&1 || die "缺少 ${1}。Debian/Ubuntu: apt-get install -y ${1}"
}

# --- 收集在检范围 ---

# CI 与开发机上用 git ls-files（自动尊重 .gitignore）；
# 测试机上跑的是 tar 同步过去的副本，没有 .git 也没装 git，退回 find。
#
# **`*.bash` 也算 bash 脚本。** 按扩展名收集时漏掉它，结果是 bash 补全脚本
# ——一份随分发装到用户机器上的代码——一项检查都过不到。它自己头上还写着
# `# shellcheck shell=bash` 和一条带理由的 disable，写的人分明以为它在检查内。
# zsh 补全另走一节：那份是 zsh 语法，shellcheck 与 shfmt 都读不了。
list_candidates() {
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -- '*.sh' '*.bash' 'bin/*'
        return
    fi
    find . -type d -name .git -prune -o \
        -type f \( -name '*.sh' -o -name '*.bash' -o -path './bin/*' \) -print \
        | sed 's|^\./||' | sort
}

declare -a files=()
while IFS= read -r f; do
    files+=("${f}")
done < <(list_candidates)

section "在检范围"
if [[ ${#files[@]} -eq 0 ]]; then
    printf '\nlint: 在检范围为空，无事可做\n'
    exit 0
fi
printf '在检 %d 个文件\n' "${#files[@]}"

# --- 1. shellcheck ---

section "shellcheck"
require shellcheck
# 版本不符只提示不失败：装得到哪个版本由发行版仓库决定，不由改代码的人决定。
# 但它必须被说出来 —— 否则本地一片绿、CI 一片红，而没人知道差别在哪
sc_ver=$(shellcheck --version | sed -n 's/^version: //p' | tr -d '\r')
[[ ${sc_ver} == "${EXPECT_SHELLCHECK_VERSION}" ]] \
    || printf '注意：本机 shellcheck %s，CI 用的是 %s —— 本地通过不代表 CI 通过\n' \
        "${sc_ver:-未知}" "${EXPECT_SHELLCHECK_VERSION}"

# CI 装 shellcheck 的那一步必须校验下载。**它装的正是执行这全部检查的二进制**，
# 从前是 `curl … | tar -xJ` 直接管道进解包，无校验 —— 规范 §11 对第三方软件的
# 要求同样管得到门禁自己。工作流退回无校验管道是没人会发现的那种退化，
# 所以在这里守住：哈希常量的消费者在工作流里，比对的就是同一个值。
ci_workflow="${REPO_ROOT}/.github/workflows/lint.yml"
if [[ -f "${ci_workflow}" ]]; then
    grep -q -- "${EXPECT_SHELLCHECK_SHA256}" "${ci_workflow}" \
        || grep -q 'EXPECT_SHELLCHECK_SHA256' "${ci_workflow}" \
        || report_fail 'CI 工作流没有引用 EXPECT_SHELLCHECK_SHA256 —— 门禁自己的二进制不能无校验下载'
    grep -q 'sha256sum -c' "${ci_workflow}" \
        || report_fail 'CI 工作流缺少 sha256sum -c 校验步骤'
fi
if shellcheck "${files[@]}"; then
    printf '零告警\n'
else
    report_fail "shellcheck 有告警"
fi

# zsh 补全归在本项里，因为要守的是同一件事——语法层面的静态检查——只是
# zsh 那份读不了（`${(f)...}`、`compadd` 都不是 bash 语法），只能换 zsh -n。
# 本机没装就说明并跳过：为一份补全脚本让整条 lint 依赖 zsh 不划算。CI 上装。
#
# （上一行不写工具名开头：任何以 `#` 加那个词起头的注释都会被当成指令解析。）
declare -a zsh_files=()
while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    zsh_files+=("${f}")
done < <(
    if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files -- '*.zsh'
    else
        find . -type d -name .git -prune -o -type f -name '*.zsh' -print | sed 's|^\./||' | sort
    fi
)
if [[ ${#zsh_files[@]} -eq 0 ]]; then
    :
elif ! command -v zsh >/dev/null 2>&1; then
    printf '注意：没装 zsh，%d 个 zsh 文件的语法检查跳过（CI 会装）\n' "${#zsh_files[@]}"
else
    zsh_bad=0
    for f in "${zsh_files[@]}"; do
        zsh -n "${f}" 2>&1 || {
            report_fail "${f} zsh 语法检查不通过"
            zsh_bad=1
        }
    done
    [[ ${zsh_bad} -eq 1 ]] || printf 'zsh 语法零告警（%d 个文件）\n' "${#zsh_files[@]}"
fi

# --- 2. shfmt ---

# 不传任何格式化开关：shfmt 一旦收到开关就整个忽略 .editorconfig，
# 于是规则会有两个来源。裸调它，.editorconfig 就是唯一真相源。
section "shfmt"
require shfmt
if shfmt -d "${files[@]}"; then
    printf '格式一致\n'
else
    report_fail "shfmt 有差异，跑 make fmt 修正"
fi

# --- 3. disable 审计 ---

section "shellcheck disable 审计"
disable_total=0
for f in "${files[@]}"; do
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        disable_total=$((disable_total + 1))
        # 期望形如：# shellcheck disable=SC2029  # 理由：……
        [[ "${hit}" == *"理由"* ]] \
            || report_fail "${f}:${hit%%:*} 的 disable 没写理由"
        # 正则只认「独占一行的注释指令」——这既是 shellcheck 唯一认的写法，
        # 也让本脚本自己的这行 grep 与上下文注释不会被算成一条 disable。
    done < <(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]+disable=' "${f}" || true)
done

printf '文件内 disable 共 %d 条（棘轮 %d）\n' "${disable_total}" "${MAX_DISABLES}"
[[ "${disable_total}" -le "${MAX_DISABLES}" ]] \
    || report_fail "文件内 disable 超过棘轮 ${MAX_DISABLES} —— 先清理旧的，或经批准后连同规则一起改"

# `.shellcheckrc` 里的全局 disable 此前完全不在审计内：那个文件自称「全局禁用的
# 规则必须逐条注明理由」「CI 统计 disable 总数」，而检查只搜了各文件里的注释指令。
# 于是往 .shellcheckrc 里加一行 disable= 是全项目最省事的消警告手段，也是唯一
# 不会被任何检查发现的那种。
global_disables=0
if [[ -f "${REPO_ROOT}/.shellcheckrc" ]]; then
    # 去空白用逐行的 sed，不用 `tr -d '[:space:]'`：后者连换行一起删，
    # 多条禁用会被拼成一行，只有一条时则连末尾换行都没有，read 直接读不进循环。
    while IFS= read -r code || [[ -n "${code}" ]]; do
        [[ -n "${code}" ]] || continue
        global_disables=$((global_disables + 1))
        printf '%s\n' "${ALLOWED_GLOBAL_DISABLES}" | tr ',' '\n' | grep -qx -- "${code}" \
            || report_fail ".shellcheckrc 全局禁用了 ${code} —— 它关掉的是所有文件的这条规则，须先写进 lint.sh 的允许列表"
    done < <(sed -nE 's/^[[:space:]]*disable=//p' "${REPO_ROOT}/.shellcheckrc" | tr ',' '\n' | sed 's/[[:space:]]//g')
fi
printf '全局 disable %d 条（允许列表：%s）\n' "${global_disables}" "${ALLOWED_GLOBAL_DISABLES}"

# --- 4. 前端零副作用---

section "前端约束"
declare -a frontends=()
for f in "${files[@]}"; do
    [[ "${f}" == bin/* ]] && frontends+=("${f}")
done
if [[ ${#frontends[@]} -eq 0 ]]; then
    printf '没有前端文件\n'
else
    for f in "${frontends[@]}"; do
        while IFS= read -r hit; do
            [[ -n "${hit}" ]] || continue
            report_fail "${f}:${hit%%:*} 前端只做路由/渲染/探测，不得有副作用：${hit#*:}"
        done < <(grep -nE '(^|[^[:alnum:]_:])os::(run|run_out|state_set|state_del|state_unit_add|secure_set|secure_del|systemd_)' "${f}" || true)
    done
    printf '检查了 %d 个前端文件\n' "${#frontends[@]}"
fi

# --- 5. 可执行位---
#
# bin/ 的前端与带 @command 的脚本都要被 exec 直接派发。漏了执行位的
# 表现是「这条命令莫名其妙不存在」，而它是提交时就能查出来的事。
#
# 反向同样要查：清单的权限取自 git 索引（packaging/make-manifest.sh），
# 被误设成 100755 的 lib 文件会把那个多余的执行位一路带到用户机器上。
# 唯一该可执行的非命令文件是切换器 —— update.sh 明确要求它 `-x`。
#
# 认 git 索引里的模式而不是工作区的：工作区的权限位随检出环境变，
# `core.filemode=false` 时 chmod 压根不进索引 —— 只看 `-x` 的结果是
# 本地与 CI 各说各话，而分发落地的权限取自索引。

section "可执行位"
has_git=0
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    has_git=1
fi

exec_checked=0
for f in "${files[@]}"; do
    need=-1
    case "${f}" in
        bin/*) need=1 ;;
        # script/ 下没有被 source 的文件 —— 每一个都由 exec 或 systemd 直接跑。
        # 只查带 @command 的那些会漏掉内部步骤脚本，而漏了执行位的表现是
        # 「Failed at step EXEC … Permission denied」，采集器每轮都挂。
        script/*) need=1 ;;
        lib/* | templates/*) need=0 ;;
        packaging/*) grep -q '^# os-contract: updater' "${f}" && need=1 || need=0 ;;
    esac
    [[ "${need}" -ge 0 ]] || continue
    exec_checked=$((exec_checked + 1))
    if [[ "${has_git}" -eq 1 ]]; then
        mode="$(git ls-files -s -- "${f}" | cut -d' ' -f1)"
        if [[ "${need}" -eq 1 ]]; then
            [[ "${mode}" == "100755" ]] \
                || report_fail "${f} 在 git 索引里的模式是 ${mode:-未跟踪}，应为 100755（git update-index --chmod=+x ${f}）"
        else
            [[ "${mode}" == "100644" ]] \
                || report_fail "${f} 在 git 索引里的模式是 ${mode:-未跟踪}，它不该可执行，应为 100644（git update-index --chmod=-x ${f}）"
        fi
    elif [[ "${need}" -eq 1 ]]; then
        [[ -x "${f}" ]] || report_fail "${f} 没有执行位"
    fi
done
printf '检查了 %d 个文件的执行位\n' "${exec_checked}"

# --- 6. desc 不含变量展开---
#
# 规范：**禁止把凭据写进 `<desc>`**，判据是「desc 参数禁止包含任何变量展开」——
# 比「检查变量名像不像凭据」严格，也才是可判定的（D47 要的就是这种检查）。
#
# **只查 script/** 与 bin/**。** 规范的适用范围段把 `desc` 固定字符串列进了
# 「lib/** 不适用的面向脚本的接口条款」，这里照它划界。框架自己拼的 desc
# （`os::systemd_restart` 的「重启 <unit>」）里放的是 unit 名与文件名，且脚本
# 传进来的值本就要过 log::redact；把这条施加到 lib 上只会让日志变成
# 「重启服务」这种查不出所以然的话。
#
# 判定方式：从函数名之后逐个词扫，跳过带值的选项（--env / --secret-val /
# --stdin-secret / --timeout）与不带值的 --allow-fail，遇到的第一个词就是 desc。
# 遇到 `--` 说明这一行根本没给 desc（多行写法里 desc 在上一行），跳过。
#
# 是启发式：desc 由变量拼成再传进来（`ufw_apply "$label" ...` 那种）它看不见。
# 但**直接写在调用点上的**那种——也就是实际会发生的那种——它抓得住。

section "desc 固定字符串"
desc_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        script/* | bin/* | templates/script.skeleton.sh) ;;
        *) continue ;;
    esac
    desc_checked=$((desc_checked + 1))
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        lineno="${hit%%:*}"
        text="${hit#*:}"
        text="${text%\\}"
        # 只取函数名之后的部分
        rest="${text#*os::}"
        rest="${rest#run_out}"
        rest="${rest#run}"
        rest="${rest#retry}"
        rest="${rest#sql_exec}"
        rest="${rest#sql_query}"
        IFS=' ' read -r -a words <<<"${rest}"

        desc=""
        i=0
        n=${#words[@]}
        while [[ "${i}" -lt "${n}" ]]; do
            w="${words[i]}"
            case "${w}" in
                '')
                    i=$((i + 1))
                    continue
                    ;;
                --env | --secret-val | --stdin-secret | --timeout)
                    i=$((i + 2)) # 跳过选项连同它的值
                    continue
                    ;;
                --allow-fail)
                    i=$((i + 1))
                    continue
                    ;;
                --) break ;; # 这一行没给 desc（多行写法里它在上一行）
            esac
            if [[ "${w}" =~ ^[0-9]+$ ]]; then
                i=$((i + 1)) # os::retry 打头的次数不是 desc
                continue
            fi
            # 把被空格拆开的引号串拼回去：desc 多半是 '重启 xxx' 这种带空格的，
            # 逐词看只会看到开头那半截，恰好漏掉后半截里的变量
            desc="${w}"
            quote=""
            case "${w}" in
                \"*) quote='"' ;;
                \'*) quote="'" ;;
            esac
            if [[ -n "${quote}" ]]; then
                while [[ ! ("${#desc}" -gt 1 && "${desc: -1}" == "${quote}") && $((i + 1)) -lt "${n}" ]]; do
                    i=$((i + 1))
                    desc="${desc} ${words[i]}"
                done
            fi
            break
        done

        [[ -n "${desc}" && "${desc}" == *'$'* ]] \
            && report_fail "${f}:${lineno} desc 含变量展开，必须是固定字符串：${desc}"
    done < <(grep -nE '(^|[^[:alnum:]_:])os::(run|run_out|retry|sql_exec|sql_query)[[:space:]]' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个脚本与前端文件\n' "${desc_checked}"

# --- 7. 切换器必须自包含---
#
# 切换器是全项目唯一允许违反规范的代码，代价是它必须**完全**自包含：
# 不 source 任何 lib、不调 os::* / ui::* / log::* / probe::*、不用 eval。
#
# 为什么要机器来查：它替换的正是自己脚下的那棵树，一旦引用了 lib 里的东西，
# 就会在「旧函数 + 新布局」这个未定义的组合里跑 —— 而这类问题**不会在
# 正常更新里暴露**，只在新旧接口恰好不兼容的那一次暴露，也就是最不该出问题的
# 那一次。靠人记着这条规则是不够的。
#
# 认的是文件里的 `# os-contract: updater` 标记，不是路径：将来切换器换个位置，
# 这条检查跟着它走。

section "切换器自包含"
updater_checked=0
for f in "${files[@]}"; do
    grep -q '^# os-contract: updater' "${f}" 2>/dev/null || continue
    updater_checked=$((updater_checked + 1))
    # **先编号再滤注释**，不能反过来：`grep -vn | grep -n` 会重新编号，
    # 报出来的行号指向的是「去掉注释之后的第几行」——而人是拿着这个数字
    # 去翻文件的（同 desc 那项的写法）
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} 切换器里不允许出现这一行（规范自包含）：$(printf '%s' "${hit#*:}" | head -c 60)"
    done < <(grep -nE '(^|[^[:alnum:]_])(source|\.)[[:space:]]+[^ ]|os::|ui::|log::|probe::|(^|[^_[:alnum:]])eval[[:space:]]' "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        || true)
done
if [[ "${updater_checked}" -eq 0 ]]; then
    report_fail "没找到带 '# os-contract: updater' 标记的切换器 —— 它是规范的硬要求"
else
    printf '检查了 %d 个切换器\n' "${updater_checked}"
fi

# --- 8. 脚本层只能调 os:: 与 probe:: ---
#
# 分层规则靠人自觉是守不住的：doctor.sh 已经调到了 registry::_meta ——
# 一个只该被前端加载的模块里的私有函数，而在这条检查存在之前，
# 没有任何机制会发现它。
#
# 白名单而不是黑名单：新增一个 lib 模块时，黑名单需要有人记得同步，
# 白名单默认拒绝，忘了改的后果是「新接口用不了」而不是「越层没人管」。

section "脚本层调用前缀"
prefix_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        script/* | bin/*) ;;
        *) continue ;;
    esac
    prefix_checked=$((prefix_checked + 1))
    # 前端是框架的一部分而非消费者，白名单更宽：registry:: 由它显式 source，
    # log:: 用来记录路由决策 —— 那是框架事件，不是给用户看的消息
    allow='os|probe'
    [[ "${f}" == bin/* ]] && allow='os|probe|registry|log'
    # **先按整行取号再滤注释，最后才抠出违规的那个词**。用 `grep -o` 直接取词
    # 会丢掉行内容，注释就再也滤不掉 —— doctor.sh 里一句「与 registry::_meta
    # 同一套解析」的注释因此被报成越层调用。这条检查同样只看整行是不是注释，
    # 行尾注释里的调用抓不到，与第 6 项一样属启发式。
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        lineno=${hit%%:*}
        body=${hit#*:}
        call=$(printf '%s' "${body}" | grep -oE "\b[a-z_]+::[a-z_0-9]+" | head -1)
        # 私有优先报：`::_` 开头或名字里带 `__`，跨模块一律禁止
        if [[ "${call}" == *::_* || "${call}" == *__* ]]; then
            report_fail "${f}:${lineno} 不得调用框架私有函数：${call}"
        else
            report_fail "${f}:${lineno} 脚本层不得调用该接口：${call}"
        fi
    done < <(grep -nE "\b[a-z_]+::[a-z_0-9]+" "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -E ":.*\b[a-z_]+::" \
        | grep -vE ":[^:]*\b(${allow})::[a-z_0-9]+" \
        || true)
    # 允许前缀里的私有函数（如 probe::_probe）单独再扫一遍
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        lineno=${hit%%:*}
        call=$(printf '%s' "${hit#*:}" | grep -oE "\b(${allow})::_[a-z_0-9]*|\b(${allow})::[a-z_0-9]*__[a-z_0-9]*" | head -1)
        [[ -n "${call}" ]] || continue
        report_fail "${f}:${lineno} 不得调用框架私有函数：${call}"
    done < <(grep -nE "\b(${allow})::_[a-z_0-9]*|\b(${allow})::[a-z_0-9]*__[a-z_0-9]*" "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        || true)
done
printf '检查了 %d 个脚本与前端文件\n' "${prefix_checked}"

# 包管理是领域边界，不只是调用前缀问题。脚本把 apt-get 塞进 os::run 仍然只会
# 命中公开接口白名单，所以要单独拦命令本体；install.sh 是尚无 lib 时运行的
# 自包含例外，lib/ 则正是唯一允许实现该边界的地方。
for f in "${files[@]}"; do
    [[ "${f}" == script/* ]] || continue
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} 包管理必须经 lib/ 的包接口，不得直接调用 apt-get"
    done < <(grep -nE '(^[[:space:]]*|[;&|({][[:space:]]*|--[[:space:]]*)apt-get([[:space:]]|$)' "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done

# --- 9. docs/API.md 与 lib/ 一致 ---
#
# 接口参考是生成的，这条检查是它「不可能过期」的全部依据：
# 少了它，生成器就只是一次性工具，文件照样会在下一次加函数时开始说谎。

# 生成到临时文件再比对，**绝不覆盖工作区里的那份**：检查跑到一半被 Ctrl-C
# 时，「先覆盖真文件、比完再拷回来」会把 docs/API.md 留在覆盖后的状态，
# 而备份还在 mktemp 里。检查工具不该有把工作区改坏的可能。
section "接口参考"
if [[ ! -f "${REPO_ROOT}/docs/API.md" ]]; then
    report_fail "docs/API.md 不存在，跑 make api 生成"
else
    api_tmp=$(mktemp)
    if bash "${REPO_ROOT}/packaging/make-api.sh" "${api_tmp}" >/dev/null 2>&1; then
        if diff -q "${api_tmp}" "${REPO_ROOT}/docs/API.md" >/dev/null 2>&1; then
            printf '与 lib/ 一致\n'
        else
            report_fail "docs/API.md 已过期，跑 make api 重新生成"
        fi
    else
        report_fail "make-api.sh 执行失败"
    fi
    rm -f "${api_tmp}"
fi
if grep -q '缺签名行' "${REPO_ROOT}/docs/API.md" 2>/dev/null; then
    report_fail "有公开接口缺签名行（函数头首行须为 '# <函数名> <参数>   <说明>'）"
fi

# --- 10. 变更流水注释棘轮 ---
#
# 「X 是某年某月某日移植 Y 时补的」这类注释解释的是一个已经不存在的代码库，
# 而历史由 git 保存。规范早就禁止写变更流水，但没有执行者，于是它一直在长。
#
# 做成棘轮而不是硬禁：存量里有「实测（某日）：某个上游 URL 返回 404」这种
# 给经验结论标注时间的写法，值不值得留要一条条看。棘轮不判断对错，只保证
# 总量单调下降 —— 新代码想加这类注释直接失败，清理一批就把阈值往下调。
#
# 认日期而不是认「移植 / 补的」这类词：日期是可精确判定的，词是启发式的。

section "变更流水注释"
changelog_total=0
while IFS= read -r hit; do
    [[ -n "${hit}" ]] || continue
    changelog_total=$((changelog_total + 1))
done < <(grep -rnE '^[[:space:]]*#.*20[0-9]{2}-[0-9]{2}-[0-9]{2}' "${files[@]}" 2>/dev/null || true)
printf '共 %d 条（阈值 %d）\n' "${changelog_total}" "${MAX_CHANGELOG_COMMENTS}"
[[ "${changelog_total}" -le "${MAX_CHANGELOG_COMMENTS}" ]] \
    || report_fail "变更流水注释超过阈值 ${MAX_CHANGELOG_COMMENTS} —— 历史归 git，不要写进注释"

# --- 11. 接口变了就得动 lib/API_VERSION ---
#
# 脚本用 `@requires_lib >= X.Y` 声明自己要的最低框架版本，框架在动手之前比对。
# 但「加了函数忘了升版」没有任何东西拦得住 —— 规范写着规则，执行者不存在，
# 于是它会烂。后果不是立刻可见的：某台机器上框架还是旧的，脚本一路跑到
# 调用新函数那一行才炸，而那时包可能已经装了、配置可能已经改了。
#
# docs/API.md 是从 lib/ 生成且已入库的，所以「接口有没有变」看它的 diff 就够，
# 不必在这里重新解析一遍 lib/。
#
# **比较基准不能想当然地取 HEAD。** 本地开发时工作区里躺着未提交的改动，
# 与 HEAD 比正是要比的那一对；但 CI 检出之后工作区**就是** HEAD，两边逐字节
# 相同，于是这条检查对每一个已提交的接口增删都报「接口无变动」—— 它看起来
# 一直在跑，实际上从来没有在 CI 里拦下过任何东西。
#
# 因此基准由 OS_LINT_API_BASE 显式给出（CI 传 PR 目标分支或推送前的 SHA），
# 没给的时候只在**工作区确实与 HEAD 有差异**时才拿 HEAD 当基准。两个条件都
# 不成立就跳过并说明 —— 宁可不检查，也不能打印一句没有根据的「无变动」。
#
# 盖不住的：改签名、改返回语义这类**语义**变化 —— 函数名没动，diff 看不出来。
# 那部分仍然只能靠 review。这条只保证最常犯的那种（新增/删除）不会漏。

section "lib API 版本"
api_fns() { grep -oE '^- .(os|probe)::[a-z_0-9]+' | sed 's/^- .//' | sort; }

api_base=''
if ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '跳过：不在 git 工作区\n'
elif [[ -n "${OS_LINT_API_BASE:-}" ]]; then
    # merge-base 优先：PR 的目标分支上可能已经有别人的接口改动，直接跟分支尖端比
    # 会把那些也算成本次的。给的是具体 SHA 时 merge-base 得到的就是它自己。
    api_base=$(git merge-base HEAD "${OS_LINT_API_BASE}" 2>/dev/null) \
        || api_base=$(git rev-parse --verify "${OS_LINT_API_BASE}^{commit}" 2>/dev/null) \
        || api_base=''
    [[ -n "${api_base}" ]] \
        || printf '跳过：给了基准 %s 但解析不到（浅克隆？CI 需要 fetch-depth: 0）\n' "${OS_LINT_API_BASE}"
elif git diff --quiet HEAD -- docs/API.md lib/API_VERSION 2>/dev/null; then
    printf '跳过：工作区与 HEAD 一致，没有可比的基准（CI 请传 OS_LINT_API_BASE）\n'
else
    api_base=HEAD
fi

if [[ -n "${api_base}" ]]; then
    if ! git cat-file -e "${api_base}:docs/API.md" 2>/dev/null; then
        printf '跳过：基准 %s 里还没有 docs/API.md\n' "${api_base}"
    else
        api_ver_now=$(cat "${REPO_ROOT}/lib/API_VERSION" 2>/dev/null || printf '')
        api_ver_base=$(git show "${api_base}:lib/API_VERSION" 2>/dev/null || printf '')
        fn_now=$(api_fns <"${REPO_ROOT}/docs/API.md" 2>/dev/null)
        fn_base=$(git show "${api_base}:docs/API.md" 2>/dev/null | api_fns)

        added=$(comm -13 <(printf '%s\n' "${fn_base}") <(printf '%s\n' "${fn_now}") | tr -d ' ')
        removed=$(comm -23 <(printf '%s\n' "${fn_base}") <(printf '%s\n' "${fn_now}") | tr -d ' ')

        if [[ -z "${api_ver_now}" ]]; then
            report_fail "lib/API_VERSION 读不到"
        elif [[ -n "${added}" && "${api_ver_now}" == "${api_ver_base}" ]]; then
            report_fail "新增了公开接口但 lib/API_VERSION 仍是 ${api_ver_now}，次版本要 +1：$(printf '%s' "${added}" | tr '\n' ' ')"
        elif [[ -n "${removed}" && "${api_ver_now%%.*}" == "${api_ver_base%%.*}" ]]; then
            report_fail "删除了公开接口但 lib/API_VERSION 主版本仍是 ${api_ver_now%%.*}，主版本要 +1：$(printf '%s' "${removed}" | tr '\n' ' ')"
        elif [[ -n "${added}" || -n "${removed}" ]]; then
            printf '接口有变动，版本已从 %s 提到 %s（基准 %s）\n' "${api_ver_base}" "${api_ver_now}" "${api_base}"
        else
            printf '接口无变动（%s，基准 %s）\n' "${api_ver_now}" "${api_base}"
        fi
    fi
fi

# --- 12. 规范目录与实际小节一致 ---
#
# 目录是章节列表的第二份拷贝，加一节忘了改它就开始说谎 —— 而它现在是
# CLAUDE.md 让人「照目录检索」的依据，说谎的后果是有人以为某节不存在。
# 有了这条检查，第二份拷贝才允许存在。

section "规范目录"
spec="${REPO_ROOT}/docs/TECHNICAL_SPEC.md"
if [[ ! -f "${spec}" ]]; then
    printf '跳过（docs/TECHNICAL_SPEC.md 不在，可能被 .gitignore 排除）\n'
else
    # 目录行形如 `| [7](#7--组件标识) | … |`，取出编号
    toc_nums=$(grep -oE '^\| \[[0-9]+\]' "${spec}" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
    head_nums=$(grep -oE '^## [0-9]+ ' "${spec}" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')
    if [[ "${toc_nums}" == "${head_nums}" ]]; then
        printf '目录与小节一致（%d 节）\n' "$(printf '%s' "${head_nums}" | wc -w)"
    else
        report_fail "规范目录与实际小节对不上：目录 [${toc_nums%% }] 实际 [${head_nums%% }]"
    fi
fi

# --- 13. 二级菜单与 dispatch 双向对应 ---
#
# 菜单项与 dispatch 是同一份清单的两处拷贝，靠字符串对上。改动作名时只改了
# 一处，菜单照样列出来，选中才报「未知操作」—— 而这条路径没有任何自动检查
# 走得到：shellcheck 看不出，bats 不进交互菜单，lint 其余各项也管不着。
# 真实踩过：`forward` 改名成 `network`，dispatch 改了菜单没改。
#
# **两个方向都查**：反向漏掉的那种（dispatch 有分支、菜单没列）不会报错，
# 它的表现是一条只有读过源码的人才知道存在的命令 —— CLI 敲得中、菜单里
# 永远看不见。要么补进菜单，要么删掉，不该以「没人知道」的状态留着。
#
# 菜单语句按**续行符**收集，不按空行断句：`sed '/os::action_menu/,/^$/p'`
# 在菜单项之间出现一个空行时会把后面的项全部漏掉，而且是静默漏掉。

section "菜单与 dispatch"

# 收集从 os::action_menu 起、直到不以 `\` 结尾的那一行为止的完整语句
menu_stmt() {
    local file=${1} line collecting=0
    while IFS= read -r line; do
        if [[ ${collecting} -eq 0 ]]; then
            [[ ${line} == *'os::action_menu'* ]] || continue
            collecting=1
        fi
        printf '%s\n' "${line}"
        [[ ${line} == *\\ ]] || collecting=0
    done <"${file}"
}

menu_checked=0
for f in "${files[@]}"; do
    # 两个都要有才是「带二级菜单的脚本」。只看 os::action_menu 的话，
    # 本文件自己的注释里提到它就会被算进来，然后拿注释里的示例当菜单项报错
    grep -q 'os::action_menu' "${f}" 2>/dev/null || continue
    grep -q '^dispatch()' "${f}" 2>/dev/null || continue
    menu_checked=$((menu_checked + 1))
    # 菜单项形如 'run=立即备份'，取 `=` 左边的动作名。`--overview action_ls`
    # 也是一个可从 CLI 调用、但交互时已经直接展示的 dispatch 动作；把函数名的
    # action_/do_ 前缀去掉后合进菜单集合，才能同时守住「不能漏入口」与「总览
    # 不必占一个重复菜单项」。
    # `|| true`：grep 找不到就返回 1，而 `var=$(...)` 会把它变成整条脚本的
    # 退出状态 —— set -e 下这里会静默死掉，连「检查了几个」都印不出来
    menu_acts=$(menu_stmt "${f}" | grep -oE "'[a-z][a-z0-9-]*=" | tr -d "'=" || true)
    overview_fn=$(menu_stmt "${f}" | sed -nE 's/.*--overview[[:space:]]+([a-z_][a-z_0-9]*).*/\1/p' | head -n1)
    case "${overview_fn}" in
        action_*) menu_acts+=$'\n'"${overview_fn#action_}" ;;
        do_*) menu_acts+=$'\n'"${overview_fn#do_}" ;;
        '') ;;
        *) report_fail "${f}：--overview 函数 ${overview_fn} 必须以 action_ 或 do_ 开头，才能对应 dispatch 动作" ;;
    esac
    menu_acts=$(printf '%s\n' "${menu_acts}" | sed '/^$/d' | sort -u)
    # dispatch 的 case 分支形如 `run) …` 或 `a | b) …`
    disp_acts=$(sed -n '/^dispatch()/,/^}/p' "${f}" \
        | grep -oE '^[[:space:]]+[a-z][a-z0-9|* -]*\)' | tr -d ' )' \
        | tr '|' '\n' | sort -u || true)
    while IFS= read -r act; do
        [[ -n "${act}" ]] || continue
        printf '%s\n' "${disp_acts}" | grep -qx -- "${act}" \
            || report_fail "${f}：菜单项「${act}」在 dispatch 里没有对应分支"
    done <<<"${menu_acts}"
    while IFS= read -r act; do
        [[ -n "${act}" ]] || continue
        printf '%s\n' "${menu_acts}" | grep -qx -- "${act}" \
            || report_fail "${f}：dispatch 分支「${act}」不在菜单里，菜单用户看不到它"
    done <<<"${disp_acts}"
done
printf '检查了 %d 个带二级菜单的脚本\n' "${menu_checked}"

# --- 14. root-nolock 必须零系统副作用 ---
#
# 这一档是为「每十秒采一次的定时器」开的：它需要 root 才探得到 systemctl /
# ufw / sshd -T，但持全局锁会随机挡住用户敲的真实命令，所以放它不取锁。
# 代价是它与真实变更并发运行 —— 一旦有人往这类脚本里塞副作用，那个副作用
# 就是在**没有互斥**的情况下发生的，正是单一全局锁要防的事。
#
# 只允许 os::query 的只读查询与 probe::。os::run 与 os::run_out 都有副作用，
# 两个都要拦 —— `` 在 `run` 与 `_` 之间不成立，所以必须分别列出。
#
# **os::install_file 曾经不在这张表里**，于是采集器用它往盘上刷了一份历史曲线 ——
# 一个不持锁的进程在写持久文件，正是这一档要防的那件事，而检查全程绿灯。
#
# **os::tmpdir 是 D244 之后加进来的**：它从前落 /run 的 tmpfs（重启即空，不算
# 持久写），落点搬到 /var/tmp 之后，调它就是在磁盘上建目录。现有两个采集器都
# 没用它，这条是防下一个。
# 黑名单只拦得住已经想到的那些：新增任何落地写接口时都得回来看一眼这里。
# public/ 下的只读产物走 os::write_public，那是这一档唯一允许的写通道。
# 静态门禁不假装自己能理解任意 shell：除公开写接口外，再覆盖常见外部写命令
# 与直接指向 OS_* / 持久绝对路径的重定向。动态构造、间接调用仍由 review 兜底。
raw_writer_re='(^|[;&|({]|[[:space:]](then|do|else))[[:space:]]*(rm|mv|cp|install|mkdir|rmdir|touch|truncate|tee|chmod|chown|ln|systemctl|service|apt-get|dpkg|dpkg-divert|update-alternatives|mount|umount|kill|pkill|reboot|shutdown)([[:space:]]|$)'
persistent_redirect_re='(^|[^<])>>?[[:space:]]*"?([$][{]?OS_|/opt/oneserver|/etc/oneserver|/var/log/oneserver|/var/backups/oneserver|/run/oneserver|/var/tmp/oneserver)'

section "root-nolock 零副作用"
nolock_checked=0
for f in "${files[@]}"; do
    grep -qE '^#[[:space:]]*@privilege[[:space:]]+root-nolock' "${f}" 2>/dev/null || continue
    nolock_checked=$((nolock_checked + 1))
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}：@privilege root-nolock 不得调用 ${hit}"
    done < <(grep -oE '\bos::(run|run_out|state_set|state_del|state_resource_add|state_resource_del|state_unit_add|install_template|install_file|secure_set|secure_del|destroy_confirm|tmpdir)\b' "${f}" \
        | sort -u || true)
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} @privilege root-nolock 不得裸调外部写命令：${hit#*:}"
    done < <(grep -nE "${raw_writer_re}" "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} @privilege root-nolock 不得向持久路径直接重定向：${hit#*:}"
    done < <(grep -nE "${persistent_redirect_re}" "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个 root-nolock 脚本\n' "${nolock_checked}"

# --- 15. 运行时路径不硬编码 ---
#
# 规范：路径的单一来源是 `lib/paths.sh`。第二处路径字面量不会跟着第一处改，
# 而它们分歧的那一刻不会有任何报错 —— 只是程序开始往一个没人维护的目录写东西。
# 真实存在过：`DB_BACKUP_DIR='/var/backups/oneserver/db'` 连同 `OS_BACKUP_DIR_MODE`
# 定义的 0700 一起绕过去了。
#
# **只查赋值右值与 `for … in` 列表**，不查命令参数位置。判据要可判定：路径
# 存进变量、或被循环遍历，就是拿它当路径用；而命令参数上的字面量多是给人看的
# 文本（`os::die '…模板留在 /etc/oneserver/templates/'`），desc 更是被第 6 项
# 强制成固定字符串、根本不许用变量。这样划分之后，`source /opt/oneserver/lib/
# bootstrap.sh` 这行规范逐字规定的引导语句自动落在范围之外，一条特例都不用写。
#
# lib/paths.sh 是来源，它自己当然要写字面量。
#
# **根卸载器也在范围内。** 它不在 script/ 下，早先因此整个落在检查之外 ——
# 而它恰恰是删东西的那个脚本，路径写错的后果比别处都大。它 source 了
# bootstrap，常量拿得到，没有豁免的理由。
#
# install.sh 与切换器仍在范围外，那是规范写明的两个自包含例外：前者跑在还没有
# /opt/oneserver 的机器上，后者要替换的正是自己脚下那棵树，两者都 source 不了
# lib/，路径只能自带。

section "运行时路径"
hardpath_re="^[[:space:]]*(readonly[[:space:]]+|local[[:space:]]+|declare[[:space:]]+-[a-zA-Z]+[[:space:]]+)?[A-Za-z_][A-Za-z_0-9]*=[\"']?(${RUNTIME_PATHS})"
hardpath_re="${hardpath_re}|^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z_0-9]*[[:space:]]+in[[:space:]].*(${RUNTIME_PATHS})"
path_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        lib/paths.sh) continue ;;
        script/* | bin/* | lib/* | uninstall.sh) ;;
        *) continue ;;
    esac
    path_checked=$((path_checked + 1))
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} 硬编码了运行时路径，改用 lib/paths.sh 里的变量：$(printf '%s' "${hit#*:}" | head -c 60)"
    done < <(grep -nE "${hardpath_re}" "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个文件\n' "${path_checked}"

# --- 16. eval 全项目零使用 ---
#
# 规范对 `eval` 的措辞是「全项目当前零使用，不留例外；确需时先改本文件说明
# 理由」。第 7 项只在切换器里拦它，其余六十多个文件不在任何检查之内 ——
# 而「零使用」这个状态一旦破了一次，规范那句话就再也不是事实。
#
# 范围是**会落到用户机器上以 root 跑的代码**，不含 tests/：检查器自己必然
# 要写出它所检查的那个词（本节的 grep 模式就是），把它算成违规只能靠给
# 自己开特例，而特例一旦存在就会被下一个人用来豁免别的东西。

section "eval 与 sh -c"
eval_hits=0
for f in "${files[@]}"; do
    case "${f}" in
        bin/* | lib/* | script/* | packaging/* | templates/* | install.sh) ;;
        *) continue ;;
    esac
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        eval_hits=$((eval_hits + 1))
        report_fail "${f}:${hit%%:*} 用了 eval —— 规范要求全项目零使用，确需时先改规范说明理由"
    done < <(grep -nE '(^|[^_[:alnum:]])eval[[:space:]]' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf 'eval 全项目 %d 处\n' "${eval_hits}"

# 同一条关切的第二半：`sh -c "…${值}…"` 是 eval 的另一种写法。
# **不单列一项**，因为它与上面查的是同一件事——禁止把数据拼成可执行文本。
#
# `eval` 被禁了，`sh -c "…${值}…"` 却是它的另一种写法，而且此前不在任何检查
# 之内。真实后果不是理论上的：`restore.sh` 的远端列举函数把 `rclone lsf` 返回的
# **远端目录名**拼进内层 shell 的脚本文本，于是一个名为 `x'; <命令>; :'` 的
# 远端目录能闭合那对单引号 —— 「谁能往备份桶里写东西」就等于「谁能在恢复机上
# 以 root 执行命令」。
#
# 判据是 `${`，不是 `$`。两者分得很干净：
#   * 危险：`sh -c "… '${dir}' …"`   —— 外层 shell 展开后拼进脚本文本
#   * 安全：`sh -c "… \"\$1\" …" sh "${dir}"` —— `$1` 是内层 shell 的位置参数，
#     值经 argv 传入，从结构上不可能被当成语法
# 后者是本仓库既有的正确写法（probe.sh 全部如此），不该被误伤。
#
# **先把续行接起来再查。** `sh -c \` 换行写的时候，脚本文本落在下一行上，
# 单行 grep 什么也看不到 —— 备份脚本那句 `sh -c \` + `"cd '${dir}' && sha256sum …"`
# 就是这么在检查眼皮底下待着的：形态与被禁的那种一模一样，只是多了个换行。
# 接行之后行号取**起始行**，报出来的位置仍指向 `sh -c` 那一行。
#
# **这条检查仍不完备，故意的。** 先拼进变量再传给 `sh -c` 的写法查不出来 ——
# 规范 §10 已经写明「动态构造或间接执行无法由文本检查完备证明，仍须代码审查」。
# 能被静态发现的那一类不该因为存在查不出的那一类就放着不查。

# logical_lines <文件>   行尾反斜杠续行接成一条逻辑行，输出「起始行号:内容」
logical_lines() {
    awk '{
        line = $0
        start = FNR
        while (line ~ /\\$/) {
            if ((getline nxt) <= 0) { break }
            sub(/\\$/, "", line)
            sub(/^[[:space:]]+/, " ", nxt)
            line = line nxt
        }
        printf "%d:%s\n", start, line
    }' "${1}"
}

shc_hits=0
for f in "${files[@]}"; do
    case "${f}" in
        bin/* | lib/* | script/* | packaging/* | templates/* | install.sh | uninstall.sh) ;;
        *) continue ;;
    esac
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        shc_hits=$((shc_hits + 1))
        report_fail "${f}:${hit%%:*} 把 \${…} 拼进了 sh -c 的脚本文本 —— 值要经位置参数传入（sh -c '… \"\$1\" …' sh \"\${值}\"）"
    done < <(logical_lines "${f}" \
        | grep -E '\b(sh|bash)[[:space:]]+-c[[:space:]]+"[^"]*\$\{' \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf 'sh -c 拼接 %d 处\n' "${shc_hits}"

# --- 17. lib 分层与装配 ---
#
# 三条规矩，坏掉的方式各不相同，但都不会当场报错：
#
#   * L0（paths/defaults/theme）只有变量赋值。它们在 bootstrap 最早期被 source，
#     那时日志与 trap 都还没起来 —— 在这里执行命令，失败了连一行记录都没有。
#   * lib 模块之间不互相 source（不变量 2）。装配只有一处，顺序才是显式的；
#     而 tests/helper/load.sh 正是照着 bootstrap 的顺序装的，模块一旦自己
#     source 别人，测试装配的就是一个现实中不存在的加载顺序。
#   * lib 不依赖 jq/python/perl。零运行时依赖是产品边界，不是偏好。

section "lib 分层"
layer_checked=0
for f in "${files[@]}"; do
    [[ "${f}" == lib/*.sh ]] || continue
    layer_checked=$((layer_checked + 1))

    case "${f}" in
        lib/paths.sh | lib/defaults.sh | lib/theme.sh)
            while IFS= read -r hit; do
                [[ -n "${hit}" ]] || continue
                report_fail "${f}:${hit%%:*} L0 只允许变量赋值，不得有函数、条件或命令调用：$(printf '%s' "${hit#*:}" | head -c 60)"
            done < <(grep -nE '^[[:space:]]*[a-z_]+\(\)|^[[:space:]]*(if|case|for|while)[[:space:]]|\$\(|`' "${f}" \
                | grep -vE '^[0-9]+:[[:space:]]*#' || true)
            ;;
    esac

    # bootstrap 是唯一的装配点，source 是它的职责
    if [[ "${f}" != lib/bootstrap.sh ]]; then
        while IFS= read -r hit; do
            [[ -n "${hit}" ]] || continue
            report_fail "${f}:${hit%%:*} lib 模块之间禁止互相 source，装配只在 bootstrap.sh 里做"
        done < <(grep -nE '^[[:space:]]*(source|\.)[[:space:]]+' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
    fi

    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        report_fail "${f}:${hit%%:*} lib 不得依赖 jq/python/perl（零运行时依赖是产品边界）"
    done < <(grep -nE '(^|[^-_[:alnum:]])(jq|python3?|perl)([^-_[:alnum:]]|$)' "${f}" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)
done
printf '检查了 %d 个 lib 模块\n' "${layer_checked}"

# --- 18. 命令脚本的文件头 ---
#
# 规范逐字规定：严格 Bash 设置、受限 PATH、`umask 027`，随后 source
# bootstrap.sh，全文件仅一次。少一样的后果都不在本地显形：
# 少 `umask 027` 时落地的文件对同机其他用户可读；少受限 PATH 时以 root
# 跑的是 PATH 上先找到的那个同名程序；source 两次会让 trap 与全局状态
# 重新初始化一遍，而第一次的记录就此丢失。
#
# **不按 `@command` 筛。** `script/**` 下还有由 systemd 直接 ExecStart 的内部
# 步骤脚本（采集器、通知器），它们同样以 root 跑、同样落文件，少一样的后果
# 一模一样；按 `@command` 筛只是因为「命令」这个词，不是因为风险有区别。
# 根卸载器同理：它不在 script/ 下，却是删东西的那个，更没有豁免的理由。
#
# install.sh 与切换器不在此列 —— 规范的两个自包含例外，它们 source 不了 lib/，
# 「随后 source bootstrap.sh」这条对它们不成立。

section "脚本文件头"
head_checked=0
for f in "${files[@]}"; do
    case "${f}" in
        script/* | uninstall.sh) ;;
        *) continue ;;
    esac
    head_checked=$((head_checked + 1))
    grep -qx 'set -Eeuo pipefail' "${f}" || report_fail "${f} 缺 'set -Eeuo pipefail'"
    grep -qx "PATH='/usr/sbin:/usr/bin:/sbin:/bin'" "${f}" || report_fail "${f} 缺受限 PATH"
    grep -qx 'umask 027' "${f}" || report_fail "${f} 缺 'umask 027'"
    n_boot=$(grep -c '^source /opt/oneserver/lib/bootstrap\.sh$' "${f}" || true)
    [[ "${n_boot}" -eq 1 ]] \
        || report_fail "${f} source bootstrap.sh ${n_boot} 次，规范要求全文件恰好一次"
done
printf '检查了 %d 个脚本的文件头\n' "${head_checked}"

# --- 19. 元数据自洽 ---
#
# `doctor --selftest` 查的是**装到机器上的那一份**，消费者是切换器：它要在
# 回滚窗口还开着的时候判断「这一版能不能用」。这里查的是**提交进仓库的那一份**，
# 消费者是写代码的人。同一类判断放在两个时刻，因为两边都无法替代对方 ——
# 一个 @order 撞车如果要等到装上去才发现，那台机器上的菜单已经是坏的了。
#
# **@order 的唯一性是组内的，不是全局的。** 它只决定排序（菜单编号按屏重排
# 1..N，不上屏），组与组之间互不相干；要求全局唯一的代价是加一个脚本得先
# 全仓找一个没被占的号，还得落在正确的号段里 —— 那是把「排序」和「标识」
# 两件事塞进同一个整数造成的。
#
# 只查静态可判定的：编号与命令名撞车、@group 的取值不存在、@requires_lib
# 声明的框架版本比仓库里的还新（那条脚本装上去必然一跑就退出）、
# @provides_unit 少了 own:/ext: 前缀（卸载时决定删文件还是只停服务），以及
# @args 与所有交互调用的 --arg 名字集合不一致。最后一项必须双向检查：只比
# 数量会被复用名字、分支与循环蒙混，而漏声明会让帮助/补全与非交互契约分裂。

section "脚本元数据"
meta_checked=0
lib_api_version=$(tr -d ' \t\n\r' <"${REPO_ROOT}/lib/API_VERSION" 2>/dev/null || printf '')
[[ -n "${lib_api_version}" ]] || report_fail 'lib/API_VERSION 读不到'
declare -a meta_orders=() meta_commands=()
meta_group=''
# 内部步骤脚本没有 @command，不参与菜单字段检查，但 bootstrap 仍会读取它的
# @privilege 与 @requires_lib。单独覆盖这类文件，避免 systemd 周期任务在安装后
# 才发现依赖版本写旧、写高或元数据掉出前 40 行。
internal_meta_checked=0
for f in "${files[@]}"; do
    [[ "${f}" == script/* ]] || continue
    grep -qE '^#[[:space:]]*@command[[:space:]]' "${f}" && continue
    internal_meta_checked=$((internal_meta_checked + 1))
    n_privilege=$(grep -cE '^#[[:space:]]*@privilege[[:space:]]+' "${f}" || true)
    n_requires_lib=$(grep -cE '^#[[:space:]]*@requires_lib[[:space:]]+' "${f}" || true)
    [[ ${n_privilege} -eq 1 ]] \
        || report_fail "${f} 的 @privilege 有 ${n_privilege} 条，内部步骤脚本必须恰好一条"
    [[ ${n_requires_lib} -eq 1 ]] \
        || report_fail "${f} 的 @requires_lib 有 ${n_requires_lib} 条，内部步骤脚本必须恰好一条"

    meta_code=$(grep -nE '^set -Eeuo' "${f}" | head -n1 | cut -d: -f1)
    meta_last=$(head -n "$((${meta_code:-41} - 1))" "${f}" \
        | grep -nE '^#[[:space:]]*@[a-z_]+[[:space:]]' | tail -n1 | cut -d: -f1)
    if [[ -n "${meta_last}" ]] && ((meta_last > 40)); then
        report_fail "${f}：元数据写到了第 ${meta_last} 行，超出 bootstrap 只读的前 40 行"
    fi
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        newest=$(printf '%s\n%s\n' "${v}" "${lib_api_version}" | sort -V | tail -1)
        [[ "${newest}" == "${lib_api_version}" ]] \
            || report_fail "${f} 要求 lib API >= ${v}，而 lib/API_VERSION 是 ${lib_api_version}"
    done < <(sed -nE 's/^#[[:space:]]*@requires_lib[[:space:]]+>=[[:space:]]*([0-9]+\.[0-9]+).*$/\1/p' "${f}")
done
printf '检查了 %d 个内部步骤脚本的元数据\n' "${internal_meta_checked}"

for f in "${files[@]}"; do
    [[ "${f}" == script/* ]] || continue
    grep -qE '^#[[:space:]]*@command[[:space:]]' "${f}" || continue
    meta_checked=$((meta_checked + 1))

    # 元数据必须整段落在**前 40 行**内 —— registry::_meta 只读那么多（规范 §6）。
    # 下面各项检查读的是整份文件，所以写在 41 行之后的字段这里条条都过，装到机器上
    # 才发现少了半截：@command 掉出窗口是「这条命令莫名其妙不存在」，@order 掉出去
    # 是 doctor --selftest 报「@order 缺失」。头注释写长一点就会把它们挤出去，
    # 只有专门查一次行号才拦得住。
    # 只看**文件头那一段注释**（`set -Eeuo` 之前）：正文里解释某个字段的注释也以
    # `# @order …` 开头，连它一起数就会把 doctor.sh 这类脚本误报成元数据超窗
    meta_code=$(grep -nE '^set -Eeuo' "${f}" | head -n1 | cut -d: -f1)
    meta_last=$(head -n "$((${meta_code:-41} - 1))" "${f}" \
        | grep -nE '^#[[:space:]]*@[a-z_]+[[:space:]]' | tail -n1 | cut -d: -f1)
    if [[ -n "${meta_last}" ]] && ((meta_last > 40)); then
        report_fail "${f}：元数据写到了第 ${meta_last} 行，超出 registry 只读的前 40 行——把长说明挪到 source 之后"
    fi

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        meta_commands+=("${v}")
    done < <(sed -nE 's/^#[[:space:]]*@command[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' "${f}")
    # @group 先读出来：@order 的唯一性是**组内**的，撞不撞车要连着组一起看
    meta_group=$(sed -nE 's/^#[[:space:]]*@group[[:space:]]+([a-z0-9-]+).*$/\1/p' "${f}" | head -n1)
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        meta_orders+=("${meta_group}/${v}")
    done < <(sed -nE 's/^#[[:space:]]*@order[[:space:]]+([0-9]+).*$/\1/p' "${f}")

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        # groups.conf 按 `|` 切字段，id 后面允许有对齐用的空格
        grep -qE "^${v}[[:space:]]*\|" "${REPO_ROOT}/templates/groups.conf" \
            || report_fail "${f} 的 @group「${v}」不在 templates/groups.conf 里"
    done < <(sed -nE 's/^#[[:space:]]*@group[[:space:]]+([a-z0-9-]+).*$/\1/p' "${f}")

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        case "${v}" in
            own:* | ext:*) ;;
            *) report_fail "${f} 的 @provides_unit「${v}」缺 own:/ext: 前缀（卸载时据此决定删文件还是只停服务）" ;;
        esac
    done < <(sed -nE 's/^#[[:space:]]*@provides_unit[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' "${f}")

    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        # 排序取最大值，若最大的不是仓库里这版就说明脚本要的比现有的新
        newest=$(printf '%s\n%s\n' "${v}" "${lib_api_version}" | sort -V | tail -1)
        [[ "${newest}" == "${lib_api_version}" ]] \
            || report_fail "${f} 要求 lib API >= ${v}，而 lib/API_VERSION 是 ${lib_api_version}"
    done < <(sed -nE 's/^#[[:space:]]*@requires_lib[[:space:]]+>=[[:space:]]*([0-9]+\.[0-9]+).*$/\1/p' "${f}")

    declared_args=$(sed -nE 's/^#[[:space:]]*@args[[:space:]]+(.+)$/\1/p' "${f}" \
        | grep -oE -- '--[a-z][a-z0-9-]*' | sed 's/^--//' | sort -u || true)
    interaction_args=$(grep -vE '^[[:space:]]*#' "${f}" \
        | grep -oE -- "--arg[[:space:]]+['\"]?[a-z][a-z0-9-]*" \
        | sed -E 's/^--arg[[:space:]]+//; s/["'\'']//g' | sort -u || true)
    while IFS= read -r v; do
        [[ -n ${v} ]] || continue
        printf '%s\n' "${interaction_args}" | grep -qx -- "${v}" \
            || report_fail "${f} 的 @args 声明了 --${v}，但没有同名交互调用"
    done <<<"${declared_args}"
    while IFS= read -r v; do
        [[ -n ${v} ]] || continue
        printf '%s\n' "${declared_args}" | grep -qx -- "${v}" \
            || report_fail "${f} 的交互调用使用 --arg ${v}，但 @args 没有声明 --${v}"
    done <<<"${interaction_args}"
done

# --- @description 要塞得进菜单的说明列 ---
#
# 它同时喂 `--help` 与菜单第二列。写成一整句的后果是菜单里每一条都以 `…` 收尾，
# 既没说清这条命令干什么，又把一屏搞得全是省略号 —— 说明列的意义当场归零。
#
# 阈值 48 从最窄的那一屏推出来：`安装与部署` 的标签列宽 20（`MariaDB（MySQL）安装`），
# 框宽 80 时说明列只剩 49 格。按**显示宽度**算，所以借 lib/ui.sh 的 ui::width——
# 一个中文字占两格，按字符数算会漏掉一半。
desc_max=48
while IFS= read -r f; do
    [[ "${f}" == script/* ]] || continue
    grep -qE '^#[[:space:]]*@command[[:space:]]' "${f}" || continue
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        w=$(
            # shellcheck source=/dev/null
            source "${REPO_ROOT}/lib/theme.sh"
            # shellcheck source=/dev/null
            source "${REPO_ROOT}/lib/ui.sh"
            ui::width "${v}"
        )
        ((w <= desc_max)) \
            || report_fail "${f} 的 @description 宽 ${w} 格，超过 ${desc_max}——菜单里会被截断成省略号"
    done < <(sed -nE 's/^#[[:space:]]*@description[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' "${f}")
done < <(printf '%s\n' "${files[@]}")

# --- 分组说明：落在菜单的同一列，且只有收纳分组用得到 ---
#
# 分组只剩一个可见成员时，groups.conf 第五列顶替那条成员脚本的 @description
# 占说明列，超宽同样被截成省略号 —— 同一列同一个阈值。
#
# 顶层分组（没有 parent 的）在菜单里只作为分区标题出现，标题没有说明列：
# 写在那儿的字一个都不会显示，而写的人不会知道。
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    IFS='|' read -r gid _ _ gparent gdesc <<<"${line}"
    gid="${gid//[[:space:]]/}"
    gparent="${gparent//[[:space:]]/}"
    gdesc="${gdesc#"${gdesc%%[![:space:]]*}"}"
    gdesc="${gdesc%"${gdesc##*[![:space:]]}"}"
    [[ -n "${gdesc}" ]] || continue
    [[ -n "${gparent}" ]] \
        || report_fail "templates/groups.conf 的顶层分组「${gid}」写了说明，但顶层分组在菜单里只是分区标题，这一列不会显示"
    w=$(
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/theme.sh"
        # shellcheck source=/dev/null
        source "${REPO_ROOT}/lib/ui.sh"
        ui::width "${gdesc}"
    )
    ((w <= desc_max)) \
        || report_fail "templates/groups.conf 的分组「${gid}」说明宽 ${w} 格，超过 ${desc_max}——菜单里会被截断成省略号"
done <"${REPO_ROOT}/templates/groups.conf"

if [[ ${#meta_orders[@]} -gt 0 ]]; then
    while IFS= read -r dup; do
        [[ -n "${dup}" ]] || continue
        report_fail "@order「${dup#*/}」在分组「${dup%%/*}」里被多个脚本用了，组内先后就成了扫描顺序决定的"
    done < <(printf '%s\n' "${meta_orders[@]}" | sort | uniq -d)
fi
if [[ ${#meta_commands[@]} -gt 0 ]]; then
    while IFS= read -r dup; do
        [[ -n "${dup}" ]] || continue
        report_fail "@command「${dup}」被多个脚本用了，路由会取到哪一个不确定"
    done < <(printf '%s\n' "${meta_commands[@]}" | sort | uniq -d)
fi
printf '检查了 %d 个脚本的元数据\n' "${meta_checked}"

# --- 20. 公开接口的测试覆盖棘轮 ---
#
# 规范写着「改动 lib/ 必须补对应 bats 测试」，而在这条检查之前它没有执行者，
# 于是欠账只增不减 —— 加上这条检查的那天，125 个公开接口里有 26 个在
# tests/lib/ 下连名字都搜不到，其中包括 os::flag（每个脚本解析参数的入口）
# 与 probe:: 全族（它们的输出直接进 public/ 快照和只读面板）。
#
# 阈值记的是「还欠多少」，不是「允许多少」。现在是 0。
#
# 判据是「函数名在 tests/ 下出现过」，不是「被真正断言过」。它拦得住
# 「加了接口没人碰」，拦不住「提到了但没验证」—— 后者只能靠 review，
# 而前者正是现在漏掉的那 26 个的形态。
#
# 函数清单取自 docs/API.md：第 9 项已经保证它与 lib/ 一致，再解析一遍 lib/
# 就是第二个解析器，两个解析器迟早对同一份代码给出不同答案。

section "接口测试覆盖"
if [[ ! -f "${REPO_ROOT}/docs/API.md" ]]; then
    printf '跳过（docs/API.md 不在）\n'
else
    uncovered=0
    api_total=0
    while IFS= read -r fn; do
        [[ -n "${fn}" ]] || continue
        api_total=$((api_total + 1))
        # 只搜 bats 用例目录：本文件的注释里就写着 os::query 这类名字，
        # 把 tests/ 整个搜一遍会让它们凭注释「被覆盖」
        grep -rqF -- "${fn}" "${REPO_ROOT}/tests/lib/" 2>/dev/null && continue
        uncovered=$((uncovered + 1))
        printf '  未覆盖：%s\n' "${fn}"
    done < <(grep -oE '^- .(os|probe)::[a-z_0-9]+' "${REPO_ROOT}/docs/API.md" | sed 's/^- .//')
    printf '%d 个公开接口，%d 个没有任何用例提到（阈值 %d）\n' \
        "${api_total}" "${uncovered}" "${MAX_UNCOVERED_API}"
    [[ "${uncovered}" -le "${MAX_UNCOVERED_API}" ]] \
        || report_fail "未覆盖接口超过阈值 ${MAX_UNCOVERED_API} —— 新增接口要带 bats 用例"
fi

# --- 21. 出参函数的局部变量前缀 ---
#
# 规范 §10：结果经**显式输出变量**交回的函数，它的局部变量一律带 `__<模块>_`
# 前缀。`local` 在 bash 里是动态作用域 —— 局部变量与调用方传进来的那个名字
# 撞上时，`printf -v "${出参}"` 写进去的是函数自己那个副本，函数一返回就没了。
# 调用方拿到空串，而且**没有任何报错**。
#
# 恢复流程踩过的形态：`rs_safe_extract` 内部 `local stage`，调用方也叫
# `stage`。隔离目录建了、归档解了、审计过了，回到调用方 `${stage}` 仍是空串，
# 于是下一步 `chown -R -- "${stage}/${root}"` 作用在了 `/test` 上。落在一台
# 恰好有那个目录的机器上，改的就是一棵与恢复毫无关系的树。
#
# 判据取可判定的那一半：函数体里出现 `printf -v "${…}"`，它的每个 `local`
# 就必须以 `__` 开头。大写开头的（`local IFS=' '`）不计 —— 调用方传的是自己
# 声明的小写变量名，与它撞不上。
#
# 棘轮，含义同第 3 / 10 / 20 项：记的是「还欠多少」，不是「允许多少」。
# 存量分布在十几个函数里，改名要连同整个函数体一起动，值不值得一个个看；
# 新代码想加当场红。
section "出参函数的局部变量"
outvar_hits=0
for f in "${files[@]}"; do
    case "${f}" in
        bin/* | lib/* | script/*) ;;
        *) continue ;;
    esac
    while IFS= read -r hit; do
        [[ -n "${hit}" ]] || continue
        outvar_hits=$((outvar_hits + 1))
        if [[ "${outvar_hits}" -gt "${MAX_UNPREFIXED_OUTVAR_LOCALS}" ]]; then
            report_fail "${f}:${hit} 出参函数的局部变量要带 __ 前缀 —— 与调用方传进来的名字同名时，回写会写进自己那个副本，调用方拿到空串且没有任何报错"
        fi
    done < <(awk '
        /^[A-Za-z_][A-Za-z_0-9:]*\(\)[[:space:]]*\{/ {
            fn = $0; sub(/\(\).*/, "", fn)
            n = 0; body = ""; on = 1; next
        }
        on { body = body "\n" $0; L[++n] = $0; N[n] = FNR }
        on && /^\}$/ {
            if (body ~ /printf -v "\$\{/) {
                for (i = 1; i <= n; i++) {
                    if (L[i] ~ /^[[:space:]]*local[[:space:]]+(-[aiAr]+[[:space:]]+)?[a-z]/) {
                        printf "%d %s() %s\n", N[i], fn, L[i]
                    }
                }
            }
            on = 0
        }
    ' "${f}" || true)
done
printf '未加前缀的局部变量 %d 处（阈值 %d）\n' "${outvar_hits}" "${MAX_UNPREFIXED_OUTVAR_LOCALS}"
[[ "${outvar_hits}" -le "${MAX_UNPREFIXED_OUTVAR_LOCALS}" ]] \
    || report_fail "出参函数的未加前缀局部变量超过阈值 ${MAX_UNPREFIXED_OUTVAR_LOCALS}"

# --- 结论 ---

section "结论"
if [[ "${fail_count}" -eq 0 ]]; then
    printf '全部通过\n'
    exit 0
fi
printf '%d 项不通过\n' "${fail_count}" >&2
exit 1
