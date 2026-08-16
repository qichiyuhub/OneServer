#!/bin/bash
#
# 安装并配置 MariaDB
#
# @command      install mariadb
# @name         MariaDB（MySQL）
# @group        app
# @order        130
# @privilege    root
# @requires_lib >= 4.4
# @provides     mariadb
# @provides_unit ext:mariadb.service
# @args         [--bind=<地址>] [--bind-public=<y|n>] [--set-root-password] [--auto-password=<y|n>] [--drop-anonymous=<y|n>]
# @description  装发行版源的 MariaDB，核对基线与监听地址
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 这个脚本为什么这么短 —— 发行版包出厂就是安全的
#
# 两个发行版实测（容器里跑的，不是照抄旧脚本的假设）：
#
#                      Debian 13        Ubuntu 24.04
#   版本               11.8.6           10.11.14
#   root@localhost     unix_socket      unix_socket
#   匿名用户           0 个             0 个
#   test 库            不存在           不存在
#   bind-address       127.0.0.1        127.0.0.1
#   服务端字符集       utf8mb4          utf8mb4
#
# 也就是说旧脚本那整套「安全初始化」在现代 Debian/Ubuntu 上是**空操作**，
# 而它唯一有实效的那一步 —— 设 root 密码 —— 是**降级**。
#
# ## root 密码为什么默认不设
#
# `root@localhost` 的认证链是 `[{}, {"plugin": "unix_socket"}]`：只有
# **操作系统的 root** 连得上。实测非 root 的系统用户会拿到
# `ERROR 1698 Access denied`。
#
# 而 `ALTER USER 'root'@'localhost' IDENTIFIED BY '...'` 会把这条链**换成**
# 密码认证 —— 此后任何拿到那个明文密码的本机用户都能以 DB root 连进来，
# 而在此之前只有 OS root 能。**多一个密码，少一层隔离。**
#
# 所以：默认什么都不做。`--set-root-password` 给确实需要密码通道的人用，
# 且写成 `VIA unix_socket OR mysql_native_password`，**两条通道都留着**。
# 否则 OS root 免密连库这条路会断，而 db_manager / backup / deploy_wordpress
# 全靠它 —— **oneserver 的所有脚本一律以 OS root 走 unix_socket 连库**，
# root 密码只是给用户自己的额外通道。
#
# ## 数据目录永不自动删除
#
# `/var/lib/mysql` 不进资源清单。卸载时只打印位置，
# 由用户自行处置 —— 那里面是他的数据，不是本项目放下的文件。

readonly MARIADB_UNIT='mariadb.service'
readonly MARIADB_CONF='/etc/mysql/mariadb.conf.d/50-server.cnf'
readonly MARIADB_DATA_DIR='/var/lib/mysql'
readonly MARIADB_SECRET_KEY='mariadb.root_password'

# 函数之间的返回通道。不用 $( ) 取返回值：那是子 shell，
# os::record_change / os::defer / 脱敏登记一条都传不出来（D74）。
MARIADB_RESTART=0
MARIADB_CHANGED=0

# ------------------------------------------------------------------

# 监听地址。**K2 就在这里**：旧脚本问的是「是否允许远程访问 (0.0.0.0)?」
# 而且默认 `y` —— 一路回车装完 MariaDB，3306 就在公网上了。
#
# 现在反过来：不给 `--bind` 就一个字节都不改（发行版默认已是 127.0.0.1），
# 给了非回环地址则是降低安全性的选项，默认必须为 n 并说清补偿控制。
#
# 也**不代劳开防火墙**。旧脚本硬编码放行 `10.0.0.0/8`（作者自己的 podman
# 网段），那是写死的个人选择：别人的容器网段不是这个，而且「装数据库顺手
# 开了个端口」不该是用户没要求就发生的事。放行走 oneserver firewall。
apply_bind() {
    local addr=${1}
    [[ -n ${addr} ]] || return 0

    local public=0
    case ${addr} in
        127.* | ::1 | localhost) ;;
        *) public=1 ;;
    esac

    if [[ ${public} -eq 1 ]]; then
        if ! os::confirm --arg bind-public \
            'MariaDB 监听非回环地址意味着 3306 对能到达这台机器的人开放。确定？' n; then
            os::die 2 '已取消：未修改监听地址'
        fi

        # §15：放宽监听地址必须在同一步骤内落实补偿控制，做不到就拒绝执行——
        # 禁止「先开放，稍后提示用户自行加固」。不代劳开防火墙的理由见函数头
        # 注释：这里只验证它已经在位，不动它。
        #
        # 判据收在 probe::ufw_port_guarded，与 install_valkey 共用一份。原来这里
        # 自己写了一半，**漏了默认入站策略**：`ufw status` 不带 verbose 看不到
        # 它，而默认 allow 时「active 且没有 Anywhere 规则」给出的是虚假的安全感
        # ——一条端口规则都没有也照样全开。
        probe::ufw_port_guarded 3306
        [[ ${OS_PROBE_VALUE} == yes ]] || os::die 2 \
            'MariaDB 监听非回环地址前必须先有真正挡得住的防火墙：要求 UFW 已启用、默认入站为 deny/reject、且 3306 没有无条件放行给 Anywhere。先执行 oneserver firewall enable 并只放行可信来源，未修改监听地址'

        os::warn '已核实：UFW 生效、默认入站拒绝、3306 未被无条件放行；root 仍只允许 localhost 连接。远程访问请另建账号（oneserver mariadb），别拿 root 连'
    fi

    os::replace_line --backup "${MARIADB_CONF}" \
        '^[[:space:]]*#?[[:space:]]*bind-address[[:space:]]*=' "bind-address            = ${addr}" \
        || os::die 1 "${MARIADB_CONF} 里找不到 bind-address 行"
    if [[ ${OS_REPLACE_CHANGED} -eq 1 ]]; then
        MARIADB_CHANGED=1
        MARIADB_RESTART=1
    fi
    return 0
}

# 安全基线核对。**两个发行版上这一段一个字都不会打** —— 出厂就是干净的。
# 留着它是为了从老系统升上来的机器，那些机器上确实可能有匿名账号。
#
# `test` 库**只警告不删**：删库是不可逆操作，而叫 `test` 的库
# 完全可能真装着东西。宁可让人自己确认后 DROP，也不替他做这个决定。
check_baseline() {
    os::sql_query '统计匿名账号' -- \
        'SELECT COUNT(*) FROM mysql.global_priv WHERE User = "";' || return 0
    local anon=${OS_RUN_OUTPUT//[^0-9]/}

    if [[ -n ${anon} && ${anon} -gt 0 ]]; then
        os::warn "发现 ${anon} 个匿名数据库账号 —— 任何人不用密码就能连上"
        if os::confirm --arg drop-anonymous '删除全部匿名账号？' y; then
            os::record_change '删除了匿名数据库账号'
            os::sql_exec '删除匿名账号' -- \
                'DELETE FROM mysql.global_priv WHERE User = ""; FLUSH PRIVILEGES;'
            MARIADB_CHANGED=1
        fi
    fi

    os::sql_query '查 test 库' -- \
        'SHOW DATABASES LIKE "test";' || return 0
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        os::warn "存在名为 test 的数据库。老版本 MariaDB 的这个库对所有账号可写；确认无用后自行 DROP DATABASE test（本脚本不替你删库）"
    fi
    return 0
}

# root@localhost 现在到底有哪几条认证通道 —— **问数据库，不问「这次做了什么」**。
#
# 一开始这里写的是「给了 --set-root-password 就报 unix_socket+password」，
# 于是**没给这个参数的那一次执行会把 state 里的 root_auth 覆写回 unix_socket**，
# 哪怕上一次刚加过密码通道。state 是 doctor 与 F6 卸载的唯一原料，
# 写进去的必须是系统的事实，不是本次执行的意图。
#
# 判据两个字段（实测出来的，不是猜的）：
#   auth_or 里有 unix_socket        → socket 通道在
#   authentication_string 是 *开头的哈希 → 密码通道在（没设密码时是 "invalid"）
detect_root_auth() {
    local -a ways=()
    os::sql_query '查 root 的认证通道' -- \
        'SELECT CONCAT(JSON_UNQUOTE(JSON_EXTRACT(Priv, "$.authentication_string")), "|", JSON_EXTRACT(Priv, "$.auth_or")) FROM mysql.global_priv WHERE User = "root" AND Host = "localhost";' \
        || {
            printf 'unknown\n'
            return 0
        }
    local row=${OS_RUN_OUTPUT}
    [[ ${row} == *unix_socket* ]] && ways+=('unix_socket')
    [[ ${row} == \** ]] && ways+=('password')
    if [[ ${#ways[@]} -eq 0 ]]; then
        printf 'unknown\n'
        return 0
    fi
    local IFS='+'
    printf '%s\n' "${ways[*]}"
    return 0
}

# root 密码 —— 默认不走这里。
#
# 关键是 `VIA unix_socket OR mysql_native_password`：**两条通道都留着**。
# 只写 `IDENTIFIED BY` 的话 unix_socket 那条会被顶掉，本机 root 免密连库
# 当场失效，而 oneserver 其余脚本全靠它。
#
# 密码经 os::sql_str 转义后进 SQL，SQL 再经 stdin 送给 mysql（不进 argv）。
set_root_password() {
    local pass=''

    if os::confirm --arg auto-password '自动生成 root 密码？（选否则手动输入）' y; then
        os::query --timeout 10 -- openssl rand -hex 16 || os::die 1 '生成密码失败'
        pass=${OS_RUN_OUTPUT}
        [[ ${#pass} -ge 16 ]] || os::die 1 '生成的密码长度异常，拒绝继续'
    else
        os::ask_secret --confirm '请输入 MariaDB root 密码' pass
    fi

    os::secure_set "${MARIADB_SECRET_KEY}" "${pass}" || os::die 1 '保存 root 密码失败'

    # os::sql_str 是纯 bash 函数（不 fork 外部命令），$( ) 取值不会让密码
    # 进任何进程的 argv；脱敏也已经由上面的 os::secure_set 登记过了
    local quoted
    quoted=$(os::sql_str "${pass}")

    os::record_change '给 root@localhost 加了密码通道'
    os::sql_exec '设置 root 密码通道' -- \
        "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD(${quoted}); FLUSH PRIVILEGES;"
    MARIADB_CHANGED=1
    os::ok "root 已同时支持 unix_socket 与密码；密码存在凭据库，键名 ${MARIADB_SECRET_KEY}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local bind_addr=''
    os::ask --arg bind '监听地址（回车保持系统默认的仅本机）' bind_addr ''

    local -i want_root_pass=0
    os::flag --arg set-root-password && want_root_pass=1

    os::pkg_install mariadb-server mariadb-client

    # **本次真装上包 = 有变更。** 不记这一笔的话，全新安装会打「已是目标状态」——
    # 因为发行版的默认配置本来就对，后面三段一个字都不用改。
    # CHANGED 位是给用户看「这次到底动了没有」的，不是给配置文件专用的。
    local pkg
    local -a own_pkgs=()
    while IFS= read -r pkg; do
        case ${pkg} in
            mariadb-server | mariadb-client) own_pkgs+=("${pkg}") ;;
            *) continue ;;
        esac
    done < <(os::pkg_installed_names)
    [[ ${#own_pkgs[@]} -gt 0 ]] && MARIADB_CHANGED=1

    probe::component_version mariadb
    local current=${OS_PROBE_VALUE}
    # `1:11.8.6-0+deb13u1` → `11.8.6`
    current=${current#*:}
    current=${current%%-*}
    [[ -n ${current} ]] && os::info "当前已安装：${current}"

    # 这一段必须排在 os::require_cmd 与任何 SQL 之前：dry-run 下 pkg_install
    # 什么都没装，紧接着去 require_cmd 一个本该由它装上的命令，必然停在
    # 「缺少 mysql」上 —— 那是预演在报告一件它自己造成的事（规范依赖断裂）。
    if [[ ! -f ${MARIADB_CONF} ]]; then
        if [[ ${OS_DRYRUN} -eq 1 ]]; then
            os::info "[dry-run] 后续步骤无法预演：${MARIADB_CONF} 尚不存在（包还没真装）"
            os::output 0 bind="${bind_addr:-default}" changed=dry-run
            return 0
        fi
        os::die 1 "装完 mariadb-server 之后仍然没有 ${MARIADB_CONF}"
    fi

    os::require_cmd mysql mysqladmin

    # 先把服务拉起来 —— 后面的基线核对与改密码都要连库。
    # 服务本来就没跑时启动它不算「变更」，那是达到目标状态。
    probe::service_active "${MARIADB_UNIT}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::systemd_restart "${MARIADB_UNIT}"
    fi

    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        probe::service_active "${MARIADB_UNIT}"
        if [[ ${OS_PROBE_VALUE} != active ]]; then
            os::query --timeout 10 -- journalctl -u "${MARIADB_UNIT}" --no-pager -n 20
            os::debug "journalctl 尾部：${OS_RUN_OUTPUT}"
            os::die 1 'MariaDB 服务启动失败，日志里有 journalctl 的尾部输出'
        fi
    fi

    check_baseline
    [[ ${want_root_pass} -eq 1 ]] && set_root_password
    apply_bind "${bind_addr}"

    # 只有 bind-address 真改了才重启。改密码是 SQL 层的事，不用重启；
    # 而重启一个正在服务的数据库会掐断全部连接（规范要求第二次执行零变更）。
    if [[ ${MARIADB_RESTART} -eq 1 ]]; then
        os::systemd_restart "${MARIADB_UNIT}"
    fi
    os::systemd_enable "${MARIADB_UNIT}"

    # 连通性验证：以 OS root 走 unix_socket，不带任何密码。
    # 这正是上面那条「所有脚本一律走 socket」的第一个消费者。
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        os::query --timeout 15 -- mysqladmin ping \
            || os::die 1 '装好了但连不上：以 root 走 unix_socket ping 不通'
    fi

    # 状态与资源清单
    probe::component_version mariadb
    local ver=${OS_PROBE_VALUE}
    ver=${ver#*:}
    ver=${ver%%-*}
    [[ -n ${ver} ]] || ver='unknown'

    local bind_now='127.0.0.1'
    os::query --timeout 5 -- sed -n 's/^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*//p' "${MARIADB_CONF}"
    [[ -n ${OS_RUN_OUTPUT} ]] && bind_now=${OS_RUN_OUTPUT%%$'\n'*}

    local root_auth='unknown'
    [[ ${OS_DRYRUN} -eq 1 ]] || root_auth=$(detect_root_auth)

    os::state_set mariadb version="${ver}" bind="${bind_now}" root_auth="${root_auth}"

    # 两层过滤（D103）：只登记本次真装上的，且只登记本组件自己的包 ——
    # own_pkgs 在上面装完包时就筛好了，这里不重筛，免得两处判据走岔。
    # **数据目录不登记** ——规范明列「数据库、站点目录、备份」永不自动删除。
    for pkg in ${own_pkgs[@]+"${own_pkgs[@]}"}; do
        os::state_resource_add mariadb pkg "${pkg}"
    done

    os::kv '版本' "${ver}" \
        '监听地址' "${bind_now}" \
        'root 认证' "${root_auth}" \
        '配置文件' "${MARIADB_CONF}" \
        '数据目录' "${MARIADB_DATA_DIR}（卸载时不会自动删除）"

    local changed_text='no'
    if [[ ${MARIADB_CHANGED} -eq 1 ]]; then
        changed_text='yes'
        os::ok "MariaDB 已安装并配置完成：${ver}"
    else
        os::ok "MariaDB ${ver} 已是目标状态"
    fi
    os::output 0 version="${ver}" bind="${bind_now}" \
        root_auth="${root_auth}" changed="${changed_text}"
    return 0
}

main "$@"
