# lib/log.sh —— L1 输出层：把消息送上磁盘
#
# 与同层的 ui.sh 职责对称：ui.sh 送给人，log.sh 送上磁盘。两者都只依赖 L0，
# **彼此不依赖**。log.sh 里因此不会出现任何 ui::* 调用 ——
# 日志写不进去时只能降级到 stderr 直写，不能反过来抛错，否则就是循环依赖。
#
# 四个落点（路径全部来自 lib/paths.sh，这里不自己拼）：
#   $OS_LOG_MAIN                  人读的主时间线
#   $OS_LOG_DIR/<command>.log     按命令分文件
#   $OS_LOG_JSONL                 机器读的同一条时间线
#   $OS_AUDIT_LOG                 os::run 自动产生的事故追溯记录
#
# **脱敏在写入前发生，不是展示时**—— 直接 cat 日志也必须安全。

# --- 状态 ---

# 写不进日志目录时置 0（非 root 跑 @privilege any 的命令是正常情况），
# 之后全部写入静默跳过。日志不可用不该让脚本失败。
OS_LOG_ENABLED=0
OS_LOG_LEVEL='info'
OS_LOG_COMMAND='oneserver'
OS_LOG_CMD_FILE=''

OS_LOG__SECRETS=()
OS_LOG__REDACTED=''
OS_LOG__ESCAPED=''
# log::exit_code → log::write 这一跳的私有通道。走变量而不是给 log::write
# 加第四个参数：退出码只有这一个来源，加进签名等于让每个调用方都要知道它
OS_LOG__EXIT_CODE=''

# 级别数值，越小越严重。比较用数值，不要比字符串。
OS_LOG__LV_ERROR=0
OS_LOG__LV_WARN=1
OS_LOG__LV_INFO=2
OS_LOG__LV_DEBUG=3

# ==================================================================
# 初始化
# ==================================================================

# log::level_value <名字>   结果写进 OS_LOG__LVV，未知名字按 info
log::level_value() {
    case ${1,,} in
        error) OS_LOG__LVV=${OS_LOG__LV_ERROR} ;;
        warn | warning) OS_LOG__LVV=${OS_LOG__LV_WARN} ;;
        debug) OS_LOG__LVV=${OS_LOG__LV_DEBUG} ;;
        *) OS_LOG__LVV=${OS_LOG__LV_INFO} ;;
    esac
    return 0
}
OS_LOG__LVV=2

# log::set_level <级别>   给装配层调，别在外面直接改 OS_LOG_LEVEL
#
# 变量归本模块所有，改它就该走本模块的入口。别处直接赋值不但越界，
# 静态检查也会把那处报成「未使用」—— 它没法知道这个变量是给谁的。
#
#（注意：注释行不要以「# shellcheck」这个词开头，那会被当成指令解析。）
log::set_level() {
    OS_LOG_LEVEL=${1:-info}
    return 0
}

# log::init <命令路径>
#
# 日志初始化由 bootstrap.sh 自动完成，脚本禁止自定义日志路径、
# 禁止自行 mkdir 日志目录。这个函数是那条规则唯一的落实点。
#
# 无论成败都返回 0：日志目录建不了（非 root）是正常情况，不该让命令失败。
log::init() {
    OS_LOG_COMMAND=${1:-oneserver}
    # 命令路径里有空格（`install php`），文件名换成短横线
    local safe=${OS_LOG_COMMAND// /-}
    safe=${safe//\//-}

    OS_LOG_LEVEL=${OS_LOG_LEVEL:-${OS_DEFAULT_LOG_LEVEL}}

    if ! mkdir -p "${OS_LOG_DIR}" 2>/dev/null; then
        OS_LOG_ENABLED=0
        return 0
    fi
    chmod "${OS_LOG_DIR_MODE}" "${OS_LOG_DIR}" 2>/dev/null || true

    OS_LOG_CMD_FILE="${OS_LOG_DIR}/${safe}.log"
    local f
    for f in "${OS_LOG_MAIN}" "${OS_LOG_JSONL}" "${OS_AUDIT_LOG}" "${OS_LOG_CMD_FILE}"; do
        # **`2>/dev/null` 必须写在 `>>` 前面**（K16）。bash 按出现顺序处理重定向：
        # 写成 `: 2>/dev/null >>"${f}"` 时，打不开 ${f} 的报错是 bash 自己打的，
        # 而那一刻 stderr 还指着终端 —— 于是普通用户敲 `oneserver php config`
        # 先看到一行
        #     lib/log.sh: line NN: /var/log/oneserver/oneserver.log: Permission denied
        # 然后才看到那句真正有用的「此命令需要 root 权限」。
        # 日志目录 0750 属 root 是对的（K5 的反面），写不进去本来就该**静默降级**，
        # 而这条降级路径（OS_LOG_ENABLED=0）一直都在，只是那行报错先漏了出去。
        if ! : 2>/dev/null >>"${f}"; then
            OS_LOG_ENABLED=0
            return 0
        fi
        chmod 0640 "${f}" 2>/dev/null || true
    done

    OS_LOG_ENABLED=1
    return 0
}

# ==================================================================
# 脱敏 —— D33：按值不按位置
# ==================================================================

# log::secret_add <值>
#
# 登记一个需要在写入前抹掉的值。**按值匹配，不按参数位置**：
# 位置索引在任何人往命令中间插一个参数时立即错位，而错位不报错，
# 唯一表现是密码开始明文进日志 —— 会在正常重构中静默失效的安全机制。
#
# 值长度 < OS_SECRET_MIN_LEN 一律拒绝：短值（'a'、'123'）在正文里到处都是，
# 全局替换会把日志打成马赛克，看上去脱敏了，实际是把证据也毁了。
# 返回非零，由调用方决定是报错还是放弃脱敏。
#
# **下限读 L0 常量，不写字面量**：入口（os::ask_secret / os::secure_set）与
# 出口（这里、os::run --secret-val）必须是同一个数。写成三处字面量的后果实测
# 过——入口根本没有下限，于是短密码永远进不了脱敏表，也永远没人发现。
log::secret_add() {
    local v=${1-}
    if [[ ${#v} -lt ${OS_SECRET_MIN_LEN} ]]; then
        return 1
    fi
    local existing
    for existing in ${OS_LOG__SECRETS[@]+"${OS_LOG__SECRETS[@]}"}; do
        if [[ ${existing} == "${v}" ]]; then
            return 0
        fi
    done
    OS_LOG__SECRETS+=("${v}")
    return 0
}

# log::redact <文本>   结果写进 OS_LOG__REDACTED
log::redact() {
    local text=${1-}
    local s
    for s in ${OS_LOG__SECRETS[@]+"${OS_LOG__SECRETS[@]}"}; do
        text=${text//"${s}"/'***'}
    done
    OS_LOG__REDACTED=${text}
    return 0
}

# ==================================================================
# JSON 转义 ——规范点名要过对抗性测试的函数
# ==================================================================

# log::json_escape <字符串>   结果写进 OS_LOG__ESCAPED（**不含**两侧引号）
#
# 手写而不用 jq：规范禁止 lib 依赖非基础命令，而 jq 在 Debian/Ubuntu
# 最小安装里不预装（D39）。
#
# 控制字符必须转成 \uXXXX：JSON 规范不允许 U+0000–U+001F 裸奔，
# 而日志正文里出现 \r（curl 进度条）、\t（命令输出）是家常便饭。
log::json_escape() {
    local LC_ALL=C
    local s=${1-}
    # 反斜杠必须第一个换，否则会把后面新加的转义符二次转义
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}

    # 剩下的控制字符逐个换成 \u00XX。先探一下有没有，绝大多数字符串没有，
    # 不该为此逐字节走一遍。
    if [[ ${s} == *[$'\x01'-$'\x1f']* ]]; then
        local out='' ch
        local -i i n=${#s} code
        for ((i = 0; i < n; i++)); do
            ch=${s:i:1}
            printf -v code '%d' "'${ch}"
            if ((code < 0x20)); then
                printf -v ch '\\u%04x' "${code}"
            fi
            out+=${ch}
        done
        s=${out}
    fi

    OS_LOG__ESCAPED=${s}
    return 0
}

# ==================================================================
# 写入
# ==================================================================

# 时间戳带**真实的时区偏移**，不写死 `Z`。
#
# `%()T` 取的是**本地时间**，而 `Z` 的意思是 UTC。在 CST 机器上把本地时间
# 标成 `Z`，等于声称它比真实 UTC 早 8 小时。人读日志看不出来，但任何按
# ISO 8601 解析的消费者（面板、跨时区排查）都会整体偏掉一个时区。
# `%z` 给出 `+0800`，本地时间与它的时区一起说清楚。
log::_now() {
    printf -v OS_LOG__TS '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    return 0
}
OS_LOG__TS=''

# log::write <级别> <消息> [来源]
#
# 三个落点一次写完。**脱敏在这里发生**，之后的所有写入都已经是安全文本。
log::write() {
    local level=${1:-info} msg=${2-} source=${3:-script}
    # 取走并**立刻清空**：下面有两条提前 return（级别过滤、日志未启用），
    # 不在这里清的话这个码会漏给下一条毫不相干的记录
    local code=${OS_LOG__EXIT_CODE}
    OS_LOG__EXIT_CODE=''

    log::level_value "${level}"
    local -i want=${OS_LOG__LVV}
    log::level_value "${OS_LOG_LEVEL}"
    if ((want > OS_LOG__LVV)); then
        return 0
    fi
    if [[ ${OS_LOG_ENABLED} -ne 1 ]]; then
        return 0
    fi

    log::redact "${msg}"
    local safe=${OS_LOG__REDACTED}
    log::_now

    # 退出码只写进**人读的那行**。JSONL 用 exit_code 字段表达同一件事，msg
    # 保持干净 —— 消费者拿字段自己渲染（面板就是这么做的），两边都写会渲染成
    # 「被信号 HUP 打断 (退出码 131) (退出码 131)」
    local human=${safe}
    [[ -n ${code} ]] && human="${safe} (退出码 ${code})"

    local line
    printf -v line '%s %-5s [%s] %s' "${OS_LOG__TS}" "${level^^}" "${OS_LOG_COMMAND}" "${human}"
    printf '%s\n' "${line}" 2>/dev/null >>"${OS_LOG_MAIN}" || true
    if [[ -n ${OS_LOG_CMD_FILE} ]]; then
        printf '%s\n' "${line}" 2>/dev/null >>"${OS_LOG_CMD_FILE}" || true
    fi

    log::json_escape "${safe}"
    local jmsg=${OS_LOG__ESCAPED}
    log::json_escape "${OS_LOG_COMMAND}"
    local jcmd=${OS_LOG__ESCAPED}
    log::json_escape "${source}"
    local jsrc=${OS_LOG__ESCAPED}
    local rc=''
    [[ -n ${code} ]] && printf -v rc ',"exit_code":%d' "${code}"
    printf '{"ts":"%s","level":"%s","source":"%s","command":"%s","msg":"%s"%s}\n' \
        "${OS_LOG__TS}" "${level,,}" "${jsrc}" "${jcmd}" "${jmsg}" "${rc}" \
        2>/dev/null >>"${OS_LOG_JSONL}" || true

    return 0
}

# log::exit_code <级别> <消息> <退出码>   带 exit_code 字段的记录
#
# 一次事件**一条记录**。从前这里先调 log::write（那已经落了一条 JSONL），
# 再自己往 JSONL 补写第二条，两条只差一个「(退出码 N)」后缀 —— 按 msg 去重的
# 消费者合并不了，面板的「最近异常」因此被同一次中断刷成两行。
log::exit_code() {
    local level=${1:-error} msg=${2-} code=${3:-1}
    OS_LOG__EXIT_CODE=${code}
    log::write "${level}" "${msg}" framework
    return 0
}

# log::audit <描述> <退出码> <命令...>
#
# 由 os::run / os::run_out 自动调用。**定位是事故追溯，不是防篡改审计** ——
# 文件就在本机、由本进程以 root 追加，能被同一个 root 改掉。
# 威胁模型里要按这个定位写，不要写成「审计日志」让人误以为它能防内鬼。
log::audit() {
    # 下面 `$*` 按 IFS 首字符连接，而调用方（脚本）的 IFS 不含空格（D91）
    local IFS=' '
    local desc=${1-} code=${2:-0}
    shift 2 2>/dev/null || true
    if [[ ${OS_LOG_ENABLED} -ne 1 ]]; then
        return 0
    fi
    log::redact "$*"
    local safe_cmd=${OS_LOG__REDACTED}
    log::redact "${desc}"
    local safe_desc=${OS_LOG__REDACTED}
    log::_now
    printf '%s [%s] rc=%d %s :: %s\n' \
        "${OS_LOG__TS}" "${OS_LOG_COMMAND}" "${code}" "${safe_desc}" "${safe_cmd}" \
        2>/dev/null >>"${OS_AUDIT_LOG}" || true
    return 0
}
