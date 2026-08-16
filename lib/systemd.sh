# lib/systemd.sh —— L3 能力层：unit 的安装 / 启用 / 重启 / 卸载
#
# 只依赖 L0–L2（用 exec.sh 的 os::run 执行 systemctl）。
# **不依赖同层的 state.sh** —— unit 归属的登记由调用方在拿到结果后自己写，
# 见下面 os::systemd_install 的说明。
#
# 这个文件回答 R7：现状里 systemd unit 没有归属，卸载会留孤儿 timer。
#
# --- own: 与 ext: 的区别是这个文件存在的全部理由（D36）---
#
#   own:  本项目提供的 unit，源文件在 packaging/systemd/
#         卸载时：停止 → 禁用 → **删除文件** → daemon-reload
#   ext:  发行版包管理器提供的 unit，本项目只是启用/配置了它
#         卸载时：停止 → 禁用 → **禁止删除文件**
#
# 孤儿 unit 只可能出自自有 unit —— 外部 unit 随包卸载而消失，永远不会成孤儿。
# 不区分的话，uninstall 会去 `rm /lib/systemd/system/php8.3-fpm.service`，
# 那是在破坏 dpkg 管理的文件，比留孤儿严重得多。
#
# **禁止操作 crontab**（K6）：`crontab -l` 因非「无 crontab」原因失败时会静默
# 得到空串，随后整体重写 → 用户所有定时任务消失且无提示。定时任务一律用 timer。

OS_SYSTEMD_UNIT_DIR='/etc/systemd/system'

# 本次进程里被操作过的 unit，格式 `own:name` / `ext:name`。
# 调用方（脚本或 bootstrap）用 os::systemd_touched 取出来写进 state ——
# 这样 systemd.sh 不必依赖同层的 state.sh。
OS_SYSTEMD__TOUCHED=()

# os::systemd_touched   打印本次执行动过的全部 unit
os::systemd_touched() {
    local u
    for u in ${OS_SYSTEMD__TOUCHED[@]+"${OS_SYSTEMD__TOUCHED[@]}"}; do
        printf '%s\n' "${u}"
    done
    return 0
}

systemd::_touch() {
    local entry=${1}
    local existing
    for existing in ${OS_SYSTEMD__TOUCHED[@]+"${OS_SYSTEMD__TOUCHED[@]}"}; do
        [[ ${existing} == "${entry}" ]] && return 0
    done
    OS_SYSTEMD__TOUCHED+=("${entry}")
    return 0
}

systemd::_check_origin() {
    case ${1-} in
        own | ext) return 0 ;;
        *)
            ui::line error "unit 来源必须是 own 或 ext，收到「${1-}」"
            return 2
            ;;
    esac
}

# os::systemd_daemon_reload   重新加载 systemd 配置
os::systemd_daemon_reload() {
    os::run 'systemd 重新加载配置' -- systemctl daemon-reload
}

# ==================================================================
# 安装
# ==================================================================

# os::systemd_install <unit 文件路径> <own|ext>
#
# 文件替换走「临时文件 + mv」换 inode：直接往目标路径写，
# systemd 有可能正读到写了一半的文件。
os::systemd_install() {
    local src=${1-} origin=${2-}
    systemd::_check_origin "${origin}" || return 2
    if [[ ! -f ${src} ]]; then
        ui::line error "unit 文件不存在：${src}"
        return 1
    fi
    if [[ ${origin} != own ]]; then
        ui::line error "只有 own: 的 unit 能安装文件；ext: 的 unit 由包管理器提供"
        return 2
    fi

    local name="${src##*/}"
    local dst="${OS_SYSTEMD_UNIT_DIR}/${name}"

    # **内容与权限都已是目标状态就什么都不做**（规范 §10「写文件前先判断内容
    # 是否变化」，同 os::install_file 的写法）。
    #
    # 不比对的代价是实测出来的：`oneserver web enable` 是 update 之后的例行动作，
    # 它装 4 个 unit —— 每跑一次就无条件重写这 4 个文件、白跑一次 daemon-reload，
    # 而且 os::backup_file 每次都往 /var/backups/oneserver/files/ 里各存一份
    # **一模一样**的副本。跑了 4 次之后那个目录里就躺着 16 份完全相同的 unit。
    #
    # 已是目标状态时仍然要 systemd::_touch：unit 归属登记记的是「这个 unit 属于
    # 本组件」这个事实，与文件这次有没有被改无关，漏了它卸载就找不到这个 unit。
    # 但**不注册 os::defer**：文件不是本次创建的，失败时删掉它是在撤销上一次的
    # 成果（§10 明说回滚动作本身也是副作用）。
    if [[ -f ${dst} ]] && cmp -s -- "${src}" "${dst}" \
        && [[ $(stat -c %a -- "${dst}" 2>/dev/null) == 644 ]]; then
        log::write info "unit ${name} 已是目标状态，未改动" framework
        systemd::_touch "own:${name}"
        return 0
    fi

    os::backup_file "${dst}"
    os::critical_begin "安装 unit ${name}"
    local -i rc=0
    # 这里的临时名**故意**还是拼 `$$`，与 template::_place 的 mktemp 不同：
    # mktemp 当场就建出文件，而这一段整个跑在 dry-run 下（下面两条 os::run 各自
    # 跳过并打 `[dry-run]` 行），建文件会破坏「dry-run 零变更」。可以这么做的
    # 前提是 unit 目录属 root 且组/其他无写位 —— 谁也预置不了这条路径。
    # 目标目录非 root 可写的地方（站点根、/etc/caddy/incoming）必须用 mktemp。
    local tmp="${dst}.tmp.$$"
    if ! os::run "写入 unit ${name}" -- cp -f -- "${src}" "${tmp}"; then
        rc=1
    elif ! os::run "就位 unit ${name}" -- mv -f -- "${tmp}" "${dst}"; then
        rc=1
    fi
    os::critical_end
    if [[ ${rc} -ne 0 ]]; then
        os::run --allow-fail '清理临时 unit' -- rm -f -- "${tmp}" || true
        return "${rc}"
    fi

    os::run '设置 unit 权限' -- chmod 0644 "${dst}"
    # 自有 unit 属「必须回滚」类：本次创建，撤销是安全的
    os::defer rm -f -- "${dst}"
    systemd::_touch "own:${name}"
    os::systemd_daemon_reload
    return 0
}

# ==================================================================
# 启用 / 禁用 / 重启
# ==================================================================

# os::systemd_enable <unit> [--now] [own|ext]
os::systemd_enable() {
    local unit='' now=0 origin='ext'
    while [[ $# -gt 0 ]]; do
        case ${1} in
            --now)
                now=1
                shift
                ;;
            own | ext)
                origin=${1}
                shift
                ;;
            *)
                [[ -z ${unit} ]] && unit=${1}
                shift
                ;;
        esac
    done
    if [[ -z ${unit} ]]; then
        ui::line error "os::systemd_enable 缺少 unit 名"
        return 2
    fi

    local -a args=(enable)
    [[ ${now} -eq 1 ]] && args+=(--now)
    args+=("${unit}")

    # enable 之前先探测原状态。**不能靠“这是我这次调用做的”这个意图去判断
    # 能不能回滚**——`ext:` unit 是发行版包管理器提供的（dpkg 装 MariaDB /
    # PHP-FPM 时多半出厂就已经 enabled），随时可能是用户既有资产；同一份
    # 代码在 `start`/`restart` 上早就是「禁止自动回滚」类（见下面两个函数），
    # 唯独这里走了 defer，而失败路径上关掉一个用户本来就要开机自启的服务，
    # 后果从「MariaDB 不再开机自启」到「unattended-upgrades 被关掉」不等。
    # 不用同层的 probe.sh（L3 内部禁止互相依赖），直接用 os::query 探测。
    # `systemctl is-enabled` 对 disabled/not-found/masked 都以非零退出码
    # 表达结论（这就是它的正常语义，不是「探测失败」）——`|| true` 之前漏了，
    # 于是全新安装（unit 还没启用过，is-enabled 必然非零）在 set -e 下直接
    # 被这一行探测语句打断退出，`install mariadb` 等一整类命令因此在第一次
    # 启用服务时就会失败（本地真机验证复现，见 systemd.bats 的新增用例）。
    os::query --timeout "${OS_DEFAULT_PROBE_TIMEOUT}" -- systemctl is-enabled "${unit}" || true
    local was_enabled=${OS_RUN_OUTPUT}

    os::run "启用 ${unit}" -- systemctl "${args[@]}" || return $?

    if [[ ${origin} == ext ]]; then
        # ext 来源一律不注册回滚，即使这次确实是 disabled→enabled：
        # dpkg 提供的服务随时可能是用户既有资产，「猜错就关掉用户的服务」
        # 这个代价太不对称，不值得为了回滚精确而冒险
        os::record_change "启用了 ${unit}"
    elif [[ ${was_enabled} != enabled ]]; then
        # own unit 且这次真的是从「未启用」变成「启用」：撤销是安全的
        # 经 os::run 而不是裸命令：回滚动作本身也是副作用，
        # 不该绕开审计日志与脱敏（§10）
        os::defer os::run --allow-fail '回滚：禁用本次启用的 unit' -- systemctl disable "${unit}"
    fi
    systemd::_touch "${origin}:${unit}"
    return 0
}

# os::systemd_disable <unit>   禁用开机自启
os::systemd_disable() {
    local unit=${1-}
    if [[ -z ${unit} ]]; then
        ui::line error "os::systemd_disable 缺少 unit 名"
        return 2
    fi
    os::run --allow-fail "禁用 ${unit}" -- systemctl disable "${unit}"
}

# os::systemd_start <unit> / os::systemd_stop <unit>
#
# **为什么框架里必须有这两个**：
# 规范要求 systemd 操作一律经本模块，而此前只有 enable / disable /
# restart / reload —— 「把一个 unit 起来」只能写成 `os::run -- systemctl start`，
# 框架从此看不见这个 unit（`os::systemd_touched` 收不到它，state 也就登记不上）。
#
# 直接的动因是 **Quadlet**：它生成的 `<名>.service` 没有真实文件，
# `systemctl enable` 对它会失败（「Unit file does not exist」）——
# 开机自启由 `.container` 里的 `[Install]` 段在生成时处理。
# 所以那类 unit 只能 start，不能 enable，而框架当时给不出这个动作。
os::systemd_start() {
    local unit=${1-}
    if [[ -z ${unit} ]]; then
        ui::line error "os::systemd_start 缺少 unit 名"
        return 2
    fi
    # 与 restart 同属「禁止自动回滚」类：它原来是开是关，框架不知道
    os::record_change "启动了服务 ${unit}"
    os::run "启动 ${unit}" -- systemctl start "${unit}"
}

# os::systemd_stop <unit>   停止服务
os::systemd_stop() {
    local unit=${1-}
    if [[ -z ${unit} ]]; then
        ui::line error "os::systemd_stop 缺少 unit 名"
        return 2
    fi
    os::record_change "停止了服务 ${unit}"
    os::run "停止 ${unit}" -- systemctl stop "${unit}"
}

# os::systemd_kick <unit>   让一个周期性 unit 提前跑一轮，不等它、不记变更
#
# 与 os::systemd_start 的区别不是「少了几个选项」，是**语义不同**：start 表达
# 「这个服务此后应该是运行着的」，所以它记变更、失败要让调用方知道。kick 表达
# 「有个 timer 反正会跑，只是我希望它现在就跑一次」——目标状态一点没变，
# 提前那一轮不该出现在变更清单里，失败了也不该让本条命令失败。
#
# 存在的理由：用户在终端里装完组件、建完容器，最想做的下一件事是去面板上看到
# 它。定时器最长要 5 分钟才轮到，而**面板本身不能有触发采集的按钮**（规范 §1：
# 零服务端逻辑）。改动发生在哪一侧，就由哪一侧顺手踢一下——那一侧本来就有
# root、也本来就知道自己改了东西。
#
# `--no-block` 不能省：慢档一轮要两三秒，等它跑完等于让每条命令都慢那么多。
os::systemd_kick() {
    local unit=${1-}
    [[ -n ${unit} ]] || return 0
    os::run --allow-fail "触发 ${unit} 提前采集" -- \
        systemctl start --no-block "${unit}" || true
    return 0
}

# os::systemd_restart <unit>
#
# 存在的理由见规范的注：没有它，「重启服务」这个所有安装脚本都要做的动作
# 就只能写成 `os::run -- systemctl restart x`，框架从此看不见这个 unit。
os::systemd_restart() {
    local unit=${1-}
    if [[ -z ${unit} ]]; then
        ui::line error "os::systemd_restart 缺少 unit 名"
        return 2
    fi
    # 重启属「禁止自动回滚」类：服务原来是开是关、是什么配置，框架不知道，
    # 猜着回滚（比如 stop）比不回滚破坏更大。只记进变更清单。
    os::record_change "重启了服务 ${unit}"
    os::run "重启 ${unit}" -- systemctl restart "${unit}"
}

# os::systemd_reload <unit>
#
# **优先热重载，unit 不支持才回落到重启**（`systemctl reload-or-restart`）。
#
# 为什么值得单独有一个：Caddy / nginx 这类的 reload 是**零停机**的配置热替换，
# 而 restart 会掐断正在进行的连接。对一台正在服务的机器，这两者的差别是
# 「用户无感」与「所有人看到一次 502」。而 unit 支不支持 reload 是 unit 自己的
# 事（ExecReload= 有没有写），脚本不该去猜 —— `reload-or-restart` 让 systemd
# 自己判断，猜错的可能性归零。
os::systemd_reload() {
    local unit=${1-}
    if [[ -z ${unit} ]]; then
        ui::line error "os::systemd_reload 缺少 unit 名"
        return 2
    fi
    # 与 restart 同属「禁止自动回滚」类：框架不知道之前那份配置是什么
    os::record_change "重载了服务 ${unit}"
    os::run "重载 ${unit}" -- systemctl reload-or-restart "${unit}"
}

# ==================================================================
# 卸载
# ==================================================================

# os::systemd_remove <own:|ext:><unit>
#
# 前缀不是可选的：没有它就判断不了该不该删文件，而**删错的代价远大于留孤儿**。
os::systemd_remove() {
    local entry=${1-}
    local origin=${entry%%:*} unit=${entry#*:}
    systemd::_check_origin "${origin}" || return 2
    if [[ -z ${unit} || ${unit} == "${entry}" ]]; then
        ui::line error "os::systemd_remove 需要带前缀的 unit，如 own:oneserver-backup.timer"
        return 2
    fi

    os::run --allow-fail "停止 ${unit}" -- systemctl stop "${unit}" || true
    os::run --allow-fail "禁用 ${unit}" -- systemctl disable "${unit}" || true

    if [[ ${origin} == ext ]]; then
        # **禁止删文件**：那是 dpkg 管理的，删了会让包处于半损坏状态
        log::write info "ext: 的 unit ${unit} 只停止禁用，不删文件" framework
        return 0
    fi

    local dst="${OS_SYSTEMD_UNIT_DIR}/${unit}"
    if [[ -f ${dst} ]]; then
        os::critical_begin "删除 unit ${unit}"
        os::run "删除 unit 文件 ${unit}" -- rm -f -- "${dst}"
        os::critical_end
    fi
    os::systemd_daemon_reload
    return 0
}
