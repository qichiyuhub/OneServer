# lib/secure.sh —— L3 能力层：凭据的唯一读写通道
#
# 只依赖 L0–L2。**不依赖同层的 state.sh / sql.sh / systemd.sh / probe.sh。**
#
# 这个文件是 K1 / K7 / K12 三条缺陷的对症药：
#
#   K1  现状用 `>` 截断整个 secure.conf 再写一行 —— 装一次 MariaDB 就抹掉
#       所有其他凭据。这里改成「读全量 → 改一行 → 原子换 inode」。
#   K7  现状 key 是扁平的（DB_PASS），部署第二个站点会覆盖第一个的凭据，
#       此后 cron 备份改去备份第二个站点，**第一个从此没有备份且无任何提示**。
#       这里强制命名空间。
#   K12 现状 `source secure.conf` —— 配置文件里写什么就执行什么。
#       这里严格解析，全文件不出现 source。
#
# --- 一个调用方必须知道的坑 ---
#
# `pass=$(os::secure_get k)` 会**丢掉值尾部的换行** —— 那是 bash 命令替换的
# 固有行为，不是这里的 bug。凭据里带尾部换行很少见，但一旦有（比如粘贴 PEM
# 私钥），取出来的东西就和存进去的不一样了。需要精确取值时用重定向：
#     os::secure_get k > "${f}"
#
# --- 落盘格式 ---
#
#   key='转义后的值'
#
# 一行一条记录。规范只要求转义单引号，这里多转义反斜杠与换行，
# 为的是**一条记录永远只占一行**：值里带换行时，行式格式才不会被撕开
# （D39 的「损坏只丢受损的行」也是这个前提）。写入与读取严格对称，
# 保证「写进去什么读出来就是什么」——这是规范点名要过对抗性测试的性质。

# ==================================================================
# key 与命名空间
# ==================================================================

# 禁止无命名空间的扁平 key
OS_SECURE__KEY_RE='^[a-z]+(\.[a-z0-9_-]+)+$'

# os::secure_key_valid <key>   凭据 key 是否带命名空间，只给返回码
os::secure_key_valid() {
    [[ ${1-} =~ ${OS_SECURE__KEY_RE} ]]
}

# os::secure_ns <组件标识>   打印该组件的凭据命名空间前缀
#
# `php:8.3` → `php.8-3`。`:` 与 `.` 在 key 里都不合法，转写规则统一放这里，
# 脚本禁止自行拼接—— 各拼各的迟早出现两种写法指向同一组件。
os::secure_ns() {
    local id=${1-}
    local type=${id%%:*}
    local instance=''
    if [[ ${id} == *:* ]]; then
        instance=${id#*:}
    fi
    if [[ -z ${instance} ]]; then
        printf '%s\n' "${type}"
        return 0
    fi
    printf '%s.%s\n' "${type}" "${instance//./-}"
    return 0
}

# ==================================================================
# 转义 —— 写入与读取必须严格对称
# ==================================================================

# secure::_encode <值>   结果写进 OS_SECURE__ENC
secure::_encode() {
    local v=${1-}
    v=${v//\\/\\\\}
    v=${v//$'\n'/\\n}
    v=${v//$'\r'/\\r}
    v=${v//\'/\\q}
    OS_SECURE__ENC=${v}
    return 0
}
OS_SECURE__ENC=''

# secure::_decode <编码后的值>   结果写进 OS_SECURE__DEC
#
# **必须逐字符扫描，不能做三次全局替换。** 编码串 `\\n` 表示「反斜杠 + 字母 n」，
# 而全局替换 `\n`→换行 会命中它后半截，得到「反斜杠 + 换行」——错得很安静。
secure::_decode() {
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
            n) out+=$'\n' ;;
            r) out+=$'\r' ;;
            q) out+="'" ;;
            "\\") out+="\\" ;;
            '')
                # 末尾落单的反斜杠：原样保留，不吞
                out+="\\"
                ;;
            *) out+="\\"${nxt} ;;
        esac
    done
    OS_SECURE__DEC=${out}
    return 0
}
OS_SECURE__DEC=''

# ==================================================================
# 读
# ==================================================================

# os::secure_get <key> [默认值]
os::secure_get() {
    local key=${1-} default=${2-}
    if ! os::secure_key_valid "${key}"; then
        ui::line error "凭据 key「${key}」缺少命名空间"
        return 2
    fi
    if [[ ! -r ${OS_SECURE_CONF} ]]; then
        printf '%s' "${default}"
        return 0
    fi

    local line found=''
    # 严格解析，**不 source**（K12）。整行匹配 key='...' 才认。
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} == "${key}="\'*\' ]] || continue
        found=${line#"${key}="\'}
        found=${found%\'}
        secure::_decode "${found}"
        printf '%s' "${OS_SECURE__DEC}"
        return 0
    done <"${OS_SECURE_CONF}"

    printf '%s' "${default}"
    return 0
}

# os::secure_load [--not-secret] <key> <变量名>   读进变量，**并在当前 shell 登记脱敏**
#
# 与 `os::secure_get` 的唯一区别就是这一句「在当前 shell」，而它是全部理由：
# `pass=$(os::secure_get redis.password)` 里的 secret_add 发生在子 shell，
# 随子 shell 一起消失 —— 拿到手的是明文，脱敏表却是空的。此后这个值被打进
# 任何一行预览或日志，都是明文。**这不会报错，也没有任何症状**（同 D74）。
#
# key 不存在时变量置空并返回 1，由调用方决定是生成一个还是报错。
#
# `--not-secret` 与 os::secure_set 的同名开关对称，用于 `web.telegram_chat_id`
# 这类「存在凭据库里但本身不是秘密」的值：不登记脱敏，也不因为它短就告警。
#
# **存量短凭据要留痕**：os::secure_set 现在拦得住新写入的短值，但机器上可能
# 已经躺着旧版本写下的。此时 log::secret_add 会拒绝登记，而调用方拿到的是
# 一个此后无法被脱敏的明文——从前这里 `|| true` 一声不吭地咽下了这个事实。
# 只记日志不上屏：web_notify 这类周期性调用者每轮都会走到这里，上屏会刷屏；
# 真正该把它摆到人眼前的是 `doctor`，它按 os::secure_list 逐条查。
os::secure_load() {
    local -i not_secret=0
    if [[ ${1-} == --not-secret ]]; then
        not_secret=1
        shift
    fi
    local key=${1-} varname=${2-}
    if [[ -z ${varname} ]]; then
        ui::line error 'os::secure_load 用法：[--not-secret] <key> <变量名>'
        return 2
    fi
    local v
    v=$(os::secure_get "${key}") || return $?
    printf -v "${varname}" '%s' "${v}"
    [[ -z ${v} ]] && return 1
    if [[ ${not_secret} -eq 0 ]] && ! log::secret_add "${v}"; then
        log::write warn "凭据 ${key} 短于 ${OS_SECRET_MIN_LEN} 位，无法登记脱敏；建议轮换它" framework
    fi
    return 0
}

# os::secure_require <key>...   缺任何一个即以退出码 3 终止
os::secure_require() {
    # `${missing[*]}` 按 IFS 首字符连接，而脚本层的 IFS 不含空格（D91）
    local IFS=' '
    local key missing=()
    for key in "$@"; do
        local v
        v=$(os::secure_get "${key}") || return $?
        if [[ -z ${v} ]]; then
            missing+=("${key}")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    ui::line error "缺少必需的凭据：${missing[*]}"
    ui::line --err muted "    存放位置 ${OS_SECURE_CONF}"
    log::exit_code error "缺少凭据 ${missing[*]}" 3
    exit 3
}

# ==================================================================
# 写 —— 读全量 + 改一行 + 原子换 inode
# ==================================================================

# secure::_rewrite <key> <编码后的值或空> <是否删除>
#
# `>` 就地截断是 K1 的根因，也违反规范「替换文件必须换 inode」。
# 这里先写同目录的临时文件再 mv：mv 在同一文件系统内是原子的，
# 任何时刻读到的要么是旧的完整文件、要么是新的完整文件，没有中间态。
secure::_rewrite() {
    local key=${1} enc=${2-} del=${3:-0}

    # dry-run 禁止对系统产生任何变更。
    #
    # 这条比写 state 那条更狠，install_redis 的验收里是这么撞上的：
    # `--dry-run --regen-password` 生成了一个新密码并**真的写进了凭据库**，
    # 而配置文件因为处在 dry-run 下没被改 —— 两边就此对不上，
    # **一次预演直接让正在跑的 Redis 连不上了**，屏幕上还全是 `[dry-run]`。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        ui::line muted "[dry-run] 将更新凭据 ${key}"
        log::write info "[dry-run] 跳过写凭据：${key}" framework
        return 0
    fi

    if ! mkdir -p "$(dirname "${OS_SECURE_CONF}")" 2>/dev/null; then
        ui::line error "无法创建 ${OS_SECURE_CONF} 所在目录"
        return 1
    fi

    # mktemp 而不是拼 `$$`（同 template::_place），且它建出来就是 0600，
    # 不必再围一圈 umask
    local tmp
    if ! tmp=$(mktemp "${OS_SECURE_CONF}.tmp.XXXXXXXX" 2>/dev/null); then
        ui::line error "无法在 ${OS_SECURE_CONF%/*} 下创建临时文件"
        return 1
    fi

    local line replaced=0
    if [[ -r ${OS_SECURE_CONF} ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            if [[ ${line} == "${key}="\'*\' ]]; then
                replaced=1
                if [[ ${del} -eq 1 ]]; then
                    continue
                fi
                printf "%s='%s'\n" "${key}" "${enc}" >>"${tmp}"
                continue
            fi
            printf '%s\n' "${line}" >>"${tmp}"
        done <"${OS_SECURE_CONF}"
    fi
    if [[ ${replaced} -eq 0 && ${del} -eq 0 ]]; then
        printf "%s='%s'\n" "${key}" "${enc}" >>"${tmp}"
    fi

    chmod "${OS_SECURE_CONF_MODE}" "${tmp}" 2>/dev/null || true
    chown root:root "${tmp}" 2>/dev/null || true
    if ! mv -f -- "${tmp}" "${OS_SECURE_CONF}"; then
        rm -f -- "${tmp}" 2>/dev/null || true
        ui::line error "无法更新 ${OS_SECURE_CONF}"
        return 1
    fi
    return 0
}

# os::secure_set [--not-secret] <key> <值>
#
# **这里不设最短长度，长度门槛在输入边界（os::ask_secret）。** 一度把它加在
# 这儿，结果是 7 条既有用例当场变红 —— 它们测的是**存储层的往返保真**（空串、
# 裸 `\r`、纯反斜杠），而「写进去什么读出来就是什么」是规范点名要过对抗性
# 测试的性质。存储原语必须忠实存下给它的任何字节序列；「这个口令够不够长」
# 是策略，属于人敲键盘的那一步，两者混在一起就是拿正确的契约去迁就策略。
#
# `--not-secret` 是给**存在凭据库里但本身不是秘密**的值用的，目前只有一个：
# `web.telegram_chat_id` 是个聊天 ID，放进凭据库只为了跟 token 共用命名空间与
# 0600 权限。它的作用只剩一件事 —— 不登记脱敏：那是个纯数字，全局替换会把
# 日志里凑巧相同的数字一起打成 `***`，把排查证据一起毁掉。
os::secure_set() {
    local -i not_secret=0
    if [[ ${1-} == --not-secret ]]; then
        not_secret=1
        shift
    fi
    local key=${1-} value=${2-}
    if ! os::secure_key_valid "${key}"; then
        ui::line error "凭据 key「${key}」缺少命名空间"
        return 2
    fi
    # 值一旦进来就登记脱敏：后面任何日志、审计、JSONL 都不会再有明文。
    # --not-secret 的值不登记，理由见函数头。
    if [[ ${not_secret} -eq 0 ]]; then
        log::secret_add "${value}" || true
    fi

    secure::_encode "${value}"
    # 整个替换过程放进不可中断区段：写到一半被 Ctrl-C 打断，
    # 留下的是一个没有这条凭据的文件，而调用方以为写成功了。
    os::critical_begin "写入凭据 ${key}"
    local -i rc=0
    secure::_rewrite "${key}" "${OS_SECURE__ENC}" 0 || rc=$?
    os::critical_end
    if [[ ${rc} -eq 0 ]]; then
        log::write info "已写入凭据 ${key}" framework
    fi
    return "${rc}"
}

# os::secure_del <key>
os::secure_del() {
    local key=${1-}
    if ! os::secure_key_valid "${key}"; then
        ui::line error "凭据 key「${key}」缺少命名空间"
        return 2
    fi
    os::critical_begin "删除凭据 ${key}"
    local -i rc=0
    secure::_rewrite "${key}" '' 1 || rc=$?
    os::critical_end
    if [[ ${rc} -eq 0 ]]; then
        log::write info "已删除凭据 ${key}" framework
    fi
    return "${rc}"
}

# os::secure_list   打印全部 key（**不打印值**），供 doctor 与卸载使用
os::secure_list() {
    [[ -r ${OS_SECURE_CONF} ]] || return 0
    local line
    while IFS= read -r line || [[ -n ${line} ]]; do
        [[ ${line} == *"='"*"'" ]] || continue
        printf '%s\n' "${line%%=*}"
    done <"${OS_SECURE_CONF}"
    return 0
}
