# lib/exec.sh —— L2 基础设施层：三个执行函数
#
# 只依赖 L0 与 L1。**不依赖同层的 errors.sh / lock.sh。**
#
#   os::run     有副作用，不需要输出   dry-run 跳过
#   os::run_out 有副作用，需要输出     dry-run 跳过
#   os::query   只读                    dry-run **照常执行**
#
# --- run_out 与 query 都不打印结果，结果在 OS_RUN_OUTPUT 里 ---
#
# 打印就意味着调用方写 `out=$(os::run_out ...)`，而 `$( )` 是子 shell ——
# 里面设的 OS_RUN_STATUS / OS_RUN_SKIPPED 一个也出不来。
# 后果不是不方便，是**判错**：dry-run 下命令没跑、输出为空、退出码 0，
# 与「真跑了且没输出」完全一样，靠输出文本判定结果的脚本会打出「✓ 已完成」。
# 那正是 D15 说的「会撒谎的 dry-run 比没有更危险」。
#
# 这个坑在本项目里已经出现三次（probe::* 见 D68、试点脚本 ufw_manager 见 D74）。
# 处理办法一致：**让函数根本不打印**，把正确做法变成唯一做法。
#
# 两个正交维度（有无副作用 × 要不要 stdout）必然产生三个格子。只有两个函数时，
# 「有副作用且要拿输出」无处安放，作者就会去用 os::query 干有副作用的事，
# 于是 dry-run 静默失真（D9）。
#
# 只读命令在 dry-run 下照常执行：全跳过的话预演探测不到任何真实
# 状态，输出的是「假装要做什么」而不是「基于真实系统会做什么」。

# OS_DRYRUN 的声明在 L0（defaults.sh）：exec.sh 与 errors.sh 都要读它，
# 归属放在任一个 L2 模块里，另一个就成了同层依赖。
OS_DRYRUN_TAINTED=0
OS_RUN_STATUS=0
OS_RUN_OUTPUT=''

# 本次调用是否因 dry-run 被跳过。
#
# 没有这个标志，dry-run 下 os::run_out 返回「空输出 + 退出码 0」，
# 与「命令真的跑了且没输出」完全一样 —— 靠输出文本判定结果的脚本
# （ufw、apt 这类退出码不可靠的命令）就会打出「✓ 已完成」。
# 那正是 D15 说的「会撒谎的 dry-run 比没有更危险」。
OS_RUN_SKIPPED=0

# ==================================================================
# 参数解析
# ==================================================================

OS_EXEC__SECRETS=()
OS_EXEC__ENV_NAMES=()
OS_EXEC__ENV_VALUES=()
OS_EXEC__STDIN_SECRET=''
OS_EXEC__HAS_STDIN_SECRET=0
OS_EXEC__STDIN=''
OS_EXEC__HAS_STDIN=0
OS_EXEC__ALLOW_FAIL=0
OS_EXEC__DESC=''
OS_EXEC__CMD=()

# os::exec__parse <参数...>   解析到 -- 为止，命令部分放进 OS_EXEC__CMD
os::exec__parse() {
    OS_EXEC__SECRETS=()
    OS_EXEC__ENV_NAMES=()
    OS_EXEC__ENV_VALUES=()
    OS_EXEC__STDIN_SECRET=''
    OS_EXEC__HAS_STDIN_SECRET=0
    OS_EXEC__STDIN=''
    OS_EXEC__HAS_STDIN=0
    OS_EXEC__ALLOW_FAIL=0
    OS_EXEC__DESC=''
    OS_EXEC__CMD=()

    while [[ $# -gt 0 ]]; do
        case ${1} in
            --secret-val)
                # 值长度 < OS_SECRET_MIN_LEN 拒绝执行。短值全局替换会把整行命令
                # 打成马赛克，看上去脱敏了，实际是把证据也毁了。
                # 下限读 L0 常量，与 log::secret_add / os::ask_secret 同源。
                if [[ ${#2} -lt ${OS_SECRET_MIN_LEN} ]]; then
                    ui::line error "--secret-val 的值长度小于 ${OS_SECRET_MIN_LEN}，拒绝执行"
                    log::exit_code error "--secret-val 值过短" 2
                    return 2
                fi
                OS_EXEC__SECRETS+=("${2}")
                log::secret_add "${2}" || true
                shift 2
                ;;
            --env)
                OS_EXEC__ENV_NAMES+=("${2%%=*}")
                OS_EXEC__ENV_VALUES+=("${2#*=}")
                # 环境变量的值同样登记脱敏：它十有八九就是密码
                log::secret_add "${2#*=}" || true
                shift 2
                ;;
            --stdin-secret)
                OS_EXEC__STDIN_SECRET=${2}
                OS_EXEC__HAS_STDIN_SECRET=1
                log::secret_add "${2}" || true
                shift 2
                ;;
            --stdin)
                # 与 --stdin-secret 同一条通道，唯一区别是不登记进脱敏表：
                # SQL 语句里的库名/表名/子句是明文数据，不是凭据，整段打成
                # *** 会毁掉排查证据（凭据部分应由调用方经 os::sql_str /
                # --secret-val 单独标记）。
                OS_EXEC__STDIN=${2}
                OS_EXEC__HAS_STDIN=1
                shift 2
                ;;
            --allow-fail)
                OS_EXEC__ALLOW_FAIL=1
                shift
                ;;
            --)
                shift
                OS_EXEC__CMD=("$@")
                return 0
                ;;
            --*)
                # **认不出的长选项一律硬失败。** 原来它落进下面那个 `*)` 分支，
                # 于是 `os::run_out --timeout 15 '发送告警' -- curl …` 的现场是：
                # `--timeout` 被当成 desc（真正的描述被丢掉，审计里那条记录写着
                # 「--timeout」）、`15` 被吃掉、而超时**根本没生效**。三件事没有
                # 一件报错。这正是 os::query 当年吞掉 `--env` 的同一个坑，那次的
                # 表现是「装好了却连不上」。选项拼错是写代码的人的失误，
                # 该在第一次运行就停下来。
                ui::line --err error "${FUNCNAME[1]:-os::run} 不认识的选项：${1}"
                log::exit_code error "执行封装收到不认识的选项 ${1}" 2
                return 2
                ;;
            *)
                if [[ -z ${OS_EXEC__DESC} ]]; then
                    OS_EXEC__DESC=${1}
                fi
                shift
                ;;
        esac
    done
    return 0
}

# 把命令数组渲染成可读文本，命中 --secret-val 的**值**整个换成 ***。
# 按值匹配不按位置（D33）：位置索引在任何人往命令中间插一个参数时立即错位，
# 而错位不报错，唯一表现是密码开始明文进日志。
os::exec__render() {
    local out='' part s
    for part in ${OS_EXEC__CMD[@]+"${OS_EXEC__CMD[@]}"}; do
        for s in ${OS_EXEC__SECRETS[@]+"${OS_EXEC__SECRETS[@]}"}; do
            part=${part//"${s}"/'***'}
        done
        if [[ -n ${out} ]]; then
            out+=' '
        fi
        out+=${part}
    done
    OS_EXEC__RENDERED=${out}
    return 0
}
OS_EXEC__RENDERED=''

# ==================================================================
# 实际执行
# ==================================================================

# 在子 shell 里 export 环境变量后 exec，而**不是** `env K=V cmd`。
#
# 规范要求 --env 的值不出现在 ps 里，而 `env PASS=xxx cmd` 会把
# PASS=xxx 放进 env 自己的 argv —— 那恰恰是这条规则要防的事。
# 子 shell 里 export 之后，ps 看到的只有 cmd 本身；值落在 /proc/<pid>/environ，
# 那是 0400 且属主可读，比 argv 安全一个量级。
os::exec__invoke() {
    local -i i
    (
        for ((i = 0; i < ${#OS_EXEC__ENV_NAMES[@]}; i++)); do
            export "${OS_EXEC__ENV_NAMES[i]}=${OS_EXEC__ENV_VALUES[i]}"
        done
        if [[ ${OS_EXEC__HAS_STDIN_SECRET} -eq 1 ]]; then
            # printf 是内建命令，值不会出现在任何进程的 argv 里
            printf '%s\n' "${OS_EXEC__STDIN_SECRET}" | "${OS_EXEC__CMD[@]}"
        elif [[ ${OS_EXEC__HAS_STDIN} -eq 1 ]]; then
            printf '%s\n' "${OS_EXEC__STDIN}" | "${OS_EXEC__CMD[@]}"
        else
            "${OS_EXEC__CMD[@]}"
        fi
    )
}

# ==================================================================
# 模块输出变量的唯一写入点
# ==================================================================
#
# OS_RUN_STATUS / OS_RUN_OUTPUT / OS_DRYRUN_TAINTED 是这个模块暴露给外面的
# 三个值，本文件内只写不读。收敛到两个 setter 有两个好处：写入点唯一，
# 以及 shellcheck 的「未使用」告警只需在这里说明一次，而不是散在六处。

# 失败必须在**这一层**说出来，因为只有它同时知道 desc 与退出码。
#
# 两头都指望不上：命令自己的 stdout/stderr 全被重定向进了日志，屏幕上一个字
# 都没有；而 ERR trap 抓到的是把失败往上带的那句 `return "${rc}"` —— 框架
# 自己的源码。于是用户拿到的只有一个光秃秃的退出码，正是规范 §9 点名的
# 「用户会看到脚本无声退出」。
exec::_announce_failure() {
    ui::line --err error "「${OS_EXEC__DESC}」失败（退出码 ${1}）"
    return 0
}

# shellcheck disable=SC2034  # 理由：本模块的输出变量，供脚本层与 dry-run 收尾读取
exec::_publish() {
    OS_RUN_STATUS=${1}
    OS_RUN_OUTPUT=${2-}
    OS_RUN_SKIPPED=${3:-0}
    return 0
}

# shellcheck disable=SC2034  # 理由：同上，dry-run 分叉标记由收尾逻辑读取
exec::_taint() {
    OS_DRYRUN_TAINTED=1
    return 0
}

# ==================================================================
# 命令输出的脱敏
# ==================================================================
#
# **命令自己的输出也必须脱敏。** 只对框架拼的那行命令做替换是不够的：
# `curl -v` 会回显带 token 的请求头，`mysql` 出错时会把连接串打出来，
# 这些原始输出如果直连日志文件，前面所有的脱敏都白做。
# 规范说的「脱敏在写入前发生」，管的就是这一段。
exec::_redact_stream() {
    local line
    while IFS= read -r line || [[ -n ${line} ]]; do
        log::redact "${line}"
        printf '%s\n' "${OS_LOG__REDACTED}"
    done
    return 0
}

# 临时文件放 /run（tmpfs）：run_out 的 stderr 要先落地再脱敏，
# 而那段原始文本可能含明文凭据 —— tmpfs 上永远不写磁盘。
# 这里不用 os::tmpdir：那个函数在同层的 errors.sh 里，L2 内部禁止互相依赖。
exec::_scratch_file() {
    mkdir -p "${OS_RUN_DIR}" 2>/dev/null || true
    local prev_umask f
    prev_umask=$(umask)
    umask 077
    f=$(mktemp "${OS_RUN_DIR}/exec.XXXXXXXX" 2>/dev/null) || f=''
    umask "${prev_umask}"
    printf '%s' "${f}"
    return 0
}

# ==================================================================
# os::run —— 有副作用，不需要 stdout
# ==================================================================

# os::run [--allow-fail] [--env K=V] [--secret-val <值>] [--stdin-secret <值>] [--stdin <文本>] <desc> -- <命令...>   有副作用且不需要 stdout；dry-run 下不执行
os::run() {
    os::exec__parse "$@" || return $?
    if [[ ${#OS_EXEC__CMD[@]} -eq 0 ]]; then
        ui::line error "os::run 缺少 -- 之后的命令"
        return 2
    fi
    os::exec__render

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        exec::_taint
        # 屏幕不在规范「禁止写入」那张表里，但一样进滚动缓冲、进录屏、进
        # 贴到群里的截图（同 errors.sh 里 os::replace_line 的先例）。
        # OS_EXEC__RENDERED 只按 --secret-val 位置替换，登记进
        # OS_LOG__SECRETS 的值（--stdin-secret、os::secure_set 等）不在其中，
        # 必须再过一遍全局脱敏表才能上屏。
        log::redact "${OS_EXEC__RENDERED}"
        ui::line muted "[dry-run] ${OS_EXEC__DESC}：${OS_LOG__REDACTED}"
        log::write info "[dry-run] 跳过：${OS_EXEC__RENDERED}" framework
        exec::_publish 0 '' 1
        return 0
    fi

    # TTY 上先转圈、跑完再落那一行；非 TTY 保持「先打行」不变 ——
    # 管道与 cron 里没有重绘，而且日志里「命令开始前就有一行」比「结束后才有」有用：
    # 卡住时能看出卡在哪一条
    local -i spinning=0
    if ui::activity_start "${OS_EXEC__DESC}"; then
        spinning=1
    else
        ui::line info "${OS_EXEC__DESC}"
    fi
    log::write debug "执行：${OS_EXEC__RENDERED}" framework

    local -i rc=0
    # stdout 与 stderr 全部进日志。日志不可用时丢弃而不是上屏 ——
    # 上屏会把命令的原始输出混进整洁的界面里。
    #
    # 走管道而不是先收进变量：apt 那种命令要跑几分钟，缓冲到结束才落盘的话，
    # 卡住时日志是空的，正好在最需要它的时候没有。
    # 退出码取 PIPESTATUS[0]（管道左端），不能看管道整体的状态：
    # 没开 pipefail 时管道状态是**右端**的，脱敏过滤器永远返回 0，
    # 命令失败就此消失。而 `|| true` 会把 PIPESTATUS 重置成 (0)，
    # 所以必须在同一个复合命令里、紧挨着管道把它存下来。
    if [[ ${OS_LOG_ENABLED} -eq 1 ]]; then
        local -a pstat=()
        {
            # `2>/dev/null` 写在 `>>` **前面**（K16 同类）：日志文件打不开时
            # 那行报错是 bash 自己打的，写在后面的话它已经漏到终端上了 ——
            # `uninstall --all` 把日志目录删掉之后紧接着还要再跑几条命令，
            # 那正是这条路径唯一会被走到的时刻
            os::exec__invoke 2>&1 | exec::_redact_stream 2>/dev/null >>"${OS_LOG_CMD_FILE:-${OS_LOG_MAIN}}"
            pstat=("${PIPESTATUS[@]}")
        } || true
        rc=${pstat[0]:-1}
    else
        os::exec__invoke >/dev/null 2>&1 || rc=$?
    fi

    if ((spinning == 1)); then
        ui::activity_stop
        ui::line info "${OS_EXEC__DESC}"
    fi

    exec::_publish "${rc}"
    log::audit "${OS_EXEC__DESC}" "${rc}" "${OS_EXEC__RENDERED}"

    if [[ ${rc} -ne 0 ]]; then
        if [[ ${OS_EXEC__ALLOW_FAIL} -eq 1 ]]; then
            log::write debug "命令返回 ${rc}（已声明 --allow-fail）：${OS_EXEC__RENDERED}" framework
        else
            log::write error "命令失败（退出码 ${rc}）：${OS_EXEC__RENDERED}" framework
            exec::_announce_failure "${rc}"
        fi
    fi
    return "${rc}"
}

# ==================================================================
# os::run_out —— 有副作用，需要 stdout
# ==================================================================

# os::run_out [选项同 os::run] <desc> -- <命令...>   有副作用且需要 stdout，结果写入 OS_RUN_OUTPUT
os::run_out() {
    os::exec__parse "$@" || return $?
    if [[ ${#OS_EXEC__CMD[@]} -eq 0 ]]; then
        ui::line error "os::run_out 缺少 -- 之后的命令"
        return 2
    fi
    os::exec__render

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        exec::_taint
        # **必须走 stderr**：这个函数的 stdout 是返回值通道，
        # 往里写一行提示，调用方 $(os::run_out ...) 拿到的就是这行提示。
        # 脱敏原因同 os::run：OS_EXEC__RENDERED 只按位置替换 --secret-val。
        log::redact "${OS_EXEC__RENDERED}"
        ui::line --err muted "[dry-run] ${OS_EXEC__DESC}：${OS_LOG__REDACTED}"
        log::write info "[dry-run] 跳过：${OS_EXEC__RENDERED}" framework
        exec::_publish 0 '' 1
        return 0
    fi

    log::write debug "执行（取输出）：${OS_EXEC__RENDERED}" framework

    # 这里不打描述行（stdout 是返回值通道），但照样要转圈：update 下载源码包
    # 走的正是这条路，几十 MB 期间屏幕上一个字都没有。转圈在 stderr 上，
    # 跑完擦干净，调用方拿到的 stdout 一个字节都没变
    local -i spinning=0
    if ui::activity_start "${OS_EXEC__DESC}"; then
        spinning=1
    fi

    local -i rc=0
    local out=''
    # stdout 回给调用方，stderr 进日志。
    # stderr 先落一个 tmpfs 上的 0600 临时文件再脱敏进日志 —— 不能像 os::run
    # 那样走管道，因为管道会占掉 stdout 的位置；也不能用进程替换，那东西
    # 什么时候写完不确定，日志会随机缺尾。stderr 量小，不需要流式。
    if [[ ${OS_LOG_ENABLED} -eq 1 ]]; then
        local errfile
        errfile=$(exec::_scratch_file)
        if [[ -n ${errfile} ]]; then
            out=$(os::exec__invoke 2>"${errfile}") || rc=$?
            exec::_redact_stream <"${errfile}" >>"${OS_LOG_CMD_FILE:-${OS_LOG_MAIN}}"
            rm -f -- "${errfile}" 2>/dev/null || true
        else
            out=$(os::exec__invoke 2>/dev/null) || rc=$?
        fi
    else
        out=$(os::exec__invoke 2>/dev/null) || rc=$?
    fi

    if ((spinning == 1)); then
        ui::activity_stop
    fi

    exec::_publish "${rc}" "${out}"
    log::audit "${OS_EXEC__DESC}" "${rc}" "${OS_EXEC__RENDERED}"

    if [[ ${rc} -ne 0 && ${OS_EXEC__ALLOW_FAIL} -ne 1 ]]; then
        log::write error "命令失败（退出码 ${rc}）：${OS_EXEC__RENDERED}" framework
        exec::_announce_failure "${rc}"
    fi
    return "${rc}"
}

# ==================================================================
# os::query —— 只读
# ==================================================================

# os::query [--timeout <秒>] [--env K=V...] [--stdin <文本>] [--want-stderr] -- <命令...>
#
# **`--want-stderr` 把 stderr 一起收进 OS_RUN_OUTPUT。** 默认丢弃是对的：
# 探测取的是值，`command -v` 之流的噪音混进来只会污染判断。但有一类命令
# 把**结论**写在 stderr 上 —— `caddy validate` 整份诊断都在那儿，stdout 一个
# 字节都没有。默认路径下调用方拿到空字符串，于是屏幕上只剩「校验未通过」，
# 真正的原因（令牌为空、模块没编进去）连日志里都不存在。
#
# **不产生审计记录**（只读无需追溯），**dry-run 下照常执行**。
# 必须有超时：菜单每次进来都要探测，podman 一挂工具就开不了机（K14 / D18）。
#
# 只用于脚本内部一次性取值。两个以上的地方需要同一个事实时，
# 它必须是 probe::*—— 否则 18 个脚本会长出 18 套互相矛盾的探测。
#
# **为什么要有 `--env`**：验证 Redis 通不通是
# 一次纯只读的 PING，可它要密码，而密码的唯一合规通道之一是环境变量。
# 此前 os::query 把 `--env` 连同它的值一起当成不认识的参数默默 shift 掉 ——
# **不报错，命令照跑，只是没带上那个变量**，于是 PING 因未授权而失败，
# 而现场看到的是「装好了却连不上」。不加这个选项的话，脚本只剩两条路：
# 用 os::run_out（给一个无副作用的命令产生审计记录，且 dry-run 下被跳过），
# 或者把密码摆进 argv —— 后者正是规范明令禁止的。
os::query() {
    local -i timeout=${OS_DEFAULT_PROBE_TIMEOUT}
    local -a env_names=() env_values=()
    local stdin='' has_stdin=0
    local -i want_stderr=0
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --timeout)
                timeout=${2}
                shift 2
                ;;
            --want-stderr)
                want_stderr=1
                shift
                ;;
            --env)
                env_names+=("${2%%=*}")
                env_values+=("${2#*=}")
                # 与 os::exec__parse 的 --env 分支对齐：值十有八九是密码，
                # 不登记的话这条通道在脱敏表里就是个洞（caddy-manager 的
                # CLOUDFLARE_API_TOKEN 正是走这条路读出来又打回日志的）。
                log::secret_add "${2#*=}" || true
                shift 2
                ;;
            --stdin)
                # 同 os::run 的 --stdin：只读命令（如 SELECT）也可能带明文
                # SQL，不该只因为要拿返回值就被逼回 --execute= 进 argv。
                stdin=${2}
                has_stdin=1
                shift 2
                ;;
            --)
                shift
                break
                ;;
            --*)
                # 同 os::exec__parse：认不出的长选项硬失败。这个分支原来是
                # `*) shift`，`--env` 就是这么被连值一起默默吃掉的
                ui::line --err error "os::query 不认识的选项：${1}"
                log::exit_code error "os::query 收到不认识的选项 ${1}" 2
                return 2
                ;;
            *) shift ;;
        esac
    done
    if [[ $# -eq 0 ]]; then
        ui::line error "os::query 缺少 -- 之后的命令"
        return 2
    fi

    local -i rc=0
    local out=''
    # 子 shell 里 export 后执行，不用 `env K=V cmd`：后者把值放进 env 自己的
    # argv，而 ps 对同机任何用户可见 —— 那正是规范要防的（同 D63）
    #
    # stderr 的去向在子 shell 第一行用 `exec` 定死，而不是挂在每条命令尾巴上：
    # 「取不取 stderr」乘上「喂不喂 stdin」本来是四份几乎一样的调用，
    # 抄错一处就是一条通道悄悄丢输出 —— 今晚丢的正是 caddy validate 的错因。
    out=$(
        if ((want_stderr == 1)); then
            exec 2>&1
        else
            exec 2>/dev/null
        fi
        local -i i
        for ((i = 0; i < ${#env_names[@]}; i++)); do
            export "${env_names[i]}=${env_values[i]}"
        done
        if ((has_stdin == 1)); then
            printf '%s\n' "${stdin}" | timeout "${timeout}" "$@"
        else
            timeout "${timeout}" "$@"
        fi
    ) || rc=$?

    # 要来的 stderr 是拿去上屏的，脱敏不能省：--env 的值已登记进脱敏表，
    # 而命令自己也可能把凭据回显在错误信息里（同 exec::_redact_stream 的理由）。
    if ((want_stderr == 1)) && [[ -n ${out} ]]; then
        out=$(printf '%s\n' "${out}" | exec::_redact_stream)
    fi

    exec::_publish "${rc}" "${out}"
    return "${rc}"
}

# os::retry [--stop-on <码,码>] <次数> [选项同 os::run] <desc> -- <命令...>   指数退避重试；dry-run 下只「跑」一次
#
# ==================================================================
# os::retry ——规范
# ==================================================================
#
#   os::retry <次数> [os::run 的选项...] <desc> -- <命令...>
#
# 规范禁止手写 `for attempt in $(seq 1 5)` 重试循环并标了 [CI]，
# 这是它的替代品。参数除了打头的次数之外原样交给 os::run，
# 因此 --env / --secret-val / --allow-fail 全都能用。
#
# 三条不显然的语义：
#
#   * **dry-run 下只「跑」一次。** 命令根本没执行，重试是在重试一件没发生的事。
#     os::run 在 dry-run 下返回 0，循环自然在第一轮就结束，不必特判。
#   * **指数退避**，封顶 OS_DEFAULT_RETRY_MAX_WAIT。固定间隔对「对端正在重启」
#     这类情况无效 —— 五次 1 秒等于白重试五次。
#   * **最后一次失败照常返回非零**：调用方没写 --allow-fail 的话，
#     set -e 与 ERR trap 该怎么响就怎么响。重试不是「吞掉失败」。
#   * **`--stop-on <码,码>` 列出「重试也不会变」的退出码**，命中即立刻返回。
#     有些失败是确定性的：HTTP 400 说明请求本身就不被接受，DNS 解析不了说明
#     网络根本不通，超时说明对端够不着 —— 对它们重试只是把同一个错误重复几遍，
#     而每一遍都可能要等到超时。没有这个选项，调用方就只能自己写重试循环，
#     而那是规范明令禁止的。
os::retry() {
    local __os_stop=''
    while [[ ${1-} == --stop-on ]]; do
        __os_stop=",${2-},"
        shift 2
    done

    local -i tries=${1:-1}
    shift || true
    if ((tries < 1)); then
        tries=1
    fi

    local -i i rc=0 wait=${OS_DEFAULT_RETRY_BASE_WAIT}
    for ((i = 1; i <= tries; i++)); do
        rc=0
        # 内部一律 --allow-fail：失败要由这里决定是重试还是放行，
        # 不能在第一次失败时就被 ERR trap 带走
        os::run --allow-fail "$@" || rc=$?
        if [[ -n ${__os_stop} && ${__os_stop} == *",${rc},"* && ${rc} -ne 0 ]]; then
            log::write info "退出码 ${rc} 重试也不会变，不再尝试" framework
            return "${rc}"
        fi
        if [[ ${rc} -eq 0 ]]; then
            if ((i > 1)); then
                log::write info "第 ${i} 次尝试成功" framework
            fi
            return 0
        fi
        if ((i >= tries)); then
            break
        fi
        ui::line warn "第 ${i}/${tries} 次失败（退出码 ${rc}），${wait} 秒后重试"
        log::write warn "第 ${i}/${tries} 次失败（退出码 ${rc}），${wait} 秒后重试" framework
        sleep "${wait}" || true
        wait=$((wait * 2))
        if ((wait > OS_DEFAULT_RETRY_MAX_WAIT)); then
            wait=${OS_DEFAULT_RETRY_MAX_WAIT}
        fi
    done

    log::write error "重试 ${tries} 次仍失败（退出码 ${rc}）" framework
    return "${rc}"
}
