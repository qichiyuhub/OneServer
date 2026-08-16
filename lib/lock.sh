# lib/lock.sh —— L2 基础设施层：flock 并发控制
#
# 只依赖 L0 与 L1。**不依赖同层的 errors.sh** —— 锁的释放不走 trap，
# 见下面「为什么不需要 trap」。
#
# **单一全局锁**，不分域（D27）：apt 本就被 dpkg 串行化、podman 有自己的锁，
# 分域只会引入锁顺序与死锁风险，换不来任何并行度。
#
# 锁文件在 $OS_RUN_DIR，**不在 /tmp**（D23 / K5）：root 进程用 `>` 打开 /tmp 下的
# 路径会跟随符号链接，本地用户预置一条软链就能让 root 截断任意文件。

OS_LOCK_HELD=0
OS_LOCK__FD=''

# os::lock_acquire [--try] [超时秒]
#
# `--try`：取不到锁**返回 1**，不打印、不写错误日志、不退出。给 `root-trylock`
# 用（规范 §6）——那类命令是周期性的，锁被占是预期内的正常情形，把它记成失败
# 会让「用户正在菜单里操作」变成每一轮一条错误日志。没有 `--try` 时行为不变：
# 取不到锁就报告持锁者并以 5 终止。
#
# 取不到锁以退出码 5 终止，并提示持锁的 PID / 命令 / 起始时间 ——
# 「另一个实例正在运行」而不告诉是哪个，用户除了等没有别的办法。
#
# **为什么不需要 trap 释放**：flock 锁在打开的文件描述符上，进程一退出内核就
# 自动释放。靠 trap 释放反而更脆——kill -9 打不到 trap，锁就永远留着了。
# 「持锁进程已死时自动接管」因此是免费的，不是我们实现的。
#
# **一个必须说清的边界**：这个 fd 会被子进程继承。持锁进程被 kill -9 时，
# 如果它还有活着的子进程（比如正在跑的 `apt-get install`），锁**仍然被持有**，
# 直到那个子进程也结束。
#
# 这是对的，不是缺陷：父进程死了不代表 apt 停了。此时若放开锁，另一个实例会
# 立刻并发去动 dpkg —— 正是这把锁要防的事。只有「持锁进程连同它的子进程都没了」
# 才会自动接管。测试里两种情形都锁住了。
os::lock_acquire() {
    local -i try=0
    if [[ ${1-} == --try ]]; then
        try=1
        shift
    fi
    local -i timeout=${1:-${OS_DEFAULT_LOCK_WAIT}}

    if [[ ${OS_LOCK_HELD} -eq 1 ]]; then
        return 0
    fi

    if ! command -v flock >/dev/null 2>&1; then
        ui::line error "缺少 flock（util-linux），无法保证并发安全"
        log::exit_code error "缺少 flock" 3
        exit 3
    fi

    if ! mkdir -p "${OS_RUN_DIR}" 2>/dev/null; then
        ui::line error "无法创建 ${OS_RUN_DIR}"
        log::exit_code error "无法创建 ${OS_RUN_DIR}" 4
        exit 4
    fi
    chmod "${OS_RUN_DIR_MODE}" "${OS_RUN_DIR}" 2>/dev/null || true

    # 用 >> 打开：`>` 会在拿到锁之前就把持锁者写的信息截掉，
    # 而那正是取锁失败时唯一能告诉用户的东西。
    if ! exec {OS_LOCK__FD}>>"${OS_LOCK_FILE}"; then
        ui::line error "无法打开锁文件 ${OS_LOCK_FILE}"
        log::exit_code error "无法打开锁文件" 4
        exit 4
    fi

    if ! flock -w "${timeout}" "${OS_LOCK__FD}" 2>/dev/null; then
        if [[ ${try} -eq 1 ]]; then
            # fd 要关掉：调用方多半会继续跑（或退出），留着一个指向锁文件的
            # 描述符会被子进程继承，而那正是「进程都退了锁还被持着」的成因
            exec {OS_LOCK__FD}>&-
            OS_LOCK__FD=''
            return 1
        fi
        os::lock_report_holder
        log::exit_code error "获取锁失败，等待 ${timeout} 秒超时" 5
        exit 5
    fi

    OS_LOCK_HELD=1
    os::lock__write_holder
    log::write debug "已取得全局锁 ${OS_LOCK_FILE}" framework
    return 0
}

# 写入持锁者信息。此刻锁在手上，用 `>` 截断不会和别的 OneServer 进程打架；
# 目录是我们自己以 0750 建的 root 目录，K5 的软链风险在这里不成立。
os::lock__write_holder() {
    local cmdline=${OS_LOG_COMMAND:-oneserver}
    local ts
    # 同 log::_now：本地时间就别标 Z
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    printf 'pid=%d\ncommand=%s\nstarted=%s\n' "$$" "${cmdline}" "${ts}" \
        2>/dev/null >"${OS_LOCK_FILE}" || true
    return 0
}

# os::lock_report_holder   打印当前持锁者的 PID、命令与起始时间
#
# 取锁失败时把持锁者报出来
os::lock_report_holder() {
    local pid='' command='' started=''
    if [[ -r ${OS_LOCK_FILE} ]]; then
        while IFS='=' read -r k v; do
            case ${k} in
                pid) pid=${v} ;;
                command) command=${v} ;;
                started) started=${v} ;;
            esac
        done <"${OS_LOCK_FILE}"
    fi

    ui::line error "另一个 OneServer 实例正在运行，无法取得全局锁"
    if [[ -n ${pid} ]]; then
        ui::line --err muted "    持锁进程 PID ${pid}"
        ui::line --err muted "    命令       ${command:-未知}"
        ui::line --err muted "    开始时间   ${started:-未知}"
        ui::line --err muted "    查看详情   ps -p ${pid} -o pid,etime,cmd"
    else
        ui::line --err muted "    锁文件 ${OS_LOCK_FILE} 里没有持锁者信息"
    fi
    return 0
}

# os::lock_release   通常用不上（进程退出即释放），留给菜单这类长驻进程
os::lock_release() {
    if [[ ${OS_LOCK_HELD} -ne 1 ]]; then
        return 0
    fi
    flock -u "${OS_LOCK__FD}" 2>/dev/null || true
    exec {OS_LOCK__FD}>&- 2>/dev/null || true
    OS_LOCK_HELD=0
    OS_LOCK__FD=''
    return 0
}
