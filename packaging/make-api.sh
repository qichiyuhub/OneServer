#!/bin/bash
#
# 从 lib/ 生成 docs/API.md —— 脚本层可调用的接口参考
#
#   bash packaging/make-api.sh [输出路径]      默认写到 docs/API.md
#
# 接受输出路径是为了让 lint 能把结果生成到临时文件再比对：写死目标的话，
# 「检查文件有没有过期」只能靠先覆盖真文件再还原，中途被打断就把工作区
# 留在覆盖后的状态（同 packaging/make-manifest.sh 的 `[输出路径]`）。
#
# 为什么生成而不是手写：手写的清单是第二份真相，加一个函数忘了同步，
# 它就开始说谎，而说谎的清单比没有清单更糟。分发清单被收敛成
# manifest.txt 时项目已经为同一件事付过一次代价。
#
# 分工：函数名与所属模块从代码解析，永远等于实现；签名与说明由人写在
# 函数头第一行（`# <函数名> <参数>   <说明>`），lint 强制它存在。
#
# 不自动提取长选项：`os::run` 把解析委托给 `os::exec__parse`，扫本函数的
# case 分支只会得到一个空列表 —— 一个在最重要的函数上恰好失效的自动化，
# 比没有自动化更容易误导。签名行是人写的，但它是唯一一处，且被强制。
#
# 只收 os:: 与 probe::。其余前缀（ui:: log:: registry::）是框架内部，
# 脚本层禁止直接调用，列进接口参考等于邀请别人用它们。

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# 层次表。手写而不是从 bootstrap.sh 的加载顺序解析：那里的顺序是实现细节，
# 而这里要表达的是契约上的分层，两者应当一致但不应互为真相。
layer_of() {
    case ${1} in
        paths | defaults | theme) printf 'L0 常量\n' ;;
        ui | log) printf 'L1 输出\n' ;;
        exec | errors | lock) printf 'L2 基础设施\n' ;;
        secure | state | sql | systemd | firewall | probe | template) printf 'L3 能力\n' ;;
        bootstrap | registry) printf 'L4 装配\n' ;;
        *) printf '未分层\n' ;;
    esac
}

emit_module() {
    local file=${1}
    local mod
    mod=$(basename "${file}" .sh)

    awk -v mod="${mod}" '
        # 注释块：只留最后一段连续注释，供下面判断首行是不是签名行
        /^#/ { block = (prev_comment ? block "\n" $0 : $0); prev_comment = 1; next }
        /^(os|probe)::[a-z_0-9]+\(\) \{/ {
            fn = $1; sub(/\(\).*/, "", fn)
            # 私有：`::_` 开头或名字里带 `__`
            if (fn ~ /::_/ || fn ~ /__/) { prev_comment = 0; block = ""; next }
            sig = ""
            if (prev_comment) {
                split(block, lines, "\n")
                first = lines[1]
                sub(/^# ?/, "", first)
                # 首行以函数名打头才算签名行，否则是普通说明
                if (index(first, fn) == 1) sig = first
            }
            printf "%s\t%s\n", fn, sig
            prev_comment = 0; block = ""
            next
        }
        { prev_comment = 0; block = "" }
    ' "${file}"
}

main() {
    local -i total=0 missing=0
    local out="${1:-${REPO_ROOT}/docs/API.md}"
    local file mod fn sig layer
    local -i emitted_module=0
    # 反引号用八进制构造再当参数传，不写进格式串：写在单引号里 shellcheck 报
    # SC2016，写进双引号格式串又会报 SC2059。同 lib/sql.sh 的办法
    local bt
    printf -v bt '\140'

    {
        # 静态头部走带引号的 heredoc：文字里全是反引号，写进单引号 printf
        # 会被 shellcheck 当成命令替换（SC2016），而为纯文本加一条 disable
        # 会白占 disable 审计的额度
        cat <<'HEADER'
# OneServer 接口参考

**本文件由 `make api` 从 `lib/` 生成，不要手工编辑。**

收录 `script/**` 与 `bin/**` 可以调用的全部接口。其余前缀（`ui::` `log::` `registry::`）
与名字含 `_` 前缀的函数是框架内部，脚本层禁止直接调用。

设计规则与行为语义见 `docs/TECHNICAL_SPEC.md`；本文件只回答“有什么、怎么调”。

HEADER

        for file in "${REPO_ROOT}"/lib/*.sh; do
            mod=$(basename "${file}" .sh)
            [[ -s ${file} ]] || continue
            local body=''
            body=$(emit_module "${file}")
            [[ -n ${body} ]] || continue

            layer=$(layer_of "${mod}")
            if ((emitted_module)); then
                printf '\n'
            fi
            emitted_module=1
            printf '## %slib/%s.sh%s · %s\n\n' "${bt}" "${mod}" "${bt}" "${layer}"
            while IFS=$'\t' read -r fn sig; do
                [[ -n ${fn} ]] || continue
                total+=1
                if [[ -z ${sig} ]]; then
                    missing+=1
                    printf -- '- %s%s%s —— **缺签名行**\n' "${bt}" "${fn}" "${bt}"
                else
                    # 签名行形如 `os::foo <a> [b]   说明`，两个以上空格分隔签名与说明
                    local head tail
                    head=${sig%%"  "*}
                    tail=${sig#*"  "}
                    tail=${tail#"${tail%%[![:space:]]*}"}
                    if [[ ${tail} == "${sig}" || -z ${tail} ]]; then
                        printf -- '- %s%s%s\n' "${bt}" "${head}" "${bt}"
                    else
                        printf -- '- %s%s%s —— %s\n' "${bt}" "${head}" "${bt}" "${tail}"
                    fi
                fi
            done <<<"${body}"
        done
    } >"${out}"

    printf '生成 %s：%d 个接口，%d 个缺说明\n' "${out#"${REPO_ROOT}/"}" "${total}" "${missing}"
    return 0
}

main "$@"
