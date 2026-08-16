#!/bin/bash
#
# 数据库管理
#
# @command      mariadb
# @name         MariaDB
# @group        db
# @order        10
# @requires     mariadb
# @privilege    root
# @requires_lib >= 4.8
# @provides     db:<name>
# @args         [--action=<list|create|delete|allow-containers>] [--name=<库名>] [--user=<用户名>] [--allow-any-host=<y|n>] [--auto-password=<y|n>] [--confirm-drop=<库名>] [--allow-containers=<y|n>]
# @description  创建、删除数据库与关联账号，管理容器访问
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 这个脚本一次核销三条缺陷，每一条都对应下面一段具体写法
#
# ## K9 · SQL 全部字符串拼接
#
# 旧脚本：`execute_mysql "SHOW DATABASES LIKE '$db_name';"`，库名、用户名、
# 密码全部来自用户输入，未做任何转义直接进 SQL。这里**一律经 lib/sql.sh**：
# 标识符走 `os::sql_ident`（反引号 + 翻倍转义），值走 `os::sql_str`
# （按 MySQL 转义表处理）。两个函数都有真库用例守着（tests/lib/sql.bats
# 让 MariaDB 自己当裁判，把恶意输入原样存进去再读出来比对）。
#
# ## K3 · 账号默认 `'user'@'%'` + GRANT ALL
#
# 旧脚本把 `DB_USER_HOST` 写死成 `%`，注释说「适用于 Docker 或远程连接」——
# 那是作者自己的用法。与 K2（监听 0.0.0.0 默认 y）叠加，就得到
# 「数据库监听全网 + 账号可从任意主机连 + 无防火墙」的组合。
#
# 现在默认 `localhost`，`%` 要显式给 `--allow-any-host` 且默认 `n`。
# `GRANT ALL` 保留但**只授到单库**（`ON <db>.*`），不是全局权限 —— 一个
# 应用账号对自己的库有全权是正常的，对整个实例有全权不是。
#
# ## K12 · source secure.conf
#
# 旧脚本 `source "$SECURE_CONF"` 取 root 密码 —— source 一个配置文件等于
# 执行它，与写入端不转义叠加就是完整的 RCE 链条。
#
# 这里连取密码这一步都没有：**按 D121，oneserver 的所有脚本一律以 OS root
# 走 unix_socket 连库**。`os::sql_*` 不带 `--defaults-file` 时就是这条路。
#
# ## 旧的 db_user_mapping.conf 也没了
#
# 那是一份自己维护的「库 → 用户」注册表，而 state 就是干这个的。
# 改用组件标识 `db:<库名>`，`list` 直接读 state。
#
# **给 F6 的提醒**：`db:*` 不登记任何 pkg/file/divert/alt/unit 资源 ——
# 它没有这些东西，而它的实体（数据库本身）按规范属「永不自动删除」。
# 想删库只有一条路：`oneserver mariadb delete`，那里走 `os::destroy_confirm`。

readonly DB_SNAPSHOT_DIR="${OS_BACKUP_DIR}/pre-delete"

# 「允许容器访问」要动的两样东西。**与 install_mariadb.sh 是同两个常量**——
# 那边装的时候定监听地址，这边是装完之后按需放开给容器，改的是同一个文件、
# 同一个端口。
readonly MARIADB_CONF='/etc/mysql/mariadb.conf.d/50-server.cnf'
readonly MARIADB_UNIT='mariadb.service'
readonly MARIADB_PORT='3306'

# 函数之间的返回通道。**不用 `printf` + `$( )`** —— os::info / os::ok / os::run
# 的提示都默认打到 stdout，会被一起吃进变量（D135 就是这么栽的）。
DB_SNAPSHOT_FILE=''

# ------------------------------------------------------------------

# 库名与用户名的合法字符。收紧到这个集合不是因为转义不住 ——
# `os::sql_ident` 处理得了任何字符 —— 而是因为库名会出现在**文件名**
# （备份文件）和 **state 的实例标识**里，那两处各有各的语法。
# 与其在三套规则之间来回翻译，不如一开始就只收都认的那部分。
# **必须与 state 的组件标识规则一致**，所以直接问 state 自己。
#
# 库名会成为 `db:<库名>` 的实例部分，而 state 的实例名只收 `[a-z0-9]` 开头。
# 这里原来松一档（允许下划线开头、允许大写），后果不是「校验漏了」那么轻：
# 库建好了、账号建好了、密码也写进凭据库了，最后 os::state_set 才以
# 「组件标识不合法」失败 —— 而屏幕上照样打出「✓ 已创建」，state 里却什么都没有，
# 于是 uninstall 再也找不到它。两套规则各写一份，迟早就是这个下场。
#
# 额外再收一道 `.`：state 的实例名允许点，但库名会进备份文件名
# `<库名>-20260804-120000.sql.gz`，点会让恢复时的解析对不上。
valid_name() {
    [[ ${1} =~ ^[a-z0-9][a-z0-9_-]*$ ]] || return 1
    os::state_id_valid "db:${1}"
}

# 用户库列表，结果留在 OS_RUN_OUTPUT 里。系统库排除掉 ——
# 它们不是用户的东西，列出来只会让人误删。
#
# **这里一个字都不许往 stdout 打。** 原来多了一行 `printf '%s\n' "${OS_RUN_OUTPUT}"`
# （第一版留下的），`--output=json` 下就在 JSON 信封前面多出两行裸库名，
# 任何解析器都会当场报错 —— 而文本模式下看不出任何异常（
# json 模式整层静默，靠的是所有输出都走 os::* 语义函数）。
user_databases() {
    os::sql_query '列出用户数据库' -- \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
         ORDER BY schema_name;" || return 1
    return 0
}

db_exists() {
    local q
    q=$(os::sql_str "${1}")
    os::sql_query '检查数据库是否存在' -- "SHOW DATABASES LIKE ${q};" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

user_exists() {
    local qu qh
    qu=$(os::sql_str "${1}")
    qh=$(os::sql_str "${2}")
    os::sql_query '检查账号是否存在' -- \
        "SELECT User FROM mysql.global_priv WHERE User = ${qu} AND Host = ${qh};" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

# ------------------------------------------------------------------

# 总览表的编号就是当前操作周期的选择符，避免把同一批库再打印一遍。
# 与容器清单同一套：清单缓存进数组，总览按它渲染，动作按它把编号翻回库名 ——
# 序号与清单同源，才不会出现「看到的 3 号」与「删掉的 3 号」不是一个。
# 对删库这种不可逆动作，这条比别处更要紧。
DB_LIST_READY=0
DB_NAMES=()
DB_ACCOUNTS=()

# 这个账号当前的**全部**来源，结果写进 DB_HOSTS，形如 `u@localhost · 10.88.0.0/255.255.0.0`。
# 第一个带 `u@`，其余只列主机部分 —— 三四个容器网段时前缀重复三四遍，一行就满了。
#
# **不用 `$( )` 返回**：os::sql_query 的提示打在 stdout 上，命令替换会把它一起
# 吃进变量（D135）。查不到就给空串，由调用方决定怎么回落。
DB_HOSTS=''

account_hosts() {
    local user=${1} qu h out=''
    DB_HOSTS=''
    qu=$(os::sql_str "${user}")
    # **localhost 排第一**，其余按字母序。纯 `ORDER BY Host` 是字母序，数字开头
    # 的容器网段会排到 localhost 前面 —— 而第一项是唯一带 `user@` 前缀的那个，
    # 于是一眼看去像「这账号主要从容器网段来」，真正的主账号反而缩在末尾。
    os::sql_query '列出账号来源' -- \
        "SELECT Host FROM mysql.global_priv WHERE User = ${qu}
         ORDER BY (Host = 'localhost') DESC, Host;" || return 1
    local IFS=$'\n'
    for h in ${OS_RUN_OUTPUT}; do
        [[ -n ${h} ]] || continue
        if [[ -z ${out} ]]; then
            out="${user}@${h}"
        else
            out+=" · ${h}"
        fi
    done
    DB_HOSTS=${out}
    return 0
}

load_db_rows() {
    DB_NAMES=()
    DB_ACCOUNTS=()
    DB_LIST_READY=1

    user_databases || os::die 1 '查询数据库列表失败'
    # **先把库名收进数组再遍历。** 下面要为每个库查一次账号来源，而
    # os::sql_query 的结果同样落在 OS_RUN_OUTPUT —— 直接 `for name in
    # ${OS_RUN_OUTPUT}` 的话，第一次查询就把正在遍历的那份列表冲掉了。
    local -a names=()
    mapfile -t names <<<"${OS_RUN_OUTPUT}"

    local name user host
    for name in ${names[@]+"${names[@]}"}; do
        [[ -n ${name} ]] || continue
        # 关联账号从 state 读。读不到不是错：用户手工建的库本来就不在 state 里
        user=$(os::state_get "db:${name}" user)
        DB_NAMES+=("${name}")
        if [[ -z ${user} ]]; then
            DB_ACCOUNTS+=('（非本工具创建，无关联账号记录）')
            continue
        fi

        # **来源以库里的现状为准，不读 state 的 host。** 那个字段是建库那一刻写
        # 下的，而 allow-containers 会为同一个账号新增容器网段来源（localhost
        # 那条按设计保留）—— 只显示 state 的话，放行完容器访问回到这一屏看到的
        # 还是 localhost，像是那一步没生效。
        account_hosts "${user}" || true
        if [[ -n ${DB_HOSTS} ]]; then
            DB_ACCOUNTS+=("${DB_HOSTS}")
        else
            # 库里查不到这个账号（被手工删过），如实说，别假装它还在
            host=$(os::state_get "db:${name}" host)
            DB_ACCOUNTS+=("${user}@${host}（登记过，但库里已不存在）")
        fi
    done
    return 0
}

# 选一个已有的库：编号或库名都收。
#
# **清单没上屏时先列一遍**：`oneserver mariadb delete` 从命令行直接跑时总览
# 不会显示（它只在交互的动作清单里跑），让人对着一个看不见的清单输编号不行。
#
# 非交互下 os::ask 没有默认值就以 2 停下 —— 绝不替用户挑第一个来删，
# 编号打错也不会落回第一项。
select_database() {
    local __db_out=${1} __db_prompt=${2}
    [[ ${DB_LIST_READY} -eq 1 ]] || action_list
    [[ ${#DB_NAMES[@]} -gt 0 ]] || os::die 2 '没有用户创建的数据库'

    local __db_picked=''
    os::ask --arg name "${__db_prompt}（输入上方编号；命令行可传 --name）" __db_picked
    if [[ ${__db_picked} =~ ^[0-9]+$ ]]; then
        local -i __db_sel=$((__db_picked - 1))
        ((__db_sel >= 0 && __db_sel < ${#DB_NAMES[@]})) \
            || os::die 2 "没有编号为「${__db_picked}」的数据库"
        __db_picked=${DB_NAMES[__db_sel]}
    fi
    db_exists "${__db_picked}" || os::die 2 "数据库 ${__db_picked} 不存在"
    printf -v "${__db_out}" '%s' "${__db_picked}"
    return 0
}

action_list() {
    load_db_rows
    os::screen_heading '数据库'
    if [[ ${#DB_NAMES[@]} -eq 0 ]]; then
        os::info '没有用户创建的数据库'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#DB_NAMES[@]}; i++)); do
        cells+=("[$((i + 1))]" "${DB_NAMES[i]}" "${DB_ACCOUNTS[i]}")
        os::output_item name="${DB_NAMES[i]}" account="${DB_ACCOUNTS[i]}"
    done
    os::table '编号' '数据库' '关联账号' -- "${cells[@]}"
    os::output 0 count="${#DB_NAMES[@]}"
    return 0
}

action_create() {
    local name=''
    os::ask --validate valid_name --hint '只收小写字母、数字、下划线、短横，且以字母数字开头' --arg name '新数据库名称' name
    if db_exists "${name}"; then
        os::die 2 "数据库 ${name} 已存在"
    fi

    local user=''
    os::ask --validate valid_name --hint '只收小写字母、数字、下划线、短横，且以字母数字开头' --arg user '关联账号名' user "${name}"

    # K3 就在这里。默认 localhost，`%` 是降低安全性的选项 → 默认必须 n
    # 默认值取 L0 的 OS_DEFAULT_DB_USER_HOST（用户可在 conf 里改），
    # 不在脚本里写死 —— defaults.sh 里那一项本来就是为 K3 准备的
    local host=${OS_DEFAULT_DB_USER_HOST}
    if os::confirm --arg allow-any-host \
        '允许这个账号从任意主机连接（%）？默认只允许本机' n; then
        host='%'
        os::warn "补偿控制：账号权限只到 ${name} 这一个库；请确认 MariaDB 的 bind-address 与防火墙确实只对可信来源开放"
    fi

    if user_exists "${user}" "${host}"; then
        os::die 2 "账号 ${user}@${host} 已存在"
    fi

    # 密码：默认自动生成，同 install_redis / install_mariadb。
    # 没有 --password=<值> 这种参数 —— 凭据进 argv 就是 ps 可见
    local pass=''
    if os::confirm --arg auto-password '自动生成账号密码？（选否则手动输入）' y; then
        os::query --timeout 10 -- openssl rand -hex 16 || os::die 1 '生成密码失败'
        pass=${OS_RUN_OUTPUT}
        [[ ${#pass} -ge 16 ]] || os::die 1 '生成的密码长度异常，拒绝继续'
    else
        os::ask_secret --confirm "请输入 ${user} 的密码" pass
    fi

    # 凭据先落库再进 SQL：secure_set 会登记脱敏，之后任何日志/审计里都没有明文。
    # key 带命名空间—— K7 的教训是扁平 key 遇到第二个同类事物就静默覆盖
    local key="db.${name}.password"
    os::secure_set "${key}" "${pass}" || os::die 1 '保存账号密码失败'

    local qdb quser qhost qpass
    qdb=$(os::sql_ident "${name}")
    quser=$(os::sql_str "${user}")
    qhost=$(os::sql_str "${host}")
    qpass=$(os::sql_str "${pass}")

    os::record_change "创建了数据库 ${name} 与账号 ${user}@${host}"

    # 三步都失败可回滚：建库、建号、授权。任一步失败就把前面的撤掉 ——
    # 半个数据库比没有更麻烦，而这几样都是本次刚造出来的，撤销不会碰用户既有资产
    os::defer os::sql_exec --allow-fail '回滚：删除刚建的账号' -- \
        "DROP USER IF EXISTS ${quser}@${qhost};"
    os::defer os::sql_exec --allow-fail '回滚：删除刚建的数据库' -- \
        "DROP DATABASE IF EXISTS ${qdb};"

    os::sql_exec '创建数据库' -- \
        "CREATE DATABASE ${qdb} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE};"
    os::sql_exec '创建数据库账号' -- \
        "CREATE USER ${quser}@${qhost} IDENTIFIED BY ${qpass};"
    # GRANT ALL 但**只到这一个库**（ON <db>.*），不是全局权限
    os::sql_exec '授予单库权限' -- \
        "GRANT ALL PRIVILEGES ON ${qdb}.* TO ${quser}@${qhost}; FLUSH PRIVILEGES;"

    # `engine` 记的是这个库归哪个数据库引擎。现在只有一种取值，但它是**持久化
    # 数据**：代码随时能改，已经写进用户机器的记录改不了。将来多一个引擎时，
    # 没有这一键的存量记录只能靠猜，而猜错就是拿另一套工具去恢复这份备份。
    os::state_set "db:${name}" engine=mariadb user="${user}" host="${host}" \
        charset="${OS_DEFAULT_DB_CHARSET}" collate="${OS_DEFAULT_DB_COLLATE}"

    # dry-run 下三条 sql_exec + secure_set + state_set 全被各自的 dry-run
    # 分支跳过，一个字节都没写——不看 OS_DRYRUN 就往下打「已创建」+
    # changed=yes，是 D15 说的「会撒谎的 dry-run」（同 podman image/volume）
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将创建数据库 ${name} 与账号 ${user}@${host}"
        os::output 0 name="${name}" user="${user}" host="${host}" changed=dry-run
        return 0
    fi

    os::kv '数据库' "${name}" \
        '账号' "${user}@${host}" \
        '字符集' "${OS_DEFAULT_DB_CHARSET} / ${OS_DEFAULT_DB_COLLATE}" \
        '密码' "已存入凭据库，键名 ${key}"
    # **密码不打在屏幕上**（旧脚本会打，还提示「请妥善保存」）——
    # 终端会进滚动缓冲、进录屏、进贴到群里的截图。要取值：
    os::info "取密码：oneserver secure get ${key}"
    os::ok "数据库 ${name} 与账号 ${user}@${host} 已创建"
    os::output 0 name="${name}" user="${user}" host="${host}" changed=yes
    return 0
}

action_delete() {
    local name=''
    select_database name '要删除哪个数据库'

    local user host
    user=$(os::state_get "db:${name}" user)
    host=$(os::state_get "db:${name}" host)

    # 规范：不可逆操作**必须先落副本**。删库之前先 dump 一份，
    # 这是「确认了才删」之外的第二道 —— 人是会打对全名然后后悔的
    local dump=''
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        snapshot_database "${name}" || os::die 1 '删除前的快照失败，已中止（不会在没有副本的情况下删库）'
        dump=${DB_SNAPSHOT_FILE}
        os::ok "删除前快照：${dump}"
    fi

    local -a items=("数据库 ${name}（含全部表与数据）")
    [[ -n ${user} ]] && items+=("账号 ${user}@${host}")
    [[ -n ${dump} ]] && items+=("（已先留快照 ${dump}；恢复时先建回同名数据库，再从统一入口导入）")

    # 打全名确认，--yes 对它不生效，非交互下要 --force-destroy
    if ! os::destroy_confirm --arg confirm-drop "${name}" -- "${items[@]}"; then
        # 文案得跟事实对得上：删除前的副本在确认点之前就已经落盘（规范要求
        # 「不可逆操作必须先落副本」），放弃删除不会把它撤销掉
        if [[ -n ${dump} ]]; then
            os::info "已取消，数据库未删除（删除前快照 ${dump} 仍保留）"
        else
            os::info '已取消，未删除任何东西'
        fi
        os::output 0 name="${name}" changed=no
        return 0
    fi

    local qdb
    qdb=$(os::sql_ident "${name}")
    os::record_change "删除了数据库 ${name}"
    os::sql_exec '删除数据库' -- "DROP DATABASE ${qdb};"

    if [[ -n ${user} ]]; then
        local quser qhost
        quser=$(os::sql_str "${user}")
        qhost=$(os::sql_str "${host}")
        os::record_change "删除了数据库账号 ${user}@${host}"
        os::sql_exec '删除数据库账号' -- \
            "DROP USER IF EXISTS ${quser}@${qhost}; FLUSH PRIVILEGES;"
    fi

    # 凭据与 state 一并清掉，否则下次建同名库会读到上一个的密码
    os::secure_del "db.${name}.password" || true
    os::state_del "db:${name}" || true

    os::ok "数据库 ${name} 已删除（删除前快照：${dump:-无}）"
    if [[ -n ${dump} ]]; then
        os::info "需要恢复快照时先建回数据库：oneserver mariadb create --name=${name}"
        os::info "再导入：oneserver restore --from=external --source=${dump} --target=db:${name}"
    fi
    os::output 0 name="${name}" snapshot="${dump}" changed=yes
    return 0
}

# 删除前用 mysqldump | gzip 留快照，结果路径写进 DB_SNAPSHOT_FILE。
#
# 用 `sh -c` 是因为这里要的是一条**管道**，而 os::run 只接一条命令。
# 进 `sh -c` 的每一个变量都必须是本脚本自己造的或过了白名单的：
# 库名经 shell_safe_name（只允许 [A-Za-z0-9_-]），路径由 DB_SNAPSHOT_DIR 与
# 时间戳拼成。**没有任何一段直接来自用户输入** —— 这是规范禁 eval 的同一条
# 思路：与其想清楚 sh 的引号规则，不如让不合规的东西根本进不来。
snapshot_database() {
    local name=${1}
    DB_SNAPSHOT_FILE=''
    shell_safe_name "${name}"

    os::run '创建删除前快照目录' -- mkdir -p "${DB_SNAPSHOT_DIR}"
    os::run '收紧快照目录权限' -- chmod 0700 "${DB_SNAPSHOT_DIR}"

    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${DB_SNAPSHOT_DIR}/${name}-${ts}.sql.gz"

    # 写临时文件再 mv：中途失败留下的半截 .sql.gz 看起来是个正常备份，
    # 而它恢复出来的是半个数据库 —— 比没有备份更危险
    local tmp="${out}.partial"
    # charset/name/tmp 经位置参数（"$1"/"$2"/"$3"）传给 sh -c，不拼进脚本文本——
    # 同 restore.sh 的 snapshot_db：值不管校验是否有漏网之鱼，都不会被当成 shell 语法解释。
    # shellcheck disable=SC2016  # 理由：$1/$2/$3 是内层 sh 的位置参数，故意不让外层展开
    if ! os::run --allow-fail '导出数据库' -- sh -c \
        'mysqldump --single-transaction --routines --triggers --default-character-set="$1" "$2" | gzip -c > "$3"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${name}" "${tmp}"; then
        os::run --allow-fail '清理未完成的备份' -- rm -f "${tmp}"
        return 1
    fi
    os::run '就位备份文件' -- mv -f "${tmp}" "${out}"
    os::run '收紧备份文件权限' -- chmod 0600 "${out}"
    DB_SNAPSHOT_FILE=${out}
    return 0
}

# 库名进命令行前的白名单确认。valid_name 已经把库名限死在 [A-Za-z0-9_-]，
# 这里再确认一遍 —— 备份/恢复那两条管道靠的就是这个前提。
shell_safe_name() {
    valid_name "${1}" || os::die 2 "数据库名「${1}」不能安全地进入命令行"
    return 0
}

# ==================================================================
# 允许容器访问数据库
# ==================================================================
#
# 解决的是一件很具体的事：容器里的应用要连宿主的 MariaDB，而宿主默认只监听
# 127.0.0.1、防火墙也默认拒绝，于是每建一个容器都要单独跑一趟放行。
#
# **放行的是探测出来的真实容器网段**，不是拍一个私有段。旧脚本写死
# `10.0.0.0/8`：实测 podman 默认只用 `10.88.0.0/16`，而 docker 默认的
# `172.17.0.0/16` 根本不在那个范围里 —— 开得过宽，而且对 docker 无效。
#
# **幂等且可刷新**：以后新建了容器网络（`172.18.0.0/16` …），重跑一次这个动作
# 就把缺的补上，已有的不动。这正是「容器一多就记不清哪个网段放行过」的解法。
#
# **网络与账号一起放行**。账号身份是「用户 + 来源」两段，`app@localhost` 匹配不了
# 从 10.88.0.x 过来的连接 —— 只开网络的话，这条命令做完容器仍然 Access denied，
# 而那个报错和「刚放行了网段」看起来毫无关系。所以同一个确认点覆盖两件事，
# 账号来源同样取自那份探测结果，两半不会各用各的依据。
#
# **不走「只绑网桥网关」那条路**（更安全但不实用）：每个容器网络有自己的网关，
# 新建一个网络就要多绑一个地址并重启数据库，容器一多就是持续的维护负担。
# 这里统一绑 0.0.0.0，边界交给防火墙 —— 代价是数据库在公网网卡上也监听着，
# 所以下面对 UFW 的要求是硬的：没有真正挡得住的防火墙就不动手。

# 这个网段放行过没有。规则匹配在 lib/firewall.sh（§11）
db_subnet_allowed() {
    local subnet=${1}
    probe::ufw_rules
    os::ufw_allowed "${OS_PROBE_VALUE}" "${MARIADB_PORT}" tcp "${subnet}"
}

# 网段 → MySQL 账号能用的来源写法：`10.88.0.0/16` → `10.88.0.0/255.255.0.0`。
#
# **不能直接把 CIDR 塞进 host**：MySQL 的 host 只认 `%`/`_` 通配或
# `地址/掩码`，`/16` 这种前缀长度它不认，写进去会变成一个永远匹配不上的字面量
# —— 而这种错不报错，只表现为容器仍然 Access denied。
#
# IPv6 网段直接跳过（返回 1）：掩码写法是 IPv4 专用的。
subnet_to_user_host() {
    local __db_out=${1} __db_cidr=${2}
    printf -v "${__db_out}" '%s' ''
    [[ ${__db_cidr} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
    local __db_ip=${__db_cidr%/*}
    # `10#` 不能省：前缀长度写成 `/08` 时，算术上下文会按八进制解析，
    # 而 08 不是合法八进制 —— 那是一次中断，不是一个 0
    local -i __db_bits=$((10#${__db_cidr#*/}))
    ((__db_bits <= 32)) || return 1

    local __db_mask=''
    local -i __db_o __db_take
    for __db_o in 1 2 3 4; do
        __db_take=$((__db_bits - (__db_o - 1) * 8))
        ((__db_take < 0)) && __db_take=0
        ((__db_take > 8)) && __db_take=8
        __db_mask+="${__db_mask:+.}$((256 - 2 ** (8 - __db_take)))"
    done
    printf -v "${__db_out}" '%s/%s' "${__db_ip}" "${__db_mask}"
    return 0
}

# 把 state 里登记的账号补上容器网段来源，新增个数写进 DB_ACCOUNTS_ADDED。
#
# **没有单独的确认点**：放行容器访问这件事本身已经在上面确认过一次，而只放行
# 网络、不放行账号的话这条命令做完容器照样连不上（账号身份是「用户+来源」两段，
# `app@localhost` 匹配不了从 10.88.0.x 过来的连接）。把它拆成两次确认，等于让
# 每个用户都踩一次「按提示做完了还是不通」。
#
# 密码从凭据库读回（建库时 action_create 存的那一份），新来源与原来同一个密码，
# 不需要用户重新提供。**必须走 os::secure_load**：它读进变量的同时登记脱敏，
# 而 lib/sql.sh 的契约写明凭据随 SQL 传入前要先登记，否则会落进日志。
#
# 原来的 `@localhost` 一律保留：删账号不可逆，而本机连接还要用它。
DB_ACCOUNTS_ADDED=0
db_extend_accounts() {
    local -a nets=("$@")
    DB_ACCOUNTS_ADDED=0

    local db user host pass net newhost qu qh qdb qpass
    local -a dbs=()
    user_databases || return 1
    mapfile -t dbs <<<"${OS_RUN_OUTPUT}"

    for db in "${dbs[@]}"; do
        [[ -n ${db} ]] || continue
        user=$(os::state_get "db:${db}" user)
        host=$(os::state_get "db:${db}" host)
        # 不在 state 里的库是用户自己建的，本工具不知道它的账号是哪个，不猜
        [[ -n ${user} && -n ${host} ]] || continue
        # 已经是 `%` 的账号本来就哪儿都能连，不用再加来源
        [[ ${host} == '%' ]] && continue

        # 凭据库里没有这个库的密码（老记录、或账号是手工建的），就不猜也不改，
        # 说清楚让用户自己补 —— 用错的密码建出来的来源同样连不上，还更难查
        if ! os::secure_load "db.${db}.password" pass; then
            os::warn "凭据库里没有 db.${db}.password，跳过 ${user}@${host} —— 这个库的容器来源要手工建"
            continue
        fi
        qpass=$(os::sql_str "${pass}")

        for net in "${nets[@]}"; do
            subnet_to_user_host newhost "${net}" || continue

            qu=$(os::sql_str "${user}")
            qh=$(os::sql_str "${newhost}")
            qdb=$(os::sql_ident "${db}")

            if ! user_exists "${user}" "${newhost}"; then
                os::record_change "为账号 ${user} 增加了来源 ${newhost}"
                # 与 action_create 同一套：**先登记撤销再动手**。这条来源是本次刚
                # 造出来的，撤销不碰用户既有资产；不登记的话，后面任一步失败都会把
                # 一个放宽了访问面的账号留在库里，而失败报告里看不出它
                os::defer os::sql_exec --allow-fail '回滚：删除刚加的容器网段来源' -- \
                    "DROP USER IF EXISTS ${qu}@${qh};"
                os::sql_exec '为账号增加容器网段来源' -- \
                    "CREATE USER ${qu}@${qh} IDENTIFIED BY ${qpass};" || return 1
                ((DB_ACCOUNTS_ADDED += 1))
            fi

            # **授权不跟着「账号是不是新建的」走。** 同一个账号服务多个库时，
            # 第一个库建出账号之后，后面几个库只会看到「账号已存在」——
            # 跟着跳过就永远不授权，而这种漏授权不报错，只表现为容器连上了
            # 却读不到表。GRANT 本身幂等，重复执行不产生变更，也不记审计。
            os::sql_exec '给容器网段来源授予单库权限' -- \
                "GRANT ALL PRIVILEGES ON ${qdb}.* TO ${qu}@${qh}; FLUSH PRIVILEGES;" || return 1
        done
    done
    return 0
}

action_allow_containers() {
    probe::container_subnets
    local subnets=${OS_PROBE_VALUE}
    if [[ -z ${subnets} ]]; then
        os::info '没有探测到任何容器网络 —— docker 与 podman 都没装，或者都没有带网段的网络'
        os::info '装了容器引擎、建过容器之后再回来跑这一步'
        os::output 0 subnets='' changed=no
        return 0
    fi

    local -a nets=()
    mapfile -t nets <<<"${subnets}"

    # §15：放宽访问来源必须在同一步落实补偿控制，落实不了就拒绝执行。
    # 这里的补偿控制有两条 —— 放行范围只到实际网段（不是 Anywhere），
    # 以及要求防火墙本身真的挡得住。后者用与 install_mariadb 同一条判据。
    #
    # **这一关必须排在下面那张表之前。** 表里「已放行 / 本次新增」那一列出自
    # os::ufw_allowed，而它读的规则文本来自 `ufw status` —— 防火墙停用时那条
    # 命令一条规则都读不出来（只有一行 `Status: inactive`），于是每个网段都会
    # 被标成「本次新增」，哪怕它早就放行过。从前门控排在表之后：用户先看到
    # 一张全错的表，再收到一句「防火墙没启用」。
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] \
        || os::die 3 '防火墙没启用，放行无从谈起（而数据库会因此对全网监听）。先执行 oneserver firewall enable'
    probe::ufw_default_incoming
    case ${OS_PROBE_VALUE} in
        deny | reject) ;;
        *) os::die 3 "防火墙默认入站是 ${OS_PROBE_VALUE}，此时「只放行容器网段」没有意义 —— 没被规则覆盖的来源同样进得来。先把默认入站改成 deny" ;;
    esac

    os::section '将要放行的容器网段'
    local n
    local -a cells=()
    for n in "${nets[@]}"; do
        cells+=("${n}" "$(db_subnet_allowed "${n}" && printf '已放行' || printf '本次新增')")
    done
    os::table '网段' '状态' -- "${cells[@]}"
    os::info "放行之后，这些网段里的容器可以连宿主的 ${MARIADB_PORT} 端口；其余来源仍被防火墙拒绝"
    os::info '本工具登记过的数据库账号会同时补上这些网段作为来源（密码不变，原来的本机来源保留）'

    os::warn "数据库的监听地址会改成 0.0.0.0（容器要够得着），此后挡在外面的只有防火墙"
    os::confirm --arg allow-containers '确认放行以上网段？' n \
        || os::die 130 '已取消，未做任何改动'

    local -i added=0
    for n in "${nets[@]}"; do
        db_subnet_allowed "${n}" && continue
        os::ufw_allow "${MARIADB_PORT}" tcp "${n}" || return 1
        added+=1
    done
    if ((added > 0)); then
        os::ufw_reload || return 1
    fi

    # 监听地址：容器连的是网桥网关，只听 127.0.0.1 的话规则放行了也连不上
    os::replace_line --backup "${MARIADB_CONF}" \
        '^[[:space:]]*#?[[:space:]]*bind-address[[:space:]]*=' 'bind-address            = 0.0.0.0' \
        || os::die 1 "${MARIADB_CONF} 里找不到 bind-address 行"
    # **紧邻着读**：OS_REPLACE_CHANGED 是单槽易失变量，中间插一次同类调用就没了
    local -i bind_changed=${OS_REPLACE_CHANGED}
    if [[ ${bind_changed} -eq 1 ]]; then
        os::record_change '把 MariaDB 的监听地址改成 0.0.0.0'
        os::systemd_restart "${MARIADB_UNIT}" || os::die 1 'MariaDB 重启失败，监听地址可能未生效'
    fi

    # 账号来源。**放在监听地址之后**：那一步会重启数据库，重启前建的账号照样在，
    # 但顺序反过来的话，中途失败会留下「账号开了、网络还没通」的半截状态 ——
    # 而这一半才是放宽了访问面的那一半。
    db_extend_accounts "${nets[@]}" || os::die 1 '补容器网段账号失败'

    # 记进 state，下次刷新时看得出上次放行到哪
    local IFS=' '
    os::state_set mariadb container_access="${nets[*]}" || true

    # `changed` 要如实反映**这一次有没有产生变更**（§10 幂等：第二次执行不产生
    # 任何新变更）。原来写成算术展开，产出的是 `1 ` / `0 ` 这种带尾随空格的值，
    # 既不是约定的 yes/no，也让消费者没法判断
    local changed='no'
    ((added > 0 || bind_changed == 1 || DB_ACCOUNTS_ADDED > 0)) && changed='yes'

    os::ok "已放行 ${added} 个新网段（共 ${#nets[@]} 个）、为账号新增 ${DB_ACCOUNTS_ADDED} 个来源；以后新建了容器网络，重跑这一步即可补上"
    os::info "容器里连数据库用宿主网关地址，例如 docker 默认是 172.17.0.1、podman 默认是 10.88.0.1"
    os::output 0 subnets="${nets[*]}" added="${added}" \
        accounts_added="${DB_ACCOUNTS_ADDED}" changed="${changed}"
    return 0
}

main() {
    # 装没装、跑没跑一律经 probe（D93）。
    #
    # **元数据里特意没有 `@requires mariadb`**：那一条查的是 state，而 state 里
    # 只有经 oneserver 装过的东西。用户自己 `apt install mariadb-server` 装的、
    # 或者像测试镜像那样随镜像来的，state 里一个字都没有 —— 于是 `db list`
    # 会以「缺少依赖组件：mariadb」拒绝执行，而机器上的数据库正跑得好好的。
    # 容器验收第一次跑就是这个现场。
    probe::service_active mariadb.service
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::die 3 'MariaDB 未在运行。先 oneserver install mariadb，或 systemctl start mariadb'
    fi
    os::require_cmd mysql mysqldump gzip openssl

    # 位置参数优先；没给才走交互（--action=... 由 os::select 自己从命令行取）
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_list --arg action '操作' dispatch \
        'create=新建数据库与账号' 'delete=删除数据库' \
        'allow-containers=允许容器访问数据库'
}

dispatch() {
    case ${1} in
        list) action_list ;;
        create) action_create ;;
        delete) action_delete ;;
        allow-containers) action_allow_containers ;;
        *) os::die 2 "未知操作「${1}」，可用：list create delete allow-containers" ;;
    esac
}

main "$@"
