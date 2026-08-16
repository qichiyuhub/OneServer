#!/bin/bash
#
# 系统诊断 —— probe 的第一个消费者
#
# @command      doctor
# @name         系统诊断
# @group        monitor
# @order        10
# @privilege    any
# @requires_lib >= 2.2
# @args         [--bundle] [--selftest]
# @description  一屏看清系统状态、已装组件与本工具自身的运行环境
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# **这个脚本里没有一处 systemctl / df / free / dpkg-query / ss**。
# 它只做两件事：调 `probe::*`，然后渲染。这条守住了，F9 的面板接入时
# 一行框架代码都不用改 —— 它换的只是渲染器（计划规范的验收线）。
#
# `@privilege any` 是有意的：issue 模板要求用户附 doctor 的输出，
# 二元权限模型会逼所有人 sudo。非 root 时 probe 走快照，
# 每一行都会如实标注「缓存 · 几分钟前」还是「需要 root 权限」。

OS_DOC_PAIRS=()

# 文本模式攒一节的键值对，JSON 模式喂信封的 data.items —— **同一份数据，
# 两个渲染器**。谁也不许自己拼 JSON。
doc_row() {
    local id=${1} label=${2} value=${3} source=${4}
    [[ -n ${value} ]] || value='—'
    # 「未安装（未安装）」这类重复：probe::describe 在探不到东西时给的就是结论
    # 本身，此时值与来源是同一句话，屏幕上打一次就够。JSON 里两个字段照旧
    # 都在 —— 机器消费者要的是可分辨的字段，不是好看的句子
    local suffix="（${source}）"
    if [[ ${value} == "${source}" ]]; then
        suffix=''
    fi
    OS_DOC_PAIRS+=("${label}" "${value}${suffix}")
    os::output_item "id=${id}" "label=${label}" "value=${value}" "source=${source}"
    return 0
}

# 紧跟在一次 probe 之后调用：来源与时间由 probe::describe 给出，
# 措辞收在那里，doctor / 菜单 / 面板不会各写各的
doc_probe_row() {
    local id=${1} label=${2}
    local value=${3-${OS_PROBE_VALUE}}
    doc_row "${id}" "${label}" "${value}" "$(probe::describe)"
    return 0
}

sec_begin() {
    os::section "${1}"
    OS_DOC_PAIRS=()
    return 0
}

sec_end() {
    if [[ ${#OS_DOC_PAIRS[@]} -gt 0 ]]; then
        os::kv "${OS_DOC_PAIRS[@]}"
    fi
    OS_DOC_PAIRS=()
    return 0
}

human_kb() {
    local -i kb=${1:-0}
    if ((kb < 1024)); then
        printf '%d KB\n' "${kb}"
    elif ((kb < 1048576)); then
        printf '%d MB\n' $((kb / 1024))
    else
        printf '%d.%d GB\n' $((kb / 1048576)) $(((kb % 1048576) * 10 / 1048576))
    fi
    return 0
}

human_duration() {
    local -i s=${1:-0}
    if ((s < 3600)); then
        printf '%d 分钟\n' $((s / 60))
    elif ((s < 86400)); then
        printf '%d 小时\n' $((s / 3600))
    else
        printf '%d 天 %d 小时\n' $((s / 86400)) $(((s % 86400) / 3600))
    fi
    return 0
}

# ------------------------------------------------------------------

section_self() {
    sec_begin '本工具'

    local ver='未知' api='未知'
    if [[ -r ${OS_VERSION_FILE} ]]; then
        IFS= read -r ver <"${OS_VERSION_FILE}" || true
    fi
    if [[ -r ${OS_API_VERSION_FILE} ]]; then
        IFS= read -r api <"${OS_API_VERSION_FILE}" || true
    fi
    doc_row self.version '版本' "${ver}" '本地'
    doc_row self.lib_api 'lib API' "${api}" '本地'
    doc_row self.root '安装路径' "${OS_ROOT}" '本地'

    # 日志能不能写是排查的前提：写不了的话「看日志」这句建议就是空话
    local logstat='可写'
    if [[ ${OS_LOG_ENABLED} -ne 1 ]]; then
        logstat='不可写（需要 root）'
    fi
    doc_row self.log "日志目录" "${OS_LOG_DIR}：${logstat}" '本地'

    # 复用 state 自己的逐行校验与 .bak 选择，不能把「文件可读」误当成内容正常。
    local state_health='' statestat=''
    os::state_health state_health
    case ${state_health} in
        ok) statestat='正常' ;;
        empty) statestat='正常（空清单）' ;;
        recovered) statestat='主文件损坏或缺失，已回退 .bak' ;;
        corrupt) statestat='主文件与 .bak 都损坏，卸载不可靠' ;;
        missing) statestat='尚未建立（还没装过任何组件）' ;;
    esac
    doc_row self.state '组件清单' "${statestat}" '本地'

    sec_end
    return 0
}

section_system() {
    sec_begin '系统'
    probe::os_pretty
    doc_probe_row os.pretty '发行版'
    probe::kernel
    doc_probe_row os.kernel '内核'
    probe::arch
    doc_probe_row os.arch '架构'
    probe::uptime_seconds
    local up=''
    [[ ${OS_PROBE_STATUS} == ok ]] && up=$(human_duration "${OS_PROBE_VALUE:-0}")
    doc_probe_row os.uptime '已运行' "${up}"
    sec_end
    return 0
}

section_resource() {
    sec_begin '资源'

    probe::mem_available_kb
    local avail=${OS_PROBE_VALUE:-0} avail_desc
    avail_desc=$(probe::describe)
    probe::mem_total_kb
    local total=${OS_PROBE_VALUE:-0}
    local memtext=''
    if [[ ${OS_PROBE_STATUS} == ok && ${total} -gt 0 ]]; then
        memtext="可用 $(human_kb "${avail}") / 共 $(human_kb "${total}")"
    fi
    doc_row mem.available '内存' "${memtext}" "${avail_desc}"

    probe::disk_free_kb /
    local disktext=''
    if [[ ${OS_PROBE_STATUS} == ok ]]; then
        disktext="根分区可用 $(human_kb "${OS_PROBE_VALUE:-0}")"
        # 1 GiB 不是容量规划结论，只是事故预警线：低于它时 apt、备份暂存与
        # 原子替换都更容易在中途碰到 ENOSPC，必须让正常 doctor 明确标出来。
        [[ ${OS_PROBE_VALUE:-0} -lt 1048576 ]] && disktext+='（空间紧张）'
    fi
    doc_probe_row disk.root '磁盘' "${disktext}"

    sec_end
    return 0
}

# 组件来自 state（本工具装过什么），unit 状态来自 probe（现在跑没跑着）。
# 两者都要：state 说「装了 caddy」而 caddy 没跑着，正是最该被看见的一行
section_components() {
    sec_begin '已装组件'

    local -a ids=()
    local one
    while IFS= read -r one; do
        [[ -n ${one} ]] && ids+=("${one}")
    done < <(os::state_list)

    if [[ ${#ids[@]} -eq 0 ]]; then
        doc_row component.none '组件' '尚未记录任何组件' '本地'
        sec_end
        return 0
    fi

    local id ver unit unit_name text
    for id in "${ids[@]}"; do
        ver=$(os::state_get "${id}" version)
        doc_row "component.${id}" "${id}" "${ver:-（未记版本）}" '本地'
        while IFS= read -r unit; do
            [[ -n ${unit} ]] || continue
            # unit 在 state 里带 own:/ext: 前缀，探测时要去掉
            unit_name=${unit#*:}

            # 两条事实拼一句话：`systemctl is-active` 对「停着」和「不存在」
            # 都说 inactive，光凭它会把「装了没跑」写成「没装」——
            # 而这恰恰是 doctor 最该说清的一行
            probe::unit_exists "${unit_name}"
            if [[ ${OS_PROBE_VALUE} != yes ]]; then
                doc_probe_row "unit.${unit_name}" "  ${unit_name}" '未安装'
                continue
            fi
            # 有同名 .timer 的 service 是 oneshot：跑完就退出，inactive 是它的
            # **正常状态**。不区分的话，每天备份跑完这里都会写一行「已停止」，
            # 而那是它该有的样子。健康看上次的运行结果，不看此刻活没活着。
            local base=${unit_name%.service}
            local oneshot=0
            if [[ ${unit_name} != *.timer ]]; then
                probe::unit_exists "${base}.timer"
                [[ ${OS_PROBE_VALUE} == yes ]] && oneshot=1
            fi

            if [[ ${oneshot} -eq 1 ]]; then
                probe::unit_result "${unit_name}"
                case ${OS_PROBE_VALUE} in
                    success) text='待触发（上次成功）' ;;
                    '') text='待触发（从未运行）' ;;
                    *) text="上次失败：${OS_PROBE_VALUE}" ;;
                esac
                probe::service_enabled "${unit_name}"
                text+=" · ${OS_PROBE_VALUE:-启用状态未知}"
                doc_probe_row "unit.${unit_name}" "  ${unit_name}" "${text}"
                continue
            fi

            probe::service_active "${unit_name}"
            case ${OS_PROBE_VALUE} in
                active) text='运行中' ;;
                inactive) text='已停止' ;;
                failed) text='失败' ;;
                '') text='未知' ;;
                *) text=${OS_PROBE_VALUE} ;;
            esac
            probe::service_enabled "${unit_name}"
            text+=" · ${OS_PROBE_VALUE:-启用状态未知}"
            doc_probe_row "unit.${unit_name}" "  ${unit_name}" "${text}"
        done < <(os::state_units "${id}")
    done

    sec_end
    return 0
}

section_network() {
    sec_begin '网络与安全'

    probe::ssh_port
    doc_probe_row ssh.port 'SSH 端口'

    probe::ufw_active
    if [[ ${OS_PROBE_STATUS} == missing ]]; then
        doc_row ufw.status '防火墙' 'UFW 未安装' '实时'
    else
        local ufw='未启用'
        [[ ${OS_PROBE_VALUE} == yes ]] && ufw='已启用'
        doc_probe_row ufw.status '防火墙' "UFW ${ufw}"
    fi

    # 先问装没装再问跑几个：`podman ps | wc -l` 的退出码来自 wc，
    # podman 不存在时它照样返回 0 和一个 0
    probe::component_version podman
    if [[ ${OS_PROBE_STATUS} == ok ]]; then
        probe::podman_running
        local running=${OS_PROBE_VALUE:-0}
        probe::podman_total
        doc_probe_row podman.containers '容器' "${running} / ${OS_PROBE_VALUE:-0} 运行中"
    fi

    sec_end
    return 0
}

# ------------------------------------------------------------------
# --bundle —— 打包诊断信息
#
# **打到 stdout，不落文件。** doctor 是 `@privilege any`，而规范明文禁止它
# 调 os::run / os::run_out（那意味着副作用），落文件也要 root 才写得进
# $OS_ROOT。打到 stdout 之后：非 root 照样能用、零副作用、`> report.txt`
# 或直接贴进 issue 都由用户决定 —— 反而比生成一个 tar 更顺手。
#
# 内容安全性靠两处既有保证：日志的脱敏发生在**写入前**（直接 cat
# 日志也必须安全），state 里按规范本来就不许有凭据。

bundle_file() {
    local title=${1} path=${2} lines=${3:-100}
    os::section "${title}"
    if [[ ! -r ${path} ]]; then
        printf '(读不到 %s —— 可能需要 root)\n' "${path}"
        return 0
    fi
    # tail 是只读的，os::query 在 dry-run 下也照常执行，
    # 且 @privilege any 只允许用它
    os::query --timeout 5 -- tail -n "${lines}" "${path}" || true
    printf '%s\n' "${OS_RUN_OUTPUT}"
    return 0
}

dump_bundle() {
    if [[ ${OS_OUTPUT} == json ]]; then
        os::warn '--bundle 是给人贴 issue 用的文本，JSON 模式下不输出'
        return 0
    fi

    os::section '诊断打包'
    os::info '以下内容可直接贴进 issue。日志在写入前已脱敏'

    bundle_file '组件清单' "${OS_STATE_FILE}" 200
    bundle_file '最近日志' "${OS_LOG_MAIN}" 100
    bundle_file '最近审计' "${OS_AUDIT_LOG}" 50
    return 0
}

# ------------------------------------------------------------------
# --selftest —— 「这一版装上去到底能不能用」
#
# **它是 `oneserver update` 四阶段模型里阶段 4 的判据**：
# 切换器把目录换成新版本之后 `exec` 它，非零就整个回滚。所以这里的每一项
# 都要满足三个条件：**快**（切换过程中在跑）· **只读**（doctor 是
# `@privilege any`，规范禁止它有副作用）· **结论明确**（要么行要么不行，
# 不给「可能有问题」这种切换器判断不了的答案）。
#
# 反过来说，这里**不查**系统健康度（磁盘满没满、服务跑没跑）——
# 那些是上面那五节的事，与「这一版的文件对不对」无关。
# 把它们混进来的后果是：一台磁盘快满的机器上，任何一次更新都会回滚。
#
# 第一项是最有力的一项，而它不需要写代码：**这个进程能跑到这里，
# 就证明新版本的 bootstrap 把 16 个 lib 模块全 source 成功了**。
# 少一个文件、语法坏一处、层与层之间的依赖断一条，都到不了这一行。

OS_ST_FAIL=0

st_pass() {
    os::ok "${1}"
    os::output_item "id=${2}" "label=${1}" "value=ok"
    return 0
}

st_fail() {
    os::err "${1}"
    OS_ST_FAIL=$((OS_ST_FAIL + 1))
    os::output_item "id=${2}" "label=${1}" "value=fail"
    return 0
}

# 每个带 @command 的脚本都必须可执行 —— 派发是 `exec`，
# 漏了执行位的表现是「这条命令莫名其妙不存在」，而更新过程中丢执行位
# 恰恰是最容易发生的一类损坏（tar 的 --no-same-permissions、
# 手工 cp 忘了 chmod）
st_check_exec_bits() {
    os::query --timeout 10 -- \
        grep -rlE '^#[[:space:]]*@command[[:space:]]' "${OS_SCRIPT_DIR}" || true
    local list=${OS_RUN_OUTPUT}
    if [[ -z ${list} ]]; then
        st_fail '一个带 @command 的脚本都没找到' selftest.commands
        return 0
    fi

    local f
    local -i n=0 bad=0
    local IFS=$'\n'
    for f in ${list}; do
        [[ -n ${f} ]] || continue
        n+=1
        [[ -x ${f} ]] || {
            os::debug "没有执行位：${f}"
            bad+=1
        }
    done
    if ((bad > 0)); then
        st_fail "${bad}/${n} 个命令脚本没有执行位" selftest.exec_bits
    else
        st_pass "${n} 个命令脚本都可执行" selftest.exec_bits
    fi
    return 0
}

# lib 的 API 版本必须满足所有脚本的 `@requires_lib`。
#
# 这一条专抓「更新只换了一半」：lib 是新的而脚本是旧的不会有事（新 lib 向下
# 兼容），反过来 —— 脚本是新的而 lib 是旧的 —— 每一条命令都会以退出码 4
# 拒绝启动，而用户看到的是「刚更新完，所有命令都用不了」。
st_check_lib_api() {
    local api=''
    [[ -r ${OS_API_VERSION_FILE} ]] && api=$(tr -d ' \t\n\r' <"${OS_API_VERSION_FILE}")
    if [[ ! ${api} =~ ^[0-9]+\.[0-9]+$ ]]; then
        st_fail "lib/API_VERSION 不合法：${api:-缺失}" selftest.lib_api
        return 0
    fi

    os::query --timeout 10 -- \
        grep -rhoE '@requires_lib[[:space:]]*>=[[:space:]]*[0-9]+\.[0-9]+' "${OS_SCRIPT_DIR}" || true
    # os::version_cmp **打印** 1 / 0 / -1，返回码恒为 0 —— 写成
    # `if os::version_cmp a b` 会永远成立，而表现是自检永远通过。
    # 这种「函数返回值不是它看起来那个意思」的坑，只有翻实现才能发现
    local want highest='0.0'
    local IFS=$'\n'
    for want in ${OS_RUN_OUTPUT}; do
        want=${want##*[[:space:]]}
        [[ ${want} =~ ^[0-9]+\.[0-9]+$ ]] || continue
        [[ $(os::version_cmp "${want}" "${highest}") == 1 ]] && highest=${want}
    done

    if [[ $(os::version_cmp "${highest}" "${api}") == 1 ]]; then
        st_fail "有脚本要求 lib API >= ${highest}，而本机是 ${api}（更新只换了一半）" selftest.lib_api
    else
        st_pass "lib API ${api} 满足全部脚本的要求（最高 ${highest}）" selftest.lib_api
    fi
    return 0
}

# @order **组内**唯一。它只决定同组内的先后（菜单编号按屏重排 1..N，不上屏），
# 组与组之间互不相干。撞车的表现不是报错，而是这两条谁排前面由扫描顺序决定 ——
# 换一台机器、换一个文件名，顺序就变了。
#
# 缺 @order 同样算失败：注册表会补 0，于是它永远排在本组最前面，而那不是
# 作者选的位置，是漏写的副产物。
st_check_order() {
    os::query --timeout 10 -- \
        grep -rlE '^#[[:space:]]*@command[[:space:]]' "${OS_SCRIPT_DIR}" || true
    local list=${OS_RUN_OUTPUT}
    if [[ -z ${list} ]]; then
        st_fail '一个带 @command 的脚本都没找到' selftest.order
        return 0
    fi

    local -a files=() orders=()
    local f line order group
    local -i n miss=0
    local IFS=$'\n'
    for f in ${list}; do
        [[ -n ${f} ]] || continue
        order=''
        group=''
        n=0
        # 与 registry::_meta 同一套解析：前 40 行、去掉 # 与缩进后必须以
        # `@order` / `@group` 加空白开头，免得正文里提到它们的注释被当成元数据
        while IFS= read -r line && ((n < 40)); do
            n+=1
            [[ ${line} == '#'* ]] || continue
            line=${line#\#}
            line=${line#"${line%%[![:space:]]*}"}
            if [[ ${line} == '@order'[[:space:]]* ]]; then
                order=${line#@order}
                order=${order//[[:space:]]/}
            elif [[ ${line} == '@group'[[:space:]]* ]]; then
                group=${line#@group}
                group=${group//[[:space:]]/}
            fi
            [[ -n ${order} && -n ${group} ]] && break
        done <"${f}"
        if [[ ! ${order} =~ ^[0-9]+$ ]]; then
            os::debug "缺 @order 或不是数字：${f}"
            miss+=1
            continue
        fi
        files+=("${f}")
        # 组一起进比较键：唯一性是组内的
        orders+=("${group}/${order}")
    done

    local -i i j dup=0
    for ((i = 0; i < ${#orders[@]}; i++)); do
        for ((j = i + 1; j < ${#orders[@]}; j++)); do
            [[ ${orders[i]} == "${orders[j]}" ]] || continue
            os::debug "分组 ${orders[i]%%/*} 内的 @order ${orders[i]#*/} 重复：${files[i]} 与 ${files[j]}"
            dup+=1
        done
    done

    if ((dup > 0 || miss > 0)); then
        st_fail "@order 有问题：${dup} 处组内重复、${miss} 个缺失（详情在日志里）" selftest.order
    else
        st_pass "${#orders[@]} 个 @order 组内互不重复" selftest.order
    fi
    return 0
}

# 注册表能不能扫出命令。**走真的前端，不自己 source registry.sh**：
# 规范说 registry.sh 由前端 source，命令脚本伸手去 source 它
# 就是越层，而且那样测的是「我自己调得通」，不是「用户敲 oneserver 有反应」。
st_check_registry() {
    local front="${OS_BIN_DIR}/oneserver"
    if [[ ! -x ${front} ]]; then
        st_fail "前端不可执行：${front}" selftest.frontend
        return 0
    fi
    if ! os::query --timeout 20 -- "${front}" --help; then
        st_fail 'oneserver --help 跑不起来（注册表扫不出命令）' selftest.registry
        return 0
    fi
    # `doctor` 一定在里面 —— 它就是当前正在跑的这条命令
    case ${OS_RUN_OUTPUT} in
        *doctor*) st_pass '注册表可用，命令列表生成正常' selftest.registry ;;
        *) st_fail '命令列表里连 doctor 都没有' selftest.registry ;;
    esac
    return 0
}

st_check_files() {
    local -a required=(
        "${OS_BIN_DIR}/oneserver"
        "${OS_BIN_DIR}/oneserver-menu"
        "${OS_LIB_DIR}/bootstrap.sh"
        "${OS_API_VERSION_FILE}"
        "${OS_VERSION_FILE}"
        "${OS_GROUPS_CONF}"
        # 两个根级脚本也在清单里、也由切换器替换（updater 的 TOP_FILES）。
        # 查它们不是凑数：从前更新根本不换这两个文件，而自检也没看过它们，
        # 于是「装了新版、卸载器还是旧的」这条路上没有任何一处会亮红
        "${OS_ROOT}/install.sh"
        "${OS_ROOT}/uninstall.sh"
    )
    local f
    local -i bad=0
    for f in "${required[@]}"; do
        [[ -f ${f} ]] || {
            os::debug "缺文件：${f}"
            bad+=1
        }
    done
    if ((bad > 0)); then
        st_fail "${bad} 个必需文件缺失" selftest.files
    else
        st_pass "必需文件齐全（${#required[@]} 项）" selftest.files
    fi
    return 0
}

# 权限只查**会造成实际后果**的两项，不做全目录巡检：
# secure.conf 松了是凭据泄露，state 目录松了是组件清单可被篡改。
# 其余目录的权限归 install.sh 管，在这里重复一遍只会让自检变慢且更容易假红。
st_check_perms() {
    local -i bad=0
    local mode
    if [[ -e ${OS_SECURE_CONF} ]]; then
        mode=$(stat -c %a "${OS_SECURE_CONF}" 2>/dev/null || printf '')
        [[ ${mode} == 600 ]] || {
            os::debug "secure.conf 权限是 ${mode:-未知}，应为 600"
            bad+=1
        }
    fi
    if [[ -d ${OS_STATE_DIR} ]]; then
        mode=$(stat -c %a "${OS_STATE_DIR}" 2>/dev/null || printf '')
        [[ ${mode} == 750 || ${mode} == 700 ]] || {
            os::debug "state 目录权限是 ${mode:-未知}，应为 750"
            bad+=1
        }
    fi
    if ((bad > 0)); then
        st_fail "${bad} 处权限不对（详情在日志里）" selftest.perms
    else
        st_pass '凭据库与状态目录权限正确' selftest.perms
    fi
    return 0
}

run_selftest() {
    os::section '自检'

    local ver='未知'
    [[ -r ${OS_VERSION_FILE} ]] && ver=$(tr -d ' \t\n\r' <"${OS_VERSION_FILE}")
    os::kv '版本' "${ver}" '安装位置' "${OS_ROOT}"

    st_pass 'lib 装配成功（跑到这一行本身就是证明）' selftest.bootstrap
    st_check_files
    st_check_exec_bits
    st_check_lib_api
    st_check_order
    st_check_registry
    st_check_perms

    if ((OS_ST_FAIL > 0)); then
        os::err "自检未通过：${OS_ST_FAIL} 项失败"
        os::output 1 selftest=fail failed="${OS_ST_FAIL}" version="${ver}"
        return 1
    fi
    os::ok '自检通过'
    os::output 0 selftest=ok failed=0 version="${ver}"
    return 0
}

# ------------------------------------------------------------------

main() {
    # --selftest 只跑自检，不打那五节报告：它的消费者是切换器，
    # 要的是一个退出码，不是一屏系统状态（而且那五节要跑十几个 probe，
    # 在切换过程中白等）
    if os::flag --arg selftest; then
        run_selftest || os::die 1 '自检未通过'
        return 0
    fi

    section_self
    section_system
    section_resource
    section_components
    section_network

    if os::flag --arg bundle; then
        dump_bundle
    fi

    os::output 0
    return 0
}

main "$@"
