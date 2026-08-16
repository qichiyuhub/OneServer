# lib/registry.sh —— L4 组装层：注册表
#
# **注册表是单一真相源**（D8）：CLI 路由与菜单生成读的是同一份数据。
# 新增功能 = 放一个带元数据头的文件，`bin/oneserver` 与菜单**零改动**。
#
# --- 谁 source 它---
#
# 由 `bin/` 前端在 `bootstrap.sh` **之后** source，不由 `bootstrap.sh` source：
# 两者同在 L4，同层禁止互相依赖。因此本文件里可以用 `os::*` 与 `os::state_*`，
# 但**不能被单独 source**（同 D56 对其余模块的要求）。
#
# --- 不做缓存（D26）---
#
# 十几个文件读头部 40 行是 20–40ms。而「按目录 mtime 失效」的缓存有个致命缺陷：
# `install` 覆盖同名文件时目录 mtime 不变 —— 缓存不失效，用户更新完菜单还是旧的。
# 这类 bug 最难排查，换来的是几十毫秒。
#
# --- 不打印，只写变量 ---
#
# `registry::resolve` 要同时给出「匹配到哪个脚本」与「吃掉了几个词」，
# 而 `$( )` 是子 shell，第二个值传不出来 —— 同 D68 / D74，把正确做法变成唯一做法。

# --- 命令表。同一下标横跨这几个数组即一条记录 ---

OS_REG_COUNT=0
OS_REG_FILE=()
OS_REG_COMMAND=()
OS_REG_NAME=()
# 有下级的命令在**自己那一屏**的第一项显示什么。空则回落 @name。
#
# 一个名字答不了两个问题：在上一层它说「这个功能叫什么」（`安装应用`），
# 在自己这一屏它说「选中它会执行什么」（`全部应用与状态`）。用同一个字符串
# 的结果是标题和第一项一字不差地重复 —— `应用 › 安装应用` 底下又是「安装应用」。
OS_REG_SELF_NAME=()
OS_REG_GROUP=()
OS_REG_ORDER=()
OS_REG_PRIVILEGE=()
OS_REG_REQUIRES=()
OS_REG_PROVIDES=()
OS_REG_DESC=()
OS_REG_ARGS=()

# 最长的 @command 有几个词。resolve 的最长前缀匹配从这里起步，
# 不必拿整条命令行去试
OS_REG_MAXWORDS=0

# --- 分组表（数据在 templates/groups.conf）---

OS_REG_GROUP_COUNT=0
OS_REG_GROUP_ID=()
OS_REG_GROUP_NAME=()
OS_REG_GROUP_ORDER=()
OS_REG_GROUP_PARENT=()
OS_REG_GROUP_DESC=()

# --- registry::resolve 的结果 ---

OS_REG_MATCH=-1
OS_REG_MATCH_WORDS=0

# --- registry::sort 的结果：按「分组序 → @order」排好的下标 ---

OS_REG_SORTED=()

# 未在 groups.conf 里声明的 @group 排在最后，且只告警一次
OS_REG__UNKNOWN_GROUP_ORDER=99999

# ==================================================================
# 分组
# ==================================================================

# registry::groups_load   读 templates/groups.conf
registry::groups_load() {
    OS_REG_GROUP_COUNT=0
    OS_REG_GROUP_ID=()
    OS_REG_GROUP_NAME=()
    OS_REG_GROUP_ORDER=()
    OS_REG_GROUP_PARENT=()
    OS_REG_GROUP_DESC=()
    [[ -r ${OS_GROUPS_CONF} ]] || {
        os::warn "读不到分组定义 ${OS_GROUPS_CONF}，菜单将不分组"
        return 0
    }

    local line id name order parent desc
    while IFS= read -r line || [[ -n ${line} ]]; do
        line=${line%%#*}
        [[ -n ${line//[[:space:]]/} ]] || continue
        # 字段用 `|` 分隔，不用空白。用空白的代价是显示名里不能有空格，
        # 于是「Podman 容器」只能写成夹一个全角空格的「Podman　容器」——
        # 屏幕上那是个两格宽的洞，而根源只是分隔符选错了。
        IFS='|' read -r id name order parent desc <<<"${line}"
        id=${id//[[:space:]]/}
        order=${order//[[:space:]]/}
        parent=${parent//[[:space:]]/}
        name=${name#"${name%%[![:space:]]*}"}
        name=${name%"${name##*[![:space:]]}"}
        desc=${desc#"${desc%%[![:space:]]*}"}
        desc=${desc%"${desc##*[![:space:]]}"}
        [[ -n ${id} && -n ${name} ]] || continue
        [[ ${order} =~ ^[0-9]+$ ]] || order=${OS_REG__UNKNOWN_GROUP_ORDER}
        OS_REG_GROUP_ID+=("${id}")
        OS_REG_GROUP_NAME+=("${name}")
        OS_REG_GROUP_ORDER+=("${order}")
        OS_REG_GROUP_PARENT+=("${parent}")
        OS_REG_GROUP_DESC+=("${desc}")
        ((OS_REG_GROUP_COUNT += 1))
    done <"${OS_GROUPS_CONF}"

    local -i i j found
    for ((i = 0; i < OS_REG_GROUP_COUNT; i++)); do
        [[ -n ${OS_REG_GROUP_PARENT[i]} ]] || continue
        found=0
        for ((j = 0; j < OS_REG_GROUP_COUNT; j++)); do
            [[ ${OS_REG_GROUP_ID[j]} == "${OS_REG_GROUP_PARENT[i]}" ]] || continue
            found=1
            break
        done
        if ((found == 0)); then
            os::warn "分组 ${OS_REG_GROUP_ID[i]} 的父分组不存在：${OS_REG_GROUP_PARENT[i]}，已作为顶层分组显示"
            OS_REG_GROUP_PARENT[i]=''
        fi
    done

    # **成环必须在这里断掉。** 菜单要沿 parent 往上/往下走，`a parent b` 加
    # `b parent a` 会让它绕不出来 —— 表现是工具一开就卡死，而原因躺在一个
    # 配置文件里，没人会往那儿找。顺着链条走，步数超过分组总数就说明回到了
    # 走过的点；断成顶层分组并告警，配错的顶多是位置不对，工具还开得起来。
    local cur
    local -i hops
    for ((i = 0; i < OS_REG_GROUP_COUNT; i++)); do
        [[ -n ${OS_REG_GROUP_PARENT[i]} ]] || continue
        cur=${OS_REG_GROUP_PARENT[i]}
        hops=0
        while [[ -n ${cur} ]]; do
            hops+=1
            if ((hops > OS_REG_GROUP_COUNT)); then
                os::warn "分组 ${OS_REG_GROUP_ID[i]} 的 parent 链成环，已作为顶层分组显示"
                OS_REG_GROUP_PARENT[i]=''
                break
            fi
            found=-1
            for ((j = 0; j < OS_REG_GROUP_COUNT; j++)); do
                [[ ${OS_REG_GROUP_ID[j]} == "${cur}" ]] || continue
                found=${j}
                break
            done
            ((found >= 0)) || break
            cur=${OS_REG_GROUP_PARENT[found]}
        done
    done
    return 0
}

# registry::group_name <id>   打印显示名；未声明的分组回落成 id 本身
registry::group_name() {
    local id=${1-}
    local -i i
    for ((i = 0; i < OS_REG_GROUP_COUNT; i++)); do
        if [[ ${OS_REG_GROUP_ID[i]} == "${id}" ]]; then
            printf '%s\n' "${OS_REG_GROUP_NAME[i]}"
            return 0
        fi
    done
    printf '%s\n' "${id}"
    return 0
}

# registry::group_desc <id>   打印分组说明（groups.conf 第五列，可选）
#
# **没写与未声明都打印空行**，两者对消费者是同一件事：这一列本来就可选，
# 菜单据此决定要不要回落。怎么写这一列见 groups.conf 的注释，什么时候用它
# 见 bin/oneserver-menu 的 menu_group_summary。
registry::group_desc() {
    local id=${1-}
    local -i i
    for ((i = 0; i < OS_REG_GROUP_COUNT; i++)); do
        if [[ ${OS_REG_GROUP_ID[i]} == "${id}" ]]; then
            printf '%s\n' "${OS_REG_GROUP_DESC[i]}"
            return 0
        fi
    done
    printf '\n'
    return 0
}

# registry::group_parent <id>   打印菜单父分组；顶层或未声明时为空
registry::group_parent() {
    local id=${1-}
    local -i i
    for ((i = 0; i < OS_REG_GROUP_COUNT; i++)); do
        if [[ ${OS_REG_GROUP_ID[i]} == "${id}" ]]; then
            printf '%s\n' "${OS_REG_GROUP_PARENT[i]}"
            return 0
        fi
    done
    printf '\n'
    return 0
}

# ==================================================================
# 扫描
# ==================================================================

OS_REG__WORDS=()
OS_REG__M_COMMAND=''
OS_REG__M_NAME=''
OS_REG__M_SELF_NAME=''
OS_REG__M_GROUP=''
OS_REG__M_ORDER=''
OS_REG__M_PRIVILEGE=''
OS_REG__M_REQUIRES=''
OS_REG__M_PROVIDES=''
OS_REG__M_DESC=''
OS_REG__M_ARGS=''

# registry::_meta <文件>   解析元数据头（前 40 行内）
#
# 与 bootstrap.sh 的 os::__parse_meta 形状相似而不共用：那边填的是一组单值全局量、
# 且只认命令自己关心的字段（不解析 @group / @order）。目前是第二处，按「第三次
# 才提取」放着；真要提取，得先想清楚它落在哪一层 —— 它现在的两个消费者分居 L4 的
# 两个文件，而同层禁止互相依赖。
registry::_meta() {
    local file=${1}
    OS_REG__M_COMMAND=''
    OS_REG__M_NAME=''
    OS_REG__M_SELF_NAME=''
    OS_REG__M_GROUP=''
    OS_REG__M_ORDER=''
    OS_REG__M_PRIVILEGE='root'
    OS_REG__M_REQUIRES=''
    OS_REG__M_PROVIDES=''
    OS_REG__M_DESC=''
    OS_REG__M_ARGS=''
    [[ -r ${file} ]] || return 1

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
            @command) OS_REG__M_COMMAND=${value} ;;
            @name) OS_REG__M_NAME=${value} ;;
            @self_name) OS_REG__M_SELF_NAME=${value} ;;
            @group) OS_REG__M_GROUP=${value} ;;
            @order) OS_REG__M_ORDER=${value} ;;
            @privilege) OS_REG__M_PRIVILEGE=${value} ;;
            @requires) OS_REG__M_REQUIRES=${value} ;;
            @provides) OS_REG__M_PROVIDES=${value} ;;
            @description) OS_REG__M_DESC=${value} ;;
            @args) OS_REG__M_ARGS=${value} ;;
        esac
    done <"${file}"
    return 0
}

# registry::_index_of <命令>   下标写进 OS_REG__IDX，没有则 -1
#
# 写变量不打印，同 registry::resolve：调用点是 registry::_add，每个脚本文件走一次，
# 而 `$( )` 每次都 fork。**fork 的代价随本进程已装配的数组规模增长，不是常数** ——
# 用一个空函数去量它会得出「fork 很便宜」的结论，而扫描发生在整张表边建边查的时候。
# 脚本越多涨得越快，这正是「以后随便加脚本」最不该付的代价。
OS_REG__IDX=-1
registry::_index_of() {
    local cmd=${1-}
    local -i i
    OS_REG__IDX=-1
    for ((i = 0; i < OS_REG_COUNT; i++)); do
        if [[ ${OS_REG_COMMAND[i]} == "${cmd}" ]]; then
            OS_REG__IDX=${i}
            return 0
        fi
    done
    return 0
}

# registry::_add <文件>
registry::_add() {
    local file=${1}
    registry::_meta "${file}" || return 0

    # 没有 @command 的 .sh 不是命令（将来的公共片段、模板）。跳过并留个日志脚印，
    # 免得作者写漏了一行元数据却在菜单里遍寻不着
    if [[ -z ${OS_REG__M_COMMAND} ]]; then
        log::write debug "跳过 ${file}：没有 @command" framework
        return 0
    fi

    # @command 里的空白归一成单个空格：resolve 是按词比对的，
    # 「install   php」与「install php」必须是同一条命令
    local cmd
    IFS=$' \t' read -r -a OS_REG__WORDS <<<"${OS_REG__M_COMMAND}"
    local IFS=' '
    cmd="${OS_REG__WORDS[*]}"

    registry::_index_of "${cmd}"
    local -i dup=${OS_REG__IDX}
    if ((dup >= 0)); then
        # @command 全局唯一。撞车时保留先扫到的那个 ——
        # 沉默地让后者覆盖前者，等于让文件名顺序决定跑哪个脚本
        os::warn "命令「${cmd}」重复：${file} 与 ${OS_REG_FILE[dup]}，已忽略前者"
        return 0
    fi

    OS_REG_FILE+=("${file}")
    OS_REG_COMMAND+=("${cmd}")
    OS_REG_NAME+=("${OS_REG__M_NAME:-${cmd}}")
    OS_REG_SELF_NAME+=("${OS_REG__M_SELF_NAME}")
    OS_REG_GROUP+=("${OS_REG__M_GROUP}")
    OS_REG_ORDER+=("${OS_REG__M_ORDER:-0}")
    OS_REG_PRIVILEGE+=("${OS_REG__M_PRIVILEGE}")
    OS_REG_REQUIRES+=("${OS_REG__M_REQUIRES}")
    OS_REG_PROVIDES+=("${OS_REG__M_PROVIDES}")
    OS_REG_DESC+=("${OS_REG__M_DESC}")
    OS_REG_ARGS+=("${OS_REG__M_ARGS}")
    ((OS_REG_COUNT += 1))

    if ((${#OS_REG__WORDS[@]} > OS_REG_MAXWORDS)); then
        OS_REG_MAXWORDS=${#OS_REG__WORDS[@]}
    fi
    return 0
}

OS_REG__WORDS=()

# registry::scan   扫 $OS_SCRIPT_DIR，重建整张表
#
# 只扫两层（`script/*.sh` 与 `script/*/*.sh`），与实际目录布局一致。
# 不用 globstar：那是个会影响调用方的 shell 选项，为一层递归开它不划算。
registry::scan() {
    OS_REG_COUNT=0
    OS_REG_FILE=()
    OS_REG_COMMAND=()
    OS_REG_NAME=()
    OS_REG_SELF_NAME=()
    OS_REG_GROUP=()
    OS_REG_ORDER=()
    OS_REG_PRIVILEGE=()
    OS_REG_REQUIRES=()
    OS_REG_PROVIDES=()
    OS_REG_DESC=()
    OS_REG_ARGS=()
    OS_REG_MAXWORDS=0

    local f
    for f in "${OS_SCRIPT_DIR}"/*.sh "${OS_SCRIPT_DIR}"/*/*.sh; do
        [[ -f ${f} ]] || continue
        registry::_add "${f}"
    done
    return 0
}

# ==================================================================
# 排序 —— 分组序在前，@order 在后
# ==================================================================

registry::sort() {
    OS_REG_SORTED=()
    local -a keys=()
    local -i i j gi go
    local key
    for ((i = 0; i < OS_REG_COUNT; i++)); do
        # 分组 order 就地查，不抽一个 `$( )` 的取值函数出来：菜单每转一圈都重排
        # 一次，而那样写是每条命令 fork 一个子 shell
        go=${OS_REG__UNKNOWN_GROUP_ORDER}
        for ((gi = 0; gi < OS_REG_GROUP_COUNT; gi++)); do
            if [[ ${OS_REG_GROUP_ID[gi]} == "${OS_REG_GROUP[i]}" ]]; then
                go=${OS_REG_GROUP_ORDER[gi]}
                break
            fi
        done
        printf -v key '%06d%06d' "${go}" "${OS_REG_ORDER[i]}"
        keys+=("${key}")
        OS_REG_SORTED+=("${i}")
    done

    # 插入排序。十几个条目不值得为它 fork 一个 sort，也免了 IFS 与子 shell 的坑
    local -i cur
    for ((i = 1; i < OS_REG_COUNT; i++)); do
        cur=${OS_REG_SORTED[i]}
        for ((j = i - 1; j >= 0; j--)); do
            [[ ${keys[${OS_REG_SORTED[j]}]} > ${keys[${cur}]} ]] || break
            OS_REG_SORTED[j + 1]=${OS_REG_SORTED[j]}
        done
        OS_REG_SORTED[j + 1]=${cur}
    done
    return 0
}

# ==================================================================
# 路由 —— 最长前缀匹配
# ==================================================================

# registry::resolve <argv...>
#
# 命中时 OS_REG_MATCH = 下标，OS_REG_MATCH_WORDS = 吃掉了几个词，返回 0。
#
# **必须是最长前缀，不是「第一个词」**：manager 类脚本的形态是「一个文件 +
# 一个位置参数选动作」（D73）—— `oneserver firewall allow` 里 `firewall` 是命令、
# `allow` 是位置参数。而 `oneserver install php` 里两个词都是命令。
# 二者的区别只有注册表知道，所以从长到短试，第一个在表里的就是答案。
registry::resolve() {
    OS_REG_MATCH=-1
    OS_REG_MATCH_WORDS=0

    # 数组的 [*] 用 IFS 首字符连接，而脚本里 IFS 是 $'\n\t' —— 不锁死的话
    # 拼出来的 key 是用换行连的，永远匹配不上
    local IFS=' '
    local -a words=()
    local a
    for a in "$@"; do
        # 选项一出现，后面就都是参数了
        if [[ ${a} == -* ]]; then
            break
        fi
        words+=("${a}")
        if ((${#words[@]} >= OS_REG_MAXWORDS)); then
            break
        fi
    done

    local -i n i
    # shellcheck disable=SC2034  # 理由：OS_REG_MATCH / OS_REG_MATCH_WORDS 是给调用方（bin/ 前端）读的，本文件内只写不读
    for ((n = ${#words[@]}; n >= 1; n--)); do
        local key="${words[*]:0:n}"
        for ((i = 0; i < OS_REG_COUNT; i++)); do
            if [[ ${OS_REG_COMMAND[i]} == "${key}" ]]; then
                OS_REG_MATCH=${i}
                OS_REG_MATCH_WORDS=${n}
                return 0
            fi
        done
    done
    return 1
}

# ==================================================================
# 可见性 —— @requires 不满足的条目在菜单里隐藏
# ==================================================================

# registry::requires_met <下标>
#
# 与 bootstrap.sh 的 os::__check_requires 是同一套语法的第二份实现：那边不满足
# 就以退出码 3 终止并指明缺哪个，这边只要一个是/否。第三处出现时提取到 state.sh
# （组件约束是否满足本就是 state 的问题），现在按「两处相似不提取」放着。
registry::requires_met() {
    local -i idx=${1}
    local spec=${OS_REG_REQUIRES[idx]}
    [[ -n ${spec} ]] || return 0

    # 整份 state 读一次，本次判定内的各组件共用。**不跨调用复用**：两次判定
    # 之间可能夹着一次 os::state_set，缓存会让后一次用上写入前的答案
    os::state_snapshot

    local one rest op want type have cmp
    local -i si i
    local IFS=','
    for one in ${spec}; do
        [[ -n ${one} ]] || continue
        op=''
        want=''
        rest=${one}
        if [[ ${one} == *'>='* ]]; then
            op='>='
            rest=${one%%>=*}
            want=${one#*>=}
        elif [[ ${one} == *'>'* ]]; then
            op='>'
            rest=${one%%>*}
            want=${one#*>}
        elif [[ ${one} == *'='* ]]; then
            op='='
            rest=${one%%=*}
            want=${one#*=}
        fi
        type=${rest}

        si=-1
        if [[ ${type} == *:* ]]; then
            # 带实例：标识精确匹配
            for ((i = 0; i < ${#OS_STATE_SNAP_IDS[@]}; i++)); do
                [[ ${OS_STATE_SNAP_IDS[i]} == "${type}" ]] || continue
                si=${i}
                break
            done
            ((si >= 0)) || return 1
            have=${OS_STATE_SNAP_VERSIONS[si]}
        else
            # 不带实例：该 type 的第一个实例，顺序即 state 的行序（同 os::state_list）
            for ((i = 0; i < ${#OS_STATE_SNAP_IDS[@]}; i++)); do
                [[ ${OS_STATE_SNAP_IDS[i]%%:*} == "${type}" ]] || continue
                si=${i}
                break
            done
            if ((si >= 0)); then
                have=${OS_STATE_SNAP_VERSIONS[si]}
            else
                # state 里没有就问探测，与 os::__check_requires 同一条规则（D138）：
                # state 只记本工具装过的东西，用户自己 apt 装的那份照样在跑。
                #
                # 这里少了这一步，后果比命令侧更隐蔽 —— 命令跑起来至少还会报
                # 「缺少依赖组件」，而菜单是**直接把一整块功能藏掉且不给任何提示**，
                # 用户看到的只是「怎么没有这一项」。D93 当初绕开 @requires 正为此。
                #
                # 带实例的（php:8.3）不回退：探测答不出哪个实例是本工具装的。
                probe::component_version "${type}"
                have=${OS_PROBE_VALUE%%$'\n'*}
                have=${have%% *}
                have=${have#v}
                [[ -n ${have} ]] || return 1
            fi
        fi

        [[ -n ${op} ]] || continue
        cmp=$(os::version_cmp "${have}" "${want}")
        case ${op} in
            '>=') [[ ${cmp} == '-1' ]] && return 1 ;;
            '>') [[ ${cmp} != '1' ]] && return 1 ;;
            '=') [[ ${cmp} != '0' ]] && return 1 ;;
        esac
    done
    return 0
}
