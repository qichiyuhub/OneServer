#!/bin/bash
#
# 卸载一个组件
#
# @command      uninstall
# @name         卸载应用
# @group        app
# @order        30
# @privilege    root
# @requires_lib >= 1.20
# @args         [--id=<组件标识>] [--keep-pkg] [--confirm-uninstall=<组件标识>]
# @description  按资源清单反向卸载应用；数据与备份永不自动删除
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 这个脚本**不做任何探测、不猜、不按组件名写分支**
# ==================================================================
#
# 它只读 state 里的资源清单并逆序反向执行。这是那份清单存在的
# 全部理由 —— 安装脚本登记的每一条 `pkg` / `file` / `divert` / `alt` /
# `unit`，兑现的地方就是这里。
#
# **反过来说：装的时候没记，到这里就卸不掉。** 规范 §12 的资源登记要求
# 在这里变成可执行的事实 —— 本文件里没有一处 `case ${type} in caddy)`。
#
# 顺序是规范定死的，一步都不能调换：
#
#     停止并禁用 unit → 移除 alt → 撤销 divert → 删除 file → purge pkg → 清凭据
#
#   先删 file 再移 alt：update-alternatives 会指向一个不存在的候选，
#                       /usr/bin/node 变成断链
#   先 purge pkg 再撤 divert：dpkg 带着分流记录卸载，留下一个谁也管不到的
#                       xxx.default
#   先清凭据再 purge：卸载过程本身可能要用它们（连库执行 DROP USER）
#
# ==================================================================
# 永不自动删除的东西
# ==================================================================
#
# 用户配置（/etc/caddy/Caddyfile、/etc/php/*/）· 数据与证书（/var/lib/caddy
# 里是 ACME 账户与私钥，删了要重新签发且可能撞上速率限制）· 数据库 ·
# 站点目录 · 备份归档。
#
# **它们不在资源清单里，所以这里根本没有删除它们的能力** —— 这不是靠自觉，
# 是靠规范里「只登记本项目创建的文件」那条规则从源头保证的。
# 本脚本只把它们的位置打出来，由人自己处置。

# ------------------------------------------------------------------

# ==================================================================
# 能卸的与不能卸的
# ==================================================================
#
# state 记的不只是「装过的软件」：`db:<库名>`（建过的库）、`wordpress:<名字>`
# （部署过的站点）、`backup-path:<名字>`（备份目标）、`network`（网络定位）
# 全都登记在同一份清单里。它们不是应用，也没有资源清单。
#
# **判据是资源清单空不空，不是类型白名单。** 这个脚本的全部能力来自那份清单
# （pkg / file / divert / alt / unit），清单空的组件卸下去只会划掉 state 里
# 一行，而实体还躺在磁盘上 —— 那不是卸载，是让用户以为自己清理干净了。
# 更糟的是记录没了之后，备份与恢复再也找不到那个库。
#
# 用类型白名单会两头不准：`firewall`、`auto-updates` 是真能 purge 的（有 pkg）
# 却不由 install_* 提供，而 `db:*` 顶着一个像应用的类型名却什么都卸不掉。
# 问清单，不问名字。
un_removable() {
    local id=${1} kind out
    for kind in pkg file divert alt; do
        out=$(os::state_resources "${id}" "${kind}")
        [[ -n ${out} ]] && return 0
    done
    out=$(os::state_units "${id}")
    [[ -n ${out} ]]
}

# 有可卸资源的组件，结果写 UN_CANDIDATES
UN_CANDIDATES=()
un_candidates() {
    UN_CANDIDATES=()
    local id
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        un_removable "${id}" && UN_CANDIDATES+=("${id}")
    done < <(os::state_list)
    return 0
}

# un_elsewhere <组件标识>   这类东西归哪条命令删；没有对应命令时为空
#
# 被挡下来时必须指路。只说「不能在这里卸」等于把人留在原地 —— 他要删的
# 那个东西是真实存在的，只是入口在别处
un_elsewhere() {
    case ${1} in
        db:*) printf 'oneserver mariadb delete --name=%s\n' "${1#*:}" ;;
        wordpress:*) printf 'oneserver site delete\n' ;;
        container:*) printf 'oneserver podman rm（或 docker rm）\n' ;;
        backup-path:*) printf 'oneserver backup remove\n' ;;
        network) printf 'oneserver network\n' ;;
        *) printf '\n' ;;
    esac
}

# 解析用户给的标识。多实例时**列出全部并要求指明完整标识**，
# 禁止猜测、禁止默认全卸——
# `uninstall php` 在装了 8.3 与 8.4 的机器上删掉哪个都是错的。
resolve_id() {
    local __un_out=${1} __un_want=${2}
    un_candidates
    local -a __un_all=(${UN_CANDIDATES[@]+"${UN_CANDIDATES[@]}"})

    if [[ ${#__un_all[@]} -eq 0 ]]; then
        os::die 2 'state 里没有可卸载的组件 —— 数据库、站点这类东西各有各的删除命令'
    fi

    # 完整标识直接命中
    local __un_i
    for __un_i in "${__un_all[@]}"; do
        if [[ ${__un_i} == "${__un_want}" ]]; then
            printf -v "${__un_out}" '%s' "${__un_want}"
            return 0
        fi
    done

    # 指名道姓要一个**登记在案、但没有任何可卸资源**的组件。不能沉默地当它
    # 不存在 —— 那会让用户以为记录丢了，转头去 state rebuild
    if os::state_has "${__un_want}"; then
        local __un_where
        __un_where=$(un_elsewhere "${__un_want}")
        [[ -n ${__un_where} ]] \
            && os::die 2 "「${__un_want}」没有可卸载的资源，它不归这里删。用：${__un_where}"
        os::die 2 "「${__un_want}」在 state 里没有登记任何资源 —— 卸载它只会划掉一行记录，实体不会消失"
    fi

    # 只给了 type：看看有几个**可卸的**实例
    local -a __un_hit=()
    local __un_one
    while IFS= read -r __un_one; do
        [[ -n ${__un_one} ]] || continue
        un_removable "${__un_one}" && __un_hit+=("${__un_one}")
    done < <(os::state_list "${__un_want}")
    if [[ ${#__un_hit[@]} -eq 1 ]]; then
        printf -v "${__un_out}" '%s' "${__un_hit[0]}"
        return 0
    fi
    # 一个 type 下有多个实例：**列出来让人挑**，而不是甩一句「请指明完整标识」。
    # 规范只要求「必须列出全部并要求指明完整标识，禁止猜测或默认全卸」——
    # 用编号选单挑一个，同样是明确指定了完整标识，而且不用人去背 `php:8.4`
    # 这种自己也未必记得的写法。
    if [[ ${#__un_hit[@]} -gt 1 ]]; then
        os::warn "「${__un_want}」下有 ${#__un_hit[@]} 个实例，挑一个"
        local __un_pick=''
        # `--keep-screen`：上一行说清了「为什么在问你」，清屏之后这个选单
        # 看起来像凭空冒出来的
        os::select --keep-screen --required --reask --arg id '要卸载哪一个' __un_pick "${__un_hit[@]}"
        printf -v "${__un_out}" '%s' "${__un_pick}"
        return 0
    fi

    # 名字对不上：也列出来让人挑，别让他退出去重来一遍
    os::warn "state 里没有「${__un_want}」"
    local __un_pick=''
    os::select --keep-screen --required --reask --arg id '已登记的组件，挑一个' __un_pick "${__un_all[@]}"
    printf -v "${__un_out}" '%s' "${__un_pick}"
    return 0
}

# 把某个组件的资源读进全局数组。**不做去重之外的任何加工** ——
# 清单里写的是什么就卸什么。
declare -a RES_UNIT=() RES_ALT=() RES_DIVERT=() RES_FILE=() RES_PKG=()
declare -a RES_KEEP=()

collect() {
    local id=${1}
    mapfile -t RES_UNIT < <(os::state_resources "${id}" unit)
    mapfile -t RES_ALT < <(os::state_resources "${id}" alt)
    mapfile -t RES_DIVERT < <(os::state_resources "${id}" divert)
    mapfile -t RES_FILE < <(os::state_resources "${id}" file)
    mapfile -t RES_PKG < <(os::state_resources "${id}" pkg)

    # 「永不自动删除」的那些：安装脚本把位置记在 state 里（`path` / `db`），
    # 卸载只负责把它们指给用户看
    local v
    RES_KEEP=()
    for v in $(os::state_resources "${id}" path); do
        [[ -n ${v} ]] && RES_KEEP+=("目录 ${v}")
    done
    for v in $(os::state_resources "${id}" db); do
        [[ -n ${v} ]] && RES_KEEP+=("数据库 ${v}")
    done
    return 0
}

# 该组件的凭据 key。按命名空间前缀扫，不逐条登记（规范最后一段）——
# 逐条登记漏一条的表现是「卸载完了密码还躺在 secure.conf 里」，
# 没有任何报错、没有任何人会发现。
declare -a RES_SECRET=()

collect_secrets() {
    local id=${1}
    local ns
    ns=$(os::secure_ns "${id}")
    RES_SECRET=()
    local k
    while IFS= read -r k; do
        [[ -n ${k} ]] || continue
        [[ ${k} == "${ns}."* ]] && RES_SECRET+=("${k}")
    done < <(os::secure_list)
    return 0
}

# ------------------------------------------------------------------

do_units() {
    local u
    for u in ${RES_UNIT[@]+"${RES_UNIT[@]}"}; do
        [[ -n ${u} ]] || continue
        # own: 删文件，ext: 只停止禁用—— 前缀不是可选的，
        # 判断该不该删文件全靠它，而删错的代价远大于留孤儿
        os::systemd_remove "${u}" || os::warn "处理 unit ${u} 时出错，继续"
    done
    return 0
}

do_alts() {
    local a link cand
    for a in ${RES_ALT[@]+"${RES_ALT[@]}"}; do
        [[ -n ${a} ]] || continue
        link=${a%%:*}
        cand=${a#*:}
        if [[ -z ${link} || -z ${cand} || ${link} == "${a}" ]]; then
            os::warn "alt 记录格式不对，跳过：${a}"
            continue
        fi
        os::run --allow-fail '移除 alternatives 候选' -- \
            update-alternatives --remove "${link}" "${cand}" || true
    done
    return 0
}

do_diverts() {
    local d
    for d in ${RES_DIVERT[@]+"${RES_DIVERT[@]}"}; do
        [[ -n ${d} ]] || continue
        os::run --allow-fail '撤销 dpkg 分流' -- \
            dpkg-divert --rename --remove "${d}" || true
    done
    return 0
}

do_files() {
    local f
    for f in ${RES_FILE[@]+"${RES_FILE[@]}"}; do
        [[ -n ${f} ]] || continue
        # 绝对路径才删。清单是本机 state 里的，但同样的道理：
        # 相对路径在这里没有意义，而 `rm -f` 一个相对路径删的是当前目录下的东西
        case ${f} in
            /*) ;;
            *)
                os::warn "file 记录不是绝对路径，跳过：${f}"
                continue
                ;;
        esac
        os::run --allow-fail '删除本工具创建的文件' -- rm -f -- "${f}" || true
    done
    return 0
}

do_pkgs() {
    [[ ${#RES_PKG[@]} -gt 0 ]] || return 0
    local -a pkgs=()
    local p
    for p in "${RES_PKG[@]}"; do
        [[ -n ${p} ]] && pkgs+=("${p}")
    done
    [[ ${#pkgs[@]} -gt 0 ]] || return 0

    os::pkg_purge "${pkgs[@]}" || os::warn '有包没能卸干净，详情看日志'
    return 0
}

do_secrets() {
    local k
    for k in ${RES_SECRET[@]+"${RES_SECRET[@]}"}; do
        [[ -n ${k} ]] || continue
        os::secure_del "${k}" || os::warn "删凭据 ${k} 失败"
    done
    return 0
}

# ------------------------------------------------------------------

main() {
    local keep_pkg=0
    os::flag --arg keep-pkg && keep_pkg=1

    un_candidates
    [[ ${#UN_CANDIDATES[@]} -gt 0 ]] \
        || os::die 2 'state 里没有可卸载的组件 —— 数据库、站点这类东西各有各的删除命令'

    # 位置参数优先，没给就**从清单里挑**。
    # 不再问「完整标识」：那是让用户去猜一个只有 state 才知道的字符串，
    # 而他手上根本没有那份清单。`--id=php` 这种不完整的写法照旧能用，
    # 由 resolve_id 收敛（多个实例时同样弹清单）
    local want=${1-}
    if [[ -z ${want} ]]; then
        os::select --required --arg id '要卸载哪个组件' want "${UN_CANDIDATES[@]}"
    fi

    local id=''
    resolve_id id "${want}"

    collect "${id}"
    collect_secrets "${id}"

    if [[ ${keep_pkg} -eq 1 ]]; then
        RES_PKG=()
    fi

    # --- 清单（规范：具体路径、条目数，不接受概括）---
    local -a lines=()
    local x
    for x in ${RES_UNIT[@]+"${RES_UNIT[@]}"}; do
        [[ -n ${x} ]] || continue
        case ${x} in
            own:*) lines+=("systemd unit ${x#own:}（停止、禁用并删除 unit 文件）") ;;
            *) lines+=("systemd unit ${x#ext:}（只停止与禁用，不删文件）") ;;
        esac
    done
    for x in ${RES_ALT[@]+"${RES_ALT[@]}"}; do
        [[ -n ${x} ]] && lines+=("alternatives 候选 ${x%%:*} → ${x#*:}")
    done
    for x in ${RES_DIVERT[@]+"${RES_DIVERT[@]}"}; do
        [[ -n ${x} ]] && lines+=("dpkg 分流 ${x}（撤销）")
    done
    for x in ${RES_FILE[@]+"${RES_FILE[@]}"}; do
        [[ -n ${x} ]] && lines+=("文件 ${x}")
    done
    for x in ${RES_PKG[@]+"${RES_PKG[@]}"}; do
        [[ -n ${x} ]] && lines+=("软件包 ${x}（apt-get purge）")
    done
    for x in ${RES_SECRET[@]+"${RES_SECRET[@]}"}; do
        [[ -n ${x} ]] && lines+=("凭据 ${x}")
    done

    # 版本从 state 读，**不探测**（§3 不变量 8：卸载只读资源清单）。
    # 这一行纯粹是给人看的，而 probe::component_version 会真去跑
    # `caddy version` / `node --version` 这类外部命令：组件此刻正坏着的时候
    # 它要么超时拖住整个卸载，要么给出一个误导的版本号 —— 而卸载动作本身
    # 一个字节都不依赖它。安装时版本已经写进 state 了。
    os::section "卸载 ${id}"
    local shown_ver
    shown_ver=$(os::state_get "${id}" version)
    os::kv '组件标识' "${id}" \
        '当前版本' "${shown_ver:-未知}" \
        '待处理资源' "${#lines[@]} 项"

    if [[ ${#lines[@]} -eq 0 ]]; then
        os::warn "${id} 在 state 里没有登记任何资源 —— 只会把它从组件清单里划掉"
        os::warn '如果它是本工具装的，那说明当初的安装脚本漏记了资源'
    fi

    # --- 不会被删的，逐条指出位置 ---
    if [[ ${#RES_KEEP[@]} -gt 0 ]]; then
        os::section '以下不会被删除'
        for x in "${RES_KEEP[@]}"; do
            os::info "    ${x}"
        done
        os::info '数据、配置、证书与备份一律由你自己处置'
    fi

    # --- 确认：打全名，--yes 对它无效（规范第 3、4 条）---
    #
    # dry-run 下 os::destroy_confirm 打完清单必然返回 1（它压根不会真的问）——
    # 那不是「用户放弃」，是「预演」。两者当年被同一个 `if ! ...; then` 分支
    # 处理，于是 uninstall 这个最危险的命令反而是唯一一个 dry-run 什么都
    # 预演不出来、还以 130（「用户取消」）退出的命令（B-M1）。
    if ! os::destroy_confirm --arg confirm-uninstall "${id}" -- \
        ${lines[@]+"${lines[@]}"}; then
        if [[ ${OS_DRYRUN} -ne 1 ]]; then
            os::info '已取消，什么都没有动'
            os::output 130 id="${id}" removed=no
            return 130
        fi
        os::info '[dry-run] 继续预演下面每一步会执行的命令（内部命令自动跳过，不会真的执行）'
    fi

    # --- 逆序执行（顺序不可调换）---
    do_units
    do_alts
    do_diverts
    do_files
    do_pkgs
    # 凭据放在 purge 之后：卸载过程本身可能要用它们
    do_secrets

    # os::state_del 内部已有 dry-run 守卫，dry-run 下自己会打 [dry-run] 且不写盘
    os::state_del "${id}" || os::warn "从 state 里删除 ${id} 失败"

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将卸载 ${id}"
        os::output 0 id="${id}" removed=no resources="${#lines[@]}" changed=dry-run
        return 0
    fi

    os::ok "${id} 已卸载"
    if [[ ${#RES_KEEP[@]} -gt 0 ]]; then
        os::info '上面列出的数据与配置仍在原处'
    fi
    os::output 0 id="${id}" removed=yes resources="${#lines[@]}"
    return 0
}

main "$@"
