#!/bin/bash
#
# 采集只读面板的数据文件
#
# @privilege    root-nolock
# @requires_lib >= 4.0
# @args         [--tier=<live|fast|slow|all>]
# @description  把 probe 与 state 落成面板用的数据文件
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 为什么分两档，以及为什么这个脚本不持锁
# ==================================================================
#
# 面板要「内存、容器数、端口」这类秒级变化的东西看起来是实时的，又要
# 「包版本、ufw 规则、sshd -T」这类几乎不变但**很贵**的东西。前者读
# /proc 与 ss，几十毫秒；后者要 apt-cache policy（15s 超时）、
# apt list --upgradable（30s）。塞进同一个周期，要么快的不够快，
# 要么慢的把采集器自己变成负载源。
#
# 两档各落各的文件，前端按不同频率拉：快档文件只有十几行，5 秒拉一次
# 也不费什么。
#
# `@privilege root-nolock`（规范 §6）：要 root 是因为 systemctl / ufw /
# sshd -T 非 root 只给降级值，把降级值写进快照比不写更糟；不取锁是因为
# 每十秒持一次全局锁会随机挡住用户敲的真实命令。代价是可能采到一次变更
# 的中途状态，下一轮自行修正——面板上每块都标了数据时刻，看得出来。
#
# 实测（别的进程持锁 5 秒时）：本脚本 314ms 跑完，而同期一条普通 root
# 命令等了 3767ms。取锁的话，用户每十秒就有一次机会撞上这个等待。

readonly TIER_LIVE='probe-live.tsv'
readonly TIER_FAST='probe-fast.tsv'
readonly TIER_SLOW='probe-slow.tsv'
readonly HISTORY_FILE="${OS_WEB_HISTORY_NAME}"
readonly HISTORY_SAMPLES='2880'

readonly ALERT_FILE='alerts.tsv'
UFW_RULES=''

# ==================================================================
# 为什么自己拼 TSV，而不是用 probe::snapshot_flush
# ==================================================================
#
# probe 的缓存里存的是**探测命令的原始输出**，解析在函数里：
# `container.engine` 缓存的是 "podman version 5.8.3"，函数才把它归成
# `podman`；`pkg.<p>.candidate` 缓存的是整段 apt-cache policy，函数才
# 从里面取出版本号。
#
# 这个分工对「调函数的人」没问题，但**只读快照文件的消费者拿不到解析结果**
# ——面板正是这种消费者。而把解析值写回缓存也不行：package_candidate 对
# 已解析的 `5.8.3+ds1-1` 再解析会得到空（它找不到 `Candidate:`），不幂等。
#
# 所以这里在每次 probe 之后取 OS_PROBE_VALUE 自己记一行：落盘的永远是
# **函数的返回值**。附带的好处是「哪些 key 会进 0755 的公开文件」变成一份
# 显式清单，而不是「本次进程碰巧探过什么」。
SNAP=''
HISTORY_SAMPLE=''

# snap <key>   把上一次 probe 的结果记进本轮快照
#
# **只压换行，保留制表符**。行式格式按 key 后的**第一个**制表符切分，
# 值里再有制表符不会撕开它；而 `podman.ports`、`ufw.rules` 这类多行多字段
# 的值正是靠制表符分字段、换行（压成空格后）分记录。一起压掉的话，
# 「8081 属于哪个容器」就再也拼不回来了——面板上那一列会永远显示「未知」。
snap() {
    local v=${OS_PROBE_VALUE}
    v=${v//$'\n'/ }
    SNAP+="${1}"$'\t'"${v}"$'\n'
    return 0
}

snap_begin() {
    local now
    printf -v now '%(%s)T' -1
    SNAP="#ts"$'\t'"${now}"$'\n'
    return 0
}

# ------------------------------------------------------------------
# 实时档：只读 /proc，一个进程都不起
# ------------------------------------------------------------------
#
# 分这一档的判据是**成本与意义的组合**，不是拍脑袋的频率表：这几个数用 bash
# 内建就能读完（实测 300 次 0 ms），而它们恰恰是秒级会变、也值得盯着看的
# 那几个。反过来，`df` 要起进程而磁盘占用 3 秒变一次没有意义，所以它留在快档；
# `apt-get -s upgrade` 一次 576 ms 而可升级包数一天变几次都算多，留在慢档。
#
# 一轮不到 20 ms，占一个核约 0.6%，树莓派上约 2.4%。**所以它用普通 timer 就够**，
# 不需要常驻进程——规范 §5 的「命令跑在自己的进程里」与 §11 的「定时一律走
# timer」都不用动。
#
# CPU 使用率在**这里**算好再落盘，不推给前端：它是两个时刻之间的量，而这一档
# 每 3 秒就有一对相邻样本，算出来的正好是这 3 秒的真实区间值。前端自己存上一份
# 去差分也行，但那样每个消费者都要实现一遍，而且刷新页面就断档。
collect_live() {
    probe::mem_total_kb
    snap 'mem.total_kb'
    probe::mem_available_kb
    snap 'mem.available_kb'
    probe::uptime_seconds
    snap 'uptime.seconds'
    probe::loadavg
    snap 'load.avg'

    probe::cpu_jiffies
    local now=${OS_PROBE_VALUE}
    snap 'cpu.jiffies'

    # 上一轮的累计值在上一份文件里。读不到（开机第一轮、或刚被 tmpfs 清空）
    # 就不落 cpu.pct —— **宁可这一轮没有这个数，也不编一个**：显示成 0% 恰好
    # 是「机器很闲」这个具体结论，而那可能与事实相反
    local prev
    prev=$(snapshot_value "${OS_PUBLIC_DIR}/${TIER_LIVE}" 'cpu.jiffies')
    if [[ -n ${prev} && -n ${now} ]]; then
        local -i pt=${prev%% *} pi=${prev##* } nt=${now%% *} ni=${now##* }
        local -i dt=$((nt - pt)) di=$((ni - pi))
        # 计数器回绕或重启后倒退时 dt 会是 0 或负数，此时同样不编数
        if ((dt > 0 && di >= 0 && di <= dt)); then
            OS_PROBE_VALUE=$(((dt - di) * 100 / dt))
            snap 'cpu.pct'
        fi
    fi
    return 0
}

# ------------------------------------------------------------------
# 快档：只读 /proc、ss、systemctl is-active
# ------------------------------------------------------------------
collect_fast() {
    probe::mem_total_kb
    snap 'mem.total_kb'
    local mem_total=${OS_PROBE_VALUE}
    probe::mem_available_kb
    snap 'mem.available_kb'
    local mem_available=${OS_PROBE_VALUE}
    probe::uptime_seconds
    snap 'uptime.seconds'
    probe::loadavg
    snap 'load.avg'
    local loadavg=${OS_PROBE_VALUE}
    probe::cpu_count
    snap 'cpu.count'
    probe::cpu_jiffies
    local cpu_jiffies=${OS_PROBE_VALUE}
    probe::listening_ports
    snap 'net.listening_tcp'

    # 挂载点不写死：/var 单独分区是常见布局，写死就只能看见 /
    local mp root_total='' root_free=''
    for mp in / /var; do
        [[ -d ${mp} ]] || continue
        probe::disk_total_kb "${mp}"
        snap "disk.${mp}.total_kb"
        [[ ${mp} == / ]] && root_total=${OS_PROBE_VALUE}
        probe::disk_free_kb "${mp}"
        snap "disk.${mp}.free_kb"
        [[ ${mp} == / ]] && root_free=${OS_PROBE_VALUE}
    done

    # CPU 使用率不落进快照 —— 它是**两个时刻之间**的量，快照只有一个时刻。
    # 把累计计数写进历史，相邻两行一差分就是那一段的使用率，顺带整条曲线
    # 都是真实区间值，而不是每 30 秒抽一次的瞬时抖动。
    local cpu_total=${cpu_jiffies%% *} cpu_idle=${cpu_jiffies##* }
    [[ ${cpu_total} =~ ^[0-9]+$ ]] || cpu_total=0
    [[ ${cpu_idle} =~ ^[0-9]+$ ]] || cpu_idle=0
    local load1=${loadavg%% *}
    [[ ${load1} =~ ^[0-9]+(\.[0-9]+)?$ ]] || load1=0

    local now
    printf -v now '%(%s)T' -1
    HISTORY_SAMPLE="${now}"$'\t'"${mem_available}"$'\t'"${mem_total}"$'\t'"${root_free}"$'\t'"${root_total}"$'\t'"${cpu_total}"$'\t'"${cpu_idle}"$'\t'"${load1}"

    # 探哪些 unit 不靠猜，取自 state 登记的清单 —— 这也正是「面板显示的
    # 异常」能有意义的原因：state 说该有，probe 说没有，才是真异常
    #
    # **先收齐名单再一次问完**：逐个 `systemctl is-active` 每次都是一次
    # fork+exec（实测 3.9 ms），十来个 unit 就是 47 ms，而一次问全部约 4 ms。
    # 本项目自己的 backup service/timer 不在任何组件的 state 里（backup 是内置
    # 功能，没有 @provides），一并收进同一批。**service 与 timer 都要探**：
    # 只探 timer 的话，服务页上那条 service 行的状态列会是空的
    local id unit u
    local -a units=()
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            units+=("${unit#*:}")
        done < <(os::state_units "${id}")
    done < <(os::state_list)
    units+=('oneserver-backup' 'oneserver-backup.timer')

    probe::services_active "${units[@]}"
    local state_line
    while IFS=$'\t' read -r u state_line || [[ -n ${u} ]]; do
        [[ -n ${u} ]] || continue
        OS_PROBE_VALUE=${state_line}
        snap "unit.${u}.active"
    done <<<"${OS_PROBE_VALUE}"

    # 不写成 `engine=$(probe::container_engine)`：命令替换是子 shell，探到的值
    # 连同缓存都留在子进程里，这个 key 就永远落不进快照
    #
    # 两个 key 答的是两个问题，别再合并回去：`container.engine` 是「`docker`
    # 这个命令名归谁」，`container.engines` 是「机器上有哪些引擎」。曾经拿前者
    # 当后者用，于是 podman 里跑着的容器在面板上根本不存在。
    probe::container_engine || true
    snap 'container.engine'
    probe::container_engines || true
    local engines=${OS_PROBE_VALUE}
    snap 'container.engines'

    # 计数按引擎各算各的：两个引擎各有各的容器存储，加总起来就再也分不清
    # 该去哪个引擎里找。端口不再单独落 key —— containers.tsv 一行一个容器，
    # 比「多条记录挤一个值再按空格切」可靠得多
    local eng
    for eng in ${engines}; do
        case ${eng} in
            podman)
                probe::podman_running
                snap 'podman.running'
                probe::podman_total
                snap 'podman.total'
                ;;
            docker)
                probe::docker_running
                snap 'docker.running'
                probe::docker_total
                snap 'docker.total'
                ;;
        esac
    done
    return 0
}

# 定长历史只保留可用于判断缓慢恶化的标量。把每次快档都追加到普通日志会无限
# 膨胀；这里在内存中截为固定行数后原子替换，保留窗口稳定且断电不会留下半行。
#
# 开机后第一轮：tmpfs 里那份还不存在，从盘上的副本回填 —— 否则每次重启曲线
# 都从零开始，而重启前后那一段恰恰是最想看的。副本由 web_persist.sh 写，
# 本脚本**只读它**：写盘是副作用，而 root-nolock 的前提就是零副作用。
append_history() {
    local -a rows=()
    local row out='' src="${OS_PUBLIC_DIR}/${HISTORY_FILE}"
    [[ -r ${src} ]] || src=${OS_WEB_HISTORY_FILE}
    if [[ -r ${src} ]]; then
        mapfile -t rows <"${src}" || true
    fi
    rows+=("${HISTORY_SAMPLE}")
    local start=0
    [[ ${#rows[@]} -gt ${HISTORY_SAMPLES} ]] && start=$((${#rows[@]} - HISTORY_SAMPLES))

    # 列数变过就丢弃旧行：格式换了以后，老行的第 6 列是不存在的，拿它做
    # 差分会算出满屏的假峰值。宁可少一段历史，也不画一段假的。
    #
    # **但不必每轮把 2880 行全查一遍**（实测 60 ms，占快档一轮的十分之一）：
    # 文件是上一轮自己写的，那时每一行都已经过了这道校验。真正没查过的只有
    # 刚追加的这一行。剩下的风险只有「版本换了、格式跟着变」，而那种情况下
    # **所有**老行会一起不合格 —— 查第一行就能发现，不用挨个查。
    # 于是常态是 2 次匹配，只有真撞上格式变更才退回全量筛一遍。
    local num='[0-9]+' tab=$'\t' re
    re="^${num}(${tab}${num}){6}${tab}${num}(\\.${num})?$"

    local -i last=$((${#rows[@]} - 1))
    if [[ ! ${rows[last]} =~ ${re} ]]; then
        # 新采的这行自己不合格：本轮什么都不追加，文件原样留着
        return 0
    fi
    if [[ ${start} -lt ${last} && ! ${rows[start]} =~ ${re} ]]; then
        for (( ; start < ${#rows[@]}; start++)); do
            row=${rows[start]}
            [[ ${row} =~ ${re} ]] || continue
            out+="${row}"$'\n'
        done
    else
        for (( ; start < ${#rows[@]}; start++)); do
            out+="${rows[start]}"$'\n'
        done
    fi
    os::write_public "${HISTORY_FILE}" "${out}" || true
    return 0
}

# 从一份快照里取某个 key 的值。**没有这个 key 就是空值，不是失败** ——
# 末尾这个 `return 0` 不能省：不写的话函数的退出码是 while 那个条件的
# （找不到时为假 → 返回 1），而每个调用点都是裸的 `v=$(snapshot_value …)`，
# 在 `set -e` 下会当场把整个采集打断。真机上撞出来的：新加一个第一轮必然
# 不存在的 key，慢档立刻从 3.4 秒变成 39 毫秒就退出，还写了半份快照。
snapshot_value() {
    local file=${1} want=${2} key val
    [[ -r ${file} ]] || return 0
    while IFS=$'\t' read -r key val || [[ -n ${key} ]]; do
        [[ ${key} == "${want}" ]] && {
            printf '%s' "${val}"
            return 0
        }
    done <"${file}"
    return 0
}

publish_alerts() {
    local fast="${OS_PUBLIC_DIR}/${TIER_FAST}" slow="${OS_PUBLIC_DIR}/${TIER_SLOW}"
    local out='' v id unit name
    v=$(snapshot_value "${slow}" 'ufw.status')
    [[ -n ${v} && ${v} != yes ]] && out+=$'ufw\terr\t防火墙未启用\n'
    v=$(snapshot_value "${slow}" 'os.reboot_required')
    [[ ${v} == yes ]] && out+=$'reboot\terr\t系统需要重启\n'
    v=$(snapshot_value "${slow}" 'apt.upgradable_security')
    [[ ${v} =~ ^[1-9][0-9]*$ ]] && out+="sec\terr\t${v} 个安全更新待安装"$'\n'
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        while IFS= read -r unit; do
            name=${unit#*:}
            v=$(snapshot_value "${fast}" "unit.${name}.active")
            [[ ${v} == failed ]] && out+="svc:${name}\terr\t${id} 的服务已失败"$'\n'
        done < <(os::state_units "${id}")
    done < <(os::state_list)
    os::write_public "${ALERT_FILE}" "${out}" || true
}

# ------------------------------------------------------------------
# 慢档：调外部命令、长超时
# ------------------------------------------------------------------
collect_slow() {
    # 不走 snap()：本工具自己的版本不是「探测」出来的，它就写在 VERSION 里。
    # 页面此前把版本号硬编码在模板中，升级后那个数字永远停在写模板那天
    local ver=''
    [[ -r ${OS_VERSION_FILE} ]] && IFS= read -r ver <"${OS_VERSION_FILE}"
    SNAP+="oneserver.version"$'\t'"${ver//[[:space:]]/}"$'\n'

    probe::hostname
    snap 'os.hostname'
    probe::os_id
    snap 'os.id'
    probe::os_version
    snap 'os.version'
    probe::os_pretty
    snap 'os.pretty'
    probe::os_codename
    snap 'os.codename'
    probe::arch
    snap 'os.arch'
    probe::kernel
    snap 'os.kernel'
    probe::reboot_required
    snap 'os.reboot_required'
    # apt 那两个数是这一档里最贵的一项（实测 576 ms —— `apt-get -s upgrade` 真的
    # 跑了一遍依赖求解器，因为「可升级」不等于「有新版本」：apt 不会升那些要连带
    # 删掉别的包才能升的）。而它们只在两种情况下会变：索引被刷新过（`apt update`，
    # 系统自己的 apt-daily.timer 一天两次），或者装过/删过/升过包。
    # 慢档 5 分钟一轮 = 一天 288 次求解，去问一个一天变两次的数。
    #
    # 判据是这两个文件的 mtime，一次 stat 拿全（0.8 ms 对 576 ms）。指纹没变就
    # 沿用上一轮 probe-slow.tsv 里的值 —— 那是**上一次真算过的结果**，不是猜的。
    # 装完包那条命令收尾时框架会踢一轮慢档（D232），而装包必然动 dpkg/status，
    # 所以「装完补丁那条红告警立刻消」这条路是通的。
    #
    # 只缓存**周期性**这条路径。`safe status` / `safe updates` 是人敲的，那时的
    # 576 ms 是他要的答案，照旧现算 —— 人主动问的时刻恰恰最不该给旧数。
    local prev_slow="${OS_PUBLIC_DIR}/${TIER_SLOW}" apt_total='' apt_security=''
    os::query --timeout 5 -- stat -c '%Y' /var/lib/apt/lists /var/lib/dpkg/status
    local fp=${OS_RUN_OUTPUT//$'\n'/-} fp_old
    fp_old=$(snapshot_value "${prev_slow}" 'apt.fingerprint')
    if [[ -n ${fp} && ${fp} == "${fp_old}" ]]; then
        apt_total=$(snapshot_value "${prev_slow}" 'apt.upgradable')
        apt_security=$(snapshot_value "${prev_slow}" 'apt.upgradable_security')
    fi
    if [[ -z ${apt_total} ]]; then
        probe::apt_upgrade_stats
        IFS=$'\t' read -r apt_total apt_security <<<"${OS_PROBE_VALUE}"
    fi
    OS_PROBE_VALUE=${fp}
    snap 'apt.fingerprint'
    OS_PROBE_VALUE=${apt_total}
    snap 'apt.upgradable'
    OS_PROBE_VALUE=${apt_security}
    snap 'apt.upgradable_security'
    probe::auto_upgrades
    snap 'apt.auto_upgrades'
    probe::container_engine
    snap 'container.engine'
    probe::php_fpm_versions
    snap 'php.fpm_versions'
    probe::ufw_active
    snap 'ufw.status'
    probe::ufw_rules
    UFW_RULES=${OS_PROBE_VALUE}
    snap 'ufw.rules'
    probe::ssh_port
    snap 'ssh.port'
    probe::ssh_authkeys root
    snap 'ssh.authkeys.root'

    local kw
    for kw in permitrootlogin passwordauthentication pubkeyauthentication x11forwarding; do
        probe::sshd_effective "${kw}"
        snap "ssh.effective.${kw}"
    done

    local id unit pkg type
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        type=$(os::state_type "${id}")
        probe::component_version "${type}"
        snap "component.${type}.version"
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            unit=${unit#*:}
            probe::unit_exists "${unit}"
            snap "unit.${unit}.exists"
            probe::service_enabled "${unit}"
            snap "unit.${unit}.enabled"
            probe::unit_result "${unit}"
            snap "unit.${unit}.result"
            if [[ ${unit} == *.timer ]]; then
                probe::timer_next "${unit}"
                snap "timer.${unit}.next"
            fi
        done < <(os::state_units "${id}")
        # 「有更新可装」= candidate 高于已装版本，终端上要敲 apt list
        # --upgradable 才知道，这里是白捡的一列
        while IFS= read -r pkg; do
            [[ -n ${pkg} ]] || continue
            probe::package_version "${pkg}"
            snap "pkg.${pkg}.version"
            probe::package_candidate "${pkg}"
            snap "pkg.${pkg}.candidate"
        done < <(os::state_resources "${id}" pkg)
    done < <(os::state_list)

    # 容器打了 io.containers.autoupdate 标签,但这个 timer 没启用的话什么也不会发生。
    # 只报标签等于报了半件事
    probe::service_enabled 'podman-auto-update.timer'
    snap 'unit.podman-auto-update.timer.enabled'

    # service 与 timer 的 exists 都要采。只采 timer 的话，没配过备份的机器上
    # 那条 service 行就只有一个 `inactive` —— 分不出「停着」和「压根没装」，
    # 而面板把这两种情况画成同一种红色
    probe::unit_exists 'oneserver-backup'
    snap 'unit.oneserver-backup.exists'
    probe::service_enabled 'oneserver-backup'
    snap 'unit.oneserver-backup.enabled'
    probe::unit_exists 'oneserver-backup.timer'
    snap 'unit.oneserver-backup.timer.exists'
    probe::service_enabled 'oneserver-backup.timer'
    snap 'unit.oneserver-backup.timer.enabled'
    probe::unit_result 'oneserver-backup'
    snap 'unit.oneserver-backup.result'
    probe::timer_next 'oneserver-backup.timer'
    snap 'timer.oneserver-backup.timer.next'
    return 0
}

# ------------------------------------------------------------------
# 日志副本 —— 面板的日志页要通过 HTTP 读，而原文件读不到
# ------------------------------------------------------------------
#
# `/var/log/oneserver/` 是 0750、JSONL 是 0640，跑 Caddy 的那个用户进不去。
# 两条路：放宽原文件权限，或复制一份到 public/。**选复制**——放宽等于把
# 目录里的 *所有* 文件（含 audit.log）一起交出去，而 audit 记的是每条实际
# 执行过的命令行，是这台机器上最不该公开的一份。
#
# **只复制 JSONL，不碰 audit.log。** JSONL 的脱敏在 log::write 写入前就完成了
# （规范 §9），所以这份副本本身是安全的。
#
# 只取尾部：原文件 20M 才轮转，整份复制会让每轮采集都搬几十兆。
# 副本被整份重写不影响前端 —— 它按 HTTP 状态码判断拿到的是不是增量，
# 发现是全量就重建列表。
readonly LOG_TAIL_LINES='2000'

publish_log() {
    [[ -r ${OS_LOG_JSONL} ]] || return 0
    os::query --timeout 5 -- tail -n "${LOG_TAIL_LINES}" "${OS_LOG_JSONL}" || return 0
    os::write_public 'oneserver.jsonl' "${OS_RUN_OUTPUT}" || true
    return 0
}

# ------------------------------------------------------------------
# state 副本 —— 面板要按组件展开资源清单，而 state 文件是 0640 读不到
# ------------------------------------------------------------------
#
# 不复制原文件而是用只读接口重建：原文件里有什么将来会变，而这份副本
# 是给外部消费的，字段得是我们想公开的那些。凭据永不进 state，但
# **公开一份 0644 的副本仍然是决定，不是顺手**——所以这里逐字段列，
# 不用 `cat`。
#
# --- 为什么要多记一列 kind ---
#
# state 一视同仁地记着三类东西，而它们在用户心里是三件不同的事：
#
#   app       装上去的软件      caddy · mariadb · podman · php:8.3 · nodejs:22
#   instance  用软件建出来的    db:blog · wordpress:shop · container:redis
#   feature   本工具的功能开关  firewall · backup · web · auto-updates
#
# 面板从前按 id 字母序排，于是 `auto-updates` 排在最前、`backup` 夹在
# `caddy` 前面 —— 看起来像随机，实际是一个对这三类毫无意义的序。
#
# **判据取自 @provides 元数据，不写死一张表**：`script/install/**` 声明过的
# type 就是「应用」。新增一个 install_*.sh，面板上的分类自动跟上，前端一个字
# 都不用改（同 install_apps.sh 从 @provides 推导可装列表的做法）。
APP_TYPES=''

load_app_types() {
    APP_TYPES=''
    # `@provides_unit` 不会被误收：这里要求 @provides 后面紧跟空白，而那个
    # 字段接的是下划线
    os::query -- grep -hE '^#[[:space:]]*@provides[[:space:]]' \
        "${OS_SCRIPT_DIR}"/install/*.sh || return 0
    local line t
    while IFS= read -r line; do
        t=${line##*@provides}
        t=${t//[[:space:]]/}
        # `php:<version>` 这类占位符只取 type 那一段
        t=${t%%:*}
        [[ -n ${t} ]] && APP_TYPES+=" ${t} "
    done <<<"${OS_RUN_OUTPUT}"
    return 0
}

component_kind() {
    local id=${1} type=${1%%:*}
    if [[ ${APP_TYPES} == *" ${type} "* ]]; then
        printf 'app'
    elif [[ ${id} == *:* ]]; then
        printf 'instance'
    else
        printf 'feature'
    fi
}

build_components() {
    load_app_types
    local out='' id key val unit res kind
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        out+="${id}"$'\t'kind$'\t'"$(component_kind "${id}")"$'\n'
        for key in version installed_at domain; do
            val=$(os::state_get "${id}" "${key}" '') || val=''
            [[ -n ${val} ]] && out+="${id}"$'\t'"${key}"$'\t'"${val}"$'\n'
        done
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            out+="${id}"$'\t'unit$'\t'"${unit}"$'\n'
        done < <(os::state_units "${id}")
        for kind in pkg file divert alt; do
            while IFS= read -r res; do
                [[ -n ${res} ]] || continue
                out+="${id}"$'\t'"${kind}"$'\t'"${res}"$'\n'
            done < <(os::state_resources "${id}" "${kind}")
        done
    done < <(os::state_list)
    printf '%s' "${out}"
}

# ------------------------------------------------------------------
# 容器清单 —— 一行一个容器，十一列：
#   引擎 名字 镜像 状态 重启 健康 自动更新 watchtower 端口 镜像ID 挂载
# ------------------------------------------------------------------
#
# **独立文件、一行一条**，不塞进快照的 key/value。快照的值是「换行压成空格」的，
# 多条记录只能靠「空格分记录、制表符分字段」再切回来，而容器的状态串本来就带空格
# （`Up About an hour`），切点会落在句子中间，整张表错位。端口那个 key 一直是
# 靠运气才没散架。
build_containers() {
    local out='' eng line
    probe::container_engines || true
    local engines=${OS_PROBE_VALUE}
    for eng in ${engines}; do
        probe::container_inventory "${eng}" || continue
        [[ -n ${OS_PROBE_VALUE} ]] || continue
        while IFS= read -r line; do
            [[ -n ${line} ]] || continue
            out+="${eng}"$'\t'"${line}"$'\n'
        done <<<"${OS_PROBE_VALUE}"
    done
    printf '%s' "${out}"
}

# ------------------------------------------------------------------
# 容器卷与镜像更新 —— 两份独立文件，都跟慢档走
# ------------------------------------------------------------------
#
# 跟慢档而不是快档：`du` 是不封顶的开销，而卷的大小与「上次换镜像是什么时候」
# 都不是秒级会变的东西。放快档等于每 30 秒把所有卷重新量一遍。
#
# volumes.tsv 一行一个挂载，七列：
#   引擎 · 容器 · 类型 · 卷名 · 源路径 · 目标路径 · 字节
#
# **只对命名卷（类型 volume）量大小。** bind mount 的源是用户自己的目录，可能是
# /srv、可能是 /——对它跑 du 是在每轮采集里埋一颗定时炸弹，而那个目录多大本来
# 就该由它的主人心里有数。量不出来（超时）时字节留空，前端显示「—」；
# **不写 0** ——那是在报一件没有依据的事。
#
# container-updates.tsv 一行一个容器，五列：
#   引擎 · 容器 · 镜像ID · 镜像变更时间(epoch) · 首次观察时间(epoch)
#
# **判据是镜像 ID 变了，不是容器重启了。** 自动更新查过一遍没发现新版本时
# 什么都不会变；原地 restart、systemd 重建 Quadlet 容器会换启动时间甚至换
# 容器 ID，但镜像 ID 不动。只有真的拉到新镜像并换上去，这一列才会变 ——
# 那正是「确实更新成功」的定义。
#
# **第一次见到一个容器时，变更时间记 0（未知）而不是 now。** 面板是某天才启用的，
# 在那之前它更新过多少次无从得知；把「我开始观察的时刻」说成「它更新的时刻」
# 是编一个数出来。前端据此显示「自 X 起未变」而不是「更新于 X」。
readonly UPDATES_FILE='container-updates.tsv'

# 按制表符切一行，结果写进 TSV_FIELDS。
#
# **不能直接 `IFS=$'\t' read`**：制表符是 IFS 的**空白**字符，连续多个会被合并
# 成一个分隔符，中间的空字段直接消失。容器行里空字段是常态（没有自动更新标签、
# 没有 watchtower 标签、没有端口映射的容器一连三个空），于是后面的字段整排左移，
# 镜像 ID 被读成空 —— 而这一切不报任何错。真机上第一次跑就撞上了。
# 换成一个非空白分隔符（US，0x1f）再切，空字段才各占各的位置。
#
# 行尾的空字段仍然不会产生元素，所以取值一律用 `${TSV_FIELDS[n]-}`。
readonly TSV_SEP=$'\x1f'
TSV_FIELDS=()

tsv_split() {
    local __one=${1//$'\t'/${TSV_SEP}}
    TSV_FIELDS=()
    IFS="${TSV_SEP}" read -r -a TSV_FIELDS <<<"${__one}"
    return 0
}

CONTAINER_VOLUMES=''
CONTAINER_UPDATES=''

build_container_extras() {
    CONTAINER_VOLUMES=''
    CONTAINER_UPDATES=''

    # 上一轮记下的镜像 ID。键是 `引擎<TAB>容器名`
    local -A prev_img=() prev_at=() prev_seen=()
    local line e n at seen
    if [[ -r "${OS_PUBLIC_DIR}/${UPDATES_FILE}" ]]; then
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ -n ${line} ]] || continue
            tsv_split "${line}"
            e=${TSV_FIELDS[0]-}
            n=${TSV_FIELDS[1]-}
            [[ -n ${e} && -n ${n} ]] || continue
            prev_img["${e}"$'\t'"${n}"]=${TSV_FIELDS[2]-}
            prev_at["${e}"$'\t'"${n}"]=${TSV_FIELDS[3]-}
            prev_seen["${e}"$'\t'"${n}"]=${TSV_FIELDS[4]-}
        done <"${OS_PUBLIC_DIR}/${UPDATES_FILE}"
    fi

    local now
    printf -v now '%(%s)T' -1

    local eng line name img_id mounts one key kind vol src dst bytes
    probe::container_engines || true
    local engines=${OS_PROBE_VALUE}
    for eng in ${engines}; do
        probe::container_inventory "${eng}" || continue
        [[ -n ${OS_PROBE_VALUE} ]] || continue
        while IFS= read -r line || [[ -n ${line} ]]; do
            [[ -n ${line} ]] || continue
            tsv_split "${line}"
            name=${TSV_FIELDS[0]-}
            img_id=${TSV_FIELDS[8]-}
            mounts=${TSV_FIELDS[9]-}
            [[ -n ${name} ]] || continue

            # --- 镜像更新 ---
            key="${eng}"$'\t'"${name}"
            if [[ -z ${prev_img[${key}]-} ]]; then
                at=0
                seen=${now}
            elif [[ ${prev_img[${key}]} != "${img_id}" ]]; then
                at=${now}
                seen=${prev_seen[${key}]:-${now}}
            else
                at=${prev_at[${key}]:-0}
                seen=${prev_seen[${key}]:-${now}}
            fi
            CONTAINER_UPDATES+="${eng}"$'\t'"${name}"$'\t'"${img_id}"$'\t'"${at}"$'\t'"${seen}"$'\n'

            # --- 卷 ---
            #
            # 循环里调 probe::dir_size_kb 会覆写 OS_PROBE_VALUE，而外层 while 正
            # 读着它 —— 不冲突：`<<<` 的展开在循环建立时就完成了，读的是那份副本。
            # `IFS=… read` 只对那一条命令生效，不会漏到后面的展开上（D91）
            local -a mlist=()
            IFS=' ' read -r -a mlist <<<"${mounts}"
            for one in ${mlist[@]+"${mlist[@]}"}; do
                [[ -n ${one} ]] || continue
                IFS='|' read -r kind vol src dst <<<"${one}"
                [[ -n ${src} ]] || continue
                bytes=''
                if [[ ${kind} == volume ]]; then
                    probe::dir_size_kb "${src}"
                    [[ -z ${OS_PROBE_VALUE} ]] || bytes=$((OS_PROBE_VALUE * 1024))
                fi
                CONTAINER_VOLUMES+="${eng}"$'\t'"${name}"$'\t'"${kind}"$'\t'"${vol}"$'\t'"${src}"$'\t'"${dst}"$'\t'"${bytes}"$'\n'
            done
        done <<<"${OS_PROBE_VALUE}"
    done
    return 0
}

# ------------------------------------------------------------------
# 防火墙规则 —— 独立文件，一行一条端口规则
# ------------------------------------------------------------------
#
# `ufw status numbered` 是面向终端的列宽文本，塞进快照后换行会被压成空格，
# 前端既无法正确分行，也无法拿它和监听端口对照。这里把端口、动作、来源和
# 网络族拆成四列；IPv4 / IPv6 的等价规则合并，既保留覆盖范围又不重复占行。
build_firewall() {
    local -a keys=() families=()
    local line target action source family key
    while IFS= read -r line; do
        [[ ${line} =~ ^\[[[:space:]]*[0-9]+\][[:space:]]+(.+)[[:space:]]+(ALLOW|DENY|REJECT|LIMIT)[[:space:]]+(IN|OUT|FWD)[[:space:]]+(.+)$ ]] || continue
        target=${BASH_REMATCH[1]}
        action="${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
        source=${BASH_REMATCH[4]}
        target=${target#"${target%%[![:space:]]*}"}
        target=${target%"${target##*[![:space:]]}"}
        source=${source#"${source%%[![:space:]]*}"}
        source=${source%"${source##*[![:space:]]}"}
        family='IPv4'
        if [[ ${target} == *' (v6)' ]]; then
            target=${target% \(v6\)}
            family='IPv6'
        fi
        source=${source% \(v6\)}
        # 面板的目标是「哪些端口放行了」，不把转发网段、应用名等非端口规则
        # 混进来；监听对照也只关心 TCP / UDP 端口与范围。
        [[ ${target} =~ ^[0-9]+(:[0-9]+)?/(tcp|udp)$ ]] || continue
        key="${target}"$'\t'"${action}"$'\t'"${source}"
        local -i i found=-1
        for ((i = 0; i < ${#keys[@]}; i++)); do
            [[ ${keys[i]} == "${key}" ]] && {
                found=${i}
                break
            }
        done
        if ((found < 0)); then
            keys+=("${key}")
            families+=("${family}")
        elif [[ ${families[found]} != *"${family}"* ]]; then
            families[found]+=" + ${family}"
        fi
    done <<<"${UFW_RULES}"

    local -i i
    for ((i = 0; i < ${#keys[@]}; i++)); do
        printf '%s\t%s\n' "${keys[i]}" "${families[i]}"
    done
    return 0
}

# ------------------------------------------------------------------
# 备份归档 —— 布局 <type>/<name>/<时间戳>.tar.gz（规范承诺的对外布局）
# ------------------------------------------------------------------
build_backups() {
    local out='' d n last count size
    [[ -d ${OS_ARCHIVE_DIR} ]] || {
        printf ''
        return 0
    }
    local type_dir name_dir
    for type_dir in "${OS_ARCHIVE_DIR}"/*/; do
        [[ -d ${type_dir} ]] || continue
        d=${type_dir%/}
        d=${d##*/}
        for name_dir in "${type_dir}"*/; do
            [[ -d ${name_dir} ]] || continue
            n=${name_dir%/}
            n=${n##*/}
            count=0
            size=0
            last=''
            local f
            for f in "${name_dir}"*.tar.gz; do
                [[ -f ${f} ]] || continue
                count=$((count + 1))
                local bytes mtime
                bytes=0
                mtime=0
                os::query -- stat -c %s -- "${f}" && bytes=${OS_RUN_OUTPUT}
                os::query -- stat -c %Y -- "${f}" && mtime=${OS_RUN_OUTPUT}
                [[ ${bytes} =~ ^[0-9]+$ ]] || bytes=0
                [[ ${mtime} =~ ^[0-9]+$ ]] || mtime=0
                size=$((size + bytes))
                [[ -z ${last} || ${mtime} -gt ${last} ]] && last=${mtime}
            done
            [[ ${count} -eq 0 ]] && continue
            out+="${d}"$'\t'"${n}"$'\t'"${last}"$'\t'"${count}"$'\t'"${size}"$'\n'
        done
    done
    printf '%s' "${out}"
}

main() {
    local tier
    os::ask --arg tier '采集哪一档' tier 'all'
    case ${tier} in
        live | fast | slow | all) ;;
        *)
            os::die 2 "--tier 只能是 live / fast / slow / all，收到「${tier}」"
            ;;
    esac

    if [[ ${tier} == live || ${tier} == all ]]; then
        snap_begin
        collect_live
        os::write_public "${TIER_LIVE}" "${SNAP}"
    fi

    if [[ ${tier} == fast || ${tier} == all ]]; then
        snap_begin
        collect_fast
        os::write_public "${TIER_FAST}" "${SNAP}"
        append_history
        # 容器清单跟快档走：容器起停是秒级的事，5 分钟一次的话页面上
        # 一个已经挂掉的容器还会显示成运行中
        os::write_public 'containers.tsv' "$(build_containers)"
        # 日志跟快档一起走：日志页要的是「刚发生了什么」，5 分钟一次没意义
        publish_log
        publish_alerts
    fi

    if [[ ${tier} == slow || ${tier} == all ]]; then
        snap_begin
        collect_slow
        os::write_public "${TIER_SLOW}" "${SNAP}"
        os::write_public 'components.tsv' "$(build_components)"
        os::write_public 'backups.tsv' "$(build_backups)"
        os::write_public 'firewall.tsv' "$(build_firewall)"
        # 两份产物一次容器巡检出，所以不走 `$(build_…)` 那种子 shell 取值：
        # 两个返回值一个命令替换带不出来，而分两次巡检就是把 inspect 跑两遍
        build_container_extras
        os::write_public 'volumes.tsv' "${CONTAINER_VOLUMES}"
        os::write_public "${UPDATES_FILE}" "${CONTAINER_UPDATES}"
        publish_alerts
    fi

    # 例行成功不进日志。这条命令由 timer 每 3 到 300 秒跑一次（视档位）,「已更新」写进 JSONL
    # 的唯一效果是把真实事件挤出保留窗口 —— 而且日志一变,publish_log 写出去的
    # 那份副本(200 KB+)就得整份重写,占了这台机器几乎全部的磁盘写入。
    # 人手敲的时候照常给回执:那时没有重复,而沉默的成功分不清跑没跑。
    if [[ ${OS_NON_INTERACTIVE} -eq 1 ]]; then
        os::debug "面板数据已更新（${tier}）"
    else
        os::ok "面板数据已更新（${tier}）"
    fi
    return 0
}

main "$@"
