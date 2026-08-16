#!/bin/bash
#
# 空间清理：报告可回收的文件，并按危险程度分档删除
#
# @command      clean
# @name         空间清理
# @group        toolbox
# @order        30
# @privilege    root
# @requires_lib >= 3.5
# @args         [--action=<overview|safe|apt|tmp|logs|images|old|volumes|archives>] [--yes-apt=<y|n>] [--yes-tmp=<y|n>] [--yes-logs=<y|n>] [--yes-images=<y|n>] [--confirm-old=<old>] [--confirm-volumes=<volumes>]
# @description  报告并清理缓存、临时文件、轮转日志与容器垃圾
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 这个脚本为什么长这样
# ==================================================================
#
# ## 一、先算后删，永远两步
#
# 默认动作是 `overview`，它**只扫描不删除**。清理类功能最大的事故来源是
# 「用户以为清的是缓存，实际清掉了唯一一份备份」——把「有多少」和「删掉它」
# 分成两条命令，中间那一屏就是唯一能拦住这件事的地方。
#
# ## 二、扫描与删除共用同一份判据
#
# 每一类各写一个 `scan_*`，结果写进全局变量；`overview` 和真正的清理动作
# **读的是同一次扫描**。两套判据迟早分叉，而分叉的现场表现是「报告说能清
# 200M，删完只少了 3M」——用户从此不再相信这个功能给的任何数字。
#
# ## 三、分两档，没有「一键全清」
#
# 安全档（apt 缓存 · 孤儿临时目录 · 已轮转日志 · 悬空镜像层）删了会自动重建，
# 走普通确认，允许一条命令做完。
#
# 危险档（`.old` · 未被引用的容器卷）不可逆且代价高，各自 `os::destroy_confirm`
# 打全名，**逐条列出**具体路径。规范 §10 要求不可逆操作 `--yes` 无效、必须
# 独立的 `--force-destroy`——一个能一次批准全部危险项的开关与那条直接冲突，
# 所以不提供。
#
# ## 四、无主归档只报告，不删除
#
# 「盘上有、state 里没登记」的备份目标是真实存在的一类（`backup overview`
# 现在就在取两者并集）。但它是用户的救命数据，而 `backup remove` 已经是管
# 归档的正规入口——在这里再开一个删除口，等于多一个能误删备份的地方。
# 因此这里只列出来并把那条命令打给用户。
#
# ## 五、不碰 journald，不碰 apt 的孤儿包
#
# `journalctl --vacuum-*` 只能按时间或大小清，会连**整台机器**其它服务的
# 历史日志一起带走，代价远超收益；`apt-get autoremove` 删的是包不是缓存，
# 那是另一个决定。两者都只在 overview 里报告占用并把命令打出来，让人自己判断。

# ------------------------------------------------------------------
# 常量
# ------------------------------------------------------------------

readonly APT_CACHE='/var/cache/apt/archives'
readonly CADDY_LOG_DIR='/var/log/caddy'

# 扫描结果。**KB 为单位**：du -sk 是唯一在 Debian/Ubuntu 上都不用装东西就有的
# 尺寸来源，而 du -sh 的输出带单位、不能相加
CL_APT_KB=0
CL_APT_N=0
CL_TMP_KB=0
CL_TMP_DIRS=''
CL_LOG_KB=0
CL_LOG_FILES=''
CL_OLD_KB=0
CL_OLD_DIRS=''
CL_IMG_N=0
CL_VOL_N=0
CL_VOL_LIST=''
CL_ARCH_ORPHAN=''

# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

# hsize <KB>   给人看的尺寸。整数除法即可 —— 这一屏是「值不值得清」，
# 不是账单，小数点后一位不会改变任何人的决定
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

# done_msg <KB>   收尾那句话。**dry-run 下不能说「已回收」** —— 预演里一个
# 字节都没少，而用户读到的是一句完成语；下次他就不会再信 --dry-run 了
done_msg() {
    local -i kb=${1:-0}
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将回收 $(hsize "${kb}")"
    else
        os::ok "已回收 $(hsize "${kb}")"
    fi
    return 0
}

# du_kb <路径>   路径不在就是 0，不报错
#
# 走 os::query 而不是裸 `du`：规范要求只读查询经带超时的通道，而这里正是最需要
# 超时的地方——`du` 撞上一个挂死的 NFS 挂载点会永远回不来，那时清理页整个卡住。
# （它不进审计日志：os::query 本就不产生审计记录。）
#
# **超时给的是 OS_DEFAULT_SCAN_TIMEOUT 而不是 probe 那 3 秒**：`du -sk /var/log`
# 在攒了半年日志的机器上十几秒很正常，按 3 秒算的话，越该清的机器越会显示成 0。
#
# 量不出来时返回 0 但**当场 warn 一声**：这个函数几乎都在 `$( )` 里调用，
# 想靠全局标记把「没量出来」传回去是传不出来的（子 shell），而 warn 走 stderr，
# 命令替换不捕获它，用户看得见。静默返回 0 才是最坏的那种——它和「真的是空的」
# 长得一模一样。
du_kb() {
    local p=${1}
    [[ -e ${p} ]] || {
        printf '0'
        return 0
    }
    if ! os::query --timeout "${OS_DEFAULT_SCAN_TIMEOUT}" -- du -sk -- "${p}"; then
        os::warn "${p} 未能在 ${OS_DEFAULT_SCAN_TIMEOUT} 秒内扫完，这一项按 0 计"
        printf '0'
        return 0
    fi
    printf '%s' "${OS_RUN_OUTPUT%%[[:space:]]*}"
}

# ------------------------------------------------------------------
# 扫描
# ------------------------------------------------------------------

scan_apt() {
    CL_APT_KB=0
    CL_APT_N=0
    [[ -d ${APT_CACHE} ]] || return 0
    # 只算 .deb：目录里还有 lock 与 partial/，那些不是可回收的东西
    local out=''
    os::query --timeout "${OS_DEFAULT_SCAN_TIMEOUT}" -- \
        find "${APT_CACHE}" -maxdepth 1 -type f -name '*.deb' && out=${OS_RUN_OUTPUT}
    [[ -n ${out} ]] || return 0
    CL_APT_N=$(printf '%s\n' "${out}" | grep -c . || true)
    local f
    while IFS= read -r f; do
        [[ -n ${f} ]] || continue
        CL_APT_KB=$((CL_APT_KB + $(du_kb "${f}")))
    done <<<"${out}"
    return 0
}

# 孤儿临时目录。
#
# **判据是「存在即孤儿」，不看时间戳。** 正常路径下 os::tmpdir 建的目录由
# errors.sh 的每一条退出路径清掉（正常 / 失败 / 信号），能留下来的只有进程被
# SIGKILL 或机器掉电那两种。而本脚本是 `@privilege root`——它**持着全局锁**，
# 此刻不可能有第二条 oneserver 命令正在用这些目录。
#
# D244 之后 os::tmpdir 只剩这一条通道（从前默认落 /run 的 tmpfs，那条重启即空、
# 不需要扫）—— 于是**所有**残留都在这里，扫描范围比过去大了，也才真的扫得全。
scan_tmp() {
    CL_TMP_KB=0
    CL_TMP_DIRS=''
    [[ -d ${OS_TMP_ROOT} ]] || return 0
    local out=''
    os::query --timeout "${OS_DEFAULT_SCAN_TIMEOUT}" -- \
        find "${OS_TMP_ROOT}" -mindepth 1 -maxdepth 1 && out=${OS_RUN_OUTPUT}
    [[ -n ${out} ]] || return 0
    CL_TMP_DIRS=${out}
    local d
    while IFS= read -r d; do
        [[ -n ${d} ]] || continue
        CL_TMP_KB=$((CL_TMP_KB + $(du_kb "${d}")))
    done <<<"${out}"
    return 0
}

# 已轮转的日志。
#
# **只认轮转产物，绝不碰正在写的那份**：`.gz` 与 `.1` 是 logrotate 与 Caddy
# 转出来的历史，删掉只丢历史；而删正在写的文件会让写入方继续往一个已经
# unlink 的 inode 里写，磁盘不会释放、日志也再看不见（K13 那一类）。
scan_logs() {
    CL_LOG_KB=0
    CL_LOG_FILES=''
    local dir out all=''
    for dir in "${OS_LOG_DIR}" "${CADDY_LOG_DIR}"; do
        [[ -d ${dir} ]] || continue
        out=''
        os::query --timeout "${OS_DEFAULT_SCAN_TIMEOUT}" -- \
            find "${dir}" -maxdepth 1 -type f \
            \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9][0-9]' \) && out=${OS_RUN_OUTPUT}
        [[ -n ${out} ]] && all+="${out}"$'\n'
    done
    all=$(printf '%s' "${all}" | grep -v '^[[:space:]]*$' || true)
    [[ -n ${all} ]] || return 0
    CL_LOG_FILES=${all}
    local f
    while IFS= read -r f; do
        [[ -n ${f} ]] || continue
        CL_LOG_KB=$((CL_LOG_KB + $(du_kb "${f}")))
    done <<<"${all}"
    return 0
}

# 上一版程序与更新残留。
#
# `.old` 是 `oneserver update rollback` 的**唯一**依据 —— 删了它就再也退不回
# 上一版。`.staging` 是更新中断留下的半成品，本身没有价值，但它俩同属
# 「更新留下的东西」，一起报告、一起确认，用户才好一次想清楚。
scan_old() {
    CL_OLD_KB=0
    CL_OLD_DIRS=''
    local d
    for d in "${OS_ROOT}/.old" "${OS_ROOT}/.staging"; do
        [[ -d ${d} ]] || continue
        CL_OLD_DIRS+="${d}"$'\n'
        CL_OLD_KB=$((CL_OLD_KB + $(du_kb "${d}")))
    done
    CL_OLD_DIRS=$(printf '%s' "${CL_OLD_DIRS}" | grep -v '^[[:space:]]*$' || true)
    return 0
}

# 容器垃圾。**不自己算，问引擎要**：悬空层的判定归引擎，自己按 `docker images`
# 的输出去猜迟早跟引擎的版本行为分叉
scan_containers() {
    CL_IMG_N=0
    CL_VOL_N=0
    CL_VOL_LIST=''
    probe::container_engines
    local engines=${OS_PROBE_VALUE}
    [[ -n ${engines} ]] || return 0

    local eng out line
    while IFS= read -r eng; do
        [[ -n ${eng} ]] || continue
        os::query --timeout 30 -- "${eng}" images --filter dangling=true --format '{{.ID}}' || continue
        out=${OS_RUN_OUTPUT}
        [[ -n ${out} ]] && CL_IMG_N=$((CL_IMG_N + $(printf '%s\n' "${out}" | grep -c . || true)))

        # 未被任何容器引用的卷。**卷里很可能是数据库的数据目录** —— 一个停掉
        # 的容器被删掉之后，它的卷就变成「未引用」，而那正是用户还想要的数据。
        # 所以这一类进危险档，且清单里逐个列出卷名
        os::query --timeout 30 -- "${eng}" volume ls --filter dangling=true --format '{{.Name}}' || continue
        out=${OS_RUN_OUTPUT}
        while IFS= read -r line; do
            [[ -n ${line} ]] || continue
            CL_VOL_N=$((CL_VOL_N + 1))
            CL_VOL_LIST+="${eng}  ${line}"$'\n'
        done <<<"${out}"
    done <<<"${engines}"
    CL_VOL_LIST=$(printf '%s' "${CL_VOL_LIST}" | grep -v '^[[:space:]]*$' || true)
    return 0
}

# 无主归档：盘上有归档目录、但 state 里没有对应备份目标的。
#
# 判据取自 backup 的登记：`backup-path:<别名>` 与站点/库各自的组件标识。
# 这里**只比对，不删除**（见头部第四节）。
scan_archives() {
    CL_ARCH_ORPHAN=''
    [[ -d ${OS_ARCHIVE_DIR} ]] || return 0

    local registered='' id
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        registered+="${id}"$'\n'
    done < <(os::state_list)

    # **先把目录列表整个复制出来再遍历**：循环体里的 du_kb 也走 os::query，
    # 而那是个单槽返回通道（规范 §10）—— 边读 OS_RUN_OUTPUT 边往里写，
    # 遍历到第二个目录时列表就已经被自己的尺寸查询覆盖掉了
    local dirs=''
    os::query --timeout "${OS_DEFAULT_SCAN_TIMEOUT}" -- \
        find "${OS_ARCHIVE_DIR}" -mindepth 2 -maxdepth 2 -type d && dirs=${OS_RUN_OUTPUT}
    [[ -n ${dirs} ]] || return 0

    local dir rel target kb
    while IFS= read -r dir; do
        [[ -n ${dir} ]] || continue
        rel=${dir#"${OS_ARCHIVE_DIR}/"}
        # 归档布局是 <type>/<name>，组件标识是 <type>:<name>
        target=${rel//\//:}
        [[ ${registered} == *"${target}"$'\n'* ]] && continue
        # backup 自己的目标登记在 backup-path:<别名> 下
        [[ ${registered} == *"backup-path:${rel#*/}"$'\n'* ]] && continue
        kb=$(du_kb "${dir}")
        CL_ARCH_ORPHAN+="${target}"$'\t'"${kb}"$'\n'
    done <<<"${dirs}"
    CL_ARCH_ORPHAN=$(printf '%s' "${CL_ARCH_ORPHAN}" | grep -v '^[[:space:]]*$' || true)
    return 0
}

scan_all() {
    scan_apt
    scan_tmp
    scan_logs
    scan_old
    scan_containers
    scan_archives
    return 0
}

# ------------------------------------------------------------------
# 总览
# ------------------------------------------------------------------

action_overview() {
    scan_all
    local -i safe_kb=$((CL_APT_KB + CL_TMP_KB + CL_LOG_KB))

    os::section '可以直接清（删了会自动重建）'
    os::kv \
        'APT 包缓存' "$(hsize "${CL_APT_KB}") · ${CL_APT_N} 个 deb" \
        '孤儿临时目录' "$(hsize "${CL_TMP_KB}") · $(printf '%s' "${CL_TMP_DIRS}" | grep -c . || true) 个" \
        '已轮转日志' "$(hsize "${CL_LOG_KB}") · $(printf '%s' "${CL_LOG_FILES}" | grep -c . || true) 份" \
        '悬空镜像层' "${CL_IMG_N} 个" \
        '合计（不含镜像）' "$(hsize "${safe_kb}")"

    os::section '要单独确认（不可逆）'
    local old_note=''
    [[ -d "${OS_ROOT}/.old" ]] && old_note=' · 删了就退不回上一版'
    os::kv \
        '上一版程序' "$(hsize "${CL_OLD_KB}")${old_note}" \
        '未被引用的卷' "${CL_VOL_N} 个"

    if [[ -n ${CL_VOL_LIST} ]]; then
        os::warn '卷里很可能是数据库的数据目录 —— 逐个看清楚再决定'
    fi

    os::section '只报告，不在这里删'
    if [[ -n ${CL_ARCH_ORPHAN} ]]; then
        local target kb
        while IFS=$'\t' read -r target kb; do
            [[ -n ${target} ]] || continue
            os::kv "无主归档 ${target}" "$(hsize "${kb}")"
        done <<<"${CL_ARCH_ORPHAN}"
        os::warn '这些归档在 state 里没有对应的备份目标，但它们是你的数据'
        os::info '    要删就走正规入口：oneserver backup remove'
    else
        os::info '    没有无主归档'
    fi

    os::spacer
    # 这两样不做，但要说清「为什么不做」和「你自己怎么做」——只说不做，
    # 用户下一步就是去搜一条来路不明的命令
    os::info '本命令不碰 journald（只能整机清）与 apt 孤儿包（那是删包不是删缓存）'
    os::info '    journalctl --disk-usage · apt-get autoremove --purge'

    os::output 0 safe_kb="${safe_kb}" apt_kb="${CL_APT_KB}" tmp_kb="${CL_TMP_KB}" \
        log_kb="${CL_LOG_KB}" old_kb="${CL_OLD_KB}" images="${CL_IMG_N}" \
        volumes="${CL_VOL_N}" orphan_archives="$(printf '%s' "${CL_ARCH_ORPHAN}" | grep -c . || true)"
    return 0
}

# ------------------------------------------------------------------
# 安全档
# ------------------------------------------------------------------

action_apt() {
    scan_apt
    os::section '清理 APT 包缓存'
    if ((CL_APT_N == 0)); then
        os::info '没有可清的 deb 缓存'
        os::output 0 freed_kb=0
        return 0
    fi
    os::kv '可回收' "$(hsize "${CL_APT_KB}") · ${CL_APT_N} 个 deb"
    if ! os::confirm --arg yes-apt '清掉这些缓存？（下次装包时会重新下载）' 'y'; then
        os::info '已取消'
        os::output 130 freed_kb=0
        return 0
    fi
    os::pkg_clean || os::die 1 '清理 APT 包缓存失败'
    done_msg "${CL_APT_KB}"
    os::output 0 freed_kb="${CL_APT_KB}"
    return 0
}

action_tmp() {
    scan_tmp
    os::section '清理孤儿临时目录'
    if [[ -z ${CL_TMP_DIRS} ]]; then
        os::info "${OS_TMP_ROOT} 下没有残留"
        os::output 0 freed_kb=0
        return 0
    fi
    local d
    while IFS= read -r d; do
        [[ -n ${d} ]] || continue
        os::info "    ${d}"
    done <<<"${CL_TMP_DIRS}"
    os::kv '可回收' "$(hsize "${CL_TMP_KB}")"
    os::info '这些是进程被强杀或机器掉电留下的 —— 正常退出时框架自己会清'
    if ! os::confirm --arg yes-tmp '清掉它们？' 'y'; then
        os::info '已取消'
        os::output 130 freed_kb=0
        return 0
    fi
    os::record_change "清理孤儿临时目录 $(hsize "${CL_TMP_KB}")"
    while IFS= read -r d; do
        [[ -n ${d} ]] || continue
        os::run --allow-fail '删除孤儿临时目录' -- rm -rf -- "${d}" || true
    done <<<"${CL_TMP_DIRS}"
    done_msg "${CL_TMP_KB}"
    os::output 0 freed_kb="${CL_TMP_KB}"
    return 0
}

action_logs() {
    scan_logs
    os::section '清理已轮转的日志'
    if [[ -z ${CL_LOG_FILES} ]]; then
        os::info '没有已轮转的日志'
        os::output 0 freed_kb=0
        return 0
    fi
    os::kv '可回收' "$(hsize "${CL_LOG_KB}") · $(printf '%s' "${CL_LOG_FILES}" | grep -c . || true) 份"
    os::info '只删轮转出来的历史（.gz / .1），正在写的那份不动'
    os::warn "审计日志按 logrotate 的策略留 26 周，清掉之后事故追溯就少了那段"
    if ! os::confirm --arg yes-logs '清掉这些历史日志？' 'n'; then
        os::info '已取消'
        os::output 130 freed_kb=0
        return 0
    fi
    os::record_change "清理已轮转日志 $(hsize "${CL_LOG_KB}")"
    local f
    while IFS= read -r f; do
        [[ -n ${f} ]] || continue
        os::run --allow-fail '删除轮转日志' -- rm -f -- "${f}" || true
    done <<<"${CL_LOG_FILES}"
    done_msg "${CL_LOG_KB}"
    os::output 0 freed_kb="${CL_LOG_KB}"
    return 0
}

# 悬空镜像层。**不自己写 prune**：docker_image.sh / podman_image.sh 里已经有
# 一条带确认的清理路径，各写各的会出现两套确认语义，而用户记住的永远是
# 宽松的那套
action_images() {
    scan_containers
    os::section '清理悬空镜像层'
    if ((CL_IMG_N == 0)); then
        os::info '没有悬空层'
        os::output 0 pruned=0
        return 0
    fi
    os::kv '悬空层' "${CL_IMG_N} 个"
    os::info '悬空层是被新版镜像顶掉的旧层，一定没有容器在用'
    if ! os::confirm --arg yes-images '清掉它们？' 'y'; then
        os::info '已取消'
        os::output 130 pruned=0
        return 0
    fi
    probe::container_engines
    local eng
    while IFS= read -r eng; do
        [[ -n ${eng} ]] || continue
        os::record_change "清理 ${eng} 的悬空镜像层"
        os::run --allow-fail '清理悬空镜像层' -- "${eng}" image prune -f || true
    done <<<"${OS_PROBE_VALUE}"
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将清理 ${CL_IMG_N} 个悬空层"
    else
        os::ok "已清理 ${CL_IMG_N} 个悬空层"
    fi
    os::output 0 pruned="${CL_IMG_N}"
    return 0
}

# 安全档一次做完。**逐项仍各自确认** —— 「一次做完」省的是重复敲命令，
# 不是省掉确认；四类的代价各不相同（清 apt 缓存只是重下，清审计日志是丢证据）
action_safe() {
    action_apt
    action_tmp
    action_logs
    action_images
    return 0
}

# ------------------------------------------------------------------
# 危险档
# ------------------------------------------------------------------

action_old() {
    scan_old
    os::section '删除上一版程序与更新残留'
    if [[ -z ${CL_OLD_DIRS} ]]; then
        os::info '没有 .old / .staging'
        os::output 0 freed_kb=0
        return 0
    fi
    local -a lines=()
    local d
    while IFS= read -r d; do
        [[ -n ${d} ]] || continue
        if [[ ${d} == */.old ]]; then
            lines+=("${d}（上一版程序，删了就再也退不回去）")
        else
            lines+=("${d}（更新中断留下的半成品）")
        fi
    done <<<"${CL_OLD_DIRS}"
    os::kv '可回收' "$(hsize "${CL_OLD_KB}")"
    if [[ -d "${OS_ROOT}/.old" ]]; then
        os::warn '删掉 .old 之后 oneserver update rollback 就没有可回退的版本了'
    fi

    if ! os::destroy_confirm --arg confirm-old 'old' -- "${lines[@]}"; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            os::info '已取消，什么都没有动'
            os::output 130 freed_kb=0
            return 0
        fi
    fi

    os::record_change "删除上一版程序 $(hsize "${CL_OLD_KB}")"
    while IFS= read -r d; do
        [[ -n ${d} ]] || continue
        os::run --allow-fail '删除更新残留' -- rm -rf -- "${d}" || true
    done <<<"${CL_OLD_DIRS}"
    done_msg "${CL_OLD_KB}"
    os::output 0 freed_kb="${CL_OLD_KB}"
    return 0
}

action_volumes() {
    scan_containers
    os::section '删除未被引用的容器卷'
    if [[ -z ${CL_VOL_LIST} ]]; then
        os::info '没有未被引用的卷'
        os::output 0 removed=0
        return 0
    fi
    local -a lines=()
    local eng name line
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        eng=${line%%[[:space:]]*}
        name=${line##*[[:space:]]}
        lines+=("${eng} 卷 ${name}")
    done <<<"${CL_VOL_LIST}"

    os::warn '卷里很可能是数据库的数据目录 —— 一个容器被删掉之后，它的卷就变成「未引用」，而那正是你还想要的数据'

    if ! os::destroy_confirm --arg confirm-volumes 'volumes' -- "${lines[@]}"; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            os::info '已取消，什么都没有动'
            os::output 130 removed=0
            return 0
        fi
    fi

    os::record_change "删除 ${CL_VOL_N} 个未被引用的容器卷"
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        eng=${line%%[[:space:]]*}
        name=${line##*[[:space:]]}
        os::run --allow-fail '删除未引用的容器卷' -- "${eng}" volume rm "${name}" || true
    done <<<"${CL_VOL_LIST}"
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将删除 ${CL_VOL_N} 个卷"
    else
        os::ok "已删除 ${CL_VOL_N} 个卷"
    fi
    os::output 0 removed="${CL_VOL_N}"
    return 0
}

# ------------------------------------------------------------------
# 只报告
# ------------------------------------------------------------------

action_archives() {
    scan_archives
    os::section '无主归档'
    if [[ -z ${CL_ARCH_ORPHAN} ]]; then
        os::info '每一份归档都有对应的备份目标'
        os::output 0 orphan=0
        return 0
    fi
    local target kb total=0
    while IFS=$'\t' read -r target kb; do
        [[ -n ${target} ]] || continue
        os::kv "${target}" "$(hsize "${kb}") · ${OS_ARCHIVE_DIR}/${target//://}"
        total=$((total + kb))
        os::output_item target="${target}" bytes_kb="${kb}"
    done <<<"${CL_ARCH_ORPHAN}"

    os::spacer
    os::warn '这些是你的备份数据，本命令不会删它们'
    os::info '确认不再需要，走备份自己的入口：oneserver backup remove'
    os::output 0 orphan="$(printf '%s' "${CL_ARCH_ORPHAN}" | grep -c . || true)" bytes_kb="${total}"
    return 0
}

# ==================================================================

dispatch() {
    case ${1} in
        overview) action_overview ;;
        safe) action_safe ;;
        apt) action_apt ;;
        tmp) action_tmp ;;
        logs) action_logs ;;
        images) action_images ;;
        old) action_old ;;
        volumes) action_volumes ;;
        archives) action_archives ;;
        *) os::die 2 "未知操作「${1}」，可用：overview safe apt tmp logs images old volumes archives" ;;
    esac
}

main() {
    os::require_cmd du find

    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_overview --arg action '操作' dispatch \
        'safe=清理全部安全项' 'apt=清 APT 包缓存' 'tmp=清孤儿临时目录' \
        'logs=清已轮转日志' 'images=清悬空镜像层' \
        'old=删上一版程序（不可逆）' 'volumes=删未引用的卷（不可逆）' \
        'archives=查看无主归档'
}

main "$@"
