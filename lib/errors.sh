# lib/errors.sh —— L2 基础设施层：ERR trap · 回滚栈 · 中断语义
#
# 只依赖 L0 与 L1（ui.sh 出屏、log.sh 落盘）。**不依赖同层的 lock.sh。**
#
# 三件事：
#   1. 副作用三分类—— 由脚本作者强制表态，框架不替他猜
#   2. 失败输出三段到 stderr—— 调用栈只进日志，不上屏
#   3. 中断语义—— 收到信号**不跑回滚栈**，打变更清单，退出码 131
#
# 全文件无 `eval`。回滚栈用「扁平参数数组 + 长度数组」重建命令，
# 规范的两处 eval 白名单都用不上。

# --- 回滚栈：必须回滚的那一类 ---
#
# bash 没有数组的数组。存成一条扁平参数序列 + 一条长度序列，
# 回放时按长度反向切片。比 printf %q 存字符串再 eval 安全，也比自造分隔符可靠
# （分隔符总会有一天出现在参数里）。
OS_ERR__DEFER_ARGS=()
OS_ERR__DEFER_LEN=()

# --- 变更清单：禁止自动回滚的那一类 ---
OS_ERR__CHANGES=()

# --- 本次执行已经备份过的文件，防止同一个文件落好几份副本 ---
OS_ERR__BACKED_UP=()

# --- 状态 ---
OS_ERR__FAILED=0
OS_ERR__FAIL_CODE=0
OS_ERR__FAIL_CMD=''
OS_ERR__FAIL_LINE=0
OS_ERR__SIGNALED=0
OS_ERR__ROLLED_BACK=()
OS_ERR__ROLLBACK_FAILED=()

# 不可中断区段：支持嵌套，计数归零时才处理挂起的信号
OS_ERR__CRITICAL=0
OS_ERR__CRITICAL_DESC=''
OS_ERR__PENDING_SIGNAL=''

# ==================================================================
# 副作用三分类 ——规范
# ==================================================================

# os::defer <命令> [参数...]
#
# 「必须回滚」类：本次创建、可安全撤销。失败时逆序自动执行。
os::defer() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi
    OS_ERR__DEFER_LEN+=("$#")
    OS_ERR__DEFER_ARGS+=("$@")
    # 同 errors::run_rollback：`$*` 按 IFS 连接，脚本层的 IFS 是 $'\n\t'（D91）
    local IFS=' '
    log::write debug "注册回滚：$*" framework
    return 0
}

# os::commit
#
# 「到此为止的副作用已经全部落地，撤销清单作废。」
#
# 框架其余部分建立在「一个进程 = 一次动作」上：回滚栈随进程结束消失，
# 所以没人需要作废它。`os::action_menu` 打破了这个前提 —— 它在**同一个进程里**
# 连着跑好几个动作，而回滚栈是进程级的。于是「配令牌」成功注册的那几条撤销项
# 会一直躺到「换配置」失败的那一刻，被当成本次动作的一部分回放掉：用户眼睁睁
# 看着刚配好的令牌、环境文件、systemd drop-in 被一次不相干的失败连坐删除，
# 而屏幕上只说「应用新配置失败」。
#
# 只作废「必须回滚」类，**不动变更清单**：撤销是动作，多做一次是破坏；
# 变更清单是告知，中断时用户想知道的是这个进程里发生过的全部事情。
#
# 已备份清单一并清掉。它防的是「同一次执行里同一个文件落好几份副本」，
# 而下一个动作再改同一个文件时，进程启动时的那份原件已经不是回滚目标了 ——
# 不清的话第二个动作改配置将完全没有备份可回滚。
os::commit() {
    OS_ERR__DEFER_ARGS=()
    OS_ERR__DEFER_LEN=()
    OS_ERR__BACKED_UP=()
    return 0
}

# os::record_change <描述>
#
# 「禁止自动回滚」类：可能是用户既有资产（apt 装的包、系统服务、内核参数）。
# **不注册回滚**，只记进清单，失败时打印出来由人判断。
#
# 回滚动作本身也是副作用：apt 装了 redis，回滚要不要卸载？
# 若用户机器上本来就有 redis，回滚比不回滚破坏更大。
os::record_change() {
    OS_ERR__CHANGES+=("${1-}")
    log::write debug "记录变更：${1-}" framework
    return 0
}

# os::backup_file <路径>
#
# 「先备份再改」类：覆盖不可重建的文件之前先存副本，回滚 = 还原副本。
# 文件不存在时是空操作（第一次写不算覆盖）。
os::backup_file() {
    local path=${1-}
    if [[ -z ${path} || ! -f ${path} ]]; then
        return 0
    fi
    # **同一次执行里同一个文件只备份一次。**
    # 回滚的目标是「进程启动时的那份」，第二次备份存的已经是自己刚写出来的东西 ——
    # 既没有回滚价值，又让 /var/backups 每跑一次涨一份。
    # 一个改三行的脚本本来会落三份一模一样的副本。
    local done_path
    for done_path in ${OS_ERR__BACKED_UP[@]+"${OS_ERR__BACKED_UP[@]}"}; do
        [[ ${done_path} == "${path}" ]] && return 0
    done
    # dry-run **禁止对系统产生任何变更**，包括创建目录与写文件。
    # 备份是副本没错，但它照样在 $OS_BACKUP_DIR 里留下东西 —— 预演跑完之后
    # 磁盘上多出一堆谁也不认识的副本，正是这条要防的。
    # 也不注册回滚：没备成的东西没什么可还原。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        # 预演里也登记「已备份过」，否则改三行配置的脚本会打三遍
        # 「将备份 xxx」，而实际只会备份一份 —— 预演多报也是报不准
        OS_ERR__BACKED_UP+=("${path}")
        ui::line muted "[dry-run] 将备份 ${path}"
        log::write info "[dry-run] 跳过备份：${path}" framework
        return 0
    fi
    local dir="${OS_BACKUP_DIR}/files"
    if ! mkdir -p "${dir}" 2>/dev/null; then
        errors::_stderr error "无法创建备份目录 ${dir}"
        return 1
    fi
    chmod "${OS_BACKUP_DIR_MODE}" "${OS_BACKUP_DIR}" 2>/dev/null || true

    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local flat=${path//\//_}
    local bak="${dir}/${ts}${flat}"
    if ! cp -a -- "${path}" "${bak}" 2>/dev/null; then
        errors::_stderr error "无法备份 ${path}"
        return 1
    fi
    OS_ERR__BACKED_UP+=("${path}")
    log::write info "已备份 ${path} → ${bak}" framework
    os::defer errors::_restore_file "${bak}" "${path}"
    return 0
}

# errors::_restore_file <副本> <目标>   换 inode 还原（临时文件 + mv）
#
# 临时文件名走 mktemp 不拼 `$$`：目标目录可能非 root 可写（站点根、
# /etc/caddy/incoming），而 PID 可以喷洒预置成符号链接，`cp` 会跟过去以 root
# 覆写它。mktemp 走 O_EXCL，路径已存在就失败。
errors::_restore_file() {
    local bak=${1} target=${2}
    local tmp
    tmp=$(mktemp "${target}.os-restore.XXXXXXXX" 2>/dev/null) || return 1
    if cp -a -- "${bak}" "${tmp}" 2>/dev/null && mv -f -- "${tmp}" "${target}" 2>/dev/null; then
        return 0
    fi
    rm -f -- "${tmp}" 2>/dev/null || true
    return 1
}

# ==================================================================
# os::replace_line —— 替换文件必须换 inode
# ==================================================================
#
#   os::replace_line [--append-if-missing] [--backup] <文件> <正则> <新行>
#
# 骨架模板里一直在用它，而它此前并不存在 —— 骨架是所有脚本的
# 抄写源头，第一个照着抄的人就会撞上。
#
# 四条硬性行为：
#
#   * **写临时文件 + `mv` 换 inode**，禁止 `sed -i` 与 `>` 就地截断。
#     GNU sed 的 `-i` 也是「写新文件再 rename」，但它 rename 的对象在
#     `/tmp` 之外的行为随版本而变，而 bash 正在读的脚本文件被就地截断
#     会让解释器以 root 执行错乱字节（K13）。自己写才说得清。
#   * **临时文件必须与目标同目录**：跨文件系统的 `mv` 是「复制 + 删除」，
#     不是原子替换。放 `os::tmpdir`（tmpfs）反而破坏了这条保证。
#   * **权限与属主随原文件走**。新 inode 默认按 umask 建，
#     一个 0600 的文件替换完会变成 0640 —— 悄悄地降了一级。
#   * **整段在不可中断区段内**：写到一半被 Ctrl-C 打断，
#     配置文件就成了半截。
#
# 匹配到多行时**全部**替换成同一行。看着浪费，但对「最后一条生效」
# （redis）与「第一条生效」（sshd）两种语义都是对的；只改第一条会在前者
# 留下一条仍然生效的旧行 —— 那正是要改掉的那一行。
#
# 一行都没匹配到时**默认报错返回 1**，不悄悄追加：正则写错了却往配置文件
# 末尾塞一行，比什么都不做更难查。确实要追加就显式写 --append-if-missing。
#
# **调用后读 `OS_REPLACE_CHANGED` 知道这次到底写没写**（同 `OS_TEMPLATE_CHANGED`）。
# 没有它，「配置没变就不重启服务」就只能靠脚本自己再读一遍文件比对 ——
# 而那份比对逻辑与这里的比对逻辑迟早会分叉，分叉的表现是每次执行都重启一次服务。
# 返回值不背这个信息：0 已经表示「成功」，让它同时表示「改了」会把
# 「已是目标状态」变成非零。
OS_REPLACE_CHANGED=0

# os::replace_line [--append-if-missing] [--backup] <文件> <正则> <新行>   按正则整行替换，是否写入见 OS_REPLACE_CHANGED
os::replace_line() {
    OS_REPLACE_CHANGED=0
    local append=0 backup=0
    while [[ ${1-} == --* ]]; do
        case ${1} in
            --append-if-missing) append=1 ;;
            --backup) backup=1 ;;
            *)
                errors::_stderr error "os::replace_line：不认识的选项 ${1}"
                return 2
                ;;
        esac
        shift
    done
    local file=${1-} re=${2-} new=${3-}
    if [[ -z ${file} || -z ${re} ]]; then
        errors::_stderr error "os::replace_line 用法：[--append-if-missing] <文件> <正则> <新行>"
        return 2
    fi
    if [[ ! -f ${file} ]]; then
        errors::_stderr error "os::replace_line：文件不存在 ${file}"
        return 1
    fi

    local line
    local -a out=()
    local -i hits=0 changed=0
    while IFS= read -r line || [[ -n ${line} ]]; do
        if [[ ${line} =~ ${re} ]]; then
            hits+=1
            if [[ ${line} != "${new}" ]]; then
                changed=1
            fi
            out+=("${new}")
        else
            out+=("${line}")
        fi
    done <"${file}"

    if ((hits == 0)); then
        if ((append == 0)); then
            errors::_stderr error "os::replace_line：${file} 里没有匹配 ${re} 的行"
            return 1
        fi
        out+=("${new}")
        changed=1
    fi

    # 已是目标状态就不写（第二次执行禁止产生任何新的变更）
    if ((changed == 0)); then
        log::write info "已是目标状态，未改动 ${file}" framework
        return 0
    fi

    # `--backup` **只在内容确实要变时才落副本**（同 os::install_template）。
    # 无条件备份的写法会让「第二次执行零变更」变成「第二次执行多一份副本」——
    # 那也是变更，只是变在 /var/backups 里没人看见。
    # 同一个文件在一次执行里只真备份一次，所以三行配置各写一次 --backup
    # 也只落一份（见 os::backup_file）。
    if [[ ${backup} -eq 1 ]]; then
        os::backup_file "${file}" || return 1
    fi

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        # 预览要过脱敏。**屏幕不在规范那张「禁止写入」的表里，但它一样会进
        # 滚动缓冲、进录屏、进贴到群里的截图。** 落盘那条路由 log::write 自己
        # 兜着，这条是唯一直接打到终端的，漏在这里就等于没做脱敏。
        # 典型现场：`requirepass <明文>` 在 `--dry-run` 下原样打了出来。
        log::redact "[dry-run] 将改写 ${file}：${new}"
        ui::line muted "${OS_LOG__REDACTED}"
        log::write info "[dry-run] 跳过改写：${file}" framework
        # 预演里也置 1：调用方拿它决定「要不要重启服务」，置 0 的话
        # dry-run 会漏报重启这一步，而漏报正是规范说的「会撒谎的 dry-run」。
        # 真正的重启由 os::run 在 dry-run 下自己跳过，这里不必替它操心。
        OS_REPLACE_CHANGED=1
        return 0
    fi

    # 临时文件名走 mktemp（同 errors::_restore_file）：`$$` 可被预置成符号链接
    local tmp
    if ! tmp=$(mktemp "${file}.os-replace.XXXXXXXX" 2>/dev/null); then
        errors::_stderr error "无法在 ${file%/*} 下创建临时文件"
        return 1
    fi
    local -i rc=0
    os::critical_begin "原子替换 ${file}"
    if ! printf '%s\n' ${out[@]+"${out[@]}"} 2>/dev/null >"${tmp}"; then
        rc=1
    fi
    if [[ ${rc} -eq 0 ]]; then
        chmod --reference="${file}" -- "${tmp}" 2>/dev/null || true
        chown --reference="${file}" -- "${tmp}" 2>/dev/null || true
        if ! mv -f -- "${tmp}" "${file}" 2>/dev/null; then
            rc=1
        fi
    fi
    if [[ ${rc} -ne 0 ]]; then
        rm -f -- "${tmp}" 2>/dev/null || true
    fi
    os::critical_end

    if [[ ${rc} -ne 0 ]]; then
        errors::_stderr error "写入 ${file} 失败"
        return 1
    fi
    # shellcheck disable=SC2034  # 理由：本模块的输出变量，由脚本层读（决定要不要重启服务）
    OS_REPLACE_CHANGED=1
    # **不记 `${new}`。** 这个函数改的正是 `requirepass <口令>` /
    # `define( 'DB_PASSWORD', '<口令>' )` 这类行，把整行写进日志等于把凭据写进
    # $OS_LOG_JSONL —— 而 JSONL 会被采集器发布到 0755 的 $OS_PUBLIC_DIR 并由
    # 只读面板对外提供。指望脱敏表兜住是不够的：它按值匹配，短于
    # OS_SECRET_MIN_LEN 的值根本登记不进去，而存量凭据里就有这种值。
    # 排查需要的是「哪个文件的哪条规则被改了几行」，不是新值本身。
    log::write info "已改写 ${file}（匹配 ${hits} 行）" framework
    return 0
}

# ==================================================================
# 临时目录 —— 必须用 os::tmpdir，自动清理
# ==================================================================
#
# 放在 errors.sh 而不是 exec.sh：清理要挂在退出路径上，而退出路径（EXIT trap）
# 归这个文件管。放别处就得再装一个 EXIT trap，两个 trap 会互相覆盖。
#
# 与 os::defer 的区别：defer 只在**失败**时回放，临时目录成功也要删。

OS_ERR__TMPDIRS=()

# os::tmpdir <变量名> [--exec]   新建 0700 临时目录，路径写进变量，退出时自动清理
#
# **路径经变量交回，不打印。** 这个函数有一件事必须留在调用方的进程里：把新目录
# 登记进 OS_ERR__TMPDIRS，退出路径才删得掉它。`d=$(os::tmpdir)` 会 fork 一个子
# shell，目录**真的建出来了**，登记却只发生在那个转瞬即逝的子 shell 里 —— 父进程
# 的清理列表始终是空的。表现不是报错：每调用一次泄漏一个目录，而清理代码看起来
# 一直在跑。被 SIGKILL 打断时目录会留在磁盘上，靠 `oneserver clean` 的孤儿扫描收。
#
# 落点**只有一条**，在磁盘上（$OS_TMP_ROOT，理由见 paths.sh 与 D244）。从前
# 分两条：默认落 /run 的 tmpfs，`--exec` 才走磁盘。tmpfs 那条撤了 —— 它买的
# 保护是象征性的（凭据真身明文躺在 secure.conf 上，且 tmpfs 会被换出到 swap），
# 换来的却是 104 MB 的天花板，WordPress 解包、备份暂存都塞不下。
#
# **`--exec` 保留，含义收窄成「验证这个目录真的能执行」**：给 /tmp 与 /var/tmp
# 挂 noexec 是常见的加固手段，那时 chmod +x 之后 exec 仍然 Permission denied
# （退出码 126），而现场表现是「下载的二进制跑不起来」—— 文件完好、体积正确、
# ELF 魔数也对，就是跑不了，一眼看不出跟挂载选项有关。更新切换器正是靠这条
# 通道投递的（见 update.sh 的注释），它断了等于安全修复发不出去。
#
# **不无条件做这个验证**：加固过的机器上 /var/tmp 就是 noexec，那时只有真正
# 要执行东西的调用该失败，其余的照常可用 —— 无条件验证会让整个工具在那种
# 机器上全线失效。
#
# **仍然要注意落点在哪个文件系统上**：这里给的是 /var/tmp，而解包出来要 mv 到
# /var/www 或 /usr/local 的东西，跨设备 mv 是复制加删除，既不原子又要双份空间。
# 那类场景应当直接在**目标所在的文件系统**上开暂存目录（见 install_nodejs.sh 的
# `.staging.$$` 与 deploy_wordpress.sh 的 `.oneserver-wp.$$`），这个函数管不了。
os::tmpdir() {
    # 内部名一律带 __os_ 前缀：输出变量靠动态作用域写回，调用方最自然的
    # `local dir; os::tmpdir dir` 会被同名局部变量截住（同 os::state_health）
    local __os_td_out=${1-}
    if [[ ! ${__os_td_out} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        errors::_stderr error 'os::tmpdir 用法：<变量名> [--exec]'
        return 2
    fi
    shift

    local -i __os_td_want_exec=0
    if [[ ${1-} == '--exec' ]]; then
        __os_td_want_exec=1
        shift
    fi

    local __os_td_root=${OS_TMP_ROOT}

    if ! mkdir -p "${__os_td_root}" 2>/dev/null; then
        errors::_stderr error "无法创建临时目录根 ${__os_td_root}"
        return 1
    fi

    # 属主校验，且必须在 chmod 之前判断（K5 同类）：`mkdir -p` 见目录已存在
    # 就成功返回，不会告诉调用方它是不是本次创建的。`--exec` 落在 /var/tmp，
    # 全局可写、带 sticky 位——本地非特权用户能在 root 第一次用到这个路径
    # 之前抢先建好它。之后不管我们把 mode 改成什么，属主仍是攻击者，随时能
    # 改回可写并劫持里面 mktemp 建出的目录（比如换成指向别处的符号链接，
    # 而这个目录里发生的正是 chmod +x 后以 root 执行下载的二进制）。
    # 因此**不 chown 抢过来**——那是在给攻击者控制的目录换主人，不解决问题，
    # 只能拒绝并要求人工确认。
    local __os_td_owner
    __os_td_owner=$(stat -c '%u' "${__os_td_root}" 2>/dev/null) || __os_td_owner=''
    if [[ ${__os_td_owner} != '0' ]]; then
        errors::_stderr error "${__os_td_root} 属主不是 root（可能已被本地用户预置），拒绝使用；请人工确认后清理该目录"
        return 1
    fi
    chmod 0700 "${__os_td_root}" 2>/dev/null || true
    local __os_td_d
    if ! __os_td_d=$(mktemp -d "${__os_td_root}/os.XXXXXXXX" 2>/dev/null); then
        errors::_stderr error "无法创建临时目录"
        return 1
    fi
    chmod 0700 "${__os_td_d}" 2>/dev/null || true

    # 当场验一次能不能执行，而不是等调用方跑那个几十 MB 的二进制时才失败：
    # 那时的报错是「二进制跑不起来」，指向的是文件，真因却在挂载选项上
    if ((__os_td_want_exec == 1)); then
        local __os_td_probe="${__os_td_d}/.execcheck"
        printf '#!/bin/sh\nexit 0\n' >"${__os_td_probe}" 2>/dev/null || true
        chmod 0700 "${__os_td_probe}" 2>/dev/null || true
        if ! "${__os_td_probe}" >/dev/null 2>&1; then
            rm -rf -- "${__os_td_d}" 2>/dev/null || true
            errors::_stderr error "${__os_td_root} 所在的文件系统禁止执行（noexec），放不下需要现场运行的二进制"
            return 1
        fi
        rm -f -- "${__os_td_probe}" 2>/dev/null || true
    fi

    OS_ERR__TMPDIRS+=("${__os_td_d}")
    printf -v "${__os_td_out}" '%s' "${__os_td_d}"
    return 0
}

errors::_clean_tmpdirs() {
    local d
    for d in ${OS_ERR__TMPDIRS[@]+"${OS_ERR__TMPDIRS[@]}"}; do
        # 只有一个根要认了（D244 之前是两个：tmpfs 一个、磁盘一个）
        [[ -n ${d} ]] || continue
        [[ ${d} == "${OS_TMP_ROOT}"/* ]] || continue
        rm -rf -- "${d}" 2>/dev/null || true
    done
    OS_ERR__TMPDIRS=()
    return 0
}

# ==================================================================
# 不可中断区段 ——规范
# ==================================================================

# os::critical_begin <描述>   进入不可中断区段，区段内的信号记录并延后
os::critical_begin() {
    OS_ERR__CRITICAL=$((OS_ERR__CRITICAL + 1))
    if [[ ${OS_ERR__CRITICAL} -eq 1 ]]; then
        OS_ERR__CRITICAL_DESC=${1-}
        log::write debug "进入不可中断区段：${OS_ERR__CRITICAL_DESC}" framework
    fi
    return 0
}

# os::critical_end   离开不可中断区段，可嵌套
os::critical_end() {
    if [[ ${OS_ERR__CRITICAL} -gt 0 ]]; then
        OS_ERR__CRITICAL=$((OS_ERR__CRITICAL - 1))
    fi
    if [[ ${OS_ERR__CRITICAL} -ne 0 ]]; then
        return 0
    fi
    log::write debug "离开不可中断区段：${OS_ERR__CRITICAL_DESC}" framework
    OS_ERR__CRITICAL_DESC=''
    # 区段内挂起的信号，到这里才处理
    if [[ -n ${OS_ERR__PENDING_SIGNAL} ]]; then
        local sig=${OS_ERR__PENDING_SIGNAL}
        OS_ERR__PENDING_SIGNAL=''
        errors::on_signal "${sig}"
    fi
    return 0
}

# ==================================================================
# 输出 —— 只经 ui.sh，绝不自己拼转义序列
# ==================================================================

# 失败报告与中断报告**整段**走 stderr，
# 不能只让 error/warn 那几行走。`muted` 样式默认去向是 stdout（D57），
# 报告里的明细行若跟着走 stdout，`cmd 2>/dev/null` 就会把「出了什么事」
# 留在屏幕上、把「已撤销了什么」冲掉——正好反了。这里显式 --err。
errors::_stderr() {
    ui::line --err "${1}" "${2-}"
    return 0
}

# ==================================================================
# trap 处理
# ==================================================================

errors::install() {
    trap 'errors::on_error $? ${LINENO} "${BASH_COMMAND}"' ERR
    trap 'errors::on_exit $?' EXIT
    trap 'errors::on_signal INT' INT
    trap 'errors::on_signal TERM' TERM
    trap 'errors::on_signal HUP' HUP
    return 0
}

# errors::on_error <退出码> <行号> <命令>
errors::on_error() {
    # 只认第一现场：后续连锁失败的行号会盖掉真正出问题的那一行
    if [[ ${OS_ERR__FAILED} -eq 1 ]]; then
        return 0
    fi
    OS_ERR__FAILED=1
    OS_ERR__FAIL_CODE=${1:-1}
    OS_ERR__FAIL_LINE=${2:-0}
    OS_ERR__FAIL_CMD=${3-}
    log::write error "命令失败：${OS_ERR__FAIL_CMD}（第 ${OS_ERR__FAIL_LINE} 行，退出码 ${OS_ERR__FAIL_CODE}）" framework

    # `return "${rc}"` 只是把失败往上带，不是失败点本身。**bash 的 ERR 只在
    # 最内层触发一次**（实测：调用点不会再触发），所以框架里那些「接住退出码
    # 再 return」的函数会让这里抓到自己的源码，屏幕上就成了
    # 「执行失败：return "${rc}"」。真正的失败已由 exec::_announce_failure
    # 按 desc 报过，这里对用户留空即可 —— 呈现层对空值有兜底。
    # 日志里那句在上面已经落过，排查时仍拿得到原文与行号。
    if [[ ${OS_ERR__FAIL_CMD} == 'return' || ${OS_ERR__FAIL_CMD} == return[[:space:]]* ]]; then
        OS_ERR__FAIL_CMD=''
    fi
    errors::_log_stack
    return 0
}

# 调用栈只进日志，不上屏 —— 终端上该出现的是「出了什么事 / 下一步敲什么」，
# 而不是给写 bash 的人看的 FUNCNAME 列表。
errors::_log_stack() {
    local -i i
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
        log::write debug "  栈 #${i} ${FUNCNAME[i]}() 于 ${BASH_SOURCE[i]:-?}:${BASH_LINENO[i - 1]}" framework
    done
    return 0
}

# errors::on_signal <信号名>
errors::on_signal() {
    local sig=${1:-INT}

    # 区段内：记录并延后，不在这里退出
    if [[ ${OS_ERR__CRITICAL} -gt 0 ]]; then
        OS_ERR__PENDING_SIGNAL=${sig}
        log::write warn "收到 ${sig}，当前处于不可中断区段（${OS_ERR__CRITICAL_DESC}），延后处理" framework
        errors::_stderr warn "收到 ${sig}，正在完成「${OS_ERR__CRITICAL_DESC}」后再退出…"
        return 0
    fi

    OS_ERR__SIGNALED=1
    # **INT 不是异常**：它只有一个来源 —— 操作者在终端按了 Ctrl-C，和已经记成
    # info 的「用户取消」（130）是同一类事，级别理应一致。记成 warn 的后果不是
    # 多一行日志，是面板的「最近异常」被自己按的 Ctrl-C 刷满，真异常反而没人看。
    # HUP / TERM 保持 warn：那是外力打断（SSH 断线、kill、关机），操作者可能
    # 根本不在场，也不知道停在了哪一步 —— 那正是需要有人看一眼的情况。
    local lv=warn
    [[ ${sig} == INT ]] && lv=info
    log::exit_code "${lv}" "被信号 ${sig} 打断" 131

    errors::_stderr error "被 ${sig} 打断，已停止执行"
    # **不跑回滚栈**：中断点的系统状态未知，此时执行回滚动作很可能加重破坏。
    # 真实 VPS 上最常见的失败是「apt 装到一半 SSH 断了」——在 dpkg 锁仍被
    # 持有的系统上执行回滚，比什么都不做糟糕得多。
    errors::_print_changes "以下变更**已经发生**，状态未知，请人工确认"
    # 临时目录里可能躺着 0600 的凭据文件，任何退出路径都要清
    errors::_clean_tmpdirs
    exit 131
}

# errors::on_exit <退出码>
errors::on_exit() {
    local -i raw_code=${1:-0} code=${1:-0}
    trap - EXIT

    # 外部命令的 rc 要原样留给 os::run / os::query 的调用方判断，但脚本进程的
    # 对外退出码只能来自规范 §8 的集合。脚本把一次 `os::run` 留作最后一条命令
    # 时，bash 会把 curl/grep/timeout 的 7、100、124 等原始码直接带到进程出口；
    # 这里是所有退出路径唯一汇合点，只在此把未知失败归为「一般失败」1。
    case ${code} in
        0 | 1 | 2 | 3 | 4 | 5 | 130 | 131) ;;
        *)
            log::write error "外部退出码 ${code} 已归一为 OneServer 退出码 1" framework
            code=1
            ;;
    esac

    # 上面那张表只拦**不在 §8 集合里**的码，而外部命令的退出码完全可能正好撞上
    # 集合里的一个：tar 用 2 表示 fatal error、`systemctl is-active` 用 3 表示
    # 服务没在跑、grep 用 1 表示没匹配。撞上 2/3/4 的那些会一路穿到进程出口，
    # 而框架据此认定「前置检查拦下的，什么都没做」，于是**回滚一条都不回放**。
    #
    # 真机上的形态：WordPress 解包因 /run 装不下而失败（tar 以 2 退出），
    # 库和账号却留在机器上，下一次部署被自己的「账号已存在但库不存在」检查挡住，
    # 用户手里只剩一个要手工 DROP USER 才能解开的死局，而他并不知道那个账号
    # 是上一次失败留下的。
    #
    # **判据用变更清单，不用「有没有经过 os::die」**：`lock.sh` 与 `secure.sh`
    # 里还有若干合法的 `exit 3/4`，它们不经过 os::die，靠调用路径区分要改动
    # 每一处。而 §8 给 2/3/4 写的系统状态就是「未变更」—— 清单非空本身就是
    # 这个码与事实矛盾的证明，判据比来源可靠。
    #
    # 归一成 1 之后什么都不用再写：1 的处理路径（回滚 + 失败报告 + 变更清单）
    # 正是这种情形该走的那条。
    #
    # **dry-run 下不成立**：预演里 os::run 一条都没真跑，而 os::record_change
    # 照记不误（清单在那时表达的是「将会发生什么」）。拿它当「已经改了东西」
    # 的证据会把一次正常的「预演时参数打错了」也说成执行失败。
    if ((OS_DRYRUN != 1)) \
        && [[ ${code} -eq 2 || ${code} -eq 3 || ${code} -eq 4 ]] \
        && ((${#OS_ERR__CHANGES[@]} > 0)); then
        log::write error \
            "退出码 ${code} 声称未变更，但变更清单里有 ${#OS_ERR__CHANGES[@]} 项，已归一为 1 并按失败处理" framework
        # **也要上屏**，与 130 那条同样的理由：这是脚本写错了退出码，而只写进
        # 日志的话没有人会去看。下面的失败报告会接着打变更清单与回滚结果。
        errors::_stderr warn \
            "退出码 ${code} 表示未变更，但已经记录到变更——多半是某个 os::run 的失败没转成 os::die 1，被调命令的退出码直接漏了出来"
        code=1
    fi

    # 装配层可以定义 os::__on_exit_hook 来做收尾（落 probe 快照、把 unit 写进
    # state）。这不是对 L4 的依赖：这里只检查「有没有这个函数」，不知道也不关心
    # 谁定义了它。装第二个 EXIT trap 会把这个覆盖掉，所以必须留成钩子。
    if declare -F os::__on_exit_hook >/dev/null 2>&1; then
        os::__on_exit_hook "${code}" || true
    fi

    errors::_clean_tmpdirs

    # 信号路径已经自己打印过、也已经决定不回滚了
    if [[ ${OS_ERR__SIGNALED} -eq 1 ]]; then
        return 0
    fi

    if [[ ${code} -eq 0 ]]; then
        # `root-nolock` 与 `root-trylock`（规范 §6）都是**周期性**命令。
        # 一句例行「完成」对它们没有追溯价值,却按周期无限重复:分档采集器最快
        # 每 3 秒一次。实测一台刚装好的机器上,面板日志副本(尾部 2000 行)里
        # 79% 是采集器的心跳,真实事件的可见窗口被压到两小时。
        # 而日志每变一次,写给面板的那份 200 KB+ 副本就要整份重写。
        #
        # **两档都要在这儿**:`root-trylock` 是后加的，只在 §6 里写了它是周期性
        # 的、却漏了这条豁免 —— 真机上表现为通知器每 30 秒往 JSONL 写一行「完成」,
        # 一天 2880 行。新增权限档时，凡是按「周期性」给的待遇都要一起给。
        # **只让成功这一条降级**:失败、警告、信号中断都还走原来的级别。
        if [[ ${OS_META_PRIVILEGE-} == root-nolock || ${OS_META_PRIVILEGE-} == root-trylock ]]; then
            log::write debug "完成" framework
        else
            log::write info "完成" framework
        fi
        return 0
    fi

    # 2（参数错）· 3（依赖缺失）· 4（环境不支持）三个码的「系统状态」
    # 一栏都是**未变更**。它们是前置检查在动手之前拦下来的，此时既没有东西可回滚，
    # 也不该再打「执行失败 / 已撤销 / doctor --bundle」那一套 —— 前面那句
    # 「缺少依赖组件：caddy」本身就是完整答案，再糊三段报告只会把它埋掉。
    if [[ ${code} -eq 2 || ${code} -eq 3 || ${code} -eq 4 ]]; then
        log::exit_code info "前置检查未通过" "${code}"
        return 0
    fi

    if [[ ${code} -eq 130 ]]; then
        # 用户在确认点说不。规范规定此时系统一定没被改动；
        # 若清单非空，说明脚本在改动之后才给的确认点，那是脚本的问题，必须说出来。
        log::exit_code info "用户取消" 130
        if [[ ${#OS_ERR__CHANGES[@]} -gt 0 ]]; then
            errors::_stderr warn "退出码 130 表示未做变更，但已记录到变更——这是脚本的确认点放晚了"
            errors::_print_changes "已发生的变更"
        fi
        return 0
    fi

    errors::run_rollback
    errors::fail_report "${code}"
    if [[ ${raw_code} -ne ${code} ]]; then
        exit "${code}"
    fi
    return 0
}

# 逆序回放回滚栈。**只回放 os::defer 注册的那一类。**
errors::run_rollback() {
    # `${cmd[*]}` 用 IFS 的第一个字符连接，而规范要求每个脚本把 IFS
    # 设成 $'\n\t' —— 不显式拨回空格的话，「已自动撤销」那一段会把一条命令的
    # 每个参数打成单独一行，路径与命令名各占一行，看着像是撤销了三件事。
    # 这是在真实失败报告里撞见的坑（D91）。
    local IFS=' '
    local -i idx=${#OS_ERR__DEFER_LEN[@]}
    local -i end=${#OS_ERR__DEFER_ARGS[@]}
    if ((idx == 0)); then
        return 0
    fi

    # **dry-run 下一条都不回放。** 预演里 os::run 全被跳过，副作用一件都没发生，
    # 可回滚栈里躺着的是**真命令** —— 回放它们等于让一次预演去 `docker rm -f`
    # 或 `rmdir` 真实存在的东西，而不变量 5 说的是「dry-run 零变更」。
    # 注册回滚本身没有副作用，所以拦在回放这一步，脚本层不用为预演写分支。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        log::write info "dry-run：跳过回滚（共 ${idx} 项，预演中没有真的变更）" framework
        return 0
    fi

    log::write info "开始回滚，共 ${idx} 项" framework
    while ((idx > 0)); do
        idx=$((idx - 1))
        local -i n=${OS_ERR__DEFER_LEN[idx]}
        local -i start=$((end - n))
        local -a cmd=("${OS_ERR__DEFER_ARGS[@]:start:n}")
        end=${start}
        if "${cmd[@]}" >/dev/null 2>&1; then
            OS_ERR__ROLLED_BACK+=("${cmd[*]}")
            log::write info "已撤销：${cmd[*]}" framework
        else
            OS_ERR__ROLLBACK_FAILED+=("${cmd[*]}")
            log::write error "撤销失败：${cmd[*]}" framework
        fi
    done
    return 0
}

errors::_print_changes() {
    local title=${1-}
    if [[ ${#OS_ERR__CHANGES[@]} -eq 0 ]]; then
        return 0
    fi
    errors::_stderr warn "${title}："
    local c
    for c in "${OS_ERR__CHANGES[@]}"; do
        errors::_stderr muted "    ${c}"
    done
    return 0
}

# 失败输出三段到 stderr
errors::fail_report() {
    local -i code=${1:-1}
    # 兜底措辞是「未记录到具体命令」不是「未知命令」：后者在本项目里是
    # 路由层的固定说法（bin/oneserver 的「未知命令：xxx」），而走到这里的
    # 十有八九是 os::die 主动退出、根本没有失败命令可记 —— 排查的人翻到
    # 这一行会以为自己敲错了命令名，而真因在上面几行的 tar / apt 里。
    log::exit_code error "失败：${OS_ERR__FAIL_CMD:-未记录到具体命令}" "${code}"

    # 一段：出了什么事
    if [[ -n ${OS_ERR__FAIL_CMD} ]]; then
        errors::_stderr error "执行失败：${OS_ERR__FAIL_CMD}"
    else
        errors::_stderr error "执行失败"
    fi

    # 二段：已自动撤销的 / 需人工确认的
    if [[ ${#OS_ERR__ROLLED_BACK[@]} -gt 0 ]]; then
        errors::_stderr warn "已自动撤销："
        local r
        for r in "${OS_ERR__ROLLED_BACK[@]}"; do
            errors::_stderr muted "    ${r}"
        done
    fi
    if [[ ${#OS_ERR__ROLLBACK_FAILED[@]} -gt 0 ]]; then
        errors::_stderr error "撤销失败，需人工处理："
        local f
        for f in "${OS_ERR__ROLLBACK_FAILED[@]}"; do
            errors::_stderr muted "    ${f}"
        done
    fi
    # 标题不能写死成「未自动撤销」。os::record_change 的清单同时服务两条路径：
    # 中断路径（§10：不跑回滚栈，只列已发生的变更）与这条失败路径。脚本对
    # 「建库建用户」这类动作会**同时** record_change 与 os::defer —— 前者是为了
    # 中断时清单里有它，后者是失败时真的撤销它。回滚栈跑过之后再声称这些
    # 「未自动撤销」，等于让人去手工 DROP 一个已经不存在的库。
    if [[ ${#OS_ERR__ROLLED_BACK[@]} -gt 0 ]]; then
        errors::_print_changes '本次执行发生过的变更（上面「已自动撤销」的那些不必再处理）'
    else
        errors::_print_changes '以下变更未自动撤销，请人工确认是否需要处理'
    fi

    # 三段：下一步。给能直接复制的东西，不给「请检查日志」这种废话。
    errors::_stderr muted "退出码 ${code}"
    if [[ ${OS_LOG_ENABLED} -eq 1 ]]; then
        errors::_stderr muted "日志：${OS_LOG_CMD_FILE:-${OS_LOG_MAIN}}"
    fi
    errors::_stderr muted "打包诊断信息：oneserver doctor --bundle"
    return 0
}
