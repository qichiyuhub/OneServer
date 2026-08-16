#!/bin/bash
#
# 安装 PHP-FPM 与常用扩展
#
# @command      install php
# @name         PHP-FPM
# @group        app
# @order        140
# @privilege    root
# @requires_lib >= 1.14
# @provides     php:<version>
# @provides_unit ext:php<version>-fpm.service
# @args         [--version=<ver>] [--extensions=<+加|-减|序号|列表|none>]
# @description  用发行版源装 PHP-FPM 与扩展，清单可配
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 只用发行版源，因此**一台机器上只有一个 PHP 版本可装**
#
# 实测：Debian 13 的源里只有 8.4，Ubuntu 24.04 只有 8.3。
# 所以版本这件事不该拿去问用户 —— 源里只有一个就用它，真出现多个才让他选。
#
# 但**组件标识照样带实例**（`php:8.4`，D35）：结构不能因为「现在只有一个」
# 就退化成扁平的。将来加了第三方源、或者换个发行版，第二个版本立刻出现，
# 那时候再回头改 state 主键，等于让所有已装机器的记录全部对不上。
#
# 诚实起见：**「两个版本并存互不覆盖」这条这次验不到** —— 发行版源下不存在
# 那个场景。能验的只有结构那半边（state 主键带实例、unit 名带版本）。
#
# ## 旧脚本那 200 行为什么整段没了
#
# 「逐个装扩展 + 三次重试 + 失败诊断 + 提示切回官方源」是 sury 第三方源与
# Ubuntu 系统库不兼容的产物 —— 它甚至专门有个 install_ubuntu_official_php()
# 在补这个洞。发行版源没有这个问题（12 个扩展在 Debian 13 上逐个确认都有），
# 留着那套重试等于继承别人的伤疤。
#
# ## 也没有版本切换
#
# 旧脚本的 handle_php_switch + `apt-get remove --purge "php8.3-*"`：源里没有
# 第二个版本可切，而通配删包会连带删掉不该删的东西。卸载走
# `oneserver uninstall php:8.3` 读 state 清单（F6），那里有精确的包名。

# 归一化后的扩展列表（逗号分隔，已排序去重，一定含 fpm）
PHP_EXTS=''
PHP_CHANGED=0

# ------------------------------------------------------------------

# 源里有哪些 PHP 版本可装，新的在前。
#
# 这是**本脚本独有的一次性取值**，所以是 os::query 不是 probe：
# 「装了哪些版本」有三个消费者（php config / doctor / 本脚本），那个是
# probe::php_fpm_versions；「源里有哪些」只有安装这一处关心。
available_versions() {
    os::query --timeout 30 -- \
        apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' || return 1
    printf '%s\n' "${OS_RUN_OUTPUT}" \
        | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/p' \
        | sort -rV
    return 0
}

# 把 os::multiselect 选出来的扩展定稿成 PHP_EXTS。
#
# 序号、增删、完全替换、none 与那三条拒绝规则全在框架里（D205），与 Caddy
# 的插件清单**逐字同一套语法** —— 用户在那边学过一遍，这边不该再换一套。
#
# 这里只补两件框架不知道的事：
#
#   * **fpm 永远在结果里。** 它不是可选扩展，是这个组件本身。用户选 `none`
#     或者 `-fpm` 也不摘 —— 摘掉之后装出来的东西根本不叫 PHP-FPM。
#   * 补完再**排序去重**（同 D108）：不排的话 `a,b` 与 `b,a` 是两个字符串，
#     state 里记的与这次算出来的对不上，每次执行都判成「清单变了」。
php_finalize_extensions() {
    local list=${1}
    local -a items=() sorted=()
    local one out='' sep=''
    IFS=',' read -r -a items <<<"${list}"
    items+=('fpm')
    mapfile -t sorted < <(printf '%s\n' "${items[@]}" | sort -u)
    for one in ${sorted[@]+"${sorted[@]}"}; do
        [[ -n ${one} ]] || continue
        out+="${sep}${one}"
        sep=','
    done
    PHP_EXTS=${out}
    return 0
}

# 扩展名 → 包名。源里没有的**跳过并说明**，不当成失败：
# 清单是给所有人用的，某个发行版少一两个扩展是正常的，
# 而为此整条命令失败会让人以为 PHP 装不上。
#
# 与旧脚本那套「装失败了再重试三次」不同：这里是**装之前先问源里有没有**，
# 有就装、没有就说一声。发行版源不存在「有这个包但依赖装不上」的情形。
resolve_packages() {
    local ver=${1}
    local -a pkgs=()
    local -a missing=()
    local ext pkg
    local IFS=','

    for ext in ${PHP_EXTS}; do
        [[ -n ${ext} ]] || continue
        pkg="php${ver}-${ext}"
        os::query --timeout 20 -- apt-cache show "${pkg}" || {
            missing+=("${ext}")
            continue
        }
        pkgs+=("${pkg}")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local IFS=' '
        os::warn "源里没有这些扩展，已跳过：${missing[*]}"
    fi

    local IFS=$'\n'
    printf '%s\n' ${pkgs[@]+"${pkgs[@]}"}
    return 0
}

# 这个组件**实际**装着哪些扩展 —— 问 state 的资源清单，不问「这次要装什么」。
#
# 差别在做减法的时候：`--extensions=-imagick` 只是不再装它，**不会把已装的
# 卸掉**（卸包是不可逆操作，而且那个包可能是用户自己装的，规范）。
# 若这里按「本次请求的清单」写 state，state 就会声称 imagick 不在，
# 而系统上它还在、资源清单里也还记着它 —— 同一份 state 里两个字段互相打脸。
# state 写的必须是系统的事实，不是本次执行的意图（D125）。
#
# **数据源是资源清单而不是 `dpkg-query php8.4-*`**：后者会把 apt 顺带拖进来的
# `php8.4-cli` / `-common` / `-readline` 一起算成「扩展」，那些不是用户选的、
# 也不归本组件管（D103 的同一条原则）。资源清单里恰好只有 oneserver 自己装的，
# 而那也正是 F6 卸载要处理的集合 —— 两处用同一份数据，不会打架。
#
# **因此它列的是「本工具装的」，不是「PHP 现在能用的」。** 清单里的某个扩展
# 若在我们动手之前就被别的包拖进来了（`opcache` 常常如此），`os::pkg_install`
# 会跳过它，它也就不进这份清单 —— 它确实在生效，但不归我们卸。
# 屏幕上的标签跟着这个含义写，别让人读成「PHP 只有这些扩展」。
recorded_extensions() {
    local id=${1} ver=${2}
    local pkg
    local -a exts=()
    while IFS= read -r pkg; do
        [[ -n ${pkg} ]] || continue
        # ${ver} 要单独加引号：${..} 里的展开默认按 glob 模式匹配，
        # 版本号里的 `.` 不引起来就成了通配符
        exts+=("${pkg#php"${ver}"-}")
    done < <(os::state_resources "${id}" pkg)
    [[ ${#exts[@]} -gt 0 ]] || return 1
    printf '%s\n' "${exts[@]}" | sort -u | paste -sd ',' -
    return 0
}

# ------------------------------------------------------------------

main() {
    os::pkg_install ca-certificates
    os::pkg_refresh || os::warn '刷新软件包索引失败，用的是本地已有的索引'

    local -a avail=()
    mapfile -t avail < <(available_versions) || true
    if [[ ${#avail[@]} -eq 0 ]]; then
        os::die 3 '发行版源里找不到任何 php<版本>-fpm 包'
    fi

    # 版本。源里只有一个就直接用 —— 给一个只有一项的菜单让人选，
    # 是把「我这里只有这个」包装成「你来决定」。
    local ver=''
    if [[ ${#avail[@]} -eq 1 ]]; then
        os::ask --arg version 'PHP 版本' ver "${avail[0]}"
    else
        os::select --arg version '要安装的 PHP 版本' ver "${avail[@]}"
    fi

    local v found=''
    for v in "${avail[@]}"; do
        [[ ${v} == "${ver}" ]] && found=1
    done
    if [[ -z ${found} ]]; then
        local IFS=' '
        os::die 2 "源里没有 PHP ${ver}，可装的是：${avail[*]}"
    fi

    # 扩展清单。默认零输入：回车就是 conf 里那份原样。
    local -a ext_options=()
    IFS=',' read -r -a ext_options <<<"${OS_DEFAULT_PHP_EXTENSIONS}"
    local picked=''
    os::multiselect --arg extensions 'PHP 扩展清单' picked "${ext_options[@]}"
    php_finalize_extensions "${picked}"

    local id="php:${ver}"
    local unit="php${ver}-fpm.service"

    local -a pkgs=()
    mapfile -t pkgs < <(resolve_packages "${ver}")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        os::die 3 "源里连 php${ver}-fpm 都没有"
    fi

    os::pkg_install "${pkgs[@]}"

    # 本次真装上包 = 有变更（D126）。全新安装时后面什么配置都不用改，
    # 不记这一笔就会打出「已是目标状态」。
    local pkg
    local -a own_pkgs=()
    while IFS= read -r pkg; do
        [[ ${pkg} == php${ver}-* ]] || continue
        own_pkgs+=("${pkg}")
    done < <(os::pkg_installed_names)
    [[ ${#own_pkgs[@]} -gt 0 ]] && PHP_CHANGED=1

    # **装没装上以 probe 为准**，不看 apt 的退出码：
    # 规范要求系统事实一律经 probe，而这里正是「装完了吗」的判据。
    probe::php_fpm_versions
    local have=0
    case " ${OS_PROBE_VALUE} " in
        *" ${ver} "*) have=1 ;;
        *) ;;
    esac

    # dry-run 下 pkg_install 什么都没装，所以「本来就没装」时后面全查不到 ——
    # 诚实声明预演到此为止（规范依赖断裂）。
    # 但**本来就装着**的时候能一路预演到服务与 state，那才是这个开关有用的场景，
    # 不该也甩一句「包还没真装」了事 —— 那句话在这里根本不成立。
    if [[ ${have} -eq 0 ]]; then
        if [[ ${OS_DRYRUN} -eq 1 ]]; then
            os::info "[dry-run] 后续步骤无法预演：PHP ${ver} 尚未安装（包还没真装）"
            os::output 0 version="${ver}" extensions="${PHP_EXTS}" changed=dry-run
            return 0
        fi
        os::die 1 "装完之后仍然没有 /etc/php/${ver}/fpm"
    fi

    # 配置一个字都没动，所以**只在服务没跑时才启动**，不重启。
    # apt 装完 FPM 自己会拉起来，这里多半只是补一次 enable。
    probe::service_active "${unit}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::systemd_restart "${unit}"
    fi
    os::systemd_enable "${unit}"

    # 这段校验 dry-run 下必须跳过：上面那次启动被跳过了，服务当然还是没起 ——
    # 再去断言它 active，就是预演在为自己造成的后果报错
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        probe::service_active "${unit}"
        if [[ ${OS_PROBE_VALUE} != active ]]; then
            os::query --timeout 10 -- journalctl -u "${unit}" --no-pager -n 20
            os::debug "journalctl 尾部：${OS_RUN_OUTPUT}"
            os::die 1 "${unit} 启动失败，日志里有 journalctl 的尾部输出"
        fi
    fi

    # 状态与资源清单。
    # **state 主键是完整组件标识 `php:8.4`**（D35）—— 扁平的 `php` 遇到第二个
    # 版本就会覆盖第一个的记录与 unit 归属，卸载时留下孤儿 php8.3-fpm.service。
    local full=''
    os::query --timeout 10 -- "php${ver}" -v
    full=${OS_RUN_OUTPUT%%$'\n'*}
    full=${full#PHP }
    full=${full%% *}
    [[ -n ${full} ]] || full=${ver}

    local socket="/run/php/php${ver}-fpm.sock"

    # **先登记本次装上的包，再回头读清单** —— 顺序不能反。
    # 反了的话首次安装读到的是空清单，extensions 字段会退回本次请求的意图，
    # 正是上面那段注释要避免的东西。
    for pkg in ${own_pkgs[@]+"${own_pkgs[@]}"}; do
        os::state_resource_add "${id}" pkg "${pkg}"
    done

    local now_exts
    now_exts=$(recorded_extensions "${id}" "${ver}") || now_exts=${PHP_EXTS}
    os::state_set "${id}" version="${full}" series="${ver}" \
        extensions="${now_exts}" socket="${socket}"

    # 请求里减掉、但系统上还装着的那些，明说一句。
    # 不说的话现象是「我明明写了 -imagick，phpinfo 里它还在」。
    local -a stale=()
    local ext
    local IFS=','
    for ext in ${now_exts}; do
        [[ -n ${ext} ]] || continue
        case ",${PHP_EXTS}," in
            *",${ext},"*) ;;
            *) stale+=("${ext}") ;;
        esac
    done
    if [[ ${#stale[@]} -gt 0 ]]; then
        local IFS=' '
        os::warn "这些扩展不在本次清单里，但系统上仍装着（本命令不卸包）：${stale[*]}。要移除走 oneserver uninstall"
    fi

    os::kv '版本' "${full}" \
        '组件标识' "${id}" \
        '扩展（本工具装的）' "${now_exts//,/ · }" \
        'Socket' "${socket}" \
        '配置目录' "/etc/php/${ver}/fpm"

    # 边界说清楚：装是装，调是调。这里只保证「装上、能起来、用发行版默认配置」，
    # 本项目那套调优配置由 `oneserver php config` 落 —— 两条命令各写一套
    # 配置逻辑的话，迟早出现「装的时候是一套、调完是另一套」。
    os::info "配置仍是发行版默认。要应用本项目的调优配置，跑：oneserver php config --version=${ver}"

    # dry-run 下 pkg_install 一个包也没真装，PHP_CHANGED 自然是 0 —— 但那不等于
    # 「无事可做」，上面那几行 [dry-run] 刚说了要装什么。据实报 dry-run。
    local changed_text='no'
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        changed_text='dry-run'
        os::ok "PHP ${full} 的预演到此结束（${id}）"
    elif [[ ${PHP_CHANGED} -eq 1 ]]; then
        changed_text='yes'
        os::ok "PHP ${full} 已安装（${id}）"
    else
        os::ok "PHP ${full} 已是目标状态（${id}）"
    fi
    os::output 0 version="${full}" series="${ver}" \
        extensions="${now_exts}" socket="${socket}" changed="${changed_text}"
    return 0
}

main "$@"
