# lib/bootstrap.sh —— L4 组装层：脚本的唯一接入点
#
# 每个脚本以 `source /opt/oneserver/lib/bootstrap.sh` 结束文件头，
# 在这之前禁止调用任何 os::* 函数。
#
# 它做四件事：
#
#   1. **装配** —— 按依赖层顺序 source L0–L3。**全项目唯一的装配点**（D56）：
#      lib 模块之间不互相 source，顺序才是显式的、能被 CI 核对的
#   2. **收留三样没有独立模块的东西**：
#        - 呈现语义函数 os::info/ok/warn/...。它们要同时用
#          ui::（出屏）与 log::（落盘），只有能依赖全部的这一层放得下
#        - /etc/oneserver/*.conf 的加载与校验（D51 D53）
#        - 交互、不可逆确认、JSON 信封
#   3. **前置检查** ——规范的固定七步顺序
#   4. **收尾** —— probe 快照落盘、动过的 unit 写进 state
#
# 之所以是「组装层」而不是「又一个功能模块」：这里不实现任何新能力，
# 只把下面四层的能力接起来，并把它们暴露成脚本看得见的那套 os::* 名字。

# ==================================================================
# 1 · 装配 —— 顺序即依赖层，不可调换
# ==================================================================

OS_LIB_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly OS_LIB_SELF_DIR

# --- 装配期的信号兜底---
#
# errors::install 要等 15 个模块 source 完才装 trap。那几十毫秒里收到 TERM，
# 进程以 143 结束 —— 而规范说被信号打断是 **131**。调用方（CI、菜单、update
# 的自检）是按这个码区分「用户取消」「被打断」「真失败」的，多一个码就是多一
# 种它们不认识的结果。规范要求随机时刻打 SIGTERM 做自检，第一枪就可能
# 打在这个窗口里（D92）。
#
# 此刻 ui.sh / log.sh 都还没加载，能做的只有「按规范的码退出」。这不损失信息：
# 装配阶段一个副作用都还没发生，系统必然未变更。errors::install 随后会覆盖它。
trap 'exit 131' INT TERM HUP

# --- 启动模式---
#
# `command`（默认）= 一个被路由到的命令；`frontend` = bin/ 下的路由与菜单。
#
# **只认同进程里的赋值，不认从环境继承的。** 否则
# `OS_BOOT_MODE=frontend oneserver install php` 就能让一条真命令跳过取锁
# 与 EUID 校验—— 一个环境变量把两条安全条款一起关掉。
# 环境来的变量带 export 属性，`declare -p` 打出来的标志位里有 `x`。
os__decl=$(declare -p OS_BOOT_MODE 2>/dev/null || true)
os__flags=${os__decl#declare }
os__flags=${os__flags%% *}
if [[ ${os__flags} == *x* ]]; then
    printf 'oneserver: OS_BOOT_MODE 只能由前端在 source 之前赋值，不接受从环境继承\n' >&2
    exit 4
fi
unset -v os__decl os__flags
OS_BOOT_MODE="${OS_BOOT_MODE:-command}"

# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/paths.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/defaults.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/theme.sh"

# 覆盖必须在 ui.sh 初始化之前应用：ui::init 会把主题值读成缓存，
# 之后再改 OS_THEME_* 就不生效了。
os::__load_conf() {
    local file=${1} prefix=${2}
    [[ -f ${file} ]] || return 0

    # 加载前强制校验：属主必须 root、权限 ≤ 0644（D53）。
    # 一个任何人都能写的配置文件，等于把 root 的行为交给任何人决定。
    local owner mode
    owner=$(stat -c %u "${file}" 2>/dev/null) || return 0
    mode=$(stat -c %a "${file}" 2>/dev/null) || return 0
    if [[ ${owner} != 0 ]]; then
        printf 'oneserver: 拒绝加载 %s：属主不是 root\n' "${file}" >&2
        return 1
    fi
    if [[ $((8#${mode} & 8#022)) -ne 0 ]]; then
        printf 'oneserver: 拒绝加载 %s：权限 %s 允许非属主写入\n' "${file}" "${mode}" >&2
        return 1
    fi

    # **严格解析，不 source**（K12 的教训：配置文件里写什么就执行什么）
    local line key val
    while IFS= read -r line || [[ -n ${line} ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n ${line} ]] || continue
        [[ ${line} == *=* ]] || continue
        key=${line%%=*}
        val=${line#*=}
        key=${key%"${key##*[![:space:]]}"}
        val=${val#"${val%%[![:space:]]*}"}
        # 去掉可选的成对引号
        if [[ ${val} == \"*\" || ${val} == \'*\' ]]; then
            val=${val:1:${#val}-2}
        fi

        # key 必须是纯标识符，先于任何 `-v`/`printf -v` 使用。两者在遇到
        # 数组下标语法（`NAME[subscript]`）时都会对 subscript 做算术求值，
        # 而算术求值会展开命令替换——`OS_DEFAULT_FOO[$(任意命令)]=1` 这一行
        # 会在下一次任何 oneserver 命令启动时以 root 执行。属主/权限校验
        # （上面那两段）挡得住普通用户直接改文件，挡不住备份归档里被动过
        # 手脚的 manifest 解出一份属主 root、权限合规、内容含注入 key 的
        # 配置文件（restore.sh 会把 /etc/oneserver 整个解出来）。
        if [[ ! ${key} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            printf 'oneserver: %s 里的 %s 不是合法的标识符，已忽略\n' "${file}" "${key}" >&2
            continue
        fi
        if [[ ${key} != "${prefix}"* ]]; then
            printf 'oneserver: %s 里的 %s 不是 %s* 开头，已忽略\n' "${file}" "${key}" "${prefix}" >&2
            continue
        fi
        # 白名单 = L0 里已定义的同前缀变量（D51）。不另维护一张表，
        # 那会是第二份真相，加一个可调项要改两处，迟早对不上。
        if [[ ! -v ${key} ]]; then
            printf 'oneserver: %s 里的 %s 不是已知配置项，已忽略\n' "${file}" "${key}" >&2
            continue
        fi
        printf -v "${key}" '%s' "${val}"
    done <"${file}"
    return 0
}

os::__load_conf "${OS_CONF_FILE}" 'OS_DEFAULT_' || true
os::__load_conf "${OS_CONF_THEME}" 'OS_THEME_' || true

# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/ui.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/log.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/exec.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/errors.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/lock.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/secure.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/state.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/sql.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/systemd.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/firewall.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/probe.sh"
# shellcheck source=/dev/null
source "${OS_LIB_SELF_DIR}/template.sh"

# ==================================================================
# 2 · 呈现语义层 —— 脚本唯一可见的输出接口
# ==================================================================
#
# 脚本表达的是「这是什么」，不是「长什么样」。颜色、符号、宽度全在下面两层，
# 这里只做「语义 → 渲染 + 落盘」的转发。
#
# --output json 时整层静默，消息攒进信封的 messages 数组。

OS_OUTPUT='text'
OS_MSG_LEVELS=()
OS_MSG_TEXTS=()

os::__msg() {
    local level=${1} style=${2} text=${3-}
    log::write "${level}" "${text}" script
    if [[ ${OS_OUTPUT} == json ]]; then
        OS_MSG_LEVELS+=("${level}")
        OS_MSG_TEXTS+=("${text}")
        return 0
    fi
    ui::line "${style}" "${text}"
    return 0
}

# os::info <消息>   进行中，走 stdout
os::info() { os::__msg info info "${1-}"; }
# os::ok <消息>   成功，走 stdout
os::ok() { os::__msg info success "${1-}"; }
# os::warn <消息>   需注意，走 stderr
os::warn() { os::__msg warn warn "${1-}"; }
# os::err <消息>   失败，走 stderr
os::err() { os::__msg error error "${1-}"; }

# os::debug <消息>   仅进日志，--verbose 时才上屏
#
# 调试信息**只进日志**，OS_LOG_LEVEL=debug 时才可能上屏
os::debug() {
    log::write debug "${1-}" script
    return 0
}

# os::section <标题>   阶段标题
os::section() {
    log::write info "== ${1-} ==" script
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::heading "${1-}"
    return 0
}

# os::screen_heading <标题>   管理屏顶部标题
os::screen_heading() {
    log::write info "== ${1-} ==" script
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::screen_heading "${1-}"
    return 0
}

# os::kv <键> <值> [<键> <值>...]   键值对，键按显示宽度右对齐
os::kv() {
    log::write debug "kv: $*" script
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::kv "$@"
    return 0
}

# os::table <表头...> -- <单元格...>   单元格按行优先铺，列数等于表头个数
os::table() {
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::table "$@"
    return 0
}

# os::box <标题> -- <行...>   强调块
os::box() {
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::box "$@"
    return 0
}

# os::spacer   一行呈现留白
os::spacer() {
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::spacer
    return 0
}

# os::prompt <提示> [固定列宽]   提问一行，输入符另起一行，光标停在它后面
#
# 没有 `OS_OUTPUT == json` 那道闸：它一律走 stderr，而整层静默只管 stdout
# （否则出了事就是无声退出）。给 bin/ 前端用 —— 前端不许直接调 ui::。
os::prompt() {
    ui::prompt "$@"
    return 0
}

# os::menu_render <条目...>   菜单，编号原样打印不做连续重排
os::menu_render() {
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::menu "$@"
    return 0
}

# os::progress <当前> <总数> [标签]   进度，非 TTY 降级为按比例打行
os::progress() {
    [[ ${OS_OUTPUT} == json ]] && return 0
    ui::progress "$@"
    return 0
}

# os::die <退出码> <消息>
os::die() {
    local -i code=${1:-1}
    os::err "${2-}"
    exit "${code}"
}

# ==================================================================
# 3 · 全局参数
# ==================================================================

OS_YES=0
OS_NON_INTERACTIVE=0
OS_FORCE_DESTROY=0
OS_HELP=0
declare -A OS_ARG_MAP=()

os::__parse_globals() {
    local -a rest=()
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --help | -h) OS_HELP=1 ;;
            --dry-run) OS_DRYRUN=1 ;;
            --non-interactive) OS_NON_INTERACTIVE=1 ;;
            --yes | -y) OS_YES=1 ;;
            --force-destroy) OS_FORCE_DESTROY=1 ;;
            --verbose) log::set_level debug ;;
            --no-color) ui::disable_color ;;
            --output)
                OS_OUTPUT=${2:-text}
                shift
                ;;
            --output=*) OS_OUTPUT=${1#*=} ;;
            --*=*)
                # 脚本自己的 @args，形如 --version=8.3。
                # key 要剥掉前导 `--`：`--arg version` 传进来的名字是不带横线的，
                # 两边对不上的话 os::ask 永远查不到命令行给的值，
                # 于是 --non-interactive 下静默走默认值 —— 正是规范要防的事。
                local __key=${1%%=*}
                OS_ARG_MAP[${__key#--}]=${1#*=}
                ;;
            --*)
                # 开关型，形如 --with-fpm
                OS_ARG_MAP[${1:2}]=1
                ;;
            *) rest+=("${1}") ;;
        esac
        shift
    done
    # 剩下的还给调用脚本：source 出来的赋值作用在同一个 shell 上
    set -- ${rest[@]+"${rest[@]}"}
    OS_POSITIONAL=("$@")
    return 0
}
OS_POSITIONAL=()

# ==================================================================
# 4 · 元数据
# ==================================================================

OS_META_COMMAND=''
OS_META_NAME=''
OS_META_PRIVILEGE='root'
OS_META_REQUIRES=''
OS_META_REQUIRES_LIB=''
OS_META_PROVIDES=''
OS_META_ARGS=''
OS_META_DESCRIPTION=''

# 元数据必须在文件前 40 行内。多读没有好处：
# 注释块之后出现的 @ 行不被解析，限定行数让这条规则可执行。
os::__parse_meta() {
    local file=${1}
    [[ -r ${file} ]] || return 0
    local line field value
    local -i n=0
    while IFS= read -r line && ((n < 40)); do
        n+=1
        [[ ${line} == '#'*'@'* ]] || continue
        line=${line#\#}
        line=${line#"${line%%[![:space:]]*}"}
        [[ ${line} == @* ]] || continue
        field=${line%%[[:space:]]*}
        value=${line#"${field}"}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        case ${field} in
            @command) OS_META_COMMAND=${value} ;;
            @name) OS_META_NAME=${value} ;;
            @privilege) OS_META_PRIVILEGE=${value} ;;
            @requires) OS_META_REQUIRES=${value} ;;
            @requires_lib) OS_META_REQUIRES_LIB=${value} ;;
            @provides) OS_META_PROVIDES=${value} ;;
            @args) OS_META_ARGS=${value} ;;
            @description) OS_META_DESCRIPTION=${value} ;;
        esac
    done <"${file}"
    return 0
}

os::__help() {
    # 正文行用 `--indent`，缩进因此来自渲染层的 INDENT，与下面 ui::kv 的参数表
    # 落在同一列。手工敲两个空格会差一格，而用 ui::box 则会把用法行按宽度截断 ——
    # 那一行是要照抄的命令
    ui::heading "${OS_META_NAME:-${OS_META_COMMAND}}"
    [[ -n ${OS_META_DESCRIPTION} ]] && ui::line --indent plain "${OS_META_DESCRIPTION}"
    ui::heading '用法'
    ui::line --indent plain "oneserver ${OS_META_COMMAND} ${OS_META_ARGS}"
    ui::heading '全局参数'
    ui::kv \
        '--help' '显示本帮助' \
        '--dry-run' '预演，不产生变更' \
        '--non-interactive' '所有交互点取默认值，无默认值则以退出码 2 终止' \
        '--yes' '所有确认点视为「是」（对删除类操作不生效）' \
        '--force-destroy' '允许不可逆操作' \
        '--verbose' '等价 OS_LOG_LEVEL=debug' \
        '--output <fmt>' 'text（默认）或 json' \
        '--no-color' '强制关闭颜色'
    return 0
}

# ==================================================================
# 5 · 交互
# ==================================================================
#
# 每个调用点必须带 --arg <名字>，且名字集合与 @args 完全一致。
# 少一个的后果不是「卡住」那么轻：--non-interactive 下框架会**静默替用户
# 做出他没同意的选择** —— K2 就是这类问题的极端形式（默认 y 把数据库开到公网）。

os::__arg_of() {
    local name=${1}
    if [[ -v "OS_ARG_MAP[${name}]" ]]; then
        printf '%s' "${OS_ARG_MAP[${name}]}"
        return 0
    fi
    return 1
}

# 终端里复制出来的路径常常连着一对引号（`"/root/x/"`），粘进来就是带引号的
# 字面量：校验判它不是绝对路径，真放行了则会建出一个名字里含引号的目录。
# 让用户每次自己删引号，是把工具的毛病转嫁给人。
#
# **只剥「整个值被一对同类引号包住」这一种形态**，值中间的引号一个不动 ——
# 那可能就是内容本身（排除模式、SQL 片段），剥它等于篡改用户输入。
os::__ask_unquote() {
    local v=${1-}
    if [[ ${#v} -ge 2 ]]; then
        case ${v} in
            \"*\" | \'*\') v=${v:1:${#v}-2} ;;
        esac
    fi
    printf '%s' "${v}"
}

# os::__ask_valid <值> <正则> <校验函数>   两者都为空即无条件通过
os::__ask_valid() {
    local __os_v=${1} __os_re=${2-} __os_fn=${3-}
    if [[ -n ${__os_re} && ! ${__os_v} =~ ${__os_re} ]]; then
        return 1
    fi
    if [[ -n ${__os_fn} ]]; then
        "${__os_fn}" "${__os_v}" || return 1
    fi
    return 0
}

# os::ask [--match <正则>] [--validate <函数名>] [--hint <说明>] [--multiline] --arg <name> <提示> <变量名> [默认值]
#
# `--multiline` 认行尾反斜杠续行：一行以 `\` 结尾就接着读下一行，直到某行不以
# 它结尾。**这不是额外发明的语法，就是 shell 自己的续行规则** —— 用户要粘的
# `docker run … \` 本来就是照那个规则断的行，工具按同一套规则理解它，
# 「粘进来的命令」与「在终端里敲的同一条命令」才是同一个东西。
# 拼接时**不补空格**，同样因为 shell 里 `\` 加换行等于什么都没有。
#
# 没有它的话，多行粘贴的后果不是「只读到第一行」那么轻：剩下几行还留在 stdin 里，
# 会被后面几个 os::ask 依次读走 —— 用户看到的是自己命令的碎片变成了别的问题的答案。
#
# `--match` / `--validate` 给出「什么算合法」，`--hint` 给出人话说明。
# **交互下不合法就在原地重问**（最多三次），命令行与非交互默认值不合法则以 2 停下 ——
# 那两条路上重问一次读到的还是同一个值。
# **所有局部变量都带 `__os_` 前缀，这不是风格洁癖。**
# `printf -v "${varname}"` 是在**本函数的作用域里**写变量：调用方写
# `os::ask --arg name '库名' name ''` 时，varname 恰好是 `name`，而本函数
# 原来也有一个 `local name`（存 --arg 的名字）—— 于是值写进了这个局部变量，
# 调用方的 `name` 一个字都没拿到，**不报错、不警告**，`--non-interactive`
# 下表现为「必须给出数据库名称」，而命令行上明明写着 --name=blog。
# db_manager 的容器验收就是这么撞上的。带前缀之后撞名不再可能。
os::ask() {
    local __os_name='' __os_prompt='' __os_varname='' __os_default=''
    local __os_match='' __os_validate='' __os_hint=''
    local -i __os_multiline=0
    # **按位置计数，不按「哪个还是空的」判**：`os::ask --arg from '提示' from ''`
    # 里默认值就是空串（「留空表示不限制」），而按空判的话它与「根本没给默认值」
    # 无法区分 —— 于是 --non-interactive 会以退出码 2 拒绝一条完全合法的调用。
    # 试点脚本的 --from 就是这么卡住的。
    local -i __os_pos=0 __os_has_default=0
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --arg)
                __os_name=${2-}
                shift 2
                ;;
            --match)
                __os_match=${2-}
                shift 2
                ;;
            --validate)
                __os_validate=${2-}
                shift 2
                ;;
            --hint)
                __os_hint=${2-}
                shift 2
                ;;
            --multiline)
                __os_multiline=1
                shift
                ;;
            *)
                case ${__os_pos} in
                    0) __os_prompt=${1} ;;
                    1) __os_varname=${1} ;;
                    2)
                        __os_default=${1}
                        __os_has_default=1
                        ;;
                esac
                __os_pos+=1
                shift
                ;;
        esac
    done
    if [[ -z ${__os_name} || -z ${__os_varname} ]]; then
        os::die 2 "os::ask 缺少 --arg 或变量名"
    fi

    # 命令行给的值同样要过校验，但**这里不能重问** —— 值来自 argv，
    # 重问一次读到的还是同一个。不合法就以 2 停下并说清哪里不对。
    local __os_given
    if __os_given=$(os::__arg_of "${__os_name}"); then
        __os_given=$(os::__ask_unquote "${__os_given}")
        if ! os::__ask_valid "${__os_given}" "${__os_match}" "${__os_validate}"; then
            os::die 2 "--${__os_name} 的值不合法：${__os_given}${__os_hint:+（${__os_hint}）}"
        fi
        printf -v "${__os_varname}" '%s' "${__os_given}"
        return 0
    fi
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        if [[ ${__os_has_default} -eq 1 ]]; then
            if ! os::__ask_valid "${__os_default}" "${__os_match}" "${__os_validate}"; then
                os::die 2 "--${__os_name} 的默认值不合法：${__os_default}${__os_hint:+（${__os_hint}）}"
            fi
            printf -v "${__os_varname}" '%s' "${__os_default}"
            return 0
        fi
        os::die 2 "--non-interactive 下缺少必需参数 --${__os_name}"
    fi

    # 提示里必须**明说回车会得到什么**。只打一个 `[8.4]` 的话，屏幕上是一行
    # 没有任何动作指示的文字，人会以为命令卡住了 —— 而交互式安装里
    # 「看着像挂了」和真的挂了后果一样：下一步就是 Ctrl-C，可能正打在装包中途。
    # `__os_tip`（回车会得到什么）与 `--hint`（怎样才算合法）是两回事，
    # 分别传给渲染层：前者对齐到固定列跟在问题后面，后者另起一行落在问题与
    # 输入符之间。都不许拼进提示文本 —— 拼进去就再也对不齐了
    local __os_reply=''
    local __os_tip=''
    if [[ -n ${__os_default} ]]; then
        __os_tip="${OS_UI_SYM_ENTER} ${__os_default}"
    elif [[ ${__os_has_default} -eq 0 ]]; then
        __os_tip='必填'
    fi

    # 没有默认值时**空输入不算数**，重问。原来直接把空串写进调用方的变量，
    # 于是「必填」在交互下形同虚设：回车一按就带着空值往下跑，
    # 而 --non-interactive 那边明明是以退出码 2 拒绝的 —— 同一个调用点，
    # 两条路径两种结果。三次仍为空就停下（同 os::ask_secret）。
    # 值不合法时**在原地重问**。原来是脚本各自在 os::ask 之后写一条
    # `... || os::die 2 "不合法"`，于是打错一个字符整条命令就结束了 ——
    # 交互式部署里前面填的十几项也跟着白填。校验收进框架，28 个调用点
    # 一处生效，而且提示语与重问逻辑不会各写各的。
    local -i __os_tries=0
    while ((__os_tries < 3)); do
        __os_tries+=1
        ui::prompt "${__os_prompt}" "${OS_THEME_ASK_WIDTH}" "${__os_tip}" "${__os_hint}"
        IFS= read -r __os_reply || true
        if [[ ${__os_multiline} -eq 1 ]]; then
            local __os_more=''
            # stdin 到头就停：粘到一半断掉时，留着那个反斜杠交给 --validate
            # 去拒绝，比在这里空转等一个永远不来的下一行强
            while [[ ${__os_reply} == *\\ ]]; do
                __os_reply=${__os_reply%\\}
                IFS= read -r __os_more || break
                __os_reply+=${__os_more}
            done
        fi
        __os_reply=$(os::__ask_unquote "${__os_reply}")
        if [[ -z ${__os_reply} ]]; then
            if [[ ${__os_has_default} -eq 1 ]]; then
                __os_reply=${__os_default}
            else
                ui::line --err warn '这一项必须填，请重试'
                continue
            fi
        fi
        if ! os::__ask_valid "${__os_reply}" "${__os_match}" "${__os_validate}"; then
            ui::line --err warn "「${__os_reply}」不合法${__os_hint:+：${__os_hint}}，请重新输入"
            continue
        fi
        printf -v "${__os_varname}" '%s' "${__os_reply}"
        return 0
    done
    os::die 2 "连续三次没有给出合法的 --${__os_name}"
}

# os::ask_secret [--confirm] <提示> <变量名>
#
# **它没有 `--arg`，而且这是特意的。** 凭据禁止进 argv，所以它不对应
# 任何命令行参数，也就绝不去查 OS_ARG_MAP ——规范的名字集合比对不把它算在内。
# 「要不要走到这里」由一个带 `--arg` 的开关决定（例：`--set-password`）。
#
# 不复用 `os::ask` 加个 `--secret` 开关的理由：ask 做的第一件事就是查
# OS_ARG_MAP，也就是允许从命令行取值。在同一个函数里既开着这个口子又要堵住它，
# 靠的是一个分支判断；那行改错了不会有任何症状，唯一表现是密码开始从 ps 里可见。
os::ask_secret() {
    local -i __os_want_confirm=0
    local __os_prompt='' __os_varname=''
    local -i __os_pos=0
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --confirm) __os_want_confirm=1 ;;
            *)
                case ${__os_pos} in
                    0) __os_prompt=${1} ;;
                    1) __os_varname=${1} ;;
                esac
                __os_pos+=1
                ;;
        esac
        shift
    done
    if [[ -z ${__os_prompt} || -z ${__os_varname} ]]; then
        os::die 2 "os::ask_secret 用法：[--confirm] <提示> <变量名>"
    fi
    # 凭据没有「默认值」这种东西，非交互下只能失败。
    # 自动化场景的正确答案是自动生成，不是从某处捞一个默认密码出来。
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        os::die 2 "--non-interactive 下无法输入凭据：${__os_prompt}"
    fi

    local __os_reply='' __os_again=''
    local -i __os_tries=0
    while ((__os_tries < 3)); do
        __os_tries+=1
        ui::prompt "${__os_prompt}" "${OS_THEME_ASK_WIDTH}" '不回显'
        IFS= read -rs __os_reply || true
        printf '\n' >&2
        if [[ -z ${__os_reply} ]]; then
            ui::line --err warn '不能为空，请重试'
            continue
        fi
        # **长度下限与脱敏表同源**（OS_SECRET_MIN_LEN）。这不是口味上的密码
        # 复杂度要求：短于这个长度的值 `log::secret_add` 会拒绝登记（全局替换
        # 会把日志正文打成马赛克），于是它此后在日志、JSONL 与面板里全程明文。
        # 从前下限只写在出口，入口一个字都不查——一个 5 位的手输密码因此可以
        # 一路穿到一个本机全局可读的文件里。理由要说出来，否则用户只会以为
        # 这里在无端刁难。
        if [[ ${#__os_reply} -lt ${OS_SECRET_MIN_LEN} ]]; then
            ui::line --err warn "至少 ${OS_SECRET_MIN_LEN} 位，请重试（短于此长度的凭据无法在日志里被可靠脱敏）"
            continue
        fi
        if [[ ${__os_want_confirm} -eq 1 ]]; then
            ui::prompt '再输入一次确认' "${OS_THEME_ASK_WIDTH}" '不回显'
            IFS= read -rs __os_again || true
            printf '\n' >&2
            if [[ ${__os_reply} != "${__os_again}" ]]; then
                ui::line --err warn '两次输入不一致，请重试'
                continue
            fi
        fi
        # 值一进来就登记脱敏，此后日志/审计/JSONL/错误消息里都不会再有明文。
        # 放在赋值之前：中间只要有一步打印，就已经晚了。
        log::secret_add "${__os_reply}" || true
        # 不做任何字符删改——那是静默篡改用户的密码
        printf -v "${__os_varname}" '%s' "${__os_reply}"
        return 0
    done
    os::die 2 '连续三次未能取得有效输入'
}

# os::confirm --arg <name> <提示> [y|n]
os::confirm() {
    # 每个分支自己 shift，不在循环尾巴上补一次。
    # 原来的写法是 `--arg` 分支 shift 2、循环尾再按「$1 是不是 --arg」决定要不要
    # 再 shift 一次 —— 而 shift 2 之后 $1 早就是提示语了，于是**提示语被白白吃掉**，
    # 屏幕上只剩一个光秃秃的 `[y/N]`。试点脚本删规则时的那句确认也是这么没的。
    local name='' prompt='' default='n'
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --arg)
                name=${2-}
                shift 2
                continue
                ;;
            y | n) default=${1} ;;
            *)
                if [[ -z ${prompt} ]]; then
                    prompt=${1}
                fi
                ;;
        esac
        shift
    done
    if [[ -z ${name} ]]; then
        os::die 2 "os::confirm 缺少 --arg"
    fi

    local given
    if given=$(os::__arg_of "${name}"); then
        case ${given,,} in
            1 | y | yes | true) return 0 ;;
            *) return 1 ;;
        esac
    fi
    # --yes 对普通确认点生效；不可逆操作走 os::destroy_confirm，那里不认它
    if [[ ${OS_YES} -eq 1 ]]; then
        return 0
    fi
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        [[ ${default} == y ]] && return 0
        return 1
    fi

    # **不用 warn 样式。** 每个普通确认都顶着一个黄色叹号的话，等真正危险的
    # os::destroy_confirm 出现时已经没有对比度可用了 —— 黄色留给覆盖配置、
    # 重启服务这类，红色留给不可逆。确认句子天生比提问长，因此不补固定列。
    local reply=''
    local hint='[y/N]'
    [[ ${default} == y ]] && hint='[Y/n]'
    # 列宽给 0：确认句天生比提问长，补齐只会把 [y/N] 顶到屏幕外
    ui::prompt "${prompt}" 0 "${hint}"
    IFS= read -r reply || true
    [[ -z ${reply} ]] && reply=${default}
    case ${reply,,} in
        y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# os::flag --arg <name>   命令行给了这个开关就返回 0
#
# 它不问任何问题，`--non-interactive` 与 `--yes` 对它都没有影响 —— 没给就是没给。
# 存在的意义是让 `--bundle` 这类纯开关也有一个合规的读取入口：
# 否则脚本只能伸手去掏 OS_ARG_MAP，那是框架内部的东西（D73）。
os::flag() {
    local name=''
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --arg)
                name=${2-}
                shift 2
                ;;
            *) shift ;;
        esac
    done
    if [[ -z ${name} ]]; then
        os::die 2 "os::flag 缺少 --arg"
    fi

    local given
    given=$(os::__arg_of "${name}") || return 1
    case ${given,,} in
        0 | no | false | '') return 1 ;;
        *) return 0 ;;
    esac
}

# os::select [--required] [--reask] [--keep-screen] [--return <值>] --arg <name> <提示> <变量名> <选项>...   从清单里挑一个；选项可写 `值=说明`，`__...__=说明` 不显示内部值
#
# `--keep-screen` 不清屏，留给「总览在上、菜单在下」那种同屏组合（os::action_menu）；
# `--return <值>` 让回车不落到第一个动作上，而是把该值写进变量、离开本菜单。
#
# 选项写成 `ls=列出` 时，屏幕上是「ls  列出」，而**返回的与命令行上给的仍然是
# `ls`** —— 说明纯粹是显示层的东西，不进变量、不进 state、不进 --action=。
# `y` 与 `n` 在菜单里显示为 `Yes` 与 `No`；交互时既可输入编号，也可输入显示
# 的选项值。菜单把 y/n 画在屏幕上、却只认编号，会让人以为选了 n 而实际落到首项。
#
# 为什么需要它：动作型命令的选项天生是英文标识（`ls` `prune` `rollback`
# `on-failure`），而菜单是中文界面。没有这一列，用户面对的是一串只有写代码的人
# 看得懂的词；把中文塞进值里又会让 `--action=列出` 成为对外承诺的一部分。
#
# 值里因此**不能含 `=`**。当前全部调用点（含动态传入的版本号、rclone remote 名、
# 组件标识）都不含，真要传含 `=` 的值时这条会咬人，所以写在这里。
os::select() {
    local __os_name='' __os_prompt='' __os_varname='' __os_return=''
    local -i __os_reask=0 __os_required=0 __os_keep_screen=0
    while [[ $# -gt 0 && ${1} == --* ]]; do
        case ${1} in
            --arg)
                __os_name=${2-}
                shift 2
                ;;
            --reask)
                __os_reask=1
                shift
                ;;
            --required)
                __os_required=1
                shift
                ;;
            --keep-screen)
                __os_keep_screen=1
                shift
                ;;
            --return)
                __os_return=${2-}
                shift 2
                ;;
            *) shift ;;
        esac
    done
    __os_prompt=${1-}
    __os_varname=${2-}
    shift 2 2>/dev/null || true
    if [[ -z ${__os_name} || -z ${__os_varname} || $# -eq 0 ]]; then
        os::die 2 "os::select 用法错误"
    fi

    local -a __os_vals=() __os_labels=() __os_descs=()
    local __os_one __os_val
    for __os_one in "$@"; do
        if [[ ${__os_one} == *=* ]]; then
            __os_val=${__os_one%%=*}
            __os_vals+=("${__os_val}")
            __os_descs+=("${__os_one#*=}")
        else
            __os_val=${__os_one}
            __os_vals+=("${__os_val}")
            __os_descs+=('')
        fi
        case ${__os_val,,} in
            y) __os_labels+=('Yes') ;;
            n) __os_labels+=('No') ;;
            *) __os_labels+=("${__os_val}") ;;
        esac
    done

    # `--reask` 跳过命令行取值直接进交互，理由同 os::multiselect：
    # 常驻的二级菜单若每轮都读回同一个 `--action=`，就成了死循环
    local __os_given
    if [[ ${__os_reask} -eq 0 ]] && __os_given=$(os::__arg_of "${__os_name}"); then
        printf -v "${__os_varname}" '%s' "${__os_given}"
        return 0
    fi
    # `--required` = 这个选项**没有隐含默认值**。不加时非交互取第一项，
    # 那对「选一个动作」是合理的；对「选哪个库来删」就是替用户挑了一个目标，
    # 而且是不可逆的那种（规范：非交互下没有默认值就以 2 终止）。
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        if [[ ${__os_required} -eq 1 ]]; then
            os::die 2 "--non-interactive 下缺少必需参数 --${__os_name}"
        fi
        printf -v "${__os_varname}" '%s' "${__os_vals[0]}"
        return 0
    fi

    # 需要离开本菜单时，把动作放到不带编号的页脚里。用户只要按回车，所有
    # 菜单就遵循同一个退出习惯；1..N 始终只表示真正的可执行动作。
    #
    # `--return` 只收**回车要写进变量的那个值**，不收文案：页脚措辞由渲染层的
    # `--nav` 定死一次（否则每个调用点都能写一句自己的「返回」）。从前这里还解析
    # 一个 `值=说明`，而那个说明解析出来就没人读过 —— 改它不会有任何效果。
    local __os_return_val=${__os_return}

    local -i __os_i __os_tries=0
    local __os_reply='' __os_normalized='' __os_notice=''
    while ((__os_tries < 3)); do
        local -a __os_menu_args=(--title "${__os_prompt}")
        [[ ${__os_keep_screen} -eq 1 ]] && __os_menu_args=(--keep-screen "${__os_menu_args[@]}")
        # 错误作为菜单的一部分重画，而不是打完就走：不带 --keep-screen 时
        # 下一轮渲染会清屏，一条打在屏幕上的错误刚好在用户读到之前被擦掉
        [[ -n ${__os_notice} ]] && __os_menu_args+=(--notice "${__os_notice}")
        for ((__os_i = 0; __os_i < ${#__os_vals[@]}; __os_i++)); do
            if [[ -n ${__os_descs[__os_i]} ]]; then
                # **说明进主列，值降次列。** 菜单是中文界面，而值天生是英文标识
                # （ls / prune / on-failure）。把 token 摆在视觉重心上、中文说明
                # 反倒成了灰色附注，读起来是反的。值仍然可以直接输入。
                # `__...__` 是调用方用于进入下一层菜单的内部控制值，界面只提供编号，
                # 不把它泄露到界面；返回值与后续分支逻辑保持不变。
                if [[ ${__os_vals[__os_i]} == __*__ ]]; then
                    __os_menu_args+=(--item "$((__os_i + 1))" "${__os_descs[__os_i]}")
                else
                    __os_menu_args+=(--item "$((__os_i + 1))" "${__os_descs[__os_i]}" "${__os_labels[__os_i]}")
                fi
            else
                __os_menu_args+=(--item "$((__os_i + 1))" "${__os_labels[__os_i]}")
            fi
        done
        [[ -n ${__os_return} ]] && __os_menu_args+=(--nav back)
        ui::menu --err "${__os_menu_args[@]}"
        ui::prompt '' 0
        IFS= read -r __os_reply || true
        # 有返回目标时，空输入不会落到第一个真动作上；它只负责离开本菜单。
        if [[ -n ${__os_return} && -z ${__os_reply} ]]; then
            printf -v "${__os_varname}" '%s' "${__os_return_val}"
            return 0
        fi
        if [[ ${__os_reply} =~ ^[0-9]+$ ]] && ((__os_reply >= 1 && __os_reply <= ${#__os_vals[@]})); then
            printf -v "${__os_varname}" '%s' "${__os_vals[__os_reply - 1]}"
            return 0
        fi
        __os_normalized=${__os_reply,,}
        for ((__os_i = 0; __os_i < ${#__os_vals[@]}; __os_i++)); do
            if [[ ${__os_normalized} == "${__os_vals[__os_i],,}" || ${__os_normalized} == "${__os_labels[__os_i],,}" ]]; then
                printf -v "${__os_varname}" '%s' "${__os_vals[__os_i]}"
                return 0
            fi
        done
        __os_notice="没有编号或选项为「${__os_reply}」的条目"
        ((__os_tries += 1))
    done
    os::die 2 "连续三次没有给出合法的 --${__os_name}"
}

# os::multiselect [--reask] --arg <name> <提示> <变量名> <选项>...   从清单里挑一个子集，结果排序去重
#
# 从一份清单里挑一个子集。选项写成 `值` 或 `值=说明`，结果是**排序去重**后的
# 逗号分隔值，写进变量（不打印，同 D74）。
#
# --- 为什么值得进框架 ---
#
# 「一份默认清单 + 用户增删」这个形态已经有两个消费者：Caddy 的插件清单与
# PHP 的扩展清单，两边的 `+/-/完全替换/none` 语法逐字相同。各写各的结果是：
# 同一套语法在两处有两种边界行为，而其中一处的边界正是下面这条 bug。
#
# --- 三条拒绝规则，每条都对着一次真实的静默出错 ---
#
#   * **裸名字与 `+/-` 混用 → 退出码 2。** 裸名字表示「完全替换」，所以
#     `+duckdns,route53` 从前的实际含义是「把十个清单项全丢掉，只装
#     duckdns 与 route53」—— 少打一个 `+`，默认清单**静默清空**，屏幕上
#     一个字的提示都没有，等到签通配符证书失败那天才发现。
#   * **命令行里出现序号 → 退出码 2。** 序号来自清单顺序，而清单可以在
#     /etc/oneserver/oneserver.conf 里被覆盖 —— 写进脚本的 `--plugins=1,3`
#     换台机器就指向别的东西。序号只在本次交互里有效。
#   * **序号同时用于挑选与排除 → 退出码 2。** `1,-3` 两种意图矛盾，
#     猜哪个都是替用户做决定。
#
# 减不掉的项**打警告而不是静默忽略**：`-dnspdo` 这种拼错的减法从前什么也不做，
# 用户以为减掉了。
#
# 排序去重是幂等的前提：不排的话 `a,b` 与 `b,a` 是两个字符串，与 state 里记的
# 对不上，于是每次执行都判成「组合变了」（同 D108）。
#
# `--reask` 跳过命令行取值直接进交互，给「命令行上那个值被下游系统拒了，
# 得让人改一改」用（Caddy 的插件名被官方构建接口以 400 顶回来就是这个形态）。
# 没有它，重问拿到的还是同一个错值，三轮问的是同一件事 —— 与菜单里
# `--choice=999` 会无限重问是同一个坑。**`--non-interactive` 下以退出码 2 终止**：
# 问不了就该停下，而不是替用户挑一个。
os::multiselect() {
    local __os_name='' __os_prompt='' __os_varname=''
    local -i __os_reask=0
    while [[ $# -gt 0 && ${1} == --* ]]; do
        case ${1} in
            --arg)
                __os_name=${2-}
                shift 2
                ;;
            --reask)
                __os_reask=1
                shift
                ;;
            *) shift ;;
        esac
    done
    __os_prompt=${1-}
    __os_varname=${2-}
    shift 2 2>/dev/null || true
    if [[ -z ${__os_name} || -z ${__os_varname} || $# -eq 0 ]]; then
        os::die 2 'os::multiselect 用法：--arg <name> <提示> <变量名> <选项>...'
    fi

    # 选项拆成「值」与「说明」两列。不带 `=` 的项说明为空 —— 老格式的清单
    # 因此原样可用，用户在 conf 里的既有覆盖不会失效
    local -a __os_vals=() __os_descs=()
    local __os_one
    for __os_one in "$@"; do
        if [[ ${__os_one} == *=* ]]; then
            __os_vals+=("${__os_one%%=*}")
            __os_descs+=("${__os_one#*=}")
        else
            __os_vals+=("${__os_one}")
            __os_descs+=('')
        fi
    done
    local -i __os_n=${#__os_vals[@]}

    # 取值来源：命令行 > 非交互（**全选**，等价于回车）> 交互
    local __os_spec=''
    local -i __os_cli=0 __os_i
    if [[ ${__os_reask} -eq 0 ]] && __os_spec=$(os::__arg_of "${__os_name}"); then
        __os_cli=1
    elif [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        if [[ ${__os_reask} -eq 1 ]]; then
            os::die 2 "--${__os_name} 的值不被接受，而 --non-interactive 下没法重新输入"
        fi
    else
        # 选法摊成表**放在清单之后**：挤成一行是 90 多个字符、比框还宽，所以它
        # 必须占几行；而读完十行选项，眼睛已经落到底部，那时才需要知道怎么输。
        # 摆在清单之前的话，用户读它的时候还不知道有什么可选，挑完了又得往回翻。
        local -a __os_menu=(--title "${__os_prompt}")
        for ((__os_i = 0; __os_i < __os_n; __os_i++)); do
            __os_menu+=(--item "$((__os_i + 1))" "${__os_vals[__os_i]}" "${__os_descs[__os_i]}")
        done
        __os_menu+=(--hint "${OS_UI_SYM_ENTER}" "全要（${__os_n} 项）")
        __os_menu+=(--hint '1,3,5' '只要这几个')
        __os_menu+=(--hint '-4,-7' '除这几个')
        __os_menu+=(--hint '+名字' '加清单外的')
        __os_menu+=(--hint 'none' '都不要')
        ui::menu --err "${__os_menu[@]}"
        ui::prompt '' 0
        IFS= read -r __os_spec || true
    fi

    __os_spec=${__os_spec#"${__os_spec%%[![:space:]]*}"}
    __os_spec=${__os_spec%"${__os_spec##*[![:space:]]}"}

    # 分类。`IFS=',' read -a` 而不是 `local IFS=','`：后者是**函数作用域**的，
    # 写在一个 if 里也会一路管到函数末尾，下面所有数组展开都跟着变语义
    local -a __os_toks=()
    if [[ -n ${__os_spec} && ${__os_spec} != none ]]; then
        IFS=',' read -r -a __os_toks <<<"${__os_spec}"
    fi

    local -a __os_pick=() __os_dropi=() __os_add=() __os_dropn=() __os_plain=()
    local __os_tok
    for __os_tok in ${__os_toks[@]+"${__os_toks[@]}"}; do
        __os_tok=${__os_tok#"${__os_tok%%[![:space:]]*}"}
        __os_tok=${__os_tok%"${__os_tok##*[![:space:]]}"}
        [[ -n ${__os_tok} ]] || continue
        if [[ ${__os_tok} == +* ]]; then
            __os_add+=("${__os_tok#+}")
        elif [[ ${__os_tok} =~ ^-[0-9]+$ ]]; then
            __os_dropi+=("${__os_tok#-}")
        elif [[ ${__os_tok} == -* ]]; then
            __os_dropn+=("${__os_tok#-}")
        elif [[ ${__os_tok} =~ ^[0-9]+$ ]]; then
            __os_pick+=("${__os_tok}")
        else
            __os_plain+=("${__os_tok}")
        fi
    done

    local -i __os_nums=$((${#__os_pick[@]} + ${#__os_dropi[@]}))
    local -i __os_deltas=$((${#__os_add[@]} + ${#__os_dropn[@]}))
    if [[ ${#__os_plain[@]} -gt 0 && $((__os_nums + __os_deltas)) -gt 0 ]]; then
        os::die 2 "--${__os_name}：不带 +/- 的名字表示「完全替换整份清单」，不能与序号或 +/- 混用。要增删就每一项都带 +/-"
    fi
    if [[ ${__os_nums} -gt 0 && ${__os_cli} -eq 1 ]]; then
        os::die 2 "--${__os_name}：命令行里不能用序号（清单一被覆盖，序号就指向别的东西），请写名字"
    fi
    if [[ ${#__os_pick[@]} -gt 0 && ${#__os_dropi[@]} -gt 0 ]]; then
        os::die 2 "--${__os_name}：序号不能同时用于挑选（3）与排除（-3）"
    fi

    # 基线。`10#` 是必须的：`08` 在算术里会被当成八进制，直接报错退出
    local -a __os_base=()
    if [[ ${#__os_plain[@]} -gt 0 ]]; then
        __os_base=("${__os_plain[@]}")
    elif [[ ${#__os_pick[@]} -gt 0 ]]; then
        for __os_tok in "${__os_pick[@]}"; do
            __os_i=$((10#${__os_tok}))
            if ((__os_i < 1 || __os_i > __os_n)); then
                os::die 2 "--${__os_name}：序号 ${__os_tok} 超出范围（1–${__os_n}）"
            fi
            __os_base+=("${__os_vals[__os_i - 1]}")
        done
    elif [[ ${__os_spec} != none ]]; then
        # 序号排除只可能落在这一支：它与 plain、pick 都已被上面拒绝
        local __os_skip='|'
        for __os_tok in ${__os_dropi[@]+"${__os_dropi[@]}"}; do
            __os_i=$((10#${__os_tok}))
            if ((__os_i < 1 || __os_i > __os_n)); then
                os::die 2 "--${__os_name}：序号 ${__os_tok} 超出范围（1–${__os_n}）"
            fi
            __os_skip+="${__os_i}|"
        done
        for ((__os_i = 0; __os_i < __os_n; __os_i++)); do
            if [[ ${__os_skip} != *"|$((__os_i + 1))|"* ]]; then
                __os_base+=("${__os_vals[__os_i]}")
            fi
        done
    fi

    # 按名字减。**末段匹配**：删一个插件不该逼人敲全路径
    local __os_drop __os_item
    local -i __os_hit
    local -a __os_kept=()
    for __os_drop in ${__os_dropn[@]+"${__os_dropn[@]}"}; do
        __os_drop=${__os_drop##*/}
        __os_hit=0
        __os_kept=()
        for __os_item in ${__os_base[@]+"${__os_base[@]}"}; do
            if [[ ${__os_item##*/} == "${__os_drop}" ]]; then
                __os_hit=1
            else
                __os_kept+=("${__os_item}")
            fi
        done
        if ((__os_hit == 0)); then
            os::warn "--${__os_name}：清单里没有「${__os_drop}」，这一项没减掉"
        fi
        __os_base=(${__os_kept[@]+"${__os_kept[@]}"})
    done
    for __os_tok in ${__os_add[@]+"${__os_add[@]}"}; do
        __os_base+=("${__os_tok}")
    done

    local -a __os_sorted=()
    mapfile -t __os_sorted < <(printf '%s\n' ${__os_base[@]+"${__os_base[@]}"} | sort -u)
    local __os_out='' __os_sep=''
    for __os_tok in ${__os_sorted[@]+"${__os_sorted[@]}"}; do
        [[ -n ${__os_tok} ]] || continue
        __os_out+="${__os_sep}${__os_tok}"
        __os_sep=','
    done
    printf -v "${__os_varname}" '%s' "${__os_out}"
    log::write info "多选 ${__os_name}：${__os_out:-（空）}" framework
    return 0
}

# os::action_menu [--overview <函数>] --arg <name> <提示> <分发函数> <选项>...   动作型命令的常驻二级菜单
#
# manager 类命令（`db` `podman` `firewall` `backup`…）是「一个脚本 + 一个动作
# 参数」（D73）。跑完一个动作就整个退出的话，「看一眼库列表」要重新走两层菜单，
# 而列表恰好是空的时候，用户看到的是「刚进去就被弹出来了」。
#
# `--overview` 把只读总览放在动作清单之前：管理对象时先看到当前有哪些对象、
# 状态如何，再决定做什么，免去每次都先选一次「列表 / 状态」。总览只在交互文本
# 模式执行；`--action`、JSON、非交互和管道调用保持一次派发，自动化语义不变。
#
# 这里让它**留在自己的动作清单上**，直到用户按回车「返回主菜单」——
# 返回提示由本函数自动追加，脚本不用自己写，也就不会有人漏写。它不占编号，
# 这样 1..N 始终是可执行动作，所有菜单的返回方式也完全一致。
#
# **只有交互路径才循环。** 命令行给了动作（`--action=list`）、`--non-interactive`、
# `--output json`、stdin 不是终端 —— 任何一条成立就只跑一次然后返回：
# 否则脚本化调用会变成死循环，JSON 消费者会收到一串信封。
#
# 分发函数收到动作名。**它内部的 os::die 仍然会结束整个进程** —— 硬失败该停就停，
# 此时退回的是主菜单而不是这个二级清单。
os::action_menu() {
    local __os_am_name='' __os_am_prompt='' __os_am_fn='' __os_am_overview=''
    while [[ $# -gt 0 && ${1} == --* ]]; do
        case ${1} in
            --arg)
                __os_am_name=${2-}
                shift 2
                ;;
            --overview)
                __os_am_overview=${2-}
                shift 2
                ;;
            *) shift ;;
        esac
    done
    __os_am_prompt=${1-}
    __os_am_fn=${2-}
    shift 2 2>/dev/null || true
    if [[ -z ${__os_am_name} || -z ${__os_am_fn} || $# -eq 0 ]]; then
        os::die 2 'os::action_menu 用法：--arg <name> <提示> <分发函数> <选项>...'
    fi
    if ! declare -F "${__os_am_fn}" >/dev/null 2>&1; then
        os::die 2 "os::action_menu：分发函数 ${__os_am_fn} 不存在"
    fi
    if [[ -n ${__os_am_overview} ]] && ! declare -F "${__os_am_overview}" >/dev/null 2>&1; then
        os::die 2 "os::action_menu：总览函数 ${__os_am_overview} 不存在"
    fi

    local -a __os_am_opts=("$@")

    local -i __os_am_loop=1
    if os::__arg_of "${__os_am_name}" >/dev/null 2>&1; then
        __os_am_loop=0
    fi
    if [[ ${OS_NON_INTERACTIVE} -eq 1 || ${OS_OUTPUT} != text ]] || [[ ! -t 0 ]]; then
        __os_am_loop=0
    fi

    local __os_am_act='' __os_am_pause=''
    local -i __os_am_first=1
    while :; do
        # 总览与操作区**是同一个框的上下两半**：先清旧屏，开框，画总览，
        # 随后 ui::menu 认出框还开着，把自己的标题画成一条小节线并收尾。
        # 从前总览无框、菜单有框，一屏两种边界，菜单那个框看着像凭空冒出来的。
        # 总览函数一个字都不用改 —— 是渲染层知道自己此刻在框里（§9：脚本
        # 不许碰边框字符）。
        [[ ${__os_am_loop} -eq 1 ]] && ui::clear_screen
        if [[ -n ${__os_am_overview} && ${__os_am_loop} -eq 1 ]]; then
            ui::frame_begin "${OS_META_NAME:-${__os_am_prompt}}" "oneserver ${OS_META_COMMAND}"
            "${__os_am_overview}"
        fi
        if [[ ${__os_am_first} -eq 1 ]]; then
            os::select --keep-screen --return back --arg "${__os_am_name}" \
                "${__os_am_prompt}" __os_am_act "${__os_am_opts[@]}"
            __os_am_first=0
        else
            os::select --keep-screen --reask --return back --arg "${__os_am_name}" \
                "${__os_am_prompt}" __os_am_act "${__os_am_opts[@]}"
        fi
        # 「返回主菜单」时给菜单留个记号，让它别再问一次「按回车返回菜单」——
        # 菜单是父进程，只拿得到退出码，而「用户选了返回」与「命令正常跑完」
        # 都是 0，分不出来。只在确实由菜单派发时才写（OS_FROM_MENU 由菜单
        # export），从命令行直接跑 `oneserver mariadb` 时不留任何东西。
        if [[ ${__os_am_act} == back ]]; then
            if [[ ${OS_FROM_MENU_ID:-0} != 0 ]]; then
                : >"${OS_MENU_BACK_FLAG}" 2>/dev/null || true
            fi
            return 0
        fi

        # **裸调，不带 `|| rc=$?`。** `||` 会让整条调用链都处在「-e 被忽略」的
        # 上下文里 —— 而这个状态会一路传进分发函数体内，于是 `os::state_set`
        # 返回 2 之后脚本照跑不误，最后还打出一句绿色的「✓ 已创建」。
        # 代价是动作返回非零就结束整个命令（回到主菜单），与加这个循环之前一致；
        # 换来的是失败仍然是失败。
        "${__os_am_fn}" "${__os_am_act}"
        # 走到这里就是上一个动作**成功**了（裸调 + set -e：失败根本回不来）。
        # 它注册的撤销项到此作废 —— 回滚栈是进程级的，而这个循环让一个进程
        # 跑好几个动作，不作废的话下一个动作失败会把这一个已经做成的事一起撤掉。
        os::commit
        [[ ${__os_am_loop} -eq 1 ]] || return 0

        ui::prompt "${OS_UI_SYM_ENTER} 返回操作列表" 0
        # 读不到（stdin 被上一步读空）就返回，不然会空转
        IFS= read -r __os_am_pause || return 0
    done
}

# ==================================================================
# 6 · 不可逆操作
# ==================================================================

# os::destroy_confirm --arg <name> <确认串> -- <清单行>...
#
# 五条强制要求里的 2–4 条在这里落实：
#   打印完整清单 · 确认方式是打全名不是按 y · **--yes 对它不生效**
#
# 第 4 条最关键：如果 --yes 能一路批准删库，那么 `backup run --yes` 这种
# 无害写法的习惯，迟早会被复制到危险命令上。危险操作必须要求一个
# **只可能被有意输入**的参数。
os::destroy_confirm() {
    local name='' target=''
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --arg)
                name=${2-}
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                [[ -z ${target} ]] && target=${1}
                shift
                ;;
        esac
    done
    if [[ -z ${name} || -z ${target} ]]; then
        os::die 2 "os::destroy_confirm 缺少 --arg 或确认串"
    fi

    ui::line --err error "以下内容将被删除，此操作不可撤销："
    local item
    for item in "$@"; do
        ui::line --err muted "    ${item}"
    done
    log::write warn "不可逆操作待确认：${target}（${#} 项）" script

    # dry-run 下输出与真实执行完全一致的清单，然后当作「未确认」返回
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        ui::line --err muted "[dry-run] 不会真的删除"
        return 1
    fi

    if [[ ${OS_NON_INTERACTIVE} -eq 1 || ! -t 0 ]]; then
        if [[ ${OS_FORCE_DESTROY} -eq 1 ]]; then
            log::write warn "经 --force-destroy 批准删除 ${target}" script
            return 0
        fi
        # **注意这里没有看 OS_YES。** --yes 对不可逆操作不生效。
        os::die 2 "非交互模式下删除 ${target} 需要显式的 --force-destroy（--yes 不生效）"
    fi

    # **打错了给重来的机会。** 这道门要的是「有意输入」，不是「一次打对」——
    # 打错一个字符就把整条命令结束掉，用户还得从头选一遍目标，而这中间
    # 前面几步可能已经落了备份。重问不削弱它：仍然必须一字不差地打出来。
    # 空输入（直接回车）当作放弃，不算打错。
    local reply=''
    local -i tries=0
    while ((tries < 3)); do
        tries+=1
        ui::prompt "打全名 ${target} 确认删除" 0 "${OS_UI_SYM_ENTER} 放弃"
        IFS= read -r reply || true
        if [[ ${reply} == "${target}" ]]; then
            return 0
        fi
        if [[ -z ${reply} ]]; then
            ui::line --err info '已放弃'
            return 1
        fi
        ui::line --err warn "输入的是「${reply}」，要一字不差地打 ${target}"
    done
    ui::line --err info '连续三次不匹配，已取消'
    return 1
}

# ==================================================================
# 7 · 机器可读输出
# ==================================================================

OS_JSON_SCHEMA=1

# data.items 的累积区。每个元素是**已经渲染好**的 JSON 对象文本
OS_JSON_ITEMS=()

# 信封发出去没有。见 os::output 与 os::__on_exit_hook
OS_JSON__SENT=0

# os::output_item <key=value>...   往信封 data 的 items 数组里追加一条记录
#
# 为什么要有它：规范禁止脚本手写 JSON，而 doctor / state list /
# log query / backup status 的 data 天然是「一串同构记录」。不给入口，
# 作者只能自己拼字符串 —— 一处转义没做对，整个信封就不再是 JSON，
# 而消费者拿到的是「解析失败」，不是「少了一个字段」。
#
# 值一律按字符串输出（与 os::output 的平铺字段一致）。要数字/布尔的那天
# 再说，现在多一种类型就多一处要转义对的地方。
os::output_item() {
    [[ ${OS_OUTPUT} == json ]] || return 0
    local obj='{' sep='' kv jk
    for kv in "$@"; do
        log::json_escape "${kv%%=*}"
        jk=${OS_LOG__ESCAPED}
        log::json_escape "${kv#*=}"
        obj+="${sep}\"${jk}\":\"${OS_LOG__ESCAPED}\""
        sep=','
    done
    obj+='}'
    OS_JSON_ITEMS+=("${obj}")
    return 0
}

# os::output <退出码> [key=value...]   打印信封并返回
os::output() {
    [[ ${OS_OUTPUT} == json ]] || return 0
    # 一次运行只发一个信封（§9：stdout 只有一个信封对象）。收尾钩子会给走不到
    # 这里的退出路径补发，脚本自己发过之后就不该再补 —— 两个对象首尾相接，
    # 那已经不是合法 JSON，而消费者报的是「解析失败」，不是「多了一段」
    [[ ${OS_JSON__SENT} -eq 0 ]] || return 0
    OS_JSON__SENT=1
    local -i code=${1:-0}
    shift || true

    local ts
    # 带真实时区偏移，不写死 Z —— `%()T` 取本地时间，标 Z 等于谎报 UTC，
    # 而这是**机器消费**的信封字段，偏移会被下游原样当真
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    local ok='false'
    [[ ${code} -eq 0 ]] && ok='true'

    log::json_escape "${OS_META_COMMAND}"
    local jcmd=${OS_LOG__ESCAPED}

    printf '{'
    printf '"schema":%d,' "${OS_JSON_SCHEMA}"
    printf '"command":"%s",' "${jcmd}"
    printf '"ok":%s,' "${ok}"
    printf '"exit_code":%d,' "${code}"
    printf '"ts":"%s",' "${ts}"

    printf '"data":{'
    local kv sep=''
    for kv in "$@"; do
        log::json_escape "${kv%%=*}"
        local jk=${OS_LOG__ESCAPED}
        log::json_escape "${kv#*=}"
        printf '%s"%s":"%s"' "${sep}" "${jk}" "${OS_LOG__ESCAPED}"
        sep=','
    done
    if [[ ${#OS_JSON_ITEMS[@]} -gt 0 ]]; then
        printf '%s"items":[' "${sep}"
        local isep='' item
        for item in "${OS_JSON_ITEMS[@]}"; do
            printf '%s%s' "${isep}" "${item}"
            isep=','
        done
        printf ']'
    fi
    printf '},'

    printf '"messages":['
    sep=''
    local -i i
    for ((i = 0; i < ${#OS_MSG_LEVELS[@]}; i++)); do
        log::json_escape "${OS_MSG_TEXTS[i]}"
        printf '%s{"level":"%s","text":"%s"}' "${sep}" "${OS_MSG_LEVELS[i]}" "${OS_LOG__ESCAPED}"
        sep=','
    done
    printf ']'
    printf '}\n'
    return 0
}

# ==================================================================
# 8 · 包管理
# ==================================================================
#
# **为什么落在 bootstrap.sh 而不是自己一个模块**：它要同时用
# `probe::package_installed`（L3，判幂等）与 `os::run` / `os::record_change`
# / `os::critical_*`（L2）。放 L3 就跟 probe.sh 同层，规则 2 禁止同层互相依赖；
# 而 L4 里再开一个模块的话，bootstrap 要 source 它 —— 又是同层依赖。
# 与 D70（呈现语义函数落在 bootstrap.sh）是同一条理由。
#
# 收进函数的动因：六个安装脚本各写一遍 `apt-get install -y -qq`，就有六种
# 关于「要不要 --no-install-recommends」「要不要 DEBIAN_FRONTEND」「装之前
# 判不判断」的答案 —— 现状正是如此，而这几条里任何一条写错，表现都是
# 「在某些机器上装出来的东西不一样」。

# apt 的两个环境变量对所有包管理调用都一样，收在一处
OS_PKG__ENV=('DEBIAN_FRONTEND=noninteractive' 'NEEDRESTART_MODE=a')

# 本次进程里**真正装上**的包。只有这些该登记进 state 的资源清单，
# 「本来就有」的不能记 —— 否则 uninstall 会把用户自己装的东西 purge 掉。
# 与 os::systemd_touched 同一个套路（D69）：函数只负责攒，写 state 由调用方决定。
OS_PKG__INSTALLED=()
# universe 只尝试一次。没有它，software-properties-common 自己取不到时
# os::pkg__ensure_available 会无限递归
OS_PKG__UNIVERSE_TRIED=0

# os::pkg_installed_names   列出本次真正装上的包
os::pkg_installed_names() {
    local p
    for p in ${OS_PKG__INSTALLED[@]+"${OS_PKG__INSTALLED[@]}"}; do
        printf '%s\n' "${p}"
    done
    return 0
}

# os::pkg_refresh   刷新软件包索引
#
# **不幂等**：索引本来就该按需刷新。只在加了新 apt 源之后调，
# 不要每个脚本开头都来一次 —— 那是几秒钟乘以脚本数量。
os::pkg_refresh() {
    os::critical_begin '刷新软件包索引'
    local -i rc=0
    os::run --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '刷新软件包索引' -- apt-get update -qq || rc=$?
    os::critical_end
    return "${rc}"
}

# os::pkg_upgrade   升级所有已安装的软件包
#
# 与 install/purge 一样，脚本层不直接拼 apt 参数：环境、临界区、dry-run 与
# 变更记录都由包边界给出同一份答案。升级可能部分成功后才返回非零，因此只要
# 真实调用过 apt 就记录；dry-run 被 os::run 跳过时不留下假账。
os::pkg_upgrade() {
    os::critical_begin '升级软件包'
    local -i rc=0
    os::run --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '升级已安装的软件包' -- apt-get upgrade -y -qq || rc=$?
    os::critical_end
    if [[ ${OS_RUN_SKIPPED} -ne 1 ]]; then
        os::record_change 'apt 升级了已安装的软件包'
    fi
    return "${rc}"
}

# 源里取不到的包，先弄清是「Ubuntu 把它放在 universe 而这台机器没开」还是
# 真的没有。**apt 对这两种情况的说法一模一样**（`has no installation
# candidate`），而退出码 100 更是把「源里没这个包」和「装到一半炸了」混成
# 一件事 —— 前者属依赖缺失（退出码 3），压根不该跑 apt。
#
# valkey 在 Ubuntu 上就在 universe，所以这件事归框架管，
# 不是某个安装脚本自己的事。**只有真取不到时才动 apt 源**：装得到的机器
# 一个字节都不该改，否则第二次执行就不是零变更了。
# universe 是 Ubuntu 官方组件，不是第三方源，D99 那条不受影响。
#
# **只认探测真答上来的那次**：非 root 读不到快照、apt-cache 超时，
# OS_PROBE_VALUE 同样是空 —— 拿它当「源里没有」会把一次探测故障
# 变成一条误杀。答不上来就别拦着，让 apt 自己去说。
os::pkg__ensure_available() {
    local pkg
    local -a missing=()
    for pkg in "$@"; do
        probe::package_candidate "${pkg}"
        [[ ${OS_PROBE_STATUS} == 'ok' && -z ${OS_PROBE_VALUE} ]] && missing+=("${pkg}")
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0

    local IFS=' '
    # dry-run 下面这些都是副作用，跑不了。**不能就此报错退出** ——
    # 规范：预演遇到依赖未满足要说清预演到哪一步，然后正常结束。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::warn "[dry-run] 源里当前取不到 ${missing[*]}；真实执行时会先尝试启用 universe"
        return 0
    fi

    # 递归护栏：software-properties-common 自己要是也取不到，
    # 下面这句会再进来一次，没有它就是死循环
    probe::os_id
    if [[ ${OS_PROBE_VALUE} == 'ubuntu' && ${OS_PKG__UNIVERSE_TRIED} -eq 0 ]]; then
        OS_PKG__UNIVERSE_TRIED=1
        os::info "apt 源里取不到 ${missing[*]}，尝试启用 universe 组件"
        os::pkg_install software-properties-common
        os::run '启用 universe 组件' -- add-apt-repository -y universe
        os::pkg_refresh

        local -a still=()
        for pkg in "${missing[@]}"; do
            probe::package_candidate "${pkg}"
            [[ -n ${OS_PROBE_VALUE} ]] || still+=("${pkg}")
        done
        [[ ${#still[@]} -gt 0 ]] || return 0
        missing=("${still[@]}")
    fi

    os::die 3 "软件源里没有：${missing[*]}（apt 装不到它，先确认发行版与源配置）"
}

# os::pkg_install <包>...   安装，已装的自动跳过
os::pkg_install() {
    [[ $# -gt 0 ]] || return 0

    # 幂等：逐个问 probe，全都装好了就一条命令都不跑。
    # 不靠 apt 自己的「already the newest version」—— 那仍然是一次 apt 事务，
    # 仍然要拿 dpkg 锁、仍然进审计日志，而规范要的是**零变更**。
    local pkg
    local -a want=()
    for pkg in "$@"; do
        probe::package_installed "${pkg}"
        [[ ${OS_PROBE_VALUE} == yes ]] || want+=("${pkg}")
    done
    if [[ ${#want[@]} -eq 0 ]]; then
        log::write info "已安装，跳过：$*" framework
        return 0
    fi

    os::pkg__ensure_available "${want[@]}"

    # 包管理器事务必须在不可中断区段内：装到一半被打断，
    # dpkg 锁会留给下一个进程，而那个进程看到的是「有人正在装」。
    os::critical_begin '安装软件包'
    local -i rc=0
    os::run --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '安装软件包' -- apt-get install -y -qq --no-install-recommends "${want[@]}" || rc=$?
    os::critical_end

    # 变更清单与资源清单都按**重新探测的结果**记，不按意图记。
    #
    # 事前记一句「apt 安装了 X」，apt 一个包都没装成时失败清单仍然要求人去
    # 处置一件没发生的事；而 apt 装了一半才失败时，真装上的那几个又会因为
    # 「rc 非零就什么都不记」而漏掉登记，卸载时留成孤儿。
    # 全成、半成、全败三种情形只有事后探测都答得对。
    # dry-run 下命令没跑，OS_RUN_SKIPPED 会拦住整段（零变更）。
    if [[ ${OS_RUN_SKIPPED} -ne 1 ]]; then
        local -a got=()
        for pkg in "${want[@]}"; do
            probe::package_installed "${pkg}"
            [[ ${OS_PROBE_VALUE} == yes ]] && got+=("${pkg}")
        done
        if [[ ${#got[@]} -gt 0 ]]; then
            # 装包属「禁止自动回滚」类：包可能是用户既有资产，
            # 卸载比不卸载破坏更大。只记进变更清单。
            local IFS=' '
            os::record_change "apt 安装了 ${got[*]}"
            OS_PKG__INSTALLED+=("${got[@]}")
        fi
    fi
    return "${rc}"
}

# os::pkg_install_deb <deb 文件>   安装一个本地 .deb
#
# 给「上游发了 .deb 却没有 apt 源」的软件用（rclone 就是这样，D238）。
# 幂等与校验归调用方：这个函数拿到的是一个文件路径，「装没装」「该不该装」
# 它一个都答不出来 —— 答得出来的只有调用方手里的版本号。
#
# **不是 `dpkg -i`**：那个不解依赖，缺一个就在系统上留下一个半配置状态的包，
# 而收拾它要人手工敲 `apt-get -f install`。apt 认本地文件，依赖照常从源里取。
#
# 只收一个文件：apt 一次事务里装多个 deb 时，中途失败会留下「装上了几个」的
# 中间态，而变更清单没法据实记录它 —— 一个文件就没有这个中间态。
os::pkg_install_deb() {
    local file=${1}

    # apt 只把**含 `/`** 的参数当文件，否则当包名拿去源里搜。裸文件名
    # （`rclone.deb`）会变成一次「找不到这个包」，而错误信息里完全看不出
    # 是路径写法的问题
    [[ ${file} == */* ]] || file="./${file}"

    # dry-run 下前面的下载没真跑，文件本就不存在 —— 这时报错就是拿预演当失败
    if [[ ${OS_DRYRUN} -ne 1 && ! -f ${file} ]]; then
        os::die 1 "本地软件包不存在：${file}"
    fi

    os::critical_begin '安装本地软件包'
    local -i rc=0
    os::run --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '安装本地软件包' -- apt-get install -y -qq --no-install-recommends "${file}" || rc=$?
    os::critical_end

    # 事后记，不按意图记（同 os::pkg_install）：apt 没装成时，
    # 失败清单不该要求人去处置一件没发生的事
    if [[ ${rc} -eq 0 && ${OS_RUN_SKIPPED} -ne 1 ]]; then
        os::record_change "apt 安装了本地软件包 ${file##*/}"
    fi
    return "${rc}"
}

# os::pkg_purge <包>...   卸载并清配置，没装的自动跳过
#
# 与 os::pkg_install 对称，动因也对称：卸载器与安装器各写一遍
# `apt-get purge -y -qq`，就会有两种关于环境变量与「装没装」的答案。
#
# **purge 属「禁止自动回滚」类**（§10）：装回去未必还原得了配置，也未必是
# 用户想要的。所以只记进变更清单，不注册回滚。
#
# 失败返回码交回调用方：卸载器要接着往下走完清单，安装器撞上 purge 失败
# 则必须当场停 —— 这两种处置只有调用方分得清。
os::pkg_purge() {
    [[ $# -gt 0 ]] || return 0

    # 幂等：没装的一个都不传给 apt。理由同 os::pkg_install ——
    # 「反正 apt 会说 not installed」仍然是一次要拿 dpkg 锁、要进审计的事务
    local pkg
    local -a want=()
    for pkg in "$@"; do
        probe::package_installed "${pkg}"
        [[ ${OS_PROBE_VALUE} == yes ]] && want+=("${pkg}")
    done
    if [[ ${#want[@]} -eq 0 ]]; then
        log::write info "未安装，跳过 purge：$*" framework
        return 0
    fi

    local IFS=' '
    os::record_change "apt purge 了 ${want[*]}"
    os::critical_begin '卸载软件包'
    local -i rc=0
    os::run --allow-fail --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '卸载软件包' -- apt-get purge -y -qq "${want[@]}" || rc=$?
    os::critical_end
    return "${rc}"
}

# os::pkg_reinstall <包>...   重装已装的包，把包自带的文件恢复回来
#
# 与 os::pkg_install 的差别是**故意的**：那个见包已装就跳过（幂等），
# 而这里要的正是「已经装着，但文件被动过，请 apt 再放一遍」。
# 现实用途只有一个形状：`dpkg-divert --rename` 把包自带的二进制挪走之后，
# 得让 apt 重新放一份回原位占住那个路径。
#
# 没装的包直接跳过而不是报错：重装一个不存在的东西没有意义，而调用方
# 想装的话该用 os::pkg_install。
#
# **属「禁止自动回滚」类**（§10）：它动的是 dpkg 管的文件，撤销要靠 dpkg
# 自己的账本，猜着还原比不还原更危险。只记进变更清单。
os::pkg_reinstall() {
    [[ $# -gt 0 ]] || return 0

    local pkg
    local -a want=()
    for pkg in "$@"; do
        probe::package_installed "${pkg}"
        [[ ${OS_PROBE_VALUE} == yes ]] && want+=("${pkg}")
    done
    if [[ ${#want[@]} -eq 0 ]]; then
        log::write info "未安装，跳过 reinstall：$*" framework
        return 0
    fi

    local IFS=' '
    os::record_change "apt 重装了 ${want[*]}"
    os::critical_begin '重装软件包'
    local -i rc=0
    os::run --allow-fail --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '重装软件包' -- apt-get install --reinstall -y -qq "${want[@]}" || rc=$?
    os::critical_end
    return "${rc}"
}

# os::pkg_clean   清空 apt 的包缓存
#
# 单独给它一个接口，而不是让清理脚本自己敲 apt-get clean：规范里「包管理只经
# 框架接口」没有例外条款，而缺一个接口就等于逼调用方违约 —— 之前正是这样。
#
# 它删的是 /var/cache/apt/archives 下已下载的 .deb，全部可以重新下载，
# 因此**不属于任何一类需要回滚的副作用**，只记进变更清单。
os::pkg_clean() {
    os::record_change '清空了 apt 包缓存'
    local -i rc=0
    os::run --allow-fail --env "${OS_PKG__ENV[0]}" --env "${OS_PKG__ENV[1]}" \
        '清理 APT 包缓存' -- apt-get clean || rc=$?
    return "${rc}"
}

# ==================================================================
# 9 · 前置检查（顺序固定）
# ==================================================================

# os::require_cmd <命令>...   缺任一命令即以退出码 3 终止
os::require_cmd() {
    # `${missing[*]}` 按 IFS 连接，脚本层的 IFS 是 $'\n\t'（D91）
    local IFS=' '
    local cmd missing=()
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    os::die 3 "缺少必需的命令：${missing[*]}"
}

os::__check_privilege() {
    # root-nolock 一样要 root：它探的是 systemctl / ufw / sshd -T，非 root 只会
    # 拿到降级值，再把降级值写进快照比不写更糟。它与 root 的区别只在不取锁。
    # root-trylock 更是要 root：它有真副作用，只是拿不到锁时不当失败。
    case ${OS_META_PRIVILEGE} in
        root | root-nolock | root-trylock) ;;
        *) return 0 ;;
    esac
    [[ ${EUID:-$(id -u)} -eq 0 ]] && return 0
    os::die 4 "此命令需要 root 权限"
}

os::__platform_supported() {
    case "${1-}" in
        debian | ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

os::__check_distro() {
    probe::os_id
    local id=${OS_PROBE_VALUE}
    local id_status=${OS_PROBE_STATUS}

    # OS 身份是执行任何命令前的安全边界，而普通用户首次运行时还没有 root
    # 快照。/etc/os-release 本身是公开的系统身份文件；只在 probe 明确表示
    # 「无缓存」时直接补读，避免把 timeout/missing 等真实故障伪装成正常。
    if [[ ${id_status} == unavailable ]]; then
        os::query --timeout 2 -- \
            sed -nE 's/^ID="?([^"]*)"?$/\1/p' /etc/os-release || true
        id=${OS_RUN_OUTPUT}
    fi
    os::__platform_supported "${id}" \
        || os::die 4 "不支持的平台：${id:-未知}（仅支持 Debian / Ubuntu）"
}

# @requires <type>[:<instance>][<op><version>]，逗号分隔
os::__check_requires() {
    [[ -n ${OS_META_REQUIRES} ]] || return 0
    local spec rest op want type have
    local IFS=','
    for spec in ${OS_META_REQUIRES}; do
        [[ -n ${spec} ]] || continue
        op=''
        want=''
        rest=${spec}
        if [[ ${spec} == *'>='* ]]; then
            op='>='
            rest=${spec%%>=*}
            want=${spec#*>=}
        elif [[ ${spec} == *'>'* ]]; then
            op='>'
            rest=${spec%%>*}
            want=${spec#*>}
        elif [[ ${spec} == *'='* ]]; then
            op='='
            rest=${spec%%=*}
            want=${spec#*=}
        fi
        type=${rest}

        if [[ ${type} == *:* ]]; then
            os::state_has "${type}" || os::die 3 "缺少依赖组件：${type}"
            have=$(os::state_get "${type}" version)
        else
            local -a insts=()
            local one
            while IFS= read -r one; do
                [[ -n ${one} ]] && insts+=("${one}")
            done < <(os::state_list "${type}")
            if [[ ${#insts[@]} -gt 0 ]]; then
                have=$(os::state_get "${insts[0]}" version)
            else
                # **state 里没有就回退到探测**（计划 6.1）。
                #
                # state 记的是「本工具装过什么」，而机器上的东西不一定是本工具装的 ——
                # 用户自己 `apt install caddy` 装的那份确实在跑，却不在 state 里。
                # 只查 state 的后果是 `@requires caddy` 在一台**装着 caddy** 的机器上
                # 报「缺少依赖组件」，而这正是 D93 / D138 当初绕开 `@requires`、
                # 改用 probe 判断的原因 —— 那是在给框架的缺口打补丁。
                #
                # **只对不带实例的约束回退**：`php:8.3` 问的是某一个实例，
                # 而 `probe::component_version php` 给的是默认那个版本，
                # 拿它去回答「8.3 装没装」是错的答案，比没有答案更糟。
                probe::component_version "${type}"
                local detected=${OS_PROBE_VALUE%%$'\n'*}
                detected=${detected%% *}
                detected=${detected#v}
                [[ -n ${detected} ]] || os::die 3 "缺少依赖组件：${type}"
                have=${detected}
                log::write info "@requires ${type}：state 里没有，按探测到的 ${have} 判定" framework
            fi
        fi

        [[ -n ${op} ]] || continue
        local cmp
        cmp=$(os::version_cmp "${have}" "${want}")
        case ${op} in
            '>=') [[ ${cmp} == '-1' ]] && os::die 3 "${type} 版本 ${have} 低于要求的 ${want}" ;;
            '>') [[ ${cmp} != '1' ]] && os::die 3 "${type} 版本 ${have} 不高于要求的 ${want}" ;;
            '=') [[ ${cmp} != '0' ]] && os::die 3 "${type} 版本 ${have} 不等于要求的 ${want}" ;;
        esac
    done
    return 0
}

os::__check_lib_api() {
    [[ -n ${OS_META_REQUIRES_LIB} ]] || return 0
    local want=${OS_META_REQUIRES_LIB#*>=}
    want=${want#"${want%%[![:space:]]*}"}
    # 读**正在跑的这份 lib** 旁边的 API_VERSION，不读 paths.sh 里的固定路径：
    # `oneserver update` 的四阶段模型里，新旧两套 lib 会同时存在于磁盘上，
    # 认路径就会读到另一套的版本号。认「我自己旁边那个」才不会错。
    local have='0.0'
    local vf="${OS_LIB_SELF_DIR}/API_VERSION"
    [[ -r ${vf} ]] || vf=${OS_API_VERSION_FILE}
    # `|| true`：文件末尾没有换行时 read 照样把内容读进变量，但返回非零 ——
    # 不吞掉的话，一个少了末尾换行的 API_VERSION 会让**每一条命令**在这里
    # 崩掉，而现场只看得到一行 `read` 失败，根本指不到版本文件上。
    [[ -r ${vf} ]] && { IFS= read -r have <"${vf}" || true; }
    local cmp
    cmp=$(os::version_cmp "${have}" "${want}")
    [[ ${cmp} == '-1' ]] && os::die 4 "lib API 版本 ${have} 低于脚本要求的 ${want}"
    return 0
}

# ==================================================================
# 10 · 收尾钩子 —— 由 errors.sh 的 EXIT trap 调用
# ==================================================================

os::__on_exit_hook() {
    local -i code=${1:-0}
    # 动过的 unit 写进 state（D69：systemd.sh 同层不能直接写 state）
    if [[ -n ${OS_META_PROVIDES} ]]; then
        local unit
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            os::state_unit_add "${OS_META_PROVIDES%%<*}" "${unit}" 2>/dev/null || true
        done < <(os::systemd_touched)
    fi
    # root 跑任何命令都顺手落一份 probe 快照——
    # 这样即使用户从不启用面板的采集 timer（oneserver-web-*.timer），
    # 普通用户也拿得到最近一次的数据。
    #
    # root-nolock 例外：这类命令的产物**就是**快照，路径由它自己定（分档采集
    # 落进不同文件）。hook 再写一份会把通用的 probe.tsv 覆盖成只剩这一档的
    # 字段——每十秒一次，通用快照就再也没有完整过。
    if [[ ${OS_META_PRIVILEGE} != root-nolock ]]; then
        probe::snapshot_flush 2>/dev/null || true
    fi

    # 真的改过东西，就顺手让面板的慢档提前采一轮。
    #
    # 面板上那个「刷新」按钮只能重新拉取已落盘的数据，**不能触发服务端探测**
    # （规范 §1：零服务端逻辑，一个能触发采集的端点就是一条从网络通向 root
    # 执行的路）。而用户想按刷新的绝大多数场合，是刚在终端里装完组件、建完
    # 容器，想立刻在页面上看到它。改动发生在这一侧，就由这一侧去踢——这一侧
    # 本来就有 root，也本来就知道自己改了东西。
    #
    # 三个前提缺一不可：`root`（root-nolock 是采集器自己，踢自己没意义；
    # `any` 没有副作用）、非 dry-run（预演零变更，包括不触发别的 unit）、
    # 以及**变更清单非空**——什么都没改的命令去踢一轮，只是白烧两三秒 CPU。
    #
    # **先探 unit 在不在，别指望 `--allow-fail` 兜底。** 兜底只挡住了屏幕：
    # systemctl 那句 `Unit oneserver-web-slow.service not found.` 走的是命令自己的
    # stderr，照样原样落进命令日志。没启用过面板的机器上，每条改动过东西的命令
    # 都会在日志尾部留下这么一行红字 —— 排查真问题的人（连同它上面那条真失败）
    # 会先被这句无关的 not found 带偏。
    if [[ ${OS_META_PRIVILEGE} == root && ${OS_DRYRUN} -ne 1 && ${#OS_ERR__CHANGES[@]} -gt 0 ]]; then
        probe::unit_exists 'oneserver-web-slow.service' 2>/dev/null || true
        if [[ ${OS_PROBE_VALUE} == yes ]]; then
            os::systemd_kick 'oneserver-web-slow.service' || true
        fi
    fi

    # **失败路径同样要有信封**（§9：json 时 stdout 只有一个信封对象）。
    # os::die 直接 exit，脚本末尾那句 os::output 根本走不到 —— 于是参数错、
    # 依赖缺失、环境不支持这些路径的 stdout 是**空的**，消费者分不清「命令失败了」
    # 和「命令根本没跑起来」，而 ok / exit_code / messages 三个字段正是为此设计的。
    # 补在钩子里而不是 os::die 里：exit 的去处不止 die 一个（ERR trap、信号、
    # 脚本自己 return 非零），逐个补迟早漏掉一条。
    #
    # 前端不会走到这里 —— frontend 模式跳过全局参数解析，OS_OUTPUT 恒是 text。
    if [[ ${OS_OUTPUT} == json && ${OS_JSON__SENT} -eq 0 ]]; then
        os::output "${code}"
    fi
    return 0
}

# ==================================================================
# 11 · 启动 ——规范的固定七步
# ==================================================================

os::__boot() {
    # 前端：跳过元数据、全局参数、EUID、@requires、取锁五步，
    # 装配 / 日志 / trap 照常。**argv 原样交还** —— `--version=8.3` 是目标脚本的
    # 参数，前端在这里吃掉它就再也传不下去了。
    if [[ ${OS_BOOT_MODE} == frontend ]]; then
        ui::init
        log::init 'oneserver'
        errors::install
        OS_POSITIONAL=("$@")
        log::write debug '启动完成：前端模式' framework
        return 0
    fi

    # 1) 元数据。BASH_SOURCE[2] 是 source 本文件的那个脚本
    #    （[0] 是 bootstrap.sh，[1] 是 os::__boot 的调用点，同在本文件里）
    os::__parse_meta "${BASH_SOURCE[2]:-${BASH_SOURCE[1]}}"

    # 2) 全局参数
    os::__parse_globals "$@"
    ui::init

    # --output 只认 text / json。值非法属参数错误 → 退出码 2。
    # json 时呈现层整层静默—— 闸门在 ui.sh，因为 exec.sh 与 lock.sh
    # 也直接调 ui::，而它们按分层读不到这里的 OS_OUTPUT
    case ${OS_OUTPUT} in
        text) ;;
        json) ui::set_quiet 1 ;;
        *)
            ui::line error "--output 只支持 text 或 json，收到「${OS_OUTPUT}」"
            exit 2
            ;;
    esac

    if [[ ${OS_HELP} -eq 1 ]]; then
        os::__help
        exit 0
    fi

    # 3) 权限
    os::__check_privilege

    # 7-a) 日志与 trap 要尽早装：后面每一步的失败都该被记下来
    log::init "${OS_META_COMMAND:-oneserver}"
    errors::install

    # 4) 发行版
    os::__check_distro
    # 5) lib API 与组件约束
    os::__check_lib_api
    os::__check_requires

    # 6) 锁。
    #    `any` 不取是因为它没有副作用；`root-nolock` 不取是因为它虽然要 root，
    #    却不改任何被锁保护的东西 —— 而每十秒采一次的定时器若持锁，会随机
    #    挡住用户敲的真实命令。代价是它可能采到变更中途的状态，见 §6。
    #
    #    `root-trylock` 有副作用、要锁，但**拿不到就走**：它是周期性的，这一轮
    #    不做下一轮还会来。以 0 退出而不是 5，因为锁被占是预期内的正常情形
    #    （用户在菜单里停留时那条命令一直持锁），记成失败的结果是每一轮都往
    #    日志里写错误——而日志本身是面板要发布的产物（规范 §6）。
    if [[ ${OS_META_PRIVILEGE} == root ]]; then
        os::lock_acquire
    elif [[ ${OS_META_PRIVILEGE} == root-trylock ]]; then
        if ! os::lock_acquire --try "${OS_TRYLOCK_WAIT}"; then
            log::write debug "锁被占，本轮跳过：${OS_META_COMMAND}" framework
            exit 0
        fi
    fi

    log::write debug "启动完成：${OS_META_COMMAND}（dry-run=${OS_DRYRUN}）" framework
    return 0
}

os::__boot "$@"
set -- ${OS_POSITIONAL[@]+"${OS_POSITIONAL[@]}"}
