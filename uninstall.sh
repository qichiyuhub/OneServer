#!/bin/bash
#
# 卸载 OneServer 自身
#
# @requires_lib >= 4.3
#
# **这一行不是装饰。** 本文件 source 得到 `lib/`，因此 §14 的 lib API 闸门本
# 就该管它；而它从前一个字都没声明，于是 `os::__check_lib_api` 直接放行 ——
# 唯一能拦住「旧脚本配新 lib」的检查，恰好在这个执行 `rm -rf` 与清凭据的
# 脚本上是关着的。切换器现在会替换它（TOP_FILES），版本对不上属于真故障，
# 该在动手之前停下来，而不是跑到一半发现某个接口签名变了。
#
# ==================================================================
# 为什么这个文件在仓库根，而不在 script/ 下
# ==================================================================
#
# `registry::scan` 只扫 `$OS_SCRIPT_DIR/*.sh` 与 `*/*.sh`，而菜单完全由注册表
# 生成 —— 放在 script/ 下就一定会出现在菜单里，没有任何「隐藏」开关。
#
# 而「卸掉整个工具」不该躺在日常操作的列表里：它是一次性的、不可逆的决定，
# 与「卸一个应用」是两件事。所以它和 `install.sh` 配成一对放在仓库根，
# 入口是 README 里的一行命令。装到机器上之后就是：
#
#     bash /opt/oneserver/uninstall.sh
#
# ==================================================================
# 锁：卸组件那一段必须先放开
# ==================================================================
#
# 组件必须**在本工具还在的时候**卸掉 —— 工具一没，那份资源清单也就没了，
# 它们此后只能手工清。而卸组件的全部能力在 `oneserver uninstall` 里，那是
# 一条 `@privilege root` 的命令，**自己要取全局锁**。持着锁去 fork 它，
# 子进程会一直等到超时（web.sh 里那条 ufw 的注释踩的是同一个坑）。
#
# 所以在 fork 之前 `os::lock_release`，那一段跑完再 `os::lock_acquire` 收回来。
#
# **不走 OS_BOOT_MODE=frontend**（菜单那条路）：前端模式连全局参数解析一起
# 跳过，于是 `--non-interactive` `--force-destroy` `--dry-run` 全部失效 ——
# 而这个脚本每一步都靠它们。装配走正常命令模式，只把锁按需放开。
#
# ==================================================================
# 确认的粒度：一件不可逆的事，一道全名门，不多不少
# ==================================================================
#
# 组件的门在 `oneserver uninstall` 自己那里（每个组件各一道）。本脚本**不**替
# 它们代答 —— 用 `--force-destroy` 一次批准掉全部组件，正是规范 §10 明令禁止
# 的「一个开关批准全部危险操作」。purge mariadb 与 purge caddy 是两个决定。
#
# 本脚本自己的三样东西各有一道门：备份归档 · 凭据库与配置 · 工具自身。
#
# ==================================================================
# 自删是安全的
# ==================================================================
#
# `rm -rf /opt/oneserver` 走的是 unlink，而 bash 持着已打开的 fd，inode 要等
# 进程退出才真正释放（危险的是**覆盖**，不是 unlink —— K13 是前者）。
# lib 早已 source 进内存，此后不再有任何 source。

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

UN_PURGE=0    # 连 /etc/oneserver 与凭据库一起删
UN_ARCHIVES=0 # 连备份归档一起删

# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

# hsize <KB>
hsize() {
    local -i kb=${1:-0}
    if ((kb >= 1048576)); then
        printf '%s.%s GB' "$((kb / 1048576))" "$(((kb % 1048576) * 10 / 1048576))"
    elif ((kb >= 1024)); then
        printf '%s MB' "$((kb / 1024))"
    else
        printf '%s KB' "${kb}"
    fi
}

du_kb() {
    local p=${1}
    [[ -e ${p} ]] || {
        printf '0'
        return 0
    }
    local out
    out=$(du -sk -- "${p}" 2>/dev/null) || {
        printf '0'
        return 0
    }
    printf '%s' "${out%%[[:space:]]*}"
}

# ------------------------------------------------------------------
# 第一步：把现状摆出来
# ------------------------------------------------------------------

UN_IDS=()

survey() {
    UN_IDS=()
    local id
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        UN_IDS+=("${id}")
    done < <(os::state_list)

    os::section '当前这台机器上的 OneServer'
    os::kv \
        '安装位置' "${OS_ROOT}" \
        '版本' "$(cat "${OS_VERSION_FILE}" 2>/dev/null || printf '未知')" \
        '已登记的组件' "${#UN_IDS[@]} 个" \
        '备份归档' "$(hsize "$(du_kb "${OS_BACKUP_DIR}")")" \
        '日志' "$(hsize "$(du_kb "${OS_LOG_DIR}")")"
    return 0
}

# ------------------------------------------------------------------
# 第二步：组件
#
# **必须在卸掉本工具之前做完。** 资源清单（pkg / file / divert / alt / unit）
# 只存在于 state 里，工具没了它也就没了 —— 那些包和文件此后只能靠人去翻。
# ------------------------------------------------------------------

handle_components() {
    if [[ ${#UN_IDS[@]} -eq 0 ]]; then
        os::info 'state 里没有登记的组件'
        return 0
    fi

    os::section '已安装的组件'
    local id
    for id in "${UN_IDS[@]}"; do
        os::info "    ${id}"
    done
    os::warn '本工具一旦卸掉，这份资源清单也就没了 —— 这些组件此后只能手工清'

    # **非交互下必须点名。** os::multiselect 在 --non-interactive 时的取值是
    # 「全选」（等价于回车）—— 放任它的话，一条 `uninstall.sh --non-interactive
    # --force-destroy` 会把十几个应用连包带库一起 purge 掉，而没有任何人打过
    # 它们的名字。这里反过来：没给 --components 就一个都不动
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]] && ! os::flag --arg components; then
        os::info '非交互模式下没有指定 --components，组件全部保留'
        return 0
    fi

    local picked=''
    os::multiselect --arg components \
        '要一并卸载哪些组件？（留空＝都留着）' picked "${UN_IDS[@]}"

    if [[ -z ${picked} ]]; then
        os::info '组件都保留，它们装的包与文件不会被动'
        return 0
    fi

    # multiselect 交回的是**逗号分隔的一行**，不是一行一个。按行读的话整串会被
    # 当成一个组件标识传下去，现场表现是 `--id=a,b,c` 找不到组件
    local -a picks=()
    IFS=',' read -r -a picks <<<"${picked}"

    # 逐个交给真正的卸载命令。**不加 --force-destroy**：每个组件在那边各有
    # 一道全名门，替它们代答就是「一个开关批准全部危险操作」（规范 §10）
    #
    # 锁必须先放开，否则子进程等到超时（见文件头）。这段期间别的 oneserver
    # 命令能插进来 —— 与菜单派发命令时的窗口是同一个，代价可接受
    # 全局开关必须传下去。**漏掉 --dry-run 的后果是预演真的把组件卸了** ——
    # 子进程是独立进程，它读的是自己的命令行，读不到这里的 OS_DRYRUN。
    local -a child=()
    [[ ${OS_DRYRUN} -eq 1 ]] && child+=(--dry-run)
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        child+=(--non-interactive)
        # **只有非交互才传 --force-destroy**，而且此时组件是被 --components
        # 逐个点过名的（见上面那道闸）。两件显式的事加在一起才放行，跟
        # 「一个开关批准全部危险操作」不是一回事。
        # 交互模式下坚决不传：那里每个组件在子进程里各自打一遍全名
        [[ ${OS_FORCE_DESTROY} -eq 1 ]] && child+=(--force-destroy)
    fi

    os::lock_release
    local one rc
    for one in ${picks[@]+"${picks[@]}"}; do
        [[ -n ${one} ]] || continue
        os::section "卸载组件 ${one}"
        rc=0
        "${OS_LOCAL_BIN_DIR}/oneserver" uninstall --id="${one}" ${child[@]+"${child[@]}"} || rc=$?
        if ((rc != 0)); then
            os::warn "组件 ${one} 没有卸干净（退出码 ${rc}）—— 它的资源仍在机器上"
        fi
    done
    os::lock_acquire

    # 卸完重新扫一遍：下面要如实报告还剩几个
    survey >/dev/null 2>&1 || true
    return 0
}

# ------------------------------------------------------------------
# 第三步：重要数据，各自一道门
# ------------------------------------------------------------------

handle_archives() {
    local kb
    kb=$(du_kb "${OS_BACKUP_DIR}")
    if [[ ! -d ${OS_BACKUP_DIR} ]]; then
        return 0
    fi

    os::section '备份归档'
    os::kv '位置' "${OS_BACKUP_DIR}" '占用' "$(hsize "${kb}")"
    os::info '归档是「这台机器没了之后还能恢复」的东西 —— 删它与卸载工具是两个决定'

    if ! os::confirm --arg remove-archives '连备份归档一起删掉？' 'n'; then
        UN_ARCHIVES=0
        os::info "备份归档保留在 ${OS_BACKUP_DIR}"
        return 0
    fi

    if ! os::destroy_confirm --arg confirm-archives 'archives' -- \
        "${OS_BACKUP_DIR} 整个目录（$(hsize "${kb}")）—— 全部备份归档，删了无法找回"; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            UN_ARCHIVES=0
            os::info "已放弃，备份归档保留在 ${OS_BACKUP_DIR}"
            return 0
        fi
    fi
    UN_ARCHIVES=1
    return 0
}

handle_secrets() {
    os::section '凭据库与配置'
    os::kv \
        '凭据库' "${OS_SECURE_CONF}" \
        '配置目录' "${OS_ETC_DIR}"
    os::warn '凭据库里是本机所有自动生成的密码 —— 站点与数据库此刻可能还在用它们'

    if ! os::confirm --arg purge '连凭据库与配置一起删掉？' 'n'; then
        UN_PURGE=0
        os::info "凭据库与配置保留（${OS_SECURE_CONF}）"
        return 0
    fi

    if ! os::destroy_confirm --arg confirm-purge 'purge' -- \
        "${OS_SECURE_CONF}（本机所有自动生成的密码，删了永久丢失）" \
        "${OS_ETC_DIR} 整个目录"; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            UN_PURGE=0
            os::info '已放弃，凭据库与配置保留'
            return 0
        fi
    fi
    UN_PURGE=1
    return 0
}

# ------------------------------------------------------------------
# 第四步：工具自身
#
# 清单就是「OneServer 会往盘上写的每一个位置」。少一行 = 卸完留一份垃圾，
# 所以它按 lib/paths.sh 逐条对过，新增落点必须同步回来。
# ------------------------------------------------------------------

self_lines() {
    local -a lines=()
    if [[ ${UN_PURGE} -eq 1 ]]; then
        lines+=("程序目录 ${OS_ROOT} 整个（含 state、面板历史与凭据库）")
        lines+=("配置目录 ${OS_ETC_DIR}")
    else
        lines+=("程序目录 ${OS_ROOT} 里除 secure.conf 之外的一切（含 state）")
    fi
    lines+=("入口 ${OS_LOCAL_BIN_DIR}/oneserver 与 ${OS_LOCAL_BIN_DIR}/os")
    lines+=("日志目录 ${OS_LOG_DIR}")
    lines+=("面板数据 ${OS_PUBLIC_DIR}")
    lines+=("运行时目录 ${OS_RUN_DIR}（锁与临时文件）")
    lines+=("logrotate 配置 ${OS_LOGROTATE_FILE}")
    lines+=("bash 补全 ${OS_COMPLETION_FILE}")
    lines+=('本工具自带的 systemd unit（备份 timer 与面板采集 timer）')
    [[ ${UN_ARCHIVES} -eq 1 ]] && lines+=("备份归档 ${OS_BACKUP_DIR} 整个")
    printf '%s\n' "${lines[@]}"
}

remove_self() {
    os::section '卸载 OneServer 自身'

    local -a lines=()
    mapfile -t lines < <(self_lines)

    if [[ ${#UN_IDS[@]} -gt 0 ]]; then
        os::warn "还有 ${#UN_IDS[@]} 个组件留在机器上，它们装的包与文件不会被动"
    fi

    if ! os::destroy_confirm --arg confirm-uninstall 'oneserver' -- "${lines[@]}"; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            os::info '已取消，什么都没有动'
            os::output 130 removed=no
            return 130
        fi
        os::info '[dry-run] 继续预演下面每一步会执行的命令'
    fi

    # own: 的 unit 先停后删 —— 留一个 ExecStart 已不存在的 timer，systemd 每次
    # 触发都记一条失败，而那时已经没有任何工具能解释它是什么
    local unit
    for unit in "${OS_SYSTEMD_UNIT_DIR}"/oneserver-*.timer "${OS_SYSTEMD_UNIT_DIR}"/oneserver-*.service; do
        [[ -e ${unit} ]] || continue
        os::systemd_remove "own:${unit##*/}" || true
    done

    # **必须在删任何东西之前置上**：落快照的钩子挂在退出路径上，而下面正要删掉
    # 快照所在的目录 —— 不关掉它，退出时会把 $OS_PUBLIC_DIR 原样 mkdir 回来，
    # 而卸载命令自己不会报任何错
    # shellcheck disable=SC2034  # 理由：由 lib/probe.sh 的退出钩子消费，本文件内必然「未使用」
    OS_PROBE_NO_SNAPSHOT=1

    os::record_change '卸载了 OneServer 自身'
    os::run --allow-fail '删除入口链接' -- rm -f -- "${OS_LOCAL_BIN_DIR}/oneserver" "${OS_LOCAL_BIN_DIR}/os" || true
    os::run --allow-fail '删除 bash 补全' -- rm -f -- "${OS_COMPLETION_FILE}" || true
    os::run --allow-fail '删除 logrotate 配置' -- rm -f -- "${OS_LOGROTATE_FILE}" || true
    os::run --allow-fail '删除面板数据目录' -- rm -rf -- "${OS_PUBLIC_DIR}" || true

    if [[ ${UN_ARCHIVES} -eq 1 ]]; then
        os::run --allow-fail '删除备份归档' -- rm -rf -- "${OS_BACKUP_DIR}" || true
    fi

    # **程序目录在前、日志目录在后**：反过来的话，删程序目录那一步已经没有日志
    # 可写了。最后两条自己写不进日志，框架静默降级（K16）
    if [[ ${UN_PURGE} -eq 1 ]]; then
        os::run --allow-fail '删除配置目录' -- rm -rf -- "${OS_ETC_DIR}" || true
        os::run --allow-fail '删除程序目录' -- rm -rf -- "${OS_ROOT}" || true
    else
        # 用 find 排除 secure.conf，而不是列一串要删的子目录：后者漏掉
        # .staging / .old 这种更新期间留下的目录，而且每加一个运行时目录
        # 就要记得回来补一行
        os::run --allow-fail '删除程序目录（保留凭据库）' -- \
            find "${OS_ROOT}" -mindepth 1 -maxdepth 1 ! -name secure.conf -exec rm -rf {} + || true
    fi
    os::run --allow-fail '删除日志目录' -- rm -rf -- "${OS_LOG_DIR}" || true
    # 锁文件就在这个目录里，本进程还持着它的 fd —— unlink 安全，见文件头
    os::run --allow-fail '删除运行时目录' -- rm -rf -- "${OS_RUN_DIR}" || true

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 将卸载 OneServer 自身'
        os::output 0 removed=no purge="${UN_PURGE}" archives="${UN_ARCHIVES}" changed=dry-run
        return 0
    fi

    os::ok 'OneServer 已卸载'
    os::section '还留在机器上的东西'
    [[ ${UN_ARCHIVES} -ne 1 ]] && os::info "    备份归档 ${OS_BACKUP_DIR}"
    if [[ ${UN_PURGE} -ne 1 ]]; then
        os::info "    凭据库 ${OS_SECURE_CONF} —— 站点可能还在用里面的密码"
        os::info "    配置 ${OS_ETC_DIR}"
    fi
    if [[ ${#UN_IDS[@]} -gt 0 ]]; then
        os::info "    ${#UN_IDS[@]} 个组件装的包与文件"
    fi
    # 这一条做不到，就如实说它做不到：journalctl 只能按时间或大小 vacuum，
    # 那会连整机其它服务的历史一起带走，代价远超收益
    os::info '    journal 里本工具的运行记录 —— 会随系统自己的保留策略过期'
    os::info '    站点目录、数据库文件、证书 —— 它们从不在资源清单里，本工具没有删它们的能力'

    os::output 0 removed=yes purge="${UN_PURGE}" archives="${UN_ARCHIVES}" components="${#UN_IDS[@]}"
    return 0
}

# ==================================================================

main() {
    os::require_cmd find du

    os::box 'OneServer 卸载' -- \
        '接下来会依次问：组件 · 备份归档 · 凭据库与配置 · 工具自身' \
        '每一样都可以单独保留；不可逆的每一步都要打全名确认'

    survey
    handle_components
    handle_archives
    handle_secrets
    remove_self
}

main "$@"
