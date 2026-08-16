#!/bin/bash
#
# PHP 配置更新
#
# @command      php config
# @name         PHP 配置更新
# @group        web
# @order        40
# @requires     php
# @privilege    root
# @requires_lib >= 1.14
# @provides_unit ext:php<version>-fpm.service
# @args         [--version=<ver>] [--template=<apply|edit>] [--edit-next=<y|n>] [--apply-edited=<y|n>]
# @description  用模板覆盖 PHP 配置与 FPM 进程池，失败自动回滚
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 把 probe 给的 "8.1 8.3" 洗成数组，**新的在前**。
#
# 顺序不是审美问题：`os::select` 在 --non-interactive 下取的是第一个选项，
# 而旧脚本的行为是「取最高版本」（`sort -V | tail -n1`）。新的在前，
# 这两件事才是同一件事。
#
# 单独一个函数是为了 `local IFS=' '`：文件头把 IFS 设成了 $'\n\t'，
# 空格在这里不分词。把 IFS 的改动关在函数里，别让它漏到 os::* 的调用上。
php_versions_desc() {
    local IFS=' '
    local -a asc=()
    read -r -a asc <<<"${1}" || true
    local -i i
    for ((i = ${#asc[@]} - 1; i >= 0; i--)); do
        printf '%s\n' "${asc[i]}"
    done
    return 0
}

# 用户改过的模板放 /etc/oneserver/templates/ —— 分发目录 templates/ 会被
# `oneserver update` 整个换掉，在那儿改等于白改。这个位置由 os::install_template
# 自动优先取用，脚本这边只负责把文件准备好、打开编辑器。
readonly PHPCONF_OVERRIDE_DIR="${OS_ETC_DIR}/templates"

# 模板名与落地文件名一致。`99-` 保证它排在 conf.d 里所有发行版文件之后 ——
# 后读的赢，`10-opcache.ini` 之类先设的值才盖不过这里。
readonly PHPCONF_DROPIN='99-oneserver.ini'

# 这次实际会用哪一份（覆盖的还是分发自带的）
effective_template() {
    local name=${1}
    if [[ -f "${PHPCONF_OVERRIDE_DIR}/${name}" ]]; then
        printf '%s（你改过的）\n' "${PHPCONF_OVERRIDE_DIR}/${name}"
    else
        printf '%s（分发自带）\n' "${OS_TEMPLATE_DIR}/${name}"
    fi
    return 0
}

# 第一次编辑时先把分发的那份复制到 /etc 下，人改的始终是自己那一份。
#
# `<第几个>` 会打在打开编辑器之前 —— 两份配置是**接着**编辑的，
# 不说的话第一个存盘退出、第二个立刻弹出来，人会以为自己没退出成功。
edit_template() {
    local name=${1} step=${2} what=${3}
    local dst="${PHPCONF_OVERRIDE_DIR}/${name}"
    os::run '准备模板覆盖目录' -- mkdir -p "${PHPCONF_OVERRIDE_DIR}"
    if [[ ! -f ${dst} ]]; then
        os::run '复制模板供编辑' -- cp -- "${OS_TEMPLATE_DIR}/${name}" "${dst}"
        os::run '设置模板权限' -- chmod 0640 "${dst}"
    fi
    os::section "${step} ${name} —— ${what}"
    os::info "文件：${dst}"
    os::info '%%PHP_VERSION%% 这类占位符请保留，渲染时会替换成实际版本号'
    os::info '编辑器里存盘退出后，会自动进行下一步（nano：Ctrl+O 存盘、Ctrl+X 退出）'

    # **必须在这里停一下。** 上面几行打完就直接开编辑器的话，nano/vim 一启动
    # 就清屏，那几行还没来得及被读到就被冲掉了 —— 现场表现是「什么提示都没有，
    # 直接跳进了编辑器」。停一下也顺带给了「这个文件我不想改」一个出口。
    os::confirm --arg edit-next "打开 ${name} 开始编辑？回车打开，选否跳过这一个" y || {
        os::info "已跳过 ${name}，用的还是它现在的内容"
        return 0
    }

    # 编辑器不经 os::run（它要接管终端，os::run 会把 stdout 收进日志管道，
    # 界面会完全乱掉），所以这里没有天然的 dry-run 拦截点——上面的
    # mkdir/cp/chmod 都被 os::run 自己的 dry-run 分支挡住了，唯独打开编辑器
    # 这一步是裸调用，dry-run 下会真的打开 nano 对着一个可能还不存在的
    # 路径，存盘退出就真的写了文件。不变量 5「dry-run 零变更」在这里被
    # 唯一一处裸调外部命令的地方违反。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将打开 ${dst} 供编辑（模板尚未复制，dry-run 下不预演编辑内容）"
        return 0
    fi

    "${EDITOR:-nano}" "${dst}"
    return 0
}

# maybe_restart_phpfpm <unit>   只在真有模板被写过时才重启
#
# 供 main() 的 defer 用：见那里「先注册重启、再注册备份」的说明——回滚栈
# 必须先注册它才能保证「先还原文件再重启」的顺序，但这就没法等确认真有
# 变更了再决定注册。把判断挪到回放这一刻，读的是 main() 里设的
# PHPCONF__CHANGED（脚本级变量，defer 回放时函数已经在同一个进程里，
# 直接可见）。
maybe_restart_phpfpm() {
    [[ ${PHPCONF__CHANGED:-0} -eq 1 ]] || return 0
    os::systemd_restart "${1}"
}

# ------------------------------------------------------------------

main() {
    # 1) 装了哪些 PHP —— 系统事实一律经 probe。
    #    旧脚本这里是自己 find /etc/php，那正是「18 个脚本长出 18 套探测」的起点。
    probe::php_fpm_versions
    local installed=${OS_PROBE_VALUE}
    if [[ -z ${installed} ]]; then
        os::die 3 '未检测到任何 PHP-FPM 安装，请先安装 PHP'
    fi

    local -a avail=()
    mapfile -t avail < <(php_versions_desc "${installed}")

    # 2) 选版本。位置参数优先，没给才走交互 —— 与试点脚本 ufw_manager 同一形态。
    local ver=${1-}
    if [[ -z ${ver} ]]; then
        os::select --arg version '要更新配置的 PHP 版本' ver "${avail[@]}"
    fi

    local v found=''
    for v in "${avail[@]}"; do
        [[ ${v} == "${ver}" ]] && found=1
    done
    if [[ -z ${found} ]]; then
        os::die 2 "PHP ${ver} 未安装 FPM，已装的是：${installed}"
    fi

    local dropin="/etc/php/${ver}/fpm/conf.d/${PHPCONF_DROPIN}"
    local pool="/etc/php/${ver}/fpm/pool.d/www.conf"
    local unit="php${ver}-fpm.service"
    local log_dir="/var/log/php${ver}"
    local fpm_bin="php-fpm${ver}"

    # **必须在任何副作用之前。** os::require_cmd 走 os::die 3，而框架对 2/3/4
    # 一律按「前置检查拦下、系统未变更」处理，不回放回滚栈。放在写模板之后，
    # 遇上「/etc/php/<版本> 还在但包已被 remove（conffile 不随 remove 删除）」
    # 这种机器，就会写完两份配置再报一句「缺少必需的命令」，而配置留在那儿。
    os::require_cmd "${fpm_bin}"

    os::section 'PHP 配置更新'
    os::kv '目标版本' "${ver}" \
        'PHP 配置' "${dropin}" \
        '进程池' "${pool}" \
        '数据来源' "$(probe::describe)"

    # 先让人看清「拿什么覆盖」，再决定要不要改。
    # 原来这里回车就直接盖了 —— 用户连即将写进去的是什么都没机会看一眼。
    os::info "将用这两份模板覆盖上面的配置："
    os::kv 'PHP 配置模板' "$(effective_template "${PHPCONF_DROPIN}")" \
        '进程池模板' "$(effective_template www.conf)"

    # **`--keep-screen` 不能省。** 不加的话 os::select 会清屏，上面刚打出来的
    # 「用哪两份模板、它们在哪」当场被冲掉，用户面对的是一个光秃秃的「模板」
    # 二选一 —— 而那正是他需要那两行才答得上来的问题。
    local tpl_choice=''
    os::select --keep-screen --arg template '这两份模板直接用，还是先改？' tpl_choice \
        'apply=就用上面这两份，直接更新' 'edit=先编辑它们，改完再更新'
    if [[ ${tpl_choice} == edit ]]; then
        os::info "共 2 个文件，一个接一个来：先 ${PHPCONF_DROPIN}，再 www.conf；每个打开前都会先停下来说明"
        edit_template "${PHPCONF_DROPIN}" '[1/2]' 'PHP 配置'
        edit_template www.conf '[2/2]' 'FPM 进程池'

        # 编辑完不立刻动手 —— 改完再确认一次，是给「我只是想看看」和
        # 「我改错了想重来」留的出口。此刻一个字节都还没写进 /etc/php
        os::section '两份模板都编辑完了'
        os::kv 'PHP 配置模板' "${PHPCONF_OVERRIDE_DIR}/${PHPCONF_DROPIN}" \
            '进程池模板' "${PHPCONF_OVERRIDE_DIR}/www.conf" \
            '将写入' "${dropin}" \
            '并写入' "${pool}"
        os::confirm --arg apply-edited '现在用它们更新 PHP 配置？' y \
            || os::die 130 '已取消，PHP 配置未改动（你改的模板留在 /etc/oneserver/templates/）'
    fi

    # 3) 日志目录。www.conf 的 error_log 指向它，目录不在 FPM 起不来。
    #
    # 已存在时连命令都不跑：第二次执行要**零变更**，包括零审计记录。
    # 代价是目录存在但属主不对时这里不纠正 —— 那属于「谁改了它」，
    # 不该由一条幂等命令悄悄改回去。
    #
    # 归「禁止自动回滚」类而不是 defer rmdir：这个目录一旦被 FPM 写进日志就删不掉，
    # 回滚里出现一条注定失败的 rmdir，只会把真正需要人看的那几行淹掉。
    if [[ ! -d ${log_dir} ]]; then
        os::record_change "创建了 PHP 日志目录 ${log_dir}"
        os::run '创建 PHP 日志目录' -- mkdir -p "${log_dir}"
        os::run '设置日志目录属主' -- chown www-data:www-data "${log_dir}"
        os::run '设置日志目录权限' -- chmod 0750 "${log_dir}"
    fi

    # 4) 落模板。
    #
    # **先注册重启、再注册备份**：回滚栈是逆序回放的（LIFO），最先注册的最后执行。
    # 顺序必须是「先还原文件、再重启服务」，反过来重启的是还没还原的配置——
    # 这就要求 restart 必须在两份模板的 os::install_template 之前注册。
    #
    # 但「必须先注册」与「只在真有变更时才重启」互相冲突：任一份模板的
    # os::install_template 若在**写入之前**就失败（比如残留占位符，D94），
    # 会因为 restart 已经注册在前而单独触发一次货真价实的 FPM 重启，
    # 此刻却一个字节都没改成。矛盾的解法是把「要不要真的重启」的判断
    # 从「要不要注册」挪到「执行那一刻」——defer 的是
    # maybe_restart_phpfpm，它在真正被回放时才读 PHPCONF__CHANGED
    # 决定动不动手，而不是直接 defer os::systemd_restart。
    #
    # %%PHP_VERSION%% 由 www.conf 用来定 socket 路径与错误日志路径；drop-in 里
    # 没有占位符，那一路不传。
    PHPCONF__CHANGED=0
    os::defer maybe_restart_phpfpm "${unit}"

    # **drop-in 不存在时要单独登记删除。** os::backup_file 对不存在的文件直接返回，
    # 既不备份也不登记回滚项——首次执行时校验失败，回滚会还原 www.conf，却把刚
    # 创建的这份留在原地，而它多半正是校验没过的原因。注册在 install_template
    # 之前，回滚逆序回放才是「删掉它 → 再重启」。
    [[ -f ${dropin} ]] \
        || os::defer os::run --allow-fail '回滚：删除本次创建的 PHP drop-in' -- rm -f -- "${dropin}"

    # --backup 只在内容确实要变时才落副本（否则第二次执行会多出一份备份 = 有变更）。
    local -i changed=0
    # --mode 不能省：drop-in 是新建文件，template::_place 对不存在的目标不给 mode
    # 就留 mktemp 的 0600，与 conf.d 里其余文件的 0644 不一致。
    os::install_template --backup --mode 0644 "${OS_TEMPLATE_DIR}/${PHPCONF_DROPIN}" "${dropin}"
    if [[ ${OS_TEMPLATE_CHANGED} -eq 1 ]]; then
        changed=1
        PHPCONF__CHANGED=1
    fi
    os::install_template --backup "${OS_TEMPLATE_DIR}/www.conf" "${pool}" "PHP_VERSION=${ver}"
    if [[ ${OS_TEMPLATE_CHANGED} -eq 1 ]]; then
        changed=1
        PHPCONF__CHANGED=1
    fi

    if [[ ${changed} -eq 0 ]]; then
        os::ok "PHP ${ver} 的配置已是目标状态，无需变更"
        os::output 0 version="${ver}" changed=no
        return 0
    fi

    # 5) dry-run 到此为止。
    #
    # 新配置根本没写进磁盘，此时跑 `php-fpm -t` 校验的是**旧配置**，
    # 它通过与否说明不了任何事。照着往下打「✓ 校验通过」就是规范
    # 说的「会撒谎的 dry-run」——诚实声明预演到哪一步为止，正常结束。
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（新配置尚未写入，校验与重启针对的会是旧配置）'
        os::output 0 version="${ver}" changed=dry-run
        return 0
    fi

    # 6) 校验。只读，用 os::query（dry-run 下照常执行，但上面已经返回了）。
    local -i vrc=0
    os::query --timeout 15 -- "${fpm_bin}" -t || vrc=$?
    if [[ ${vrc} -ne 0 ]]; then
        # 原始输出只进日志（调用栈与命令原文不上屏）
        os::debug "php-fpm -t 输出：${OS_RUN_OUTPUT}"
        # 退出码 1 → 框架逆序回放回滚栈：撤销两份配置的改动，再重启服务回到更新前的状态
        os::die 1 "php-fpm 配置校验未通过（退出码 ${vrc}），正在回滚到更新前的配置"
    fi
    os::ok 'PHP-FPM 配置校验通过'

    # 7) 重启。os::systemd_restart 自己会 os::record_change（禁止自动回滚类）
    os::systemd_restart "${unit}"

    os::ok "PHP ${ver} 配置已更新，${unit} 已重启"
    os::output 0 version="${ver}" changed=yes php_conf="${dropin}" pool_conf="${pool}"
    return 0
}

main "$@"
