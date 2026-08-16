# lib/state.sh —— L3 能力层：组件与 unit 清单
#
# 只依赖 L0–L2。**不依赖同层的 secure.sh / sql.sh / systemd.sh / probe.sh。**
#
# 这个文件回答一个现在完全答不上来的问题：**这台机器上装过什么。**
# 现状只有 `db_user_mapping.conf` 一处局部记录（R12）。没有它，
# 卸载只能靠猜，孤儿 unit 只能靠人翻。
#
# --- 格式：行式，不是 JSON（D39）---
#
#   <组件标识>\t<键>\t<值>
#
#   php:8.3	version	8.3.11
#   php:8.3	method	apt
#   php:8.3	unit	ext:php8.3-fpm.service
#
# JSON 是**全有或全无**的：末尾少一个 `}` 整个文件报废，而 state 报废意味着
# 所有组件都没法卸载。行式格式坏一行只丢一行，其余照常可用。
# 校验它也不需要 jq ——规范禁止 lib 依赖非基础命令。
#
# --- 主键是完整组件标识（D35）---
#
# `php:8.3` 与 `php:8.1` 是两条独立记录，各有各的 unit 列表。
# 扁平标识遇到「第二个同类事物」就静默覆盖 —— 与 K7 是同一类错误。
#
# --- 与 secure.sh 的重复 ---
#
# 转义与原子写这两段和 `secure.sh` 长得像，但没有提取：两者同在 L3，
# 同层禁止互相依赖。这是分层规则要求的重复，不是疏忽。
# 真要提取，得先想清楚它该落在哪一层——目前只有两处，按「第三次才提取」放着。

OS_STATE__DEC=''
OS_STATE__ENC=''
OS_STATE__CORRUPT=0

# os::state_snapshot 的输出：同一下标是同一个组件
OS_STATE_SNAP_IDS=()
OS_STATE_SNAP_VERSIONS=()

# ==================================================================
# 转义 —— 制表符与换行会撕开行式格式，必须编码
# ==================================================================

state::_encode() {
    local v=${1-}
    v=${v//\\/\\\\}
    v=${v//$'\t'/\\t}
    v=${v//$'\n'/\\n}
    v=${v//$'\r'/\\r}
    OS_STATE__ENC=${v}
    return 0
}

# 逐字符扫描，不做多次全局替换 —— 理由同 secure.sh：编码串 `\\t` 表示
# 「反斜杠 + 字母 t」，全局替换会命中它的后半截。
state::_decode() {
    local s=${1-}
    local out='' ch nxt
    local -i i n=${#s}
    for ((i = 0; i < n; i++)); do
        ch=${s:i:1}
        if [[ ${ch} != "\\" ]]; then
            out+=${ch}
            continue
        fi
        i+=1
        nxt=${s:i:1}
        case ${nxt} in
            t) out+=$'\t' ;;
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            "\\") out+="\\" ;;
            '') out+="\\" ;;
            *) out+="\\"${nxt} ;;
        esac
    done
    OS_STATE__DEC=${out}
    return 0
}

# ==================================================================
# 组件标识
# ==================================================================

OS_STATE__ID_RE='^[a-z][a-z0-9-]*(:[a-z0-9][a-z0-9._-]*)?$'

# os::state_id_valid <组件标识>   组件标识是否合法，只给返回码
os::state_id_valid() {
    [[ ${1-} =~ ${OS_STATE__ID_RE} ]]
}

# os::state_type <组件标识>   打印 type 部分
os::state_type() {
    printf '%s\n' "${1%%:*}"
}

# os::state_instance <组件标识>   打印 instance 部分，单实例组件为空
os::state_instance() {
    local id=${1-}
    if [[ ${id} == *:* ]]; then
        printf '%s\n' "${id#*:}"
    fi
    return 0
}

# ==================================================================
# 读
# ==================================================================

# 本进程用哪一份 state。算一次就记住 —— state_get/state_has 会被按组件×键
# 反复调用，每次都重新判定等于把整个文件扫上几十遍。写入成功后由
# state::_rewrite 清掉这个记号。
OS_STATE__SOURCE=''
OS_STATE__SOURCE_DONE=0

# state::_has_valid_line <文件>   该文件里有没有至少一行能解析的记录
#
# **判据不能只是「文件读得到」。** 被写坏的 components.tsv（掉电写了半截、
# 磁盘满、误编辑、非 UTF-8 垃圾）照样可读，逐行解析后每行都是坏行，
# 结果是一个空清单 —— 而空清单跟「这台机器上还没装过任何组件」在调用方
# 看来一模一样。实测过后果：把 state 写成二进制垃圾之后
# `oneserver uninstall docker` 会说「在 state 里没有登记任何资源 ——
# 只会把它从组件清单里划掉」，包、文件、unit 全部残留，而 `.bak` 里明明
# 躺着完整的清单。规范 §12 要的正是这条回退。
state::_has_valid_line() {
    local f=${1} rid rkey _rval
    while IFS=$'\t' read -r rid rkey _rval || [[ -n ${rid} ]]; do
        [[ -n ${rid} && -n ${rkey} ]] || continue
        os::state_id_valid "${rid}" && return 0
    done <"${f}"
    return 1
}

# state::_source_file   选出本次该读哪一份 state；两份都不可用时返回 1
#
# 规范「逐行恢复」：非法行跳过，其余可用；整份读不出有效记录时回退 `.bak`；
# 两者都坏进入降级模式并**明确告知卸载不可靠**。
# **不是**「一行坏了就当整个文件没了」，也不是「文件在就照单全收」。
state::_source_file() {
    if [[ ${OS_STATE__SOURCE_DONE} -eq 1 ]]; then
        [[ -n ${OS_STATE__SOURCE} ]] || return 1
        return 0
    fi
    OS_STATE__SOURCE_DONE=1
    OS_STATE__SOURCE=''

    local -i main_ok=0 main_empty=0 bak_ok=0
    if [[ -r ${OS_STATE_FILE} ]]; then
        if state::_has_valid_line "${OS_STATE_FILE}"; then
            main_ok=1
        elif [[ ! -s ${OS_STATE_FILE} ]]; then
            main_empty=1
        fi
    fi
    if [[ ${main_ok} -eq 1 ]]; then
        OS_STATE__SOURCE=${OS_STATE_FILE}
        return 0
    fi

    # 已存在的空主文件就是权威的空清单。删除最后一个组件时，原子写会把旧的
    # 非空主文件留在 .bak，再把空清单换成主文件；若此处优先看 .bak，刚删掉的
    # 组件会在下一次读取时复活，卸载会重复处理旧资源。
    if [[ ${main_empty} -eq 1 ]]; then
        OS_STATE__SOURCE=${OS_STATE_FILE}
        return 0
    fi

    if [[ -r ${OS_STATE_BAK} ]] && state::_has_valid_line "${OS_STATE_BAK}"; then
        bak_ok=1
    fi

    if [[ ${bak_ok} -eq 1 ]]; then
        OS_STATE__SOURCE=${OS_STATE_BAK}
        ui::line --err warn "${OS_STATE_FILE} 里读不出任何有效记录，已回退到上一版 ${OS_STATE_BAK}"
        log::write warn "state 主文件损坏，已回退 .bak" framework
        return 0
    fi

    # 两份都坏。**必须明说卸载不可靠**：静默当成「什么都没装」的代价是
    # 用户以为卸干净了，而包、文件、unit 全部残留。
    if [[ -s ${OS_STATE_FILE} || -s ${OS_STATE_BAK} ]]; then
        ui::line --err error 'state 与它的备份都读不出有效记录 —— 组件清单不可信，此时卸载会漏删资源'
        ui::line --err muted "    主文件 ${OS_STATE_FILE}"
        ui::line --err muted "    备份   ${OS_STATE_BAK}"
        ui::line --err muted '    可尝试 oneserver state rebuild 重建（只能重建探测得到的那部分）'
        log::write error 'state 与备份都损坏，组件清单不可信' framework
    fi
    return 1
}

# os::state_health <变量名>   返回 missing / empty / ok / recovered / corrupt
os::state_health() {
    local __os_sh_out=${1-}
    if [[ ! ${__os_sh_out} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        ui::line --err error 'os::state_health 用法：<变量名>'
        return 2
    fi

    # 内部名不能叫 health：Bash 的输出变量依赖动态作用域，调用方最自然的
    # `local health; os::state_health health` 会被同名局部变量截住。
    local __os_sh_value='corrupt'
    if state::_source_file; then
        if [[ ${OS_STATE__SOURCE} == "${OS_STATE_BAK}" ]]; then
            __os_sh_value='recovered'
        elif [[ -s ${OS_STATE_FILE} ]]; then
            __os_sh_value='ok'
        else
            __os_sh_value='empty'
        fi
    elif [[ ! -e ${OS_STATE_FILE} && ! -e ${OS_STATE_BAK} ]]; then
        __os_sh_value='missing'
    fi
    printf -v "${__os_sh_out}" '%s' "${__os_sh_value}"
    return 0
}

# os::state_get <组件标识> <键> [默认值]
os::state_get() {
    local id=${1-} key=${2-} default=${3-}
    state::_source_file || {
        printf '%s' "${default}"
        return 0
    }
    local f=${OS_STATE__SOURCE}

    local rid rkey rval
    while IFS=$'\t' read -r rid rkey rval || [[ -n ${rid} ]]; do
        [[ ${rid} == "${id}" && ${rkey} == "${key}" ]] || continue
        state::_decode "${rval}"
        printf '%s' "${OS_STATE__DEC}"
        return 0
    done <"${f}"
    printf '%s' "${default}"
    return 0
}

# os::state_has <组件标识>   state 中是否已登记该组件，只给返回码
os::state_has() {
    local id=${1-}
    state::_source_file || return 1
    local f=${OS_STATE__SOURCE}
    local rid _rest
    while IFS=$'\t' read -r rid _rest || [[ -n ${rid} ]]; do
        [[ ${rid} == "${id}" ]] && return 0
    done <"${f}"
    return 1
}

# os::state_list [type]   列出组件标识，去重；给了 type 只列该 type 的实例
os::state_list() {
    local want=${1-}
    state::_source_file || return 0
    local f=${OS_STATE__SOURCE}
    local rid _k _v seen=''
    while IFS=$'\t' read -r rid _k _v || [[ -n ${rid} ]]; do
        [[ -n ${rid} ]] || continue
        os::state_id_valid "${rid}" || continue
        if [[ -n ${want} && ${rid%%:*} != "${want}" ]]; then
            continue
        fi
        [[ ${seen} == *"|${rid}|"* ]] && continue
        seen+="|${rid}|"
        printf '%s\n' "${rid}"
    done <"${f}"
    return 0
}

# os::state_snapshot   把整份 state 读进两个平行数组，同一下标是同一个组件
#
#   OS_STATE_SNAP_IDS[i]        组件标识，顺序与去重规则同 os::state_list
#   OS_STATE_SNAP_VERSIONS[i]   该组件的 version，取首个匹配行（同 os::state_get），
#                               没有 version 行时为空串
#
# **每次调用都重读文件，不留跨调用缓存。** 同一个进程里两次调用之间可能夹着一次
# os::state_set —— install 与 uninstall 正是这么用的。缓存会让第二次拿着写入前的
# 答案去判可见性，表现是刚装完的组件在菜单里不出现、刚卸载的还留着，而且不报错。
# 重读的代价是纯 bash 过一遍小文件，买不起这个风险。
#
# **为什么要有它**：判定一条 `@requires` 从前是每个组件一次 os::state_list 加一次
# os::state_get，两者都得经 `$( )` / `< <( )` 取值 —— 每问一次 fork 一个子 shell，
# 且各自把整份文件重读一遍。菜单一屏要问十几条，这是它最大的一笔开销；而 fork 的
# 代价随进程已装配的数组规模增长，不是常数。写变量不打印（同 D68 / D74）才能一次
# 把「有哪些组件」和「各自什么版本」两个答案一起带出来。
os::state_snapshot() {
    OS_STATE_SNAP_IDS=()
    OS_STATE_SNAP_VERSIONS=()
    state::_source_file || return 0
    local f=${OS_STATE__SOURCE}

    # 哨兵取一个 id 里不可能出现的字节，空 id 才不会与它初值相等
    local rid rkey rval seen='' vset='' last=$'\x01'
    local -i i last_ok=0
    while IFS=$'\t' read -r rid rkey rval || [[ -n ${rid} ]]; do
        [[ -n ${rid} ]] || continue
        # **id 校验只在 id 变了的时候做一次。** 一份 state 十几个组件却上百行
        # ——unit / pkg / file 这些多值键每条各占一行，而同一个组件的行是连着的。
        # 逐行跑一次正则是本函数最贵的一笔（实测占它一半以上），而答案在这一
        # 段里不会变。id 交替出现时自动退回逐行校验，结论不受文件顺序影响。
        if [[ ${rid} != "${last}" ]]; then
            last=${rid}
            last_ok=0
            os::state_id_valid "${rid}" || continue
            last_ok=1
            if [[ ${seen} != *"|${rid}|"* ]]; then
                seen+="|${rid}|"
                OS_STATE_SNAP_IDS+=("${rid}")
                OS_STATE_SNAP_VERSIONS+=('')
            fi
        elif ((last_ok == 0)); then
            continue
        fi
        # 只认第一条 version：os::state_get 匹配到就返回，后面的同名行它根本
        # 读不到。这里若改成后者覆盖前者，同一个问题两个接口会给出不同答案
        [[ ${rkey} == version ]] || continue
        [[ ${vset} != *"|${rid}|"* ]] || continue
        vset+="|${rid}|"
        state::_decode "${rval}"
        # 倒着找：这一行的 id 多半就是刚追加的那个
        for ((i = ${#OS_STATE_SNAP_IDS[@]} - 1; i >= 0; i--)); do
            [[ ${OS_STATE_SNAP_IDS[i]} == "${rid}" ]] || continue
            OS_STATE_SNAP_VERSIONS[i]=${OS_STATE__DEC}
            break
        done
    done <"${f}"
    return 0
}

# 多值键 —— 同一个键可以有多行，写入时追加而不是覆盖。
#
# 这五个就是卸载的全部原料：uninstall 不探测、不猜、不按组件名写死，
# 只读这份清单并**逆序**反向执行。少记一样，那样东西就永远留在系统里。
state::_is_multi() {
    case ${1} in
        unit | pkg | file | divert | alt) return 0 ;;
        *) return 1 ;;
    esac
}

# os::state_resources <组件标识> <键>   列出该组件某个多值键的全部值
os::state_resources() {
    local id=${1-} key=${2-}
    state::_source_file || return 0
    local f=${OS_STATE__SOURCE}
    local rid rkey rval
    while IFS=$'\t' read -r rid rkey rval || [[ -n ${rid} ]]; do
        [[ ${rid} == "${id}" && ${rkey} == "${key}" ]] || continue
        state::_decode "${rval}"
        printf '%s\n' "${OS_STATE__DEC}"
    done <"${f}"
    return 0
}

# os::state_units <组件标识>   列出该组件的 unit（带 own:/ext: 前缀）
os::state_units() {
    os::state_resources "${1-}" unit
}

# os::state_resource_add <组件标识> <pkg|file|divert|alt> <值>
#
# 安装类脚本把自己动过的每一样东西登记进来，F6 的 uninstall
# 照着逆序反向执行。**重复登记会被吞掉**，所以脚本可以无脑调用，
# 重复执行不会让清单越长越离谱（幂等）。
os::state_resource_add() {
    local id=${1-} key=${2-} val=${3-}
    case ${key} in
        pkg | file | divert | alt) ;;
        *)
            ui::line error "os::state_resource_add：未知资源类型「${key}」"
            return 2
            ;;
    esac
    if [[ -z ${val} ]]; then
        ui::line error "os::state_resource_add：${key} 的值不能为空"
        return 2
    fi

    local existing
    while IFS= read -r existing; do
        [[ ${existing} == "${val}" ]] && return 0
    done < <(os::state_resources "${id}" "${key}")
    os::state_set "${id}" "${key}=${val}"
}

# os::state_resource_del <组件标识> <pkg|file|divert|alt> <值>
#
# 把一条资源从清单里摘掉。**不是给卸载用的** —— 卸载走 os::state_del 整份删。
#
# 用在**一个组件动了另一个组件登记过的东西**时：装 Docker 必须先 purge 掉
# podman 登记在自己名下的 podman-docker。不摘掉的话 state 里就留着一条假事实，
# 而 state 是卸载的唯一依据（§12）—— 日后卸 podman 会照着清单去 purge 一个
# 早就不在的包，更要命的是同一个包名此时可能已经属于别人。
#
# 清单里本来就没有它时直接返回 0 且不写文件：这是幂等，不是失败。
os::state_resource_del() {
    local id=${1-} key=${2-} val=${3-}
    case ${key} in
        pkg | file | divert | alt) ;;
        *)
            ui::line error "os::state_resource_del：未知资源类型「${key}」"
            return 2
            ;;
    esac
    if [[ -z ${val} ]]; then
        ui::line error "os::state_resource_del：${key} 的值不能为空"
        return 2
    fi

    local existing found=1
    while IFS= read -r existing; do
        if [[ ${existing} == "${val}" ]]; then
            found=0
            break
        fi
    done < <(os::state_resources "${id}" "${key}")
    [[ ${found} -eq 0 ]] || return 0

    os::critical_begin "从 state 移除 ${id} 的 ${key}"
    local -i rc=0
    state::_rewrite "${id}" 2 "${key}=${val}" || rc=$?
    os::critical_end
    if [[ ${rc} -eq 0 ]]; then
        log::write info "state 已移除 ${id} 的 ${key}=${val}" framework
    fi
    return "${rc}"
}

# ==================================================================
# 写 —— 原子替换 + 上一版备份
# ==================================================================

# state::_rewrite <组件标识> <删除标记> [键=值...]
#
# 删除标记：0 写入给定的键值 · 1 整个组件删光 · 2 只删掉与给定键值**逐字相等**的行。
#
# 之所以要有 2 这一档：资源清单是多值键，`skip` 那套「同键即覆盖」的逻辑
# 对它是关掉的（不关掉的话每加一个包就把前一个挤掉），于是按键根本删不掉单条 ——
# 只能按值定位。
#
# 读全量 → 在内存里改 → 写 .tmp → 校验 → 当前版存 .bak → mv 换 inode。
# 中途被 kill 只会留下一个没人引用的 .tmp，原文件一直是完整的旧版本 ——
# 这正是「写入中途被 kill 后文件仍可读」那条对抗性用例要的性质。
state::_rewrite() {
    local id=${1} del=${2}
    shift 2

    # 写入前必须重新检查磁盘上的最新状态，不能沿用本进程早先的读取缓存。
    # 两份都坏时把它当空清单写回，会同时毁掉故障现场与所有未知旧记录；这种
    # 情况只能先人工恢复或显式 rebuild，普通 set/add/del 一律硬拒绝。
    OS_STATE__SOURCE_DONE=0
    local __os_state_health=''
    os::state_health __os_state_health
    if [[ ${__os_state_health} == corrupt ]]; then
        ui::line error 'state 与 .bak 都损坏，拒绝覆盖；请先恢复备份或运行 oneserver state rebuild'
        return 1
    fi
    local -i source_was_bak=0
    [[ ${__os_state_health} == recovered ]] && source_was_bak=1

    # dry-run **禁止对系统产生任何变更**，state 文件也算系统。
    #
    # 这一条是在 install_redis 的验收里现原形的：预演跑完，
    # `components.tsv` 里的 maxmemory_mb 已经改成了预演用的那个值 ——
    # 而 state 正是「已是目标状态吗」的判据来源，于是**一次预演就能让
    # 后续的幂等判断全部失准**。之前没暴露，是因为 install_caddy 在
    # dry-run 下提前返回，根本走不到写 state 这一步。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        ui::line muted "[dry-run] 将更新组件状态 ${id}"
        log::write info "[dry-run] 跳过写 state：${id}" framework
        return 0
    fi

    if ! mkdir -p "${OS_STATE_DIR}" 2>/dev/null; then
        ui::line error "无法创建 ${OS_STATE_DIR}"
        return 1
    fi

    # 名字走 mktemp 不拼 `$$`（同 template::_place）：写法在全项目里必须一致
    local tmp
    if ! tmp=$(mktemp "${OS_STATE_FILE}.tmp.XXXXXXXX" 2>/dev/null); then
        ui::line error "无法在 ${OS_STATE_DIR} 下创建临时文件"
        return 1
    fi

    # 1) 抄写其他组件的行；本组件里被本次覆盖的键**就地换成新值**
    #
    # **就地换而不是「先删掉、末尾再补」**：后者会让被覆盖的键每次都挪到文件
    # 末尾，于是「值一个字都没改」的第二次执行仍然产出一份行序不同的 state ——
    # 下面那道「内容没变就不落地」的比对因此永远命中不了，幂等在第一次重跑时
    # 就破了。就地换之后行序稳定，重跑真的是零字节变化。
    local -a keys=() vals=() emitted=()
    local kv
    for kv in "$@"; do
        keys+=("${kv%%=*}")
        vals+=("${kv#*=}")
        emitted+=(0)
    done

    local f rid rkey rval skip
    local -i i hit
    if state::_source_file; then
        f=${OS_STATE__SOURCE}
        while IFS=$'\t' read -r rid rkey rval || [[ -n ${rid} ]]; do
            [[ -n ${rid} ]] || continue
            if ! os::state_id_valid "${rid}" || [[ -z ${rkey} ]]; then
                OS_STATE__CORRUPT=$((OS_STATE__CORRUPT + 1))
                log::write warn "state 有损坏的行，已跳过：${rid}" framework
                continue
            fi
            if [[ ${rid} == "${id}" ]]; then
                [[ ${del} -eq 1 ]] && continue
                skip=0
                hit=-1
                if [[ ${del} -eq 2 ]]; then
                    # 比的是解码后的值：清单里存的是编码形态，拿它跟调用方
                    # 给的原文比，带制表符或换行的值永远删不掉
                    state::_decode "${rval}"
                    for ((i = 0; i < ${#keys[@]}; i++)); do
                        [[ ${rkey} == "${keys[i]}" && ${OS_STATE__DEC} == "${vals[i]}" ]] && skip=1 && break
                    done
                else
                    for ((i = 0; i < ${#keys[@]}; i++)); do
                        [[ ${rkey} == "${keys[i]}" ]] && skip=1 && hit=${i} && break
                    done
                    # 多值键追加不覆盖 —— 资源清单全是多值
                    state::_is_multi "${rkey}" && skip=0
                fi
                if [[ ${skip} -eq 1 ]]; then
                    # 覆盖类（del=0）在原位置写新值；同一个键在文件里出现两次
                    # （损坏或历史遗留）时只留第一处，其余丢掉
                    if [[ ${hit} -ge 0 && ${emitted[hit]} -eq 0 ]]; then
                        state::_encode "${vals[hit]}"
                        printf '%s\t%s\t%s\n' "${id}" "${keys[hit]}" "${OS_STATE__ENC}" >>"${tmp}"
                        emitted[hit]=1
                    fi
                    continue
                fi
            fi
            printf '%s\t%s\t%s\n' "${rid}" "${rkey}" "${rval}" >>"${tmp}"
        done <"${f}"
    fi

    # 2) 补上文件里原本没有的键（已就地换过的不再重复写）
    if [[ ${del} -eq 0 ]]; then
        for ((i = 0; i < ${#keys[@]}; i++)); do
            [[ ${emitted[i]} -eq 1 ]] && continue
            state::_encode "${vals[i]}"
            printf '%s\t%s\t%s\n' "${id}" "${keys[i]}" "${OS_STATE__ENC}" >>"${tmp}"
        done
    fi

    # 3) 校验：每行必须是三段，且组件标识合法。自己写坏了不能落地。
    local bad=0
    while IFS=$'\t' read -r rid rkey rval || [[ -n ${rid} ]]; do
        [[ -n ${rid} ]] || continue
        if ! os::state_id_valid "${rid}" || [[ -z ${rkey} ]]; then
            bad=1
            break
        fi
    done <"${tmp}"
    if [[ ${bad} -eq 1 ]]; then
        rm -f -- "${tmp}" 2>/dev/null || true
        ui::line error "state 写入校验失败，已放弃本次变更"
        return 1
    fi

    # **内容没变就不落地**（规范 §10「写文件前先判断内容是否变化」）。
    #
    # 不加这一步的话，一条已经幂等的命令第二次执行仍然会换掉 state 的 inode
    # 并轮转一次 `.bak` —— 实测 `install php` / `mariadb` / `caddy` / `docker`
    # 连跑两次，components.tsv 字节完全相同（2584 → 2584）而 mtime 与 .bak 全变。
    # 两个后果：一是违反「第二次执行不产生任何新变更」；二是 `.bak` 本该是
    # **上一版**，被空转轮换几次之后它只是当前版的副本，损坏时可回退的那一份
    # 就没了。
    #
    # 比对放在校验之后：先确认要写的东西本身是好的，再决定要不要写。
    if [[ -f ${OS_STATE_FILE} ]] && cmp -s -- "${tmp}" "${OS_STATE_FILE}"; then
        rm -f -- "${tmp}" 2>/dev/null || true
        log::write debug "state 内容未变化，未改动 ${OS_STATE_FILE}" framework
        return 0
    fi

    chmod "${OS_STATE_FILE_MODE}" "${tmp}" 2>/dev/null || true
    # recovered 时主文件正是损坏的那份，绝不能在新主文件就位前拿它覆盖唯一
    # 有效的 .bak。新主文件已经由 .bak 全量重建，原 .bak 留作上一版即可。
    if [[ -f ${OS_STATE_FILE} && ${source_was_bak} -eq 0 ]]; then
        cp -a -- "${OS_STATE_FILE}" "${OS_STATE_BAK}" 2>/dev/null || true
    fi
    if ! mv -f -- "${tmp}" "${OS_STATE_FILE}"; then
        rm -f -- "${tmp}" 2>/dev/null || true
        ui::line error "无法更新 ${OS_STATE_FILE}"
        return 1
    fi
    # 主文件刚被写好，之前若因损坏而选中了 .bak，那个判定已经过期
    OS_STATE__SOURCE_DONE=0
    return 0
}

# os::state_set <组件标识> <键>=<值> [<键>=<值>...]
os::state_set() {
    local id=${1-}
    shift || true
    if ! os::state_id_valid "${id}"; then
        ui::line error "组件标识「${id}」不合法"
        return 2
    fi
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    # 首次登记时补一个安装时间，卸载时列实例要用
    local -a extra=()
    if ! os::state_has "${id}"; then
        local now
        printf -v now '%(%s)T' -1
        extra=("installed_at=${now}")
    fi

    os::critical_begin "写入 state ${id}"
    local -i rc=0
    state::_rewrite "${id}" 0 "$@" ${extra[@]+"${extra[@]}"} || rc=$?
    os::critical_end
    if [[ ${rc} -eq 0 ]]; then
        log::write info "state 已记录 ${id}：$*" framework
    fi
    return "${rc}"
}

# os::state_unit_add <组件标识> <own:|ext:><unit>
#
# 由 lib/systemd.sh 自动调用，脚本不用手写。
os::state_unit_add() {
    local id=${1-} unit=${2-}
    if [[ ${unit} != own:* && ${unit} != ext:* ]]; then
        ui::line error "unit「${unit}」缺少 own:/ext: 前缀"
        return 2
    fi
    # 已经记过就不重复记
    local existing
    while IFS= read -r existing; do
        [[ ${existing} == "${unit}" ]] && return 0
    done < <(os::state_units "${id}")
    os::state_set "${id}" "unit=${unit}"
}

# os::state_del <组件标识>
os::state_del() {
    local id=${1-}
    if ! os::state_id_valid "${id}"; then
        ui::line error "组件标识「${id}」不合法"
        return 2
    fi
    os::critical_begin "删除 state ${id}"
    local -i rc=0
    state::_rewrite "${id}" 1 || rc=$?
    os::critical_end
    if [[ ${rc} -eq 0 ]]; then
        log::write info "state 已删除 ${id}" framework
    fi
    return "${rc}"
}

# ==================================================================
# 版本比较
# ==================================================================

# os::version_cmp <a> <b>   打印 -1 / 0 / 1
#
# 纯 bash，不用 `sort -V`：规范要求 lib 在没有 coreutils 保证的场景下
# 也能工作，而且这里逐段比数字比调用外部命令快得多（菜单每次进都要跑）。
# 非数字段按 0 处理：`8.3.11-1ubuntu2` 与 `8.3.11` 比出来相等，够用。
os::version_cmp() {
    local a=${1-0} b=${2-0}
    local -a pa pb
    IFS='.' read -r -a pa <<<"${a%%[-+~]*}"
    IFS='.' read -r -a pb <<<"${b%%[-+~]*}"
    local -i i n=${#pa[@]}
    # x/y 故意**不声明为整型**：`local -i x` 会在赋值时就做算术求值，
    # 而 `x=08` 在那里被当成八进制 —— 直接报 "value too great for base"。
    # 留成字符串，比较时再用 10# 显式指定十进制。
    local x y
    [[ ${#pb[@]} -gt ${n} ]] && n=${#pb[@]}
    local sa sb
    for ((i = 0; i < n; i++)); do
        # 纯参数展开剔除非数字，不 fork tr：这个函数在菜单里每条 @requires 都要跑
        sa=${pa[i]:-0}
        sb=${pb[i]:-0}
        sa=${sa//[!0-9]/}
        sb=${sb//[!0-9]/}
        x=${sa:-0}
        y=${sb:-0}
        if ((10#${x:-0} > 10#${y:-0})); then
            printf '1\n'
            return 0
        fi
        if ((10#${x:-0} < 10#${y:-0})); then
            printf -- '-1\n'
            return 0
        fi
    done
    printf '0\n'
    return 0
}
