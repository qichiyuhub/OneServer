# lib/probe.sh —— L3 能力层：系统探测的唯一实现
#
# 只依赖 L0–L2（用 exec.sh 的 os::query 执行只读命令）。
# **不依赖同层的 state.sh / secure.sh / sql.sh / systemd.sh。**
#
# 它是 L3 中唯一允许被脚本层直接调用的模块。
#
# --- 两条硬性要求 ---
#
# 1. **每项都有超时**（D18 / K14）。菜单状态面板每次进菜单都跑一遍 probe，
#    podman 无响应或 mount 挂起时，没有超时会让工具**开不了机**。
#    超时返回 status=timeout 而不是阻塞、也不是报错退出。
#
# 2. **双数据路径必须逐项标注来源与时间**（D44）。
#    root 走实时探测并顺手落一份快照；非 root 读快照。不标注的话，
#    「一套代码两条数据路径」就是 D10 要消灭的「多套真相」换了个形式 ——
#    用户会拿着 20 分钟前的数据排查现在的故障。
#
# --- 所有 probe::* 都不打印结果，只写变量 ---
#
#   OS_PROBE_VALUE    探到的值
#   OS_PROBE_STATUS   ok | stale | timeout | unavailable | missing
#   OS_PROBE_SOURCE   live | cache | none
#   OS_PROBE_AGE      缓存数据的秒龄；实时探测为 0
#
# **为什么不打印**：打印就意味着调用方要写 `v=$(probe::os_id)`，而 `$( )` 是
# 子 shell —— 里面设的 OS_PROBE_SOURCE / OS_PROBE_AGE 出不来。于是规范
# 「消费者必须逐项标注来源与时间」这条就被静默架空了，界面上看不出这是
# 20 分钟前的旧数据。让函数根本不打印，这个坑就不存在（同 D57 的思路：
# 把正确做法变成唯一做法，而不是写进文档指望人记得）。

OS_PROBE_VALUE=''
OS_PROBE_STATUS='none'
OS_PROBE_SOURCE='none'
OS_PROBE_AGE=0

# 本次进程探到的实时结果，退出前由 probe::snapshot_flush 落盘
OS_PROBE__KEYS=()
OS_PROBE__VALS=()

# 缓存超过这个秒数就明确告知「数据是旧的」，而不是默默用
OS_PROBE_CACHE_MAX_AGE="${OS_DEFAULT_PROBE_SNAPSHOT_MAX_AGE}"

# 置 1 则退出时不落快照。**只有卸载器该动它**：快照钩子跑在退出路径上，
# 而卸载的最后一步正是删掉快照所在的目录（见 probe::snapshot_flush）
OS_PROBE_NO_SNAPSHOT=0

probe::_is_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]]
}

# ==================================================================
# 快照 —— 非 root 的唯一数据来源
# ==================================================================

probe::_remember() {
    local key=${1} val=${2}
    local -i i
    for ((i = 0; i < ${#OS_PROBE__KEYS[@]}; i++)); do
        if [[ ${OS_PROBE__KEYS[i]} == "${key}" ]]; then
            OS_PROBE__VALS[i]=${val}
            return 0
        fi
    done
    OS_PROBE__KEYS+=("${key}")
    OS_PROBE__VALS+=("${val}")
    return 0
}

# probe::snapshot_flush   把本次探测结果落盘为 /run/oneserver-public/probe.tsv，供非 root 读取
#
# 规范：root 执行任何命令时框架自动落一份快照 —— 这样即使
# 用户从不启用面板的采集 timer（oneserver-web-*.timer），普通用户也能拿到
# 最近一次 root 操作时的数据。
# 由 bootstrap.sh 在收尾时调用。
#
# **落的是缓存里的原始输出**，不是各 probe 函数的解析结果（解析在函数里，
# 且未必幂等）。因此只读这个文件的消费者拿到的是原始值 —— 需要解析后的值
# 就得自己调函数记录，`script/ops/web_collect.sh` 就是这么做的。
probe::snapshot_flush() {
    local target=${OS_PROBE_SNAPSHOT}
    # 卸载器删完落点之后置 1。**这个钩子挂在退出路径上，包括卸载那一次** ——
    # 没有这个开关的话，它会在 $OS_PUBLIC_DIR 刚被删掉之后立刻 mkdir 回来：
    # 卸载命令自己没有任何报错，机器上却留着一个目录（实测撞见，见
    # tests/lib/uninstall.bats 那条全盘扫描）
    [[ ${OS_PROBE_NO_SNAPSHOT:-0} -eq 1 ]] && return 0
    probe::_is_root || return 0
    [[ ${#OS_PROBE__KEYS[@]} -gt 0 ]] || return 0
    # **`mkdir` 不带 `-p`，这是有意的**：这个钩子挂在退出路径上，包括卸载那次。
    # 带 `-p` 就会为了放一份可有可无的快照，把一整棵刚被删掉的目录树造回来 ——
    # 现场表现是「卸载说成功了，可目录还在」（容器实测撞见）。
    # 数据目录搬到 tmpfs 之后父目录 `/run` 必然存在，`-p` 更没有必要。
    # 快照是个可有可无的东西，**没地方放就不放**。
    mkdir "${OS_PUBLIC_DIR}" 2>/dev/null || true
    [[ -d ${OS_PUBLIC_DIR} ]] || return 0
    chmod "${OS_PUBLIC_DIR_MODE}" "${OS_PUBLIC_DIR}" 2>/dev/null || true

    # 名字走 mktemp 不拼 `$$`：public/ 是 0755，`$$` 可预测，攻击面同
    # template::_place。这里目录属 root 不可写，但落地写法在全项目里必须一致，
    # 否则下一个复制这段代码的人会把它带去一个可写目录
    local tmp
    tmp=$(mktemp "${target}.tmp.XXXXXXXX" 2>/dev/null) || return 0
    local now
    printf -v now '%(%s)T' -1
    {
        printf '#ts\t%s\n' "${now}"
        local -i i
        for ((i = 0; i < ${#OS_PROBE__KEYS[@]}; i++)); do
            # 落的是**命令原始输出**，而这个文件是 0644 —— 只要有哪个探测项
            # 碰到含凭据的配置，明文就直接躺在一个人人可读的文件里。所以和
            # os::write_public 一样，脱敏做在通道上，不靠各 probe 函数自觉
            local v
            log::redact "${OS_PROBE__VALS[i]}"
            v=${OS_LOG__REDACTED}
            # 值里的制表符与换行会撕开行式格式，换成空格即可 ——
            # 快照是给人看的概览，不需要精确还原
            v=${v//$'\t'/ }
            v=${v//$'\n'/ }
            printf '%s\t%s\n' "${OS_PROBE__KEYS[i]}" "${v}"
        done
    } 2>/dev/null >"${tmp}" || {
        rm -f -- "${tmp}" 2>/dev/null || true
        return 0
    }
    # 0644：快照就是给非 root 读的。**因此它永远不能含凭据**。
    chmod 0644 "${tmp}" 2>/dev/null || true
    mv -f -- "${tmp}" "${target}" 2>/dev/null || rm -f -- "${tmp}" 2>/dev/null || true
    return 0
}

# probe::_from_cache <key>   命中则把值写进 OS_PROBE_VALUE 并置 SOURCE/AGE
probe::_from_cache() {
    local key=${1}
    OS_PROBE_SOURCE='none'
    OS_PROBE_AGE=0
    [[ -r ${OS_PROBE_SNAPSHOT} ]] || return 1

    local now snap_ts=0 rkey rval found='' hit=1
    printf -v now '%(%s)T' -1
    while IFS=$'\t' read -r rkey rval || [[ -n ${rkey} ]]; do
        if [[ ${rkey} == '#ts' ]]; then
            snap_ts=${rval:-0}
            continue
        fi
        if [[ ${rkey} == "${key}" ]]; then
            found=${rval}
            hit=0
        fi
    done <"${OS_PROBE_SNAPSHOT}"
    [[ ${hit} -eq 0 ]] || return 1

    OS_PROBE_SOURCE='cache'
    OS_PROBE_AGE=$((now - snap_ts))
    OS_PROBE_VALUE=${found}
    return 0
}

# ==================================================================
# 探测原语
# ==================================================================

# probe::_probe <key> <超时秒> -- <只读命令...>
#
# root：跑命令，结果记进快照缓冲区
# 非 root：读快照，标注来源与时间
probe::_probe() {
    # --rc-ok：非零退出码**不算探测失败**，只要命令打了东西出来就认它。
    # 给 `systemctl is-active` 这类「用退出码表达结论」的命令用：
    # 它对停着的 unit 返回 3，按失败处理的话，「装了没跑」与「根本没装」
    # 就成了同一种结果 —— 而这两件事在界面上是完全不同的两行。
    local rc_ok=0
    if [[ ${1-} == '--rc-ok' ]]; then
        rc_ok=1
        shift
    fi
    local key=${1} timeout=${2}
    shift 2
    [[ ${1-} == '--' ]] && shift

    OS_PROBE_VALUE=''
    if ! probe::_is_root; then
        if probe::_from_cache "${key}"; then
            if [[ ${OS_PROBE_AGE} -gt ${OS_PROBE_CACHE_MAX_AGE} ]]; then
                OS_PROBE_STATUS='stale'
            else
                OS_PROBE_STATUS='ok'
            fi
            return 0
        fi
        # 规范：禁止留空、禁止显示过期值而不告知
        OS_PROBE_STATUS='unavailable'
        OS_PROBE_SOURCE='none'
        return 0
    fi

    OS_PROBE_SOURCE='live'
    OS_PROBE_AGE=0
    local rc=0
    os::query --timeout "${timeout}" -- "$@" || rc=$?
    # os::query 不打印，结果在 OS_RUN_OUTPUT 里（见 exec.sh 头部说明）
    local out=${OS_RUN_OUTPUT}
    if [[ ${rc} -eq 124 ]]; then
        # timeout(1) 用 124 表示超时。这里**不报错退出**，降级返回。
        OS_PROBE_STATUS='timeout'
        log::write warn "probe ${key} 超时（${timeout}s）" framework
        return 0
    fi
    if [[ ${rc} -ne 0 ]]; then
        if [[ ${rc_ok} -eq 1 && -n ${out} ]]; then
            OS_PROBE_STATUS='ok'
            OS_PROBE_VALUE=${out}
            probe::_remember "${key}" "${out}"
            return 0
        fi
        OS_PROBE_STATUS='missing'
        probe::_remember "${key}" ''
        return 0
    fi
    OS_PROBE_STATUS='ok'
    OS_PROBE_VALUE=${out}
    probe::_remember "${key}" "${out}"
    return 0
}

# probe::_probe_proc <key> <文件> <字段选择器>   零进程读 /proc
#
# 与 probe::_probe 的差别只有一处：**不走 os::query**，因此不起子 shell、
# 不起 timeout、不起 awk/cut。缓存降级、状态字、来源标注全部一模一样。
#
# **为什么这一类可以免掉超时**：规范 §11 要求每项探测有超时，那是给会挂住的
# 东西用的——apt、podman inspect、du、网络。procfs 的读取不走网络、不走磁盘、
# 不会阻塞，超时保护在这里买的是一个不存在的风险。而代价是实打实的：实测同一
# 件事（读一次 /proc/loadavg）三种写法各 300 次，bash 内建 0 ms、子 shell 加
# cat 220 ms、再套一层 timeout 510 ms —— **timeout 这一层比它保护的命令还贵**。
# 快档一轮 625 ms 里，真正的探测只有 92 ms，其余大半是这条三进程通道的钱。
#
# 选择器是一份**封闭的小词汇表**，只覆盖 /proc 下我们真正读的这几个文件。
# 它不打算变成一门查询语言：多一种形态就多一条没人测过的分支，而这里一共
# 只有四个消费者。
#   `line:<前缀>:<第几列>`  取以该前缀开头那一行的第 N 个空白分隔字段
#   `intfield:<第几列>`     取第一行第 N 个字段并截掉小数部分
#   `range:<起>:<止>`       取第一行的第 起..止 个字段，空格连接
#   `cpumodel`              /proc/cpuinfo：按架构兼容字段取 CPU 型号
#   `cpustat`               /proc/stat 首行：`总时间 空闲时间`（空闲含 iowait）
#   `kv:<字段名>`           `KEY=值` 形态的配置文件（/etc/os-release），剥外层引号
#
# `kv:` 同样**不 source 那个文件**（K12：配置文件写什么就执行什么）。按字段名
# 逐行精确匹配、剥掉包裹的引号，全程不经 shell 解释文件内容一个字节。
probe::_probe_proc() {
    local key=${1} file=${2} sel=${3}

    OS_PROBE_VALUE=''
    if ! probe::_is_root; then
        if probe::_from_cache "${key}"; then
            if [[ ${OS_PROBE_AGE} -gt ${OS_PROBE_CACHE_MAX_AGE} ]]; then
                OS_PROBE_STATUS='stale'
            else
                OS_PROBE_STATUS='ok'
            fi
            return 0
        fi
        OS_PROBE_STATUS='unavailable'
        OS_PROBE_SOURCE='none'
        return 0
    fi

    OS_PROBE_SOURCE='live'
    OS_PROBE_AGE=0

    # 读不到就是「没有」，与 _probe 里命令失败的那条分支同义。
    # procfs 不存在只有一种可能：这不是 Linux，或者内核关掉了 procfs
    local content=''
    if [[ ! -r ${file} ]] || ! content=$(<"${file}"); then
        OS_PROBE_STATUS='missing'
        probe::_remember "${key}" ''
        return 0
    fi

    local out='' line want col from to
    local -a f=()
    case ${sel} in
        line:*)
            want=${sel#line:}
            col=${want##*:}
            want=${want%:*}
            local IFS=$'\n'
            for line in ${content}; do
                [[ ${line} == "${want}"* ]] || continue
                IFS=$' \t' read -r -a f <<<"${line}"
                out=${f[col - 1]-}
                break
            done
            ;;
        kv:*)
            want=${sel#kv:}
            local IFS=$'\n'
            for line in ${content}; do
                [[ ${line} == "${want}="* ]] || continue
                out=${line#*=}
                # 剥外层引号，**只剥成对包住整个值的那一对**：值中间的引号
                # 是内容本身（PRETTY_NAME 里就可能有），剥它等于篡改
                if [[ ${#out} -ge 2 ]]; then
                    case ${out} in
                        '"'*'"') out=${out:1:${#out}-2} ;;
                        "'"*"'") out=${out:1:${#out}-2} ;;
                    esac
                fi
                break
            done
            ;;
        cpumodel)
            # x86 用 model name；arm64 机器还会见到 Model / Hardware / Processor；
            # s390 常见 machine。按信息精确度找，不按它们在文件里的偶然顺序取。
            for want in 'model name' Model Hardware Processor machine; do
                local IFS=$'\n'
                for line in ${content}; do
                    case ${line} in
                        "${want}"[[:space:]]:* | "${want}":*) out=${line#*:} ;;
                        "${want}"[[:space:]]=*) out=${line#*=} ;;
                        *) continue ;;
                    esac
                    while [[ ${out} == [[:space:]]* ]]; do out=${out#?}; done
                    while [[ ${out} == *[[:space:]] ]]; do out=${out%?}; done
                    break 2
                done
            done
            ;;
        intfield:* | range:* | cpustat)
            # 只看第一行：这几个文件的目标值都在首行
            line=${content%%$'\n'*}
            IFS=$' \t' read -r -a f <<<"${line}"
            local -i i
            case ${sel} in
                intfield:*)
                    out=${f[${sel#intfield:} - 1]-}
                    # `/proc/uptime` 是 `12345.67 98765.43`，秒数取整数部分
                    out=${out%%.*}
                    ;;
                range:*)
                    want=${sel#range:}
                    from=${want%%:*}
                    to=${want##*:}
                    for ((i = from; i <= to; i++)); do
                        out+="${out:+ }${f[i - 1]-}"
                    done
                    ;;
                cpustat)
                    # 首行是 `cpu user nice system idle iowait …`。总时间是
                    # 全部字段之和，空闲要把 iowait 算进去（等 IO 的那段 CPU
                    # 确实没在干活）。返回累计值而不是使用率：使用率是两个时刻
                    # 之间的量，单次采样算不出来
                    local -i total=0
                    for ((i = 1; i < ${#f[@]}; i++)); do
                        [[ ${f[i]} =~ ^[0-9]+$ ]] || continue
                        total+=${f[i]}
                    done
                    out="${total} $((${f[4]:-0} + ${f[5]:-0}))"
                    ;;
            esac
            ;;
    esac

    OS_PROBE_STATUS='ok'
    OS_PROBE_VALUE=${out}
    probe::_remember "${key}" "${out}"
    return 0
}

# probe::describe   把 OS_PROBE_STATUS/SOURCE/AGE 渲染成一行来源标注
#
# probe::describe   把来源与时间渲染成可直接贴到界面上的短语
#
# 规范要求消费者逐项标注。把措辞收在这里，
# doctor / 菜单 / 面板就不会各写各的。
probe::describe() {
    case ${OS_PROBE_STATUS} in
        ok)
            if [[ ${OS_PROBE_SOURCE} == live ]]; then
                printf '实时\n'
            else
                printf '缓存 · %s前\n' "$(probe::_human_age "${OS_PROBE_AGE}")"
            fi
            ;;
        stale) printf '缓存已过期 · %s前\n' "$(probe::_human_age "${OS_PROBE_AGE}")" ;;
        timeout) printf '探测超时\n' ;;
        missing) printf '未安装\n' ;;
        unavailable) printf '需要 root 权限，或面板采集未启用（oneserver web）\n' ;;
        *) printf '未探测\n' ;;
    esac
    return 0
}

probe::_human_age() {
    local -i s=${1:-0}
    if ((s < 60)); then
        printf '%d 秒' "${s}"
    elif ((s < 3600)); then
        printf '%d 分钟' $((s / 60))
    elif ((s < 86400)); then
        printf '%d 小时' $((s / 3600))
    else
        printf '%d 天' $((s / 86400))
    fi
    return 0
}

# ==================================================================
# 具体探测项 ——规范禁止脚本直调的那一串，逐个在这里提供替代
# ==================================================================

# 发行版：脚本禁止自己读 /etc/os-release
#
# 严格解析，不 source（K12 的同一条规则——配置文件写什么就执行什么，
# /etc/os-release 虽是 root 拥有、风险低，但没有理由破例）。按字段名精确匹配
# 那一行、去掉包裹的双引号，全程不经 shell 解释文件内容一个字节。
# 取值用 sed 的反向引用 `\1`，不用 awk 的 `$1`——后者在单引号脚本里会被
# lint 工具当成没转义的 shell 变量报告警，前者不会，不用另写 disable 说明。
probe::_os_release() {
    local field=${1} key=${2}
    # 走零进程读（同 /proc 那批，见 probe::_probe_proc）：`/etc/os-release` 是
    # 一个本地小文件，不走网络不走磁盘队列不会阻塞，超时保护买的是不存在的
    # 风险。而它的代价不是零 —— **每一条 oneserver 命令启动时都要过一次发行版
    # 校验**，从前那条 `子 shell + timeout + sed` 的三进程通道实测 3.1 ms，
    # 全都摊在每个命令的启动延迟上。
    probe::_probe_proc "${key}" /etc/os-release "kv:${field}"
    # **找不到字段时 sed 照样退出 0**，于是「这份 os-release 里没有这一项」会被
    # 记成「探测到一个空值」并报 ok —— 而 os-release 的字段不是每个发行版都齐，
    # Debian 的滚动版就没有 VERSION_ID。空值配 ok 的后果是消费者拿着空串继续拼，
    # 拼出来的路径看着是好的，直到装包那步才报「找不到包」
    if [[ ${OS_PROBE_STATUS} == ok && -z ${OS_PROBE_VALUE} ]]; then
        OS_PROBE_STATUS='missing'
    fi
    return 0
}

# probe::os_id   发行版 ID（debian / ubuntu）
probe::os_id() { probe::_os_release ID 'os.id'; }
# probe::os_version   发行版版本号（VERSION_ID）
probe::os_version() { probe::_os_release VERSION_ID 'os.version'; }
# probe::os_pretty   发行版完整名称（PRETTY_NAME）
probe::os_pretty() { probe::_os_release PRETTY_NAME 'os.pretty'; }
# probe::os_codename   发行版代号（trixie / noble），第三方 apt 源的路径要用它
#
# **不是 VERSION_ID 的同义词**：第三方源的目录名一律是代号（`.../debian trixie stable`），
# 写 `13` 那条源根本不存在，而 `apt-get update` 对不存在的 suite 只在末尾打一行
# 警告并照常返回 0 —— 于是失败推迟到装包那一步才现形，报的却是「找不到包」。
probe::os_codename() { probe::_os_release VERSION_CODENAME 'os.codename'; }

# probe::hostname   主机名
#
# 读 /etc/hostname 而不是调 hostname(1)：后者在最小化镜像里未必存在，
# 而这个文件是 Debian/Ubuntu 上的权威来源。取第一行——文件按约定只有一行，
# 但多一行时静默把两行拼起来会得到一个不存在的主机名。
probe::hostname() {
    probe::_probe 'os.hostname' 2 \
        -- sh -c "head -n1 /etc/hostname 2>/dev/null | tr -d '[:space:]'"
}

# probe::arch   机器架构
probe::arch() {
    probe::_probe 'os.arch' 2 -- uname -m
}

# probe::kernel   内核版本
probe::kernel() {
    probe::_probe 'os.kernel' 2 -- uname -r
}

# probe::unit_exists <unit>   unit 文件是否存在
#
# 服务状态：脚本禁止直调 systemctl is-active / is-enabled / list-unit-files
probe::unit_exists() {
    local unit=${1}
    probe::_probe "unit.${unit}.exists" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl list-unit-files "${unit}" --no-legend
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        OS_PROBE_VALUE='yes'
    else
        OS_PROBE_VALUE='no'
    fi
    # 规范化后的值必须写回缓存：不写的话，直接调用本函数拿到的是 yes/no，
    # 而快照里留的是 systemctl 的原始输出（不存在时是空）——同一个 key 两种
    # 语义。只读快照的消费者（面板）拿到空值，分不出「unit 不存在」和
    # 「探测失败」，而这两件事要采取的行动完全不同。
    probe::_remember "unit.${unit}.exists" "${OS_PROBE_VALUE}"
    return 0
}

# probe::service_active <unit>   服务是否正在运行
#
# 值是 systemctl 自己的状态词：active / inactive / failed / activating…
#
# **它分不出「停着」与「不存在」**（两者都是 inactive + 退出码 3），
# 这是 systemctl 的语义，不是这里的疏漏。要区分就先问 probe::unit_exists ——
# 消费者拿两条事实拼一句话，比在这里编一个第三种值可靠。
probe::service_active() {
    local unit=${1}
    probe::_probe --rc-ok "unit.${unit}.active" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl is-active "${unit}"
}

# probe::services_active <unit>...   一次问多个 unit 的运行状态
#
# 结果一行一个 `unit<TAB>状态`，顺序与传入一致；同时把每一条按
# `unit.<名>.active` 记进本进程的探测结果表，于是它们会跟着 `snapshot_flush`
# 一起落进快照，**非 root 的消费者照样能按单个 unit 的 key 读到**。
#
# **但这不会让同进程里随后的 `probe::service_active` 少起一次进程**：root 路径
# 每次都真探（`probe::_probe` 只在非 root 时读缓存）。想省进程就直接用这个批量
# 结果，别指望它给单个查询加速——写这句是因为我第一版注释正好写反了，而配套的
# 测试也跟着写错，直到容器里跑起来才暴露。
#
# **为什么要有它**：`systemctl is-active` 每次调用都是一次 fork+exec，实测约
# 3.9 ms。面板的快档要问 state 里登记的每一个 unit，十来个就是 47 ms —— 而
# `systemctl is-active a b c` 一次就能把全部答案拿回来，约 4 ms。unit 越多
# 省得越多，而 unit 数量是随用户装的东西增长的。
#
# **输出行数必须与传入个数相等**，否则对不上号：`systemctl is-active` 对每个
# 参数恰好打一行（不存在的 unit 打 `inactive` 并让整条命令返回非零，所以这里
# 照旧 `--rc-ok`）。行数对不上时整体降级为 missing 而不是错位映射——错位不会
# 报错，它只会让面板上某个服务的状态长期显示成另一个服务的。
probe::services_active() {
    local -a units=("$@")
    OS_PROBE_VALUE=''
    [[ ${#units[@]} -gt 0 ]] || return 0

    probe::_probe --rc-ok 'unit.active.batch' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl is-active "${units[@]}"
    [[ ${OS_PROBE_STATUS} == ok ]] || return 0

    local -a states=()
    mapfile -t states <<<"${OS_PROBE_VALUE}"
    if [[ ${#states[@]} -ne ${#units[@]} ]]; then
        OS_PROBE_STATUS='missing'
        OS_PROBE_VALUE=''
        return 0
    fi

    local out=''
    local -i i
    for ((i = 0; i < ${#units[@]}; i++)); do
        out+="${units[i]}"$'\t'"${states[i]}"$'\n'
        probe::_remember "unit.${units[i]}.active" "${states[i]}"
    done
    OS_PROBE_VALUE=${out%$'\n'}
    return 0
}

# probe::service_enabled <unit>   服务是否开机自启
#
# 值是 enabled / disabled / static / masked…，同样用 --rc-ok：
# `is-enabled` 对 disabled 的 unit 返回 1
probe::service_enabled() {
    local unit=${1}
    probe::_probe --rc-ok "unit.${unit}.enabled" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl is-enabled "${unit}"
}

# probe::package_version <包名>   已装包的版本，未装为空
#
# 软件包：脚本禁止直调 dpkg-query / dpkg -l
probe::package_version() {
    local pkg=${1}
    # shellcheck disable=SC2016  # 理由：${Version} 是 dpkg 的模板语法，必须原样传给它
    probe::_probe "pkg.${pkg}.version" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- dpkg-query -W -f='${Version}' "${pkg}"
}

# probe::package_installed <包名>   包是否已安装，值为 yes / no
probe::package_installed() {
    probe::package_version "${1}"
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        OS_PROBE_VALUE='yes'
    else
        OS_PROBE_VALUE='no'
    fi
    return 0
}

# probe::timer_next <timer>   下次触发时间，没装或没启用为空
# probe::timer_next <timer>   下次触发的墙钟时刻，不会再触发时为空
#
# **不能用 `systemctl show -p NextElapseUSecRealtime`**：那个字段只对
# OnCalendar 这类挂在墙钟上的定时器有值。OnUnitActiveSec / OnBootSec 走的是
# 单调时钟，下次时刻记在 NextElapseUSecMonotonic 里，Realtime 恒为空 ——
# 而本项目自己的面板采集 timer 正是这一类，实测表现是面板上它们永远显示
# 「未排期」，可 `systemctl list-timers` 明明白白写着还有 12 秒。
# list-timers 两种时钟都替我们换算好了，所以直接问它。
# 从不触发的 timer 那一列是 `-`，要滤掉：照抄的话面板上会出现一个
# 名叫「-」的时刻。
probe::timer_next() {
    probe::_probe "timer.${1}.next" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "systemctl list-timers --all --no-legend --no-pager \"\$1\" \
            | awk 'NR==1{if(\$1==\"-\")exit; print \$1, \$2, \$3, \$4}'" sh "${1}"
}

# probe::unit_result <unit>   上次运行的结果（success / exit-code / timeout …），没跑过为空
#
# **定时任务到底成没成，只有 systemd 说了算。** 脚本自己往 state 里写的那句
# 「上次执行 ok」是跑到最后才写的：中途被 OOM 杀掉、磁盘写满、超时打断，
# 那一行根本没机会更新，于是界面永远显示正常 —— 备份工具最不能有的一类错。
#
# **不能只看 Result。** 已在 Debian 13 / Ubuntu 24.04 上实测确认：一个 unit
# 只要被 systemd 加载过——哪怕主进程从没起过一次——`Result` 就已经是
# `success`（这是该属性的枚举默认值，不是「跑成功了」）。所以先看
# `ExecMainStartTimestamp`：主进程真的起过一次它才非空，这是「跑没跑过」
# 唯一可信的信号，`Result` 只在确认跑过之后才有意义去读。
probe::unit_result() {
    probe::_probe "unit.${1}.started" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl show "${1}" -p ExecMainStartTimestamp --value
    [[ -n ${OS_PROBE_VALUE} ]] || return 0

    probe::_probe "unit.${1}.result" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl show "${1}" -p Result --value
}

# probe::unit_restarts <unit>   systemd 至今为这个 unit 重启过几次，读不到为空
#
# **判断「服务起来之后有没有崩过」只能用它，不能靠采样状态。** 直觉写法是隔一秒
# 查一次 `is-active`、掉出 active 就算失败；但 `Restart=` 的默认 `RestartSec`
# 是 100 毫秒，从进程退出到重新起来的整个非 active 窗口只有一两百毫秒，
# 秒级采样大概率整段错过 —— 实测：一个「起来 3 秒后退出」的容器，连采 5 次
# 全是 active，判定为成功。`NRestarts` 是 systemd 自己累加的计数，不存在
# 错过窗口的问题，稳定期结束时它大于 0 就证明崩过。
#
# 计数在 `systemctl reset-failed` 时归零，所以它的语义是「自上次复位以来」，
# 而不是「这台机器开机以来」—— 消费者要的恰好是前者：刚创建的服务此前必然是 0。
probe::unit_restarts() {
    probe::_probe "unit.${1}.restarts" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- systemctl show "${1}" -p NRestarts --value
}

# probe::package_candidate <包名>   apt 源里可安装的版本，源里没有为空
#
# 与 package_version 的分工：那个问「装了什么」，这个问「装得到什么」。
# dpkg 系的接口全都只认已装的包，判断某个包在当前源里存不存在只能问 apt。
probe::package_candidate() {
    local pkg=${1}
    # 3 秒不够：源多的机器上 apt-cache 读完全部索引要好几秒，
    # 而超时返回的空值会被读成「源里没有这个包」
    probe::_probe "pkg.${pkg}.candidate" 15 -- apt-cache policy "${pkg}"
    local out=${OS_PROBE_VALUE}
    OS_PROBE_VALUE=''
    [[ ${out} == *'Candidate:'* ]] || return 0

    # 取 `Candidate:` 后的第一个词。**不能按换行切**：非 root 拿到的是
    # snapshot_flush 压过的值，里面的换行已经变成空格，按换行切会把
    # 整张 Version table 一起带上。按空白切两种形态都对。
    local v=${out#*Candidate:}
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%%[[:space:]]*}
    [[ ${v} == '(none)' ]] || OS_PROBE_VALUE=${v}
    return 0
}

# probe::_version_token   把 OS_PROBE_VALUE 里的版本号摘出来
#
# 走命令输出的那几个分支格式各不相同：
#   podman --version         → "podman version 5.8.3"
#   node --version           → "v22.1.0"
#   valkey-server --version  → "Valkey server v=8.0.1 sha=00000000:0 …"
#   dockerd --version        → "Docker version 24.0.7, build afdd53b"
# 消费者要的是版本号本身。不摘出来的话，拿整行去和 state 里记的版本比对
# **永远不相等**，「版本漂移」就成了一条永不消失的假告警。
#
# 只对这几个分支用，**不碰 package_version 的结果**：dpkg 版本形如
# `5.8.3+ds1-1`，摘成 `5.8.3` 会把 @requires 的版本比较判错。
probe::_version_token() {
    [[ ${OS_PROBE_VALUE} =~ ([0-9]+(\.[0-9]+)+) ]] && OS_PROBE_VALUE=${BASH_REMATCH[1]}
    return 0
}

# probe::component_version <组件类型>   组件的运行版本
#
# 组件版本：骨架模板里的幂等检查用的就是它
probe::component_version() {
    local type=${1}
    case ${type} in
        caddy)
            probe::_probe 'component.caddy.version' "${OS_DEFAULT_PROBE_TIMEOUT}" -- caddy version
            probe::_version_token
            ;;
        valkey)
            probe::_probe 'component.valkey.version' "${OS_DEFAULT_PROBE_TIMEOUT}" -- valkey-server --version
            probe::_version_token
            ;;
        mariadb) probe::package_version mariadb-server ;;
        # Node.js **不是 apt 包**（官方 tar 解到 /usr/local/lib/nodejs），
        # 落到默认分支去问 dpkg 只会得到空 —— 而空会被读成「没装」
        nodejs)
            # 命令脚本的受限 PATH 不含 /usr/local/bin；Node 的 alternatives
            # 权威入口就在这里，调用裸 node 会让定时采集稳定地误报未安装。
            probe::_probe 'component.nodejs.version' "${OS_DEFAULT_PROBE_TIMEOUT}" \
                -- "${OS_LOCAL_BIN_DIR}/node" --version
            probe::_version_token
            ;;
        # PHP-FPM 装的是 `php8.3-fpm` 这类包，**没有一个叫 `php` 的包一定在**。
        # 落到默认分支去问 dpkg 要 `php`，装着 PHP 的机器也会答空 —— 而空会被
        # 读成「没装」，@requires php 于是把整块功能藏掉。
        # 多版本共存时报最高的那个：问的是这台机器上有没有够新的 PHP，
        # 有 8.4 就该算满足 8.2（php_fpm_versions 按 sort -V 升序，末位即最高）
        php)
            probe::php_fpm_versions
            OS_PROBE_VALUE=${OS_PROBE_VALUE##* }
            ;;
        podman)
            probe::_probe 'component.podman.version' "${OS_DEFAULT_PROBE_TIMEOUT}" -- podman --version
            probe::_version_token
            ;;
        # **问二进制，不问 dpkg**，两个理由都致命：一、rclone 官方的装法就是
        # 往 /usr/bin 扔一个二进制，dpkg 对它一无所知，落到默认分支只会答空，
        # 而空会被读成「没装」；二、发行版包的版本形如 `1.60.1+dfsg-2`，
        # 和官方 version.txt 的 `1.75.0` 不同形，拿去比对永远不相等（D238
        # 要的正是这个比对）。`rclone version` 首行是 "rclone v1.75.0"
        rclone)
            probe::_probe 'component.rclone.version' "${OS_DEFAULT_PROBE_TIMEOUT}" -- rclone version
            probe::_version_token
            ;;
        # **判据是 `dockerd` 而不是 `docker`**：`docker --version` 在装了
        # podman-docker 的机器上打的是 "podman version 5.4.1"，拿它判断
        # 「装没装 Docker」会在最需要区分的那台机器上答错。dockerd 是引擎本体，
        # podman 侧没有任何东西提供它。也不查包名 —— docker-ce 与 docker.io
        # 两个包都提供它，而这里问的是引擎在不在，不是哪个包装的（同
        # probe::container_engine 的思路：认行为，不认包名）
        docker)
            probe::_probe 'component.docker.version' "${OS_DEFAULT_PROBE_TIMEOUT}" -- dockerd --version
            probe::_version_token
            ;;
        # compose 两侧都要能被 @requires 判到，否则装了引擎没装 compose 时
        # 菜单照样列出条目，选进去才被拒（§6：不满足要隐藏，不是进去再报）。
        #
        # **podman 侧的判据是「现在真的能用」，不是「有没有 provider」，更不是
        # 「podman-compose 这个包装没装」**：
        #
        #   podman-compose  直接跟 podman 说话，装上就能用
        #   Compose v2      说的是 Docker API，**要通过 podman 的 docker 兼容
        #                   socket**，podman.socket 没启用时 `podman compose
        #                   version` 照样答得出来（本地查询），一 up 就失败
        #
        # 只问「有没有 provider」的后果实测过：机器上有 Docker 的 Compose v2
        # 插件、podman.socket 是 disabled，菜单把「Compose 项目」列了出来，
        # 而它一个项目也起不了。反过来只认 podman-compose 也不对 —— 会把认真
        # 用 Compose v2（且开了 socket）的机器整块藏掉，而藏掉且不给提示比报错
        # 难查得多。
        compose-usable)
            probe::compose_provider
            if [[ -z ${OS_PROBE_VALUE} ]]; then
                OS_PROBE_VALUE=''
                return 0
            fi
            local __pv_kind=${OS_PROBE_VALUE%%$'\t'*}
            local __pv_ver=${OS_PROBE_VALUE#*$'\t'}
            __pv_ver=${__pv_ver%%$'\t'*}
            if [[ ${__pv_kind} != compose-v2 ]]; then
                OS_PROBE_VALUE=${__pv_ver}
                return 0
            fi
            # enabled 就够：socket 激活是按需拉起的，不必要求它此刻 active
            probe::service_enabled podman.socket
            local __pv_en=${OS_PROBE_VALUE}
            probe::service_active podman.socket
            if [[ ${__pv_en} == enabled || ${OS_PROBE_VALUE} == active ]]; then
                OS_PROBE_VALUE=${__pv_ver}
            else
                OS_PROBE_VALUE=''
            fi
            ;;
        # docker 侧是官方 Compose v2 插件，一条命令就答完（D218：这边没有
        # podman 那种「三个 provider 要挑一个」的问题）
        docker-compose-plugin)
            probe::_probe 'component.docker_compose.version' "${OS_DEFAULT_PROBE_TIMEOUT}" \
                -- docker compose version --short
            probe::_version_token
            ;;
        *) probe::package_version "${type}" ;;
    esac
}

# probe::php_fpm_versions   已装的 PHP-FPM 版本列表，空格分隔
#
# 已装的 PHP-FPM 版本，空格分隔且从旧到新（"8.1 8.3"）。一个都没有时是空串。
#
# **为什么是 probe 而不是脚本里的 os::query**：规范的判据是「两个以上的
# 地方需要同一个事实」——`php config` 要知道给哪个版本改配置，`install php`
# 要知道装没装过、装了哪些，`doctor` 要显示装了几个。三处各写一份 find /etc/php
# 的话，迟早一处认得只装了 cli 没装 fpm 的版本、另一处不认。
#
# 认的是 `/etc/php/<ver>/fpm` 而不是 `/etc/php/<ver>`：只装了 php-cli 的版本
# 没有 fpm 目录，而这个事实的全部消费者关心的都是 FPM。
#
# 值用空格分隔而不是换行：快照落盘时换行会被换成空格（见 probe::snapshot_flush），
# 非 root 读缓存拿到的格式必须与 root 实时探测拿到的一致。
probe::php_fpm_versions() {
    probe::_probe 'php.fpm_versions' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "ls -1d /etc/php/*/fpm 2>/dev/null | cut -d/ -f4 | sort -V | paste -sd ' ' -"
}

# probe::caddy_plugins   当前 Caddy 编进了哪些 Go 模块（模块路径，空格分隔）
#
# 用 `build-info` 而不是 `list-modules`：前者列的是**编译进去的 Go 模块路径**，
# 与插件清单里写的东西一一对应；后者列的是 Caddy 模块名，跟插件名没有可靠关系
# （`caddy-ratelimit` 的模块叫 `http.handlers.rate_limit`，`cache-handler` 叫
# `http.handlers.cache`）。按名字猜会把装好的插件判成缺失，而 caddy-dns 系列
# 恰好能对上，于是这个错误只在遇到第一个非 DNS 插件时才暴露。
#
# 只取 `dep`/`mod` 行的第二列（模块路径），不返回整份 build-info：那是几百行，
# 塞进探测快照既没意义又会把 public/probe.tsv 撑大。
#
# 值用空格分隔而不是换行，理由同 php_fpm_versions：快照落盘时换行会被换成空格。
# Caddy 没装或不在 PATH 时是空串——调用方要区分「没装」与「装了但没这个插件」
# 的话，另问 probe::component_version caddy。
probe::caddy_plugins() {
    probe::_probe 'caddy.plugins' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "caddy build-info 2>/dev/null | awk '\$1==\"dep\"||\$1==\"mod\"{print \$2}' | sort -u | paste -sd ' ' -"
}

# probe::compose_provider   compose provider：`种类<制表符>版本<制表符>路径`，没有则空
#
# `podman compose` 只是个转发壳，真正解析 compose 文件的是外部 provider，
# 可以是 Compose v2、podman-compose 或 Compose v1 三者之一。**挑选顺序
# v2 > podman-compose > v1 是 D203 定的**，不是 podman 自己的默认顺序。
#
# **为什么是 probe 而不是脚本里的 os::query**：两个消费者要同一个事实 ——
# `podman compose` 那个脚本要知道用哪一个（还要路径，它得把 provider 钉住，
# D204），注册表要知道有没有（没有就该把整个菜单条目藏掉，§6）。两处各探各的，
# 迟早出现「菜单里有、进去说没有」，而那种不一致最难查。
#
# 三列一起给，不是只给版本：路径是钉住 provider 的依据，种类决定要不要提醒
# 用户兼容度（v1 已停止维护）。只回版本号的话，脚本还得再探一次去找路径 ——
# 那就又是两份实现。
#
# 候选路径是 `podman compose --help` 列的那几条，**去掉 ~/.docker**：
# root 的家目录不该参与决定一个系统服务跑什么。
probe::compose_provider() {
    # 与 probe::caddy_plugins 同一种写法：脚本体走双引号 + 转义 `$`，
    # 单引号里出现 `$` 会被 shellcheck 判成「表达式不会展开」（SC2016）
    probe::_probe 'compose.provider' "${OS_DEFAULT_PROBE_TIMEOUT}" -- sh -c "
        ver_of() { \"\$1\" version --short 2>/dev/null | head -n1 | sed 's/^v//; s/[^0-9.].*//'; }
        paths=\$(command -v docker-compose 2>/dev/null)
        for c in /usr/local/lib/docker/cli-plugins/docker-compose \
                 /usr/local/libexec/docker/cli-plugins/docker-compose \
                 /usr/lib/docker/cli-plugins/docker-compose \
                 /usr/libexec/docker/cli-plugins/docker-compose; do
            [ -x \"\$c\" ] && paths=\"\$paths \$c\"
        done
        for p in \$paths; do
            v=\$(ver_of \"\$p\")
            case \$v in
                '' | 0 | 0.* | 1 | 1.*) ;;
                *) printf 'compose-v2\t%s\t%s\n' \"\$v\" \"\$p\"; exit 0 ;;
            esac
        done
        p=\$(command -v podman-compose 2>/dev/null)
        if [ -n \"\$p\" ]; then
            printf 'podman-compose\t%s\t%s\n' \"\$(ver_of \"\$p\")\" \"\$p\"
            exit 0
        fi
        for p in \$paths; do
            v=\$(ver_of \"\$p\")
            [ -n \"\$v\" ] && { printf 'compose-v1\t%s\t%s\n' \"\$v\" \"\$p\"; exit 0; }
        done
        exit 0
    "
}

# probe::port_listening <端口>   该 TCP 端口是否有进程监听
#
# 端口：脚本禁止直调 ss / netstat
probe::port_listening() {
    local port=${1}
    probe::_probe "port.${port}" "${OS_DEFAULT_PROBE_TIMEOUT}" -- ss -Hltn "sport = :${port}"
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        OS_PROBE_VALUE='yes'
    else
        OS_PROBE_VALUE='no'
    fi
    return 0
}

# probe::port_families <端口>   该 TCP 端口正在监听的地址族，空格分隔（v4 / v6）
#
# 只问「在不在听」不够：`safe ssh` 改 SSH 端口时踩过一次真实竞态——
# 短时间内连续多次重配置同一个 socket unit，端口确实「在听」，但只绑上了
# IPv6，IPv4 悄悄丢失，外部最常见的连接方式直接被拒绝。改动前后**比对地址族
# 集合**（而不只是「有没有在听」）才能接住这类只掉了一半的监听。
probe::port_families() {
    local port=${1}
    probe::_probe "port.${port}.families" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- ss -Hltn "sport = :${port}"
    local out=${OS_PROBE_VALUE}
    local -a fam=()
    [[ ${out} == *'0.0.0.0:'* ]] && fam+=('v4')
    [[ ${out} == *'[::]:'* ]] && fam+=('v6')
    local IFS=' '
    OS_PROBE_VALUE="${fam[*]}"
    OS_PROBE_STATUS='ok'
    return 0
}

# probe::listening_ports   全部监听中的 TCP 端口，空格分隔
#
# 正在监听的 TCP 端口，去重后从小到大，空格分隔。
#
# 消费者：`firewall enable` 在把默认策略改成「拒绝入站」之前，要把
# 「正在听、但不在放行清单里」的端口指名道姓地列给用户看 —— 否则启用防火墙
# 就是一次盲操作，用户要等到某个服务连不上了才知道自己关掉了什么。
# `safe status` 也用它核对 SSH 端口是真的在听。
#
# 值用空格分隔而不是换行，理由同 php_fpm_versions：快照落盘时换行会被换成空格。
probe::listening_ports() {
    probe::_probe 'net.listening_tcp' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "ss -Hltn | awk '{print \$4}' | sed 's/.*://' | grep -E '^[0-9]+\$' | sort -nu | paste -sd ' ' -"
    return 0
}

# probe::listening_scoped   监听端口按「防火墙管不管得到」分成两拨
#
# OS_PROBE_VALUE 为 `对外端口<TAB>仅本地端口`，两侧各自空格分隔、去重升序。
#
# **probe::listening_ports 把 `127.0.0.1:3306` 和 `0.0.0.0:80` 一样只取端口号**，
# 于是防火墙界面会把一堆只听 loopback 的服务列进「启用后将无法从外部访问」。
# 真机实测：12 个监听端口里 7 个是 127.0.0.1，纯噪音 —— 而真正危险的那个
# （对外监听的 3306）混在里面，长得跟它们一模一样。更糟的是界面据此建议
# 「要放行就带上 --ports=…」，照做等于把 MySQL 开到公网。
#
# 判据是**非 loopback 即受管**：绑到内网 IP（192.168.x.x）的服务同样走 INPUT
# 链，防火墙拦得到它，所以算「对外」那一拨 —— 这里区分的是「防火墙管不管得到」，
# 不是「能不能从公网访问」，后者还取决于路由与云厂商安全组，探不出来也不该猜。
#
# 同一个端口既听 0.0.0.0 又听 127.0.0.1 时归入对外：只要有一条对外的监听，
# 防火墙的开关就影响得到它。
#
# 原 listening_ports 保留不动：safe status 与面板采集还在用它，
# 而它们要的正是「所有在听的端口」这个不分地址的口径。
probe::listening_scoped() {
    probe::_probe 'net.listening_scoped' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "ss -Hltn | awk '{addr=\$4; port=addr; sub(/.*:/, \"\", port); sub(/:[^:]*\$/, \"\", addr); if (port ~ /^[0-9]+\$/) print (addr ~ /^127\./ || addr ~ /^\[?::1\]?\$/) ? \"L\" : \"P\", port}'"

    local raw=${OS_PROBE_VALUE}
    OS_PROBE_VALUE=''
    [[ -n ${raw} ]] || return 0

    # **按词两两配对，不按行读。** 探测的原始输出是 `L|P<空格>端口` 一行一条，
    # 但缓存落盘时换行会被换成空格（见 probe::snapshot_flush），非 root 从
    # 快照读回来的就是挤成一行的同一串词。按行读的话，那一行会被当成
    # 「一个 scope + 一个叫『80 L 6379』的端口」—— 拼进界面就是个垃圾值。
    # 词序在两种形态下是一样的，所以配对是唯一对两者都成立的读法。
    #
    # 每个端口仍单独验一次是不是数字：快照那条路上的值经过脱敏通道，
    # 万一被改动过，宁可少算一个端口，也不要把一串非数字当端口显示出去。
    # 先把换行抹平成空格，再一次读成词数组：`toks=(${raw})` 那种裸展开
    # 会顺带做一次路径扩展，快照里万一混进个 `*` 就变成读目录了
    local flat=${raw//$'\n'/ }
    local -a toks=()
    IFS=$' \t' read -ra toks <<<"${flat}" || true

    local scope port p hit
    local -i i
    local -a pub=() loc=()
    for ((i = 0; i + 1 < ${#toks[@]}; i += 2)); do
        scope=${toks[i]}
        port=${toks[i + 1]}
        [[ ${port} =~ ^[0-9]+$ ]] || continue
        [[ ${scope} == 'P' ]] && pub+=("${port}")
    done
    for ((i = 0; i + 1 < ${#toks[@]}; i += 2)); do
        scope=${toks[i]}
        port=${toks[i + 1]}
        [[ ${scope} == 'L' && ${port} =~ ^[0-9]+$ ]] || continue
        hit=''
        for p in ${pub[@]+"${pub[@]}"}; do
            [[ ${p} == "${port}" ]] && {
                hit=1
                break
            }
        done
        [[ -n ${hit} ]] || loc+=("${port}")
    done

    # 不带参数的 printf 会照样吐一个空行，空数组因此会变成 ("")，
    # 拼进消息里就是一个凭空多出来的空端口
    [[ ${#pub[@]} -gt 0 ]] && mapfile -t pub < <(printf '%s\n' "${pub[@]}" | sort -nu)
    [[ ${#loc[@]} -gt 0 ]] && mapfile -t loc < <(printf '%s\n' "${loc[@]}" | sort -nu)

    local IFS=' '
    OS_PROBE_VALUE="${pub[*]}"$'\t'"${loc[*]}"
    return 0
}

# probe::dir_size_kb <路径>   这个目录占多少（KB），算不出来为空
#
# 面板要显示容器卷有多大。**超时给 5 秒，而且算不出来时返回空而不是 0**：
# `du` 在大目录上是不封顶的，超时降级返回 0 会让一个几十 G 的卷显示成「0 B」——
# 那比不显示更糟，用户会据此以为磁盘没被谁占着。
#
# 调用方自己决定该不该算：bind mount 可能指向 /srv 甚至 /，对它跑 du 是在
# 每轮采集里埋一颗定时炸弹（见 web_collect 的 build_volumes，只算命名卷）。
probe::dir_size_kb() {
    local path=${1}
    probe::_probe "dir.${path}.size_kb" 5 \
        -- sh -c "du -sk -- \"\$1\" 2>/dev/null | awk '{print \$1}'" sh "${path}"
    [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]] || OS_PROBE_VALUE=''
    return 0
}

# probe::disk_free_kb [路径]   该路径所在文件系统的可用空间（KB），默认 /
#
# 磁盘与内存：脚本禁止直调 df / free
probe::disk_free_kb() {
    local path=${1:-/}
    probe::_probe "disk.${path}.free_kb" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "df -Pk \"\$1\" | awk 'NR==2{print \$4}'" sh "${path}"
}

# probe::disk_total_kb [路径]   该路径所在文件系统的总容量（KB），默认 /
#
# 单有 free 表达不了「用了多少」：面板要显示占用比例，消费者拿不到分母
# 就只能自己去 df，而那正是规范禁止脚本做的事。
probe::disk_total_kb() {
    local path=${1:-/}
    probe::_probe "disk.${path}.total_kb" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "df -Pk \"\$1\" | awk 'NR==2{print \$2}'" sh "${path}"
}

# probe::mem_total_kb   物理内存总量（KB）
probe::mem_total_kb() {
    probe::_probe_proc 'mem.total_kb' /proc/meminfo 'line:MemTotal::2'
}

# probe::mem_available_kb   可用内存（KB）
probe::mem_available_kb() {
    probe::_probe_proc 'mem.available_kb' /proc/meminfo 'line:MemAvailable::2'
}

# probe::uptime_seconds   系统已运行秒数
probe::uptime_seconds() {
    probe::_probe_proc 'uptime.seconds' /proc/uptime 'intfield:1'
}

# probe::loadavg   1 / 5 / 15 分钟平均负载，空格分隔的三个数
#
# 一次给三个而不是三个函数：三个数只有放在一起才有意义（1 分钟高、15 分钟低
# 是刚起的一阵，反过来是持续压着），而 /proc/loadavg 本来就是一次读全。
probe::loadavg() {
    probe::_probe_proc 'load.avg' /proc/loadavg 'range:1:3'
}

# probe::cpu_count   在线 CPU 核心数
#
# 负载没有分母就读不懂：load 4 在 1 核上是排队排疯了，在 16 核上是闲着。
probe::cpu_count() {
    probe::_probe 'cpu.count' 2 -- sh -c "nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo"
}

# probe::cpu_model   CPU 型号
probe::cpu_model() {
    probe::_probe_proc 'cpu.model' /proc/cpuinfo 'cpumodel'
    [[ ${OS_PROBE_STATUS} != ok || -n ${OS_PROBE_VALUE} ]] || OS_PROBE_STATUS='missing'
    return 0
}

# probe::cpu_jiffies   `总时间 空闲时间` 两个累计计数（单位 jiffy）
#
# 返回累计值而不是使用率：使用率是**两个时刻之间**的量，单次采样算不出来。
# 消费者拿相邻两轮做差分（idle 增量 / 总增量 = 这段时间的空闲比例），这样
# 「使用率」覆盖的正好是两次采集之间的完整区间，不是采集那一瞬的抖动。
# 空闲要把 iowait 算进去：等 IO 的那段时间 CPU 确实没在干活。
probe::cpu_jiffies() {
    probe::_probe_proc 'cpu.jiffies' /proc/stat 'cpustat'
}

# probe::podman_running   运行中的容器数
#
# podman 与 ufw：这两个是 K14 的直接来源 —— podman 一挂，没超时就开不了机
probe::podman_running() {
    probe::_probe 'podman.running' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "podman ps --format '{{.ID}}' | wc -l"
}

# probe::podman_total   容器总数，含已停止
probe::podman_total() {
    probe::_probe 'podman.total' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "podman ps -a --format '{{.ID}}' | wc -l"
}

# probe::podman_ports   每个容器的端口映射，一行 `名字<制表符>映射`，没映射的也占一行
#
# 切换网络定位时要指出「哪几个已有容器跟新定位对不上」。绑定地址是建容器那一刻
# 写死在 Quadlet 里的，改定位不会追溯 —— 不列出来的话，用户以为切完就生效了。
probe::podman_ports() {
    probe::_probe 'podman.ports' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- podman ps -a --format '{{.Names}}\t{{.Ports}}'
}

# probe::docker_running   运行中的 Docker 容器数
#
# 与 podman 那三个并列而不是合成一个「容器数」：两个引擎各有各的容器存储，
# 同一台机器上都可能有东西在跑，加总起来就再也分不清该去哪个引擎里找。
#
# 超时比 podman 更要紧：`docker ps` 要连 daemon，而 dockerd 挂起时它不返回
# 也不报错（K14 的同一类失败，只是换了个 daemon）。
probe::docker_running() {
    probe::_probe 'docker.running' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "docker ps --format '{{.ID}}' | wc -l"
}

# probe::docker_total   Docker 容器总数，含已停止
probe::docker_total() {
    probe::_probe 'docker.total' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "docker ps -a --format '{{.ID}}' | wc -l"
}

# probe::docker_ports   每个 Docker 容器的端口映射，一行 `名字<制表符>映射`
#
# 用途同 probe::podman_ports：切换网络定位时指出哪几个已有容器对不上。
# Docker 这边尤其要列 —— 容器的绑定地址在 `docker run` 那一刻就定死了，
# 而改 daemon 的默认绑定地址只影响此后新建的容器。
probe::docker_ports() {
    probe::_probe 'docker.ports' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- docker ps -a --format '{{.Names}}\t{{.Ports}}'
}

# probe::container_engine   /usr/bin/docker 由谁提供：docker / podman / 空
#
# **`docker` 这个命令名有两个可能的主人**，而分不清它们的后果都是硬的：
# 真 Docker 与 podman-docker 都提供 `/usr/bin/docker`，dpkg 层面必然冲突 ——
# 装 podman-docker 前不问就装，apt 直接失败；装 Docker 前不问就装，同样失败。
# 而「机器上有没有 docker 命令」这个问题答成 yes/no 是不够的：接管方是 podman
# 时答 yes，会让人以为不能再装 podman-docker（其实已经装了）。
#
# 判据是版本串本身：podman-docker 的 wrapper 就是 `exec podman "$@"`，
# 于是 `docker --version` 打的是 "podman version 5.4.1"。**不去看文件是不是
# 软链、也不查包**：包名在两个发行版上不保证一致，而这行输出是行为本身。
#
# `docker --version` 是纯客户端命令，不连 daemon —— daemon 挂了它照样立刻返回。
# 超时仍然给，理由同 K14：这条会被菜单面板每次调用。
probe::container_engine() {
    probe::_probe 'container.engine' "${OS_DEFAULT_PROBE_TIMEOUT}" -- docker --version
    case ${OS_PROBE_VALUE} in
        '') ;;
        *[Pp]odman*) OS_PROBE_VALUE='podman' ;;
        *) OS_PROBE_VALUE='docker' ;;
    esac
    return 0
}

# probe::container_engines   机器上真正装着的引擎，一行一个（podman / docker）
#
# **与 probe::container_engine 是两个问题**，混用过一次就知道后果有多硬：
# 那个答「`docker` 这个命令名由谁提供」，用途是安装期的冲突判定；这个答
# 「机器上有哪些引擎」。真 Docker 与 podman 并存是常见布局，两者各有各的
# 容器存储。拿前者当后者用，只会采到一个引擎的容器；另一个引擎的容器会在
# 面板上完全不存在。
#
# 一行一个而不是空格分隔：调用方的 IFS 不含空格（D91），空格分隔在 for 里不分词。
probe::container_engines() {
    probe::_probe 'container.engines' "${OS_DEFAULT_PROBE_TIMEOUT}" -- sh -c "
        out=\"\"
        if podman --version >/dev/null 2>&1; then out=\"podman\"; fi
        # podman-docker 接管 docker 命令时，它不是第二个引擎，是同一个
        case \$(docker --version 2>/dev/null) in
            \"\" | *[Pp]odman*) ;;
            *) out=\"\${out:+\${out}
}docker\" ;;
        esac
        printf \"%s\" \"\${out}\"
    "
    return 0
}

# probe::container_inventory <engine>   每个容器一行，制表符分隔十列：
#   名字 · 镜像 · 状态 · 重启策略 · 健康 · 自动更新标签 · watchtower 标签 · 端口
#   · 镜像 ID · 挂载
#
# 后两列是追加的，排在末尾而不是插在中间：按列号取值的消费者不会因为加一列而
# 整体错位（同 manifest「加字段不破坏老客户端」）。
#
# **镜像 ID 与「镜像」那一列不是一回事**：后者是 `nickfedor/watchtower:latest`
# 这种名字，标签不动而内容换掉时它一个字符都不变；ID 才是内容的身份。面板靠
# 它判断「这个容器**确实**换过镜像」—— 自动更新查过一遍没更新、或者原地重启，
# ID 都不会变，而名字与启动时间都会骗人。
#
# 挂载格式是 `类型|卷名|源|目标`，条目之间用空格分隔（同端口那列）。
# 用 `|` 而不是 `:` 分字段：卷名与路径里都可能有 `:`，而 `|` 在这两处都不合法。
# 代价是**源路径含空格的挂载会被切错**，那种路径在容器场景里没见过，
# 真出现时表现是多出一条看得出来的坏行，不会静默错到别的容器头上。
#
# 一条 inspect 拿全，**不和 `ps` 合流**：两个引擎的模板在名字、镜像、状态、
# 重启策略、标签上完全通用（真机逐字段验过），唯独端口的字段名不同 ——
# docker 是 `.HostIp`、podman 是 `.HostIP`，同一个模板在 podman 上直接报
# 「can't evaluate field HostIp」。既然本函数本来就按引擎调用，端口那段按引擎
# 选字段名即可，比「ps 取端口 + inspect 取其余 + 按名字合流」少一条命令。
#
# docker 的 `.Name` 带前导斜杠（`/adguardhome`），podman 不带，统一剥掉。
# 没有容器时 `inspect` 会因缺参数报错，先用 `ps -aq` 判空。
#
# **分隔符写成 `{{"\t"}}` 而不是 `\t`**：`ps --format` 两个引擎都会把 `\t` 当转义
# 处理，但 `inspect --format` 只有 podman 会 —— docker 原样输出两个字符，整行
# 落成一列（真机实测）。`{{"\t"}}` 是 Go 模板里的字符串字面量，由模板引擎产出
# 真制表符，绕开了 CLI 层这处不一致。
probe::container_inventory() {
    local eng=${1-}
    local ip='HostIp'
    [[ ${eng} == podman ]] && ip='HostIP'
    local t='{{"\t"}}'
    local tpl
    tpl="{{.Name}}${t}{{.Config.Image}}${t}{{.State.Status}}${t}{{.HostConfig.RestartPolicy.Name}}"
    tpl+="${t}{{if .State.Health}}{{.State.Health.Status}}{{else}}{{end}}"
    tpl+="${t}{{index .Config.Labels \"io.containers.autoupdate\"}}"
    tpl+="${t}{{index .Config.Labels \"com.centurylinklabs.watchtower.enable\"}}"
    tpl+="${t}{{range \$p, \$c := .NetworkSettings.Ports}}{{range \$c}}{{.${ip}}}:{{.HostPort}}->{{\$p}} {{end}}{{end}}"
    tpl+="${t}{{.Image}}"
    tpl+="${t}{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}} {{end}}"
    probe::_probe "container.inventory.${eng}" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "
            ids=\$(\"\$1\" ps -aq 2>/dev/null) || exit 0
            [ -n \"\$ids\" ] || exit 0
            printf '%s\\n' \"\$ids\" | while IFS= read -r id; do
                [ -n \"\$id\" ] || continue
                \"\$1\" inspect --format \"\$2\" \"\$id\" 2>/dev/null
            done | sed \"s|^/||\"
        " sh "${eng}" "${tpl}"
    return 0
}

# probe::ssh_port   sshd 实际监听的端口
#
# SSH 端口。**两个以上地方需要同一事实就必须是 probe**——
# `ufw` 删规则时要拦住它（删了就把自己锁在门外），SSH 加固改端口时也要读它。
# 两处各写一份 grep 的话，迟早一处认得 sshd_config.d 里的覆盖、另一处不认。
#
# 读主配置 + Include 进来的片段。只认第一条 Port：sshd 本身就是这个语义。
#
# **socket 激活时端口根本不在 sshd_config 里**（实测：Ubuntu 24.04
# 默认 `ssh.socket` enabled 而 `ssh.service` disabled，Debian 13 反过来）。
# 此时监听由 systemd 完成，端口写在 ssh.socket 的 `ListenStream=`，
# sshd 拿到的是一个已经连上的 fd，配置里那行 `Port` 完全不起作用。
# 只读配置文件的话，在 Ubuntu 上改完端口会得到「配置写着 2222、
# 机器其实还听在 22」——而 ufw 会照着 2222 去保护一条根本不存在的规则。
probe::ssh_port() {
    probe::service_enabled 'ssh.socket'
    if [[ ${OS_PROBE_VALUE} == enabled ]]; then
        # `Listen` 而不是 `ListenStream`：后者是 unit 文件里的写法，
        # systemctl show 暴露的属性名是前者，值形如
        #   0.0.0.0:22 (Stream)
        #   [::]:22 (Stream)
        # 多行时取第一行即可 —— 同一个 socket 的多个 ListenStream 是同一个端口
        # 的 v4/v6 两面（实测两台机器都是这样）。
        probe::_probe 'ssh.socket_listen' "${OS_DEFAULT_PROBE_TIMEOUT}" \
            -- systemctl show ssh.socket -p Listen --value
        local sock=${OS_PROBE_VALUE%%$'\n'*}
        sock=${sock%% *}
        sock=${sock##*:}
        if [[ ${sock} =~ ^[0-9]+$ ]]; then
            OS_PROBE_VALUE=${sock}
            OS_PROBE_STATUS='ok'
            return 0
        fi
    fi

    # 文件清单在 bash 这边展开，探测只做一次 grep：把整段逻辑塞进 `sh -c '...'`
    # 会因为里面的 $f / $p 触发 SC2016，而那是「给内层 sh 看的」——
    # 与其加 disable 解释，不如让它根本不需要内层 shell
    local -a files=(/etc/ssh/sshd_config)
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f ${f} ]] && files+=("${f}")
    done

    probe::_probe 'ssh.port' 2 -- grep -hE '^[[:space:]]*Port[[:space:]]+[0-9]+' "${files[@]}"

    # 只认第一条 Port —— sshd 本身就是这个语义。一条都没有时是 22（sshd 的默认），
    # 这是确定的答案而不是「探测失败」，所以状态置 ok。
    local line=${OS_PROBE_VALUE%%$'\n'*}
    local port=${line##*[[:space:]]}
    [[ ${port} =~ ^[0-9]+$ ]] || port='22'
    OS_PROBE_VALUE=${port}
    OS_PROBE_STATUS='ok'
    return 0
}

# probe::sshd_effective <配置关键字>   sshd -T 的生效值，不是配置文件字面值
#
# sshd 的**有效**配置项。keyword 用 sshd 自己的名字（port /
# passwordauthentication / permitrootlogin / pubkeyauthentication /
# kbdinteractiveauthentication），大小写随便写，这里统一转小写再比。
#
# **为什么不自己 grep 配置文件**：sshd 的取值规则是「第一次出现的值生效」，
# 而两个发行版的主配置第 12 行都是 `Include /etc/ssh/sshd_config.d/*.conf`，
# 片段目录里的文件因此**先于**主配置生效，片段之间又按文件名字典序排。
# Ubuntu 的云镜像正是靠 `50-cloud-init.conf` 在那里写
# `PasswordAuthentication yes`（实测）。自己 grep 一遍等于重写一遍
# sshd 的取值规则，而写错的表现是「工具说密码登录已关闭，实际还开着」——
# 一个让人放心地把机器暴露在公网上的假结论。
#
# **两个发行版的 `sshd -T` 大小写不一样**：Ubuntu 24.04（openssh 9.6）全小写
# `permitrootlogin yes`，Debian 13（openssh 10.x）是驼峰 `PermitRootLogin yes`。
# 按原样比对的话，同一份代码在一个发行版上永远读不到值 —— 这正是 D65 那类
# 「只测一个发行版等于没测」的坑，所以 awk 里两边都 tolower。
probe::sshd_effective() {
    local kw=${1,,}
    probe::_probe "ssh.effective.${kw}" "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- sh -c "sshd -T 2>/dev/null | awk -v k=\"\$1\" 'tolower(\$1)==k{print \$2; exit}'" sh "${kw}"
    return 0
}

# probe::user_home <用户>   用户家目录
#
# 用户的 home 目录。`safe` 要往 <home>/.ssh/authorized_keys 写公钥，
# probe::ssh_authkeys 要去数那个文件里有几把钥匙 —— 两个消费者。
# 值经**位置参数**交给 `sh -c`，不拼进脚本文本。用户名来自 `oneserver safe ssh
# --user=`，眼下调用方在调用前过了一遍正则，但那是调用方的自觉：探测接口不该
# 把「我的参数会不会被当成 shell 代码」这件事留给每一个调用方各自记得。
# 同理见下面几个带路径与 unit 名的探测。
probe::user_home() {
    local user=${1}
    probe::_probe "user.${user}.home" 2 \
        -- sh -c "getent passwd \"\$1\" | cut -d: -f6" sh "${user}"
    return 0
}

# probe::ssh_authkeys <用户>   该用户 authorized_keys 中的公钥条数，读不到为 0
#
# 目标用户 authorized_keys 里的公钥条数。**关掉密码登录之前必须先问它**：
# 一把钥匙都没有就关，等于把自己锁在门外，而且是在远程操作时。
# `safe status` 也要显示它，两个消费者。
probe::ssh_authkeys() {
    local user=${1}
    probe::user_home "${user}"
    local home=${OS_PROBE_VALUE}
    if [[ -z ${home} ]]; then
        OS_PROBE_VALUE='0'
        OS_PROBE_STATUS='missing'
        return 0
    fi
    # 认 openssh 支持的三类前缀：ssh-*（rsa/ed25519/dss）· ecdsa-* · sk-*（FIDO2）。
    # grep -c 在零匹配时退出码是 1，_probe 会把它记成 missing 并留空 ——
    # 所以下面把空值兜成 0，而不是让调用方看到一个空串去做数值比较
    probe::_probe "ssh.authkeys.${user}" 2 \
        -- grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys"
    [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]] || OS_PROBE_VALUE='0'
    OS_PROBE_STATUS='ok'
    return 0
}

# probe::apt_upgrade_stats   可升级的包数量，以及其中属于安全更新的数量
#
# `safe status`／`safe updates`／面板采集都要同时问这两个数。它们来自
# **同一次** `apt-get -s upgrade` 模拟输出，拆成两个探测各跑一遍会让这条
# 本就不便宜的命令执行两次——是 `safe` 菜单每次刷新总览都卡顿的来源。
#
# 超时给 30 秒而不是默认的 3：apt 要读几十兆的索引，慢是常态，
# 按 probe 的尺度会把一次正常查询判成「挂了」（同 OS_DEFAULT_SQL_TIMEOUT 的理由）。
# `-o Debug::NoLocking=true` 让它不去抢 dpkg 锁 —— 探测不该因为别人正在装包而卡住。
#
# 认 `-security`（Ubuntu 的 noble-security）与 `Debian-Security`，
# 两个发行版的源标签不同名。
#
# OS_PROBE_VALUE 是 `总数<TAB>安全更新数`（同 probe::ufw_rules 一类多值探测的
# 制表符约定）：`IFS=$'\t' read -r total security <<<"${OS_PROBE_VALUE}"`。
probe::apt_upgrade_stats() {
    probe::_probe 'apt.upgrade_sim' 30 \
        -- sh -c "apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep '^Inst ' || true"
    local lines=${OS_PROBE_VALUE}
    local -i total=0 security=0
    if [[ -n ${lines} ]]; then
        total=$(grep -c '' <<<"${lines}")
        security=$(grep -ciE '(-security|Debian-Security)' <<<"${lines}" || true)
    fi
    OS_PROBE_VALUE="${total}"$'\t'"${security}"
    return 0
}

# probe::auto_upgrades   APT::Periodic::Unattended-Upgrade 的生效值
#
# 自动安全更新开没开。值是 apt 配置里的次数（'1' = 每天），空或 '0' = 没开。
#
# 读 apt 自己的配置栈而不是去看某个文件在不在：`20auto-upgrades` 只是
# 惯例文件名，同一个键可以写在 apt.conf.d 下任何一个文件里。
probe::auto_upgrades() {
    probe::_probe 'apt.auto_upgrades' "${OS_DEFAULT_PROBE_TIMEOUT}" \
        -- apt-config dump --format '%v%n' APT::Periodic::Unattended-Upgrade
    return 0
}

# probe::reboot_required   是否需要重启，值为 yes / no
#
# 装完更新要不要重启。**这个标记文件是 Ubuntu 的东西**（update-notifier-common
# 创建），Debian 上默认没有，所以 Debian 上永远是 no —— 这是诚实的降级，
# 不是判断失误：Debian 要同等能力得装 needrestart 再解析它的输出，
# 而那是「为了一行提示引入一个依赖」。
probe::reboot_required() {
    probe::_probe 'os.reboot_required' 2 \
        -- sh -c "if [ -e /var/run/reboot-required ]; then echo yes; else echo no; fi"
    return 0
}

# probe::ufw_rules   ufw 带编号的规则列表原文
#
# 带编号的规则列表，删除前要原样展示给用户看。
#
# **只在 ufw 已启用时有内容**：未启用时 `ufw status numbered` 只打一行
# `Status: inactive`。要在两种状态下都读得到规则，用 probe::ufw_added_rules。
probe::ufw_rules() {
    probe::_probe 'ufw.rules' "${OS_DEFAULT_PROBE_TIMEOUT}" -- ufw status numbered
}

# probe::ufw_added_rules   已添加的规则原文，**停用状态下也读得到**
#
# `ufw status numbered` 在未启用时只打一行 `Status: inactive` —— 规则一条都
# 读不出来，而它们全都还在 /etc/ufw/user.rules 里。停用撤的是 netfilter 链，
# 不是规则本身（`ufw disable` 自己的措辞就是 "Firewall stopped"，不是 removed）。
# 拿 status 当规则表的话，用户停用防火墙之后回到面板会看到一份空清单，
# 与停用时那句「规则仍保留，重新启用即生效」正面冲突 —— 实测撞出来的。
#
# `ufw show added` 不受启用状态影响。代价是它**没有序号**，而且把 v4/v6
# 合并成一条显示（status numbered 里它们是分开编号的两条）。所以按序号删
# 仍然只能用 ufw_rules，这个探测的用途是「让用户看见规则还在、长什么样」。
probe::ufw_added_rules() {
    probe::_probe 'ufw.added_rules' "${OS_DEFAULT_PROBE_TIMEOUT}" -- ufw show added
}

# probe::container_subnets   两个引擎所有容器网络的网段，一行一个，已去重
#
# **给「让容器连上宿主的服务」用**：容器访问宿主的网关 IP 走的是 INPUT 链，
# 受 ufw 管（实测：未放行时 docker 与 podman 都连不通，加一条对应网段的
# allow 之后都通）。所以要放行的是**这些网段**，不是拍一个私有段。
#
# 旧脚本写死 `10.0.0.0/8`，那是整个私有 A 段：实测 podman 默认只用
# `10.88.0.0/16`（是它的六万五千分之一），而 docker 默认的 `172.17.0.0/16`
# **根本不在那个范围里** —— 那条规则既开得过宽，又对 docker 完全无效。
#
# 两个引擎的 inspect 字段名不同（docker 是 `.IPAM.Config[].Subnet`，
# podman 是 `.Subnets[].Subnet`），所以分别取。脚本文本是静态单引号，
# 值经内层 shell 自己的变量传递，不拼接。
#
# 超时给得比默认宽：网络多的机器上要逐个 inspect。
probe::container_subnets() {
    # 两个引擎走同一段循环，只有 inspect 的字段名不同（docker 是
    # `.IPAM.Config[].Subnet`，podman 是 `.Subnets[].Subnet`）。
    #
    # 引擎名走变量而不是各写一段：**probe.sh 不许出现行首直接调外部命令**
    # （tests/lib/probe.bats 有一条元测试守着，它认的就是「行首是 podman/df/ss…」），
    # 而两段复制粘贴的代码本来也该合成一段。
    # 内层变量写成 `\$x`（双引号 + 转义），与本文件其余各处一致 ——
    # 单引号写法会触发 SC2016，为它加 disable 就把棘轮顶上去了。
    probe::_probe 'container.subnets' "${OS_DEFAULT_SCAN_TIMEOUT}" -- sh -c "
        for eng in docker podman; do
            command -v \"\$eng\" >/dev/null 2>&1 || continue
            case \"\$eng\" in
                docker) fmt='{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}' ;;
                *) fmt='{{range .Subnets}}{{.Subnet}}{{println}}{{end}}' ;;
            esac
            \"\$eng\" network ls -q 2>/dev/null | while read -r net; do
                \"\$eng\" network inspect \"\$net\" --format \"\$fmt\" 2>/dev/null
            done
        done
    "

    # **按空白切分，不按行。** 非 root 走缓存时，snapshot_flush 已经把换行压成
    # 空格（本文件与 probe.bats 都写过这个坑）——按行切的话，缓存路径下多个网段
    # 会被糊成一个词，正则一条都匹配不上，而实时路径下看起来完全正常。
    # host / none 这类网络没有网段，会给出空词，正则自然滤掉。
    local tok out='' seen=''
    local IFS=$' \t\n'
    for tok in ${OS_PROBE_VALUE}; do
        [[ ${tok} =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || continue
        [[ ${seen} == *"|${tok}|"* ]] && continue
        seen+="|${tok}|"
        out+="${tok}"$'\n'
    done
    OS_PROBE_VALUE=${out%$'\n'}
    return 0
}

# probe::ufw_default_incoming   ufw 的默认入站策略，值为 deny / reject / allow / unknown
#
# **`ufw status` 不带 verbose 是看不到它的**，而它恰恰是「防火墙到底挡不挡得住
# 东西」的前提：默认 allow 时，一条端口规则都没有也照样全开。
probe::ufw_default_incoming() {
    probe::_probe 'ufw.default_incoming' "${OS_DEFAULT_PROBE_TIMEOUT}" -- ufw status verbose
    local out=${OS_PROBE_VALUE}
    OS_PROBE_VALUE='unknown'
    local line
    while IFS= read -r line; do
        [[ ${line} == *'Default:'* ]] || continue
        # 形如 `Default: deny (incoming), allow (outgoing), disabled (routed)`
        case ${line} in
            *'deny (incoming)'*) OS_PROBE_VALUE='deny' ;;
            *'reject (incoming)'*) OS_PROBE_VALUE='reject' ;;
            *'allow (incoming)'*) OS_PROBE_VALUE='allow' ;;
        esac
        break
    done <<<"${out}"
    return 0
}

# probe::ufw_port_guarded <端口>   该端口是否真的被防火墙挡着，值为 yes / no
#
# **这是一条安全判据，只写一份。** 从前 install_mariadb 自己写了一半
# （active + 没有 `Anywhere` 放行），install_valkey 干脆一句警告了事 ——
# 同一条规范（§15：放宽必须同步落实补偿控制）在两个脚本里两种执行力度。
#
# 三个条件缺一不可，而原来那半份漏了中间这条：
#   1. UFW 处于 active
#   2. **默认入站是 deny 或 reject** —— 默认 allow 时前后两条都没有意义
#   3. 没有把这个端口无条件放行给 Anywhere 的规则（v4 与 v6 都算）
#
# 限定过来源的规则（`From` 是具体 CIDR）不算「无条件放行」，照常放行。
probe::ufw_port_guarded() {
    local port=${1-}
    OS_PROBE_VALUE='no'
    [[ -n ${port} ]] || {
        OS_PROBE_STATUS='ok'
        return 0
    }

    # 三个内层 probe 各自会覆写 OS_PROBE_STATUS，所以本函数的状态在**最后**
    # 统一置位 —— 在开头置好会被内层调用覆盖掉，调用方读到的是 ufw_rules 的状态
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] || {
        OS_PROBE_VALUE='no'
        OS_PROBE_STATUS='ok'
        return 0
    }

    probe::ufw_default_incoming
    case ${OS_PROBE_VALUE} in
        deny | reject) ;;
        *)
            OS_PROBE_VALUE='no'
            OS_PROBE_STATUS='ok'
            return 0
            ;;
    esac

    probe::ufw_rules
    local rules=${OS_PROBE_VALUE} line
    while IFS= read -r line; do
        # `[ 1] 3306/tcp    ALLOW IN    Anywhere` / `… (v6)  ALLOW IN  Anywhere (v6)`
        if [[ ${line} =~ ^\[[[:space:]]*[0-9]+\][[:space:]]+${port}(/(tcp|udp))?([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+Anywhere ]]; then
            OS_PROBE_VALUE='no'
            OS_PROBE_STATUS='ok'
            return 0
        fi
    done <<<"${rules}"

    OS_PROBE_VALUE='yes'
    OS_PROBE_STATUS='ok'
    return 0
}

# probe::ufw_active   ufw 是否已启用，值为 yes / no
probe::ufw_active() {
    probe::_probe 'ufw.status' "${OS_DEFAULT_PROBE_TIMEOUT}" -- ufw status
    if [[ ${OS_PROBE_VALUE} == *'Status: active'* ]]; then
        OS_PROBE_VALUE='yes'
    else
        OS_PROBE_VALUE='no'
    fi
    return 0
}
