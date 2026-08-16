#!/bin/bash
#
# 备份：站点 / 数据库 / 任意目录 / oneserver 自身配置
#
# @command      backup
# @name         备份管理
# @group        backup
# @order        10
# @privilege    root
# @requires_lib >= 4.0
# @provides     backup
# @provides_unit own:oneserver-backup.service
# @provides_unit own:oneserver-backup.timer
# @args         [--action=<overview|run|log|verify|add|remove|remote|schedule|unschedule>] [--target=<标识|all>] [--name=<别名>] [--source=<路径>] [--exclude=<模式,模式>] [--targets=<清单>] [--remote=<名字>] [--remote-dir=<路径>] [--local-keep=<n>] [--remote-keep=<n>] [--lines=<n>] [--allow-plaintext-backup] [--allow-plaintext-secrets] [--frequency=<daily|weekly>] [--at=<HH:MM>] [--weekday=<0-6>] [--confirm-remove=<别名>] [--confirm-unschedule=<backup>]
# @description  备份站点、数据库与目录，可推送 rclone 远端
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
# ## 一、rclone 是「传输」，不是「备份」——本工具也不把它当备份工具用
#
# 归档格式是 `tar.gz` 加一份同名 `sha256`，不用 restic / borg。备份要在
# 「这台机器没了」那一刻兑现，而那一刻手里可能只有一个桶和一台陌生的 Linux ——
# coreutils 就该解得开，连 oneserver 都不必装。
#
# 诚实说清代价：**无去重、无增量。** 5 GB 的站点每天传 5 GB，不粉饰。
#
# 完整论证、两处不能当成绝对的例外，以及什么时候该重估这个选择，见 D236。
# **别照「以后在目的地那层换成 restic」的思路改** —— 那样拿不到去重收益，
# D236 讲了为什么。
#
# 于是 rclone 的定位就清楚了：**它只负责把一个已经做好的归档搬到远端。**
# 选它而不是 rsync/sftp/awscli，是因为它一个二进制覆盖 70 个后端。
# 装的是**官方最新版而不是发行版源里那份**，理由见 ensure_rclone 与 D238。
#
# ## 二、加密交给 rclone 的 crypt remote，本脚本不自己写加密
#
# 归档里有数据库转储和 wp-config.php，推到别人家的对象存储上是明文。
# 但自己套一层 `openssl enc` 是在自造密钥管理、自造格式、自造恢复路径 ——
# 三样都是备份系统里最不该自造的东西。
#
# rclone 原生的 crypt remote 就是干这个的，久经考验，且**对本脚本完全透明**：
# `rclone lsf` / `copy` / `cat` 看到的仍是明文名字与内容。
# 本脚本要做的只有一件事：**认出目的地是不是 crypt，并按规范分级把关**。
#
# ## 三、备份对象是「目标」，不是「WordPress 站点」
#
# 保留策略、上传后回读校验、清理、定时、失败计数与 dry-run 都与目标类型
# 无关；只有采集步骤依赖类型。因此核心流程只认目标，避免把恢复格式绑定到
# 某一种应用。
#
# 更硬的理由是：**归档布局与 state 键名一旦落地就改不了。** 用户远端上躺着
# 一堆归档，改命名 = 老归档恢复不了。所以它必须一次定死，而不是
# 「先按 WordPress 写，以后再说」。
#
# 四种目标，标识沿用 D35 的 `<type>:<name>`：
#
#   site:<站点名>    站点目录 + 它的库      来源：state
#   db:<库名>        单个数据库             来源：state，或库真实存在
#   path:<别名>      任意目录或文件         来源：用户 `backup add` 注册
#   oneserver:self   /etc/oneserver + state + secure.conf
#
# **容器数据（`volume:` / `compose:` 之类）现在不做**，理由同 D28：现在定它的
# 接口等于对着空气设计。但**加它时不该改动本文件的骨架**，这一点已经守住：
# 保留策略、上传回读校验、清理、定时、失败计数、dry-run 全部只认
# `<type>:<name>`；归档布局 `archives/<type>/<name>/<时间戳>.tar.gz` 对新类型
# 天然成立；总览的目标一览也不写死类型，行来自磁盘目录与 resolve_targets。
# 真正要加的只有两处：`resolve_targets` 的一个 case 分支，以及采集那二十行。
#
# 目标记录是五字段（type/name/source/db/subtype）。容器数据要带的信息
# （卷清单、备份前是否停容器）塞不进这几格，到时候按需再加一格 ——
# **不预先留空字段**，那是对着空气设计的另一种形式。
#
# **「站点」不写死 wordpress**：见 `OS_DEFAULT_BACKUP_SITE_TYPES`。
#
# ## 四、远端统一交给 rclone
#
# 安装、配置和连通性验证对所有 rclone 后端都相同；为单个云厂商再包一层会
# 产生互相竞争的交互流程。无头授权只需要操作提示，统一放在 action_remote。
#
# 备份遍历 state 的命名空间，数据库转储以 OS root 走 unix_socket；定时交给
# systemd timer，全局并发由 bootstrap 的锁管理。第三方工具只经包管理器落地
# （官方 deb 也是先校验 SHA256 再交给 apt），这些边界共同避免凭据进脚本环境、
# 覆盖用户 crontab 或运行未校验安装脚本。

readonly BK_UNIT='oneserver-backup.service'
readonly BK_TIMER='oneserver-backup.timer'

# manifest 的格式版本。归档布局与 manifest 字段是**对外承诺**：
# 加字段可以，改含义要升这个数，restore 按它决定怎么读。
readonly BK_MANIFEST_SCHEMA=1

# 函数之间的返回通道（D135：脚本自己的函数也一律用变量返回）
BK_TARGETS=''
BK_ARCHIVE=''
BK_REMOTE=''
BK_REMOTE_DIR=''
BK_REMOTE_CRYPT=0
# 总览列出的目标条数。函数之间的返回通道不用 $( )：那是子 shell（D135）
BK_OVERVIEW_N=0

# ==================================================================
# 目标解析
# ==================================================================

# 目标名要能同时当目录名与 state 实例名用，所以用 state 那套实例名规则。
bk_name_valid() {
    [[ ${1-} =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# 下面三个都是给 os::ask 的 --validate 用的，**不是各写一条 `|| os::die 2`**：
# 打错一个字符就整条命令结束，前面填过的几项跟着白填。

# 去尾斜杠后为空 = 用户填的是根目录 `/`，那不是备份，是把整台机器打进包里。
bk_source_valid() {
    local p=${1-}
    [[ ${p} == /* ]] || return 1
    p=${p%/}
    [[ -n ${p} ]] || return 1
    [[ -e ${p} ]] || return 1
    return 0
}

# 远端目录去尾斜杠后必须还剩点东西：`/` 或 `///` 会让 prune_remote 的清理范围
# 变成整个远端。绝对路径与 `.` `..` 段一并拒掉。
#
# 删除本身跑不出 `<远端目录>/<类型>/<名字>/` —— 类型是代码里的字面量、名字不含
# `/`、文件名要过时间戳正则。但**备份目录自己会被挪走**：sftp / local 这类有真实
# 目录树的后端上 `..` 是真的往上跳一级，而 prune 随后就在挪过去的那个位置上删
# 时间戳名的文件；对象存储又不解释它，只当成一段古怪的 key。同一个值在两种
# 后端上是两个地方 —— 备份目的地不该是一个看后端脸色的东西。
bk_remote_dir_valid() {
    local d=${1-}
    while [[ ${d} == */ ]]; do d=${d%/}; done
    [[ -n ${d} ]] || return 1
    [[ ${d} != /* ]] || return 1
    # 前后各补一个斜杠，`.` 与 `..` 不管在头、在中间还是在尾，都归成同一种形状
    local probe="/${d}/"
    [[ ${probe} != *'/./'* && ${probe} != *'/../'* ]] || return 1
    return 0
}

# 注销时要的是「已经登记过的别名」，光有语法不够 —— 名字合法但没登记过，
# 同样该在原地重填，而不是被退出去从头再来。
bk_path_registered() {
    bk_name_valid "${1-}" || return 1
    os::state_has "backup-path:${1}"
}

# 一行一个目标，五个字段：type / name / source / db / subtype
#
# source 与 db 都可能为空（只备库的目标没有 source，静态站点没有 db），
# 采集函数按「哪个非空就采哪个」决定动作，不按类型写 case。
#
# **分隔符不能用制表符。** 制表符是 IFS 的空白字符之一，而 bash 的 read 会把
# **连续的 IFS 空白折成一个分隔符**：`db⇥manual⇥⇥manual` 读出来是
# type=db name=manual source=manual db=空 —— 空字段直接消失、后面的字段整体左移。
# 现场表现是「备份数据库时报『源路径不存在：manual』」，而代码里那个位置
# 明明传的是空串。用 US（\x1f，非空白）之后空字段照样是空字段，
# 而且它不可能出现在路径或库名里。
readonly BK_FS=$'\x1f'

# subtype 是**具体**的站点类型（wordpress …）。`type` 只到 `site` 为止，
# 而恢复时要判断「这份归档该怎么校对凭据」，靠的正是这一层 —— 不把它落进
# 归档 manifest，恢复端就只能回头猜活系统上还有没有同名组件。
bk_emit() {
    printf '%s%s%s%s%s%s%s%s%s\n' \
        "${1}" "${BK_FS}" "${2}" "${BK_FS}" "${3}" "${BK_FS}" "${4}" "${BK_FS}" "${5-}"
}

# 站点：state 里类型在白名单内、且带 `path` 键的组件（见 OS_DEFAULT_BACKUP_SITE_TYPES）
bk_sites() {
    local want=${1}
    local -a types=()
    local IFS=$', \t\n'
    read -ra types <<<"${OS_DEFAULT_BACKUP_SITE_TYPES}"
    IFS=$'\n\t'

    local type id name path db
    for type in ${types[@]+"${types[@]}"}; do
        [[ -n ${type} ]] || continue
        while IFS= read -r id; do
            [[ -n ${id} ]] || continue
            name=${id#*:}
            [[ ${want} == '*' || ${want} == "${name}" ]] || continue
            path=$(os::state_get "${id}" path)
            # 没有 path 的组件不是站点（例如将来某个只有配置的类型）
            [[ -n ${path} ]] || continue
            db=$(os::state_get "${id}" db)
            bk_emit site "${name}" "${path}" "${db}" "${type}"
        done < <(os::state_list "${type}")
    done
}

# 数据库：先看 state 里的 `db:*`（`oneserver mariadb create` 建的），
# 指名道姓要一个不在 state 里的库时，**去数据库里确认它真的存在**再收下 ——
# 手工建的库也该能备，但不能凭一个拼错的名字产生一个空归档。
bk_dbs() {
    local want=${1}
    local id name found=0
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        name=${id#*:}
        [[ ${want} == '*' || ${want} == "${name}" ]] || continue
        bk_emit db "${name}" '' "${name}" ''
        found=1
    done < <(os::state_list db)

    if [[ ${want} == '*' || ${found} -eq 1 ]]; then
        return 0
    fi
    # 不在 state 里，可能是手工建的库 —— 那也该能备，但得先确认它真的存在，
    # 否则一个拼错的库名会产生一个「成功了」的空归档
    command -v mysql >/dev/null 2>&1 || return 0
    local quoted
    quoted=$(os::sql_str "${want}")
    if os::sql_query '查询数据库是否存在' -- "SHOW DATABASES LIKE ${quoted}" \
        && [[ -n ${OS_RUN_OUTPUT} ]]; then
        bk_emit db "${want}" '' "${want}" ''
    fi
    return 0
}

# 目录 / 文件：用户注册过的。state 主键是 `backup-path:<别名>` ——
# 用 `-` 而不是第二个冒号，是因为实例名里不允许冒号（state.sh 的 ID 正则）。
bk_paths() {
    local want=${1}
    local id name src
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        name=${id#*:}
        [[ ${want} == '*' || ${want} == "${name}" ]] || continue
        src=$(os::state_get "${id}" source)
        [[ -n ${src} ]] || continue
        bk_emit path "${name}" "${src}" '' ''
    done < <(os::state_list backup-path)
}

# 把 `--target` 的值解析成目标清单，结果放 BK_TARGETS。
#
# 接受逗号分隔的多项：`site:*,db:wp_blog,oneserver:self`。
# `all` 展开成「四类全要」。
resolve_targets() {
    local spec=${1}
    local -a items=()
    local IFS=$',\n'
    read -ra items <<<"${spec}"
    IFS=$'\n\t'

    local out='' item type name chunk
    for item in ${items[@]+"${items[@]}"}; do
        item=${item// /}
        [[ -n ${item} ]] || continue
        if [[ ${item} == all ]]; then
            out+=$(bk_sites '*')$'\n'
            out+=$(bk_dbs '*')$'\n'
            out+=$(bk_paths '*')$'\n'
            out+=$(bk_emit oneserver self '' '' '')$'\n'
            continue
        fi
        if [[ ${item} != *:* ]]; then
            os::warn "目标要写成 <类型>:<名字>，收到「${item}」（可用 all）"
            return 1
        fi
        type=${item%%:*}
        name=${item#*:}
        if [[ ${name} != '*' ]] && ! bk_name_valid "${name}"; then
            os::warn "目标名只能是小写字母数字与 . _ -，收到「${name}」"
            return 1
        fi

        case ${type} in
            site) chunk=$(bk_sites "${name}") ;;
            db) chunk=$(bk_dbs "${name}") ;;
            path) chunk=$(bk_paths "${name}") ;;
            oneserver)
                if [[ ${name} != self && ${name} != '*' ]]; then
                    os::warn 'oneserver 类型只有一个目标：oneserver:self'
                    return 1
                fi
                chunk=$(bk_emit oneserver self '' '' '')
                ;;
            *)
                os::warn "未知的目标类型「${type}」，可用：site db path oneserver"
                return 1
                ;;
        esac
        if [[ -z ${chunk} ]]; then
            os::warn "没有匹配的目标：${item}"
            return 1
        fi
        out+=${chunk}$'\n'
    done

    # 去掉空行并去重（`all` 与显式项同时给时会重复）
    BK_TARGETS=$(printf '%s' "${out}" | grep -v '^[[:space:]]*$' | sort -u || true)
    [[ -n ${BK_TARGETS} ]]
}

# ==================================================================
# 采集
# ==================================================================

# manifest 是**恢复时的唯一依据**：restore 不猜文件名、不查 state、
# 不要求归档还在原来那台机器上。从别人那儿拷来一个归档也能恢复。
#
# 旧 restore.sh 的最大缺陷正是这个 —— 它得 `source secure.conf` 才知道
# 该恢复到哪个目录、哪个库，于是换台机器就用不了。
write_manifest() {
    local stage=${1} type=${2} name=${3} source=${4} db=${5} root=${6} subtype=${7-}
    local host ver created
    # 走 probe 而不是读 /etc/hostname：那个文件按约定只有一行，但真出现第二行时
    # 直接读会把两行拼成一个不存在的主机名写进 manifest，而 manifest 是恢复端的
    # 唯一依据。探测降级（超时）时值为空，manifest 的字段不留空。
    probe::hostname
    host=${OS_PROBE_VALUE:-unknown}
    ver=$(cat "${OS_VERSION_FILE}" 2>/dev/null || printf 'unknown')
    printf -v created '%(%Y-%m-%dT%H:%M:%S%z)T' -1

    {
        printf 'schema=%s\n' "${BK_MANIFEST_SCHEMA}"
        printf 'type=%s\n' "${type}"
        # 具体站点类型。恢复端靠它决定「这份归档该怎么校对凭据」——
        # 只有 type=site 这一层的话，恢复完的 wp-config 里还是备份那一刻的
        # 数据库密码，而活系统上的账号早就是另一个密码了。
        printf 'site_type=%s\n' "${subtype}"
        printf 'name=%s\n' "${name}"
        printf 'created=%s\n' "${created}"
        printf 'host=%s\n' "${host}"
        printf 'oneserver_version=%s\n' "${ver}"
        printf 'source_path=%s\n' "${source}"
        printf 'archive_root=%s\n' "${root}"
        printf 'db_name=%s\n' "${db}"
        printf 'db_charset=%s\n' "${OS_DEFAULT_DB_CHARSET}"
        printf 'has_files=%s\n' "$([[ -n ${root} ]] && printf yes || printf no)"
        printf 'has_db=%s\n' "$([[ -n ${db} ]] && printf yes || printf no)"
    } >"${stage}/manifest"
    chmod 0600 "${stage}/manifest"
}

# 落盘前先看放不放得下。
#
# 备份跑到一半把根分区撑爆，比「这次没备成」严重得多 —— 后者只是没备成，
# 前者会让站点、数据库、日志一起写不进去。按未压缩体积估，偏保守。
check_space() {
    local source=${1} db=${2}
    local -i need=0
    if [[ -n ${source} && -e ${source} ]]; then
        # 没有管道，直接走 argv——source 经参数传给 du 而不是拼进 shell 脚本
        # 文本，不管它来自 state 的 path 字段（站点 --path 只校验 `^/`）
        # 里有没有 shell 元字符都安全
        os::query --timeout 60 -- du -sk "${source}" || return 0
        local -- dksize=${OS_RUN_OUTPUT%%[[:space:]]*}
        [[ ${dksize} =~ ^[0-9]+$ ]] && need=${dksize}
    fi
    # 库的体积不该靠拍脑袋：information_schema 给的是数据加索引的实际字节，
    # 而转储通常比它小（不含索引），按它估偏保守，正合适。
    #
    # 512 MB 只在**查不到时**兜底。原来无条件按 512 MB 估，一个 5 GB 的库
    # 会让空间检查一路绿灯，然后在打包途中把分区撑爆 —— 而撑爆分区正是这个
    # 函数存在的全部理由。
    local -i db_need=0
    if [[ -n ${db} ]]; then
        local dbq
        dbq=$(os::sql_str "${db}")
        if os::sql_query '估算数据库体积' -- \
            "SELECT COALESCE(SUM(data_length + index_length) DIV 1024, 0) FROM information_schema.tables WHERE table_schema = ${dbq}" \
            && [[ ${OS_RUN_OUTPUT} =~ ^[0-9]+$ ]] && [[ ${OS_RUN_OUTPUT} -gt 0 ]]; then
            db_need=${OS_RUN_OUTPUT}
        else
            db_need=524288
        fi
        need+=${db_need}
    fi

    probe::disk_free_kb "${OS_ARCHIVE_DIR}"
    local free=${OS_PROBE_VALUE}
    [[ ${free} =~ ^[0-9]+$ ]] || return 0

    if ((free < need)); then
        os::err "磁盘空间不足：估计需要 $((need / 1024)) MB，可用 $((free / 1024)) MB"
        return 1
    fi

    # **数据库转储先落暂存目录，那可能是另一个文件系统。** 上面查的是归档目录
    # （/var/backups），而 mysqldump 的 --result-file 写在 os::tmpdir 给的目录里，
    # D244 之后它在程序目录下 —— 两处各自挂载时，归档那边绿灯不代表转储写得下。
    # 写不下时 mysqldump 报的是它自己的错，跟「备份空间不够」对不上号，而这个
    # 函数存在的全部理由就是别让人在打包途中才发现分区满了。
    #
    # **查 OS_ROOT 而不是 OS_TMP_ROOT**：后者要到 os::tmpdir 第一次跑才存在，
    # 对着不存在的路径查可用空间只会得到降级值，然后这条检查被静默跳过。
    # 它是 OS_ROOT 的子目录，同一个文件系统，查父目录等价且必然存在。
    ((db_need > 0)) || return 0
    probe::disk_free_kb "${OS_ROOT}"
    local tmpfree=${OS_PROBE_VALUE}
    [[ ${tmpfree} =~ ^[0-9]+$ ]] || return 0

    if ((tmpfree < db_need)); then
        os::err "暂存空间不足：数据库转储估计需要 $((db_need / 1024)) MB，${OS_TMP_ROOT} 所在文件系统可用 $((tmpfree / 1024)) MB"
        return 1
    fi
    return 0
}

# 做一个归档。成功时 BK_ARCHIVE 是归档路径。
#
# 归档内容（一次 tar，不套两层）：
#   manifest        恢复依据
#   database.sql    有库才有
#   <archive_root>/ 源目录，按它自己的名字放在归档根下
#
# 为什么不先 `tar` 成 site.tar 再打进 tar.gz：那样 5 GB 的站点会在临时目录里
# 先躺一份未压缩的完整副本，磁盘峰值直接翻倍，而且要压两次。
# GNU tar 的 `-C` 可以在文件操作数中间反复出现，一次调用就能把不同父目录下的
# 东西收进同一个归档。
make_archive() {
    local type=${1} name=${2} source=${3} db=${4} exclude=${5} subtype=${6-}
    local dir="${OS_ARCHIVE_DIR}/${type}/${name}"
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${dir}/${ts}.tar.gz"

    check_space "${source}" "${db}" || return 1

    os::run '创建备份目录' -- mkdir -p "${dir}"
    os::run '收紧备份目录权限' -- chmod 0700 "${dir}"

    # **先扫掉上一次留下的半成品。**
    #
    # 打包到一半被 TERM / 掉电 / OOM 打断时，`.partial` 会留在原地 ——
    # 一个 300 MB 的站点就是 300 MB，而 `backup list` 只认 `.tar.gz`，
    # 所以它是**看不见的**，攒几次就把分区撑爆，且没有任何人会想到是备份干的。
    #
    # 为什么是「下次开跑时扫」而不是在中断处理里删：D40 说中断**不执行回滚栈**，
    # 在那里删文件就是回滚。而且 SIGKILL 与掉电根本没有中断处理可言，
    # 只有「下次开跑时扫」这条路能兜住全部情况。
    #
    # 为什么可以放心删别人的 `.partial`：规范是**单一全局锁**，同一时刻只可能有
    # 一个 oneserver 进程。既然本进程持着锁，此刻存在的 `.partial` 必然是死的。
    os::run --allow-fail '清理上次遗留的半成品' -- \
        find "${dir}" -maxdepth 1 -name '*.tar.gz.partial' -delete

    local stage
    os::tmpdir stage || return 1

    # --- 库 ---
    if [[ -n ${db} ]]; then
        os::info "导出数据库 ${db}"
        # 凭据零参与：D121，OS root 走 unix_socket
        #
        # 用 `--result-file=` 而不是 `sh -c '… > 文件'`：后者要一层 shell，
        # 于是库名与路径必须拼进脚本文本。mysqldump 自己就能落盘，一层 shell
        # 都不需要 —— 每一个值都以 argv 传进去，不可能被当成 shell 语法解释。
        os::run '导出数据库' -- mysqldump --single-transaction --routines \
            --triggers --events --quick --hex-blob \
            --default-character-set="${OS_DEFAULT_DB_CHARSET}" \
            --result-file="${stage}/database.sql" "${db}" \
            || {
                os::err "数据库 ${db} 导出失败，${type}:${name} 未产生备份"
                return 1
            }
        chmod 0600 "${stage}/database.sql" 2>/dev/null || true
    fi

    # --- 文件 ---
    local -a files=()
    local root=''
    if [[ ${type} == oneserver ]]; then
        # 这三样在三个不同的父目录下，一次 `-C parent basename` 收不齐；
        # 而它们加起来只有几十 KB，先归拢到临时目录里再打包，代价可以忽略。
        # `cp -a` 保权限：secure.conf 是 0600，解出来必须还是 0600。
        root='oneserver-config'
        mkdir -p "${stage}/${root}"
        if [[ -d ${OS_ETC_DIR} ]]; then
            os::run '收集 /etc/oneserver' -- cp -a "${OS_ETC_DIR}" "${stage}/${root}/etc" || return 1
        fi
        if [[ -d ${OS_STATE_DIR} ]]; then
            os::run '收集 state' -- cp -a "${OS_STATE_DIR}" "${stage}/${root}/state" || return 1
        fi
        if [[ -f ${OS_SECURE_CONF} ]]; then
            os::run '收集凭据库' -- cp -a "${OS_SECURE_CONF}" "${stage}/${root}/secure.conf" || return 1
        fi
        files=(-C "${stage}" "${root}")
        source="${OS_ETC_DIR},${OS_STATE_DIR},${OS_SECURE_CONF}"
    elif [[ -n ${source} ]]; then
        if [[ ! -e ${source} ]]; then
            if [[ -n ${db} ]]; then
                os::warn "源路径不存在（${source}），本次只备份数据库"
            else
                os::err "源路径不存在：${source}"
                return 1
            fi
        else
            root=${source##*/}
            local parent=${source%/*}
            [[ -n ${parent} ]] || parent='/'
            files=(-C "${parent}" "${root}")
        fi
    fi

    write_manifest "${stage}" "${type}" "${name}" "${source}" "${db}" "${root}" "${subtype}"

    local -a targs=(-czf "${out}.partial" --warning=no-file-changed -C "${stage}" manifest)
    [[ -n ${db} ]] && targs+=(database.sql)
    local pat
    local -a excl=()
    if [[ -n ${exclude} ]]; then
        local IFS=$',\n'
        read -ra excl <<<"${exclude}"
        IFS=$'\n\t'
        for pat in ${excl[@]+"${excl[@]}"}; do
            [[ -n ${pat} ]] && targs+=("--exclude=${pat}")
        done
    fi
    targs+=(${files[@]+"${files[@]}"})

    os::info "打包 ${type}:${name}"
    # **tar 的退出码 1 不是失败。** 活动站点上「文件在读取过程中变了」是常态
    # （PHP 写 session、日志滚动），GNU tar 为此返回 1 并把归档正常写完。
    # 把 1 当失败，等于「越忙的站点越备不成」。只有 >=2 才是真出错。
    os::run --allow-fail '生成备份文件' -- tar "${targs[@]}"
    local -i rc=${OS_RUN_STATUS}
    if ((rc == 1)); then
        os::warn "打包期间有文件发生变化（活动站点上属正常），备份仍然可用"
    elif ((rc >= 2)); then
        os::run --allow-fail '清理未完成的备份文件' -- rm -f "${out}.partial"
        os::err "${type}:${name} 打包失败（tar 退出码 ${rc}）"
        return 1
    fi

    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        os::info "[dry-run] 会生成备份文件 ${out}"
        BK_ARCHIVE=${out}
        return 0
    fi

    # **解一遍验一遍。** 只看 tar 的退出码不够：这是备份系统里唯一能区分
    # 「以为有」和「真的有」的一步，而「真要用时发现是半个」正是备份最怕的事。
    # 代价是一次完整解压读，认这个代价。
    # os::query 本来就把 stdout 收进变量、不往屏幕上打，所以不需要
    # `sh -c '… > /dev/null'` —— 少一层 shell，路径也就不用拼进脚本文本
    os::query --timeout 3600 -- tar -tzf "${out}.partial" || {
        os::run --allow-fail '清理损坏的备份文件' -- rm -f "${out}.partial"
        os::err "${type}:${name} 的备份文件自检未通过，已删除"
        return 1
    }

    os::run '启用备份文件' -- mv -f "${out}.partial" "${out}"
    os::run '收紧备份文件权限' -- chmod 0600 "${out}"
    # `.sha256` 里存的是**相对文件名**，所以要先 cd 过去；重定向也只有 shell 能做，
    # 内层 shell 在这里省不掉。但值一律经位置参数进去，不拼进脚本文本（规范 §10）：
    # 这两个值眼下由本脚本自己构造、不含元字符，而「值恰好安全」是会在重构里
    # 静默失效的保证，结构上传不进语法的值不需要这种保证。
    #
    # 脚本文本用**双引号加反斜杠**而不是规范示例里的单引号：`$1` 写在单引号里
    # 会触发 SC2016，而消掉它要再加一条 `disable`，那个数是只降不升的棘轮。
    # `\$1` 在双引号里同样不展开，两种写法送进内层 shell 的字节一模一样 ——
    # 唯一要守的是那几个反斜杠：去掉任何一个，值就在**外层**展开了，
    # 这一句也就退回成规范禁止的那种拼接。
    os::run '生成备份文件的 SHA256 校验文件' -- sh -c \
        "cd \"\$1\" && sha256sum \"\$2\" >\"\$2.sha256\"" sh "${dir}" "${ts}.tar.gz"

    BK_ARCHIVE=${out}
    os::ok "${type}:${name} 已备份到 ${out}"
    return 0
}

# ==================================================================
# 远端
# ==================================================================

load_remote() {
    BK_REMOTE=$(os::state_get backup remote)
    BK_REMOTE_DIR=$(os::state_get backup remote_dir)
    [[ -n ${BK_REMOTE} && -n ${BK_REMOTE_DIR} ]]
}

# 目的地是不是 rclone 的 crypt remote。
#
# crypt 对本脚本完全透明（lsf/copy/cat 看到的仍是明文名字与内容），
# 所以除了这一处判断，加不加密对后面的代码没有任何影响。
detect_crypt() {
    BK_REMOTE_CRYPT=0
    os::query --timeout 30 -- rclone config show "${BK_REMOTE}" || return 0
    case ${OS_RUN_OUTPUT} in
        *"type = crypt"* | *"type=crypt"*) BK_REMOTE_CRYPT=1 ;;
    esac
    return 0
}

# 推到远端并**回读校验和比对**。
#
# 只看 `rclone copy` 的退出码不够：传了一半的文件在对端也是一个文件。
push_remote() {
    local type=${1} name=${2} file=${3}
    local base=${file##*/}
    local dest="${BK_REMOTE}:${BK_REMOTE_DIR}/${type}/${name}"

    os::run '上传备份文件' -- rclone copy "${file}" "${dest}" --stats-one-line || return 1
    os::run '上传 SHA256 校验文件' -- rclone copy "${file}.sha256" "${dest}" || return 1

    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        return 0
    fi

    os::query --timeout 300 -- rclone cat "${dest}/${base}.sha256" || return 1
    local remote_sum=${OS_RUN_OUTPUT%% *}
    # 取第一列用 shell 自己的 read，不为一个字段起一层 shell —— 路径拼进
    # `sh -c` 的脚本文本是一条不必要的注入面（同 restore.sh 的列举函数）。
    #
    # **`IFS=' '` 前缀不能省。** 本文件顶上把 IFS 设成了 $'\n\t'，里面没有空格，
    # 而 sha256sum 那行的分隔符正是两个空格 —— 不带前缀的话「哈希 + 文件名」
    # 整行都落进第一个变量，于是每次上传都判成校验和不一致，而报错里打出来的
    # 两个哈希看着一模一样（本地那个后面拖着文件名，肉眼几乎看不出来）。
    local local_sum=''
    IFS=' ' read -r local_sum _ <"${file}.sha256" 2>/dev/null || true
    [[ -n ${local_sum} ]] || return 1

    if [[ -z ${remote_sum} || ${remote_sum} != "${local_sum}" ]]; then
        os::err "远端的 SHA256 与本机不一致（远端 ${remote_sum:-空}，本机 ${local_sum}）"
        return 1
    fi
    os::ok '远端备份校验通过'
    return 0
}

# ==================================================================
# 保留策略
# ==================================================================
#
# **列不出东西时一律不删。** 这是 K6 的教训换个地方复现：「列表为空」既可能是
# 真的没有，也可能是命令失败——而按前者行事的代价是把所有备份删光。
# 宁可这次不清理。

prune_local() {
    local type=${1} name=${2} keep=${3}
    local dir="${OS_ARCHIVE_DIR}/${type}/${name}"
    # 目录名不拼进 `sh -c` 的脚本文本（同 restore.sh 的列举函数）：命令经 argv
    # 执行，形态判定在 bash 里做，排序经 os::query --stdin 从 stdin 送进 sort。
    # 「列不出东西就一律不删」这条语义不变 —— 见本节开头 K6 的教训。
    os::query --timeout 30 -- \
        find "${dir}" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' \
        || return 0
    local line filtered=''
    while IFS= read -r line; do
        [[ ${line} =~ ^[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] || continue
        filtered+="${line}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -n ${filtered} ]] || return 0
    # **喂给 `--stdin` 的文本不能自带末尾换行。** 那头是 `printf '%s\n'`，
    # 于是 filtered 结尾的换行会多出一个空行，`sort` 把空行排在最前面 ——
    # 删除循环的第一项就成了空名字，`rm -f "${dir}/"` 以退出码 1 失败，
    # 整次备份被判失败，而「删了几份」还多算了一份。
    os::query --timeout 10 --stdin "${filtered%$'\n'}" -- sort || return 0
    local list=${OS_RUN_OUTPUT}
    [[ -n ${list} ]] || return 0

    local -a all=()
    mapfile -t all <<<"${list}"
    local -i total=${#all[@]}
    ((total > keep)) || return 0

    local -i n=$((total - keep)) i
    os::record_change "删除了 ${n} 份 ${type}:${name} 的旧本机备份"
    for ((i = 0; i < n; i++)); do
        os::run '删除旧本机备份' -- rm -f "${dir}/${all[i]}" "${dir}/${all[i]}.sha256"
    done
    os::ok "${type}:${name} 已清理 ${n} 份旧本机备份"
    return 0
}

prune_remote() {
    local type=${1} name=${2} keep=${3}
    # 在真正动手删的地方再校验一次，而且用的是输入端那个函数，不是只判空：
    # 这个值来自 state，可能是更早的版本写进去的，而入口校验管不到已经落库的值
    bk_remote_dir_valid "${BK_REMOTE_DIR}" || {
        os::warn "远端目录「${BK_REMOTE_DIR:-空}」不合法，跳过远端清理（防止删到备份目录以外）"
        os::info '用「配置 rclone 远端」重设一次即可：oneserver backup remote'
        return 0
    }
    local dest="${BK_REMOTE}:${BK_REMOTE_DIR}/${type}/${name}"

    # dest 经位置参数（"$1"）传给 sh -c，不拼进脚本文本——它含 BK_REMOTE_DIR，
    # 跨越了「这次执行」的边界（写进 state，几个月后被 timer 触发的备份读到）
    # shellcheck disable=SC2016  # 理由：$1 是内层 sh 的位置参数，故意不让外层展开
    os::query --timeout 300 -- sh -c \
        'rclone lsf "$1" --files-only 2>/dev/null | grep -E "^[0-9]{8}-[0-9]{6}\.tar\.gz$" | sort' \
        _ "${dest}" \
        || {
            os::warn '取不到远端备份列表，跳过远端清理'
            return 0
        }
    local list=${OS_RUN_OUTPUT}
    [[ -n ${list} ]] || return 0

    local -a all=()
    mapfile -t all <<<"${list}"
    local -i total=${#all[@]}
    ((total > keep)) || return 0

    local -i n=$((total - keep)) i
    os::record_change "删除了 ${n} 份 ${type}:${name} 的旧远端备份"
    for ((i = 0; i < n; i++)); do
        os::run '删除旧远端备份' -- rclone deletefile "${dest}/${all[i]}"
        os::run --allow-fail '删除旧远端的 SHA256 校验文件' -- rclone deletefile "${dest}/${all[i]}.sha256"
    done
    os::ok "${type}:${name} 已清理 ${n} 份旧远端备份"
    return 0
}

# ==================================================================
# 动作
# ==================================================================

# 四类目标必须在**问之前**列出来 —— 不列的话用户只能从默认值里猜，
# 于是 db: 与 path: 这两类在界面上等于不存在。
#
# 立即备份与定时备份问的是同一件事，两处必须字字相同 —— 各写一份迟早会
# 漂移，届时其中一个菜单就在撒谎。
target_legend() {
    os::kv 'site:<名字>' '站点 —— 目录与它的数据库打进同一个包' \
        'db:<库名>' '单个数据库' \
        'path:<别名>' '用「登记要备份的目录或文件」添加的目录或文件' \
        'oneserver:self' '本工具自身 —— 配置、state 与凭据库'
    return 0
}

# 注销时先把已登记的列出来 —— 让人凭记忆敲别名，是把工具的活推给人。
# 总览的目标一览也会显示它们，但那是「备没备上」的视角，不带路径与排除模式，
# 而要判断「该注销哪一个」看的正是路径。
path_targets_show() {
    local id name src exclude
    local -i n=0
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        name=${id#*:}
        src=$(os::state_get "${id}" source)
        exclude=$(os::state_get "${id}" exclude)
        os::kv "path:${name}" "${src}${exclude:+   排除 ${exclude}}"
        n+=1
    done < <(os::state_list backup-path)
    [[ ${n} -gt 0 ]] || os::info '还没有登记任何 path 目标（用「登记要备份的目录或文件」添加）'
    return 0
}

action_run() {
    local spec='' default_spec
    default_spec=$(os::state_get backup targets "${OS_DEFAULT_BACKUP_TARGETS}")

    # 目标当场解析。放到后面再解析的话，用户要先答完保留份数与排除模式，
    # 才被告知第一个问题就填错了 —— 而且是直接退出，前面几项全白填。
    #
    # **解析结果就落在 BK_TARGETS 里，后面不再解析第二遍**：命令行给值、
    # 非交互取默认值、交互输入这三条路都会经过校验函数，没有漏网的分支。
    target_legend
    os::ask --validate resolve_targets \
        --arg target \
        '备份哪些目标？（多个用逗号分隔；把名字写成 * 表示该类全部，all 表示四类全部）' \
        spec "${default_spec}"

    local local_keep='' remote_keep='' exclude=''
    os::ask --match '^[1-9][0-9]*$' --hint '要正整数' --arg local-keep \
        '本机备份保留几份' local_keep \
        "$(os::state_get backup local_keep "${OS_DEFAULT_BACKUP_LOCAL_KEEP}")"
    os::ask --match '^[1-9][0-9]*$' --hint '要正整数' --arg remote-keep \
        '远端保留几份' remote_keep \
        "$(os::state_get backup remote_keep "${OS_DEFAULT_BACKUP_REMOTE_KEEP}")"
    os::ask --arg exclude '打包时排除的模式（逗号分隔，可留空）' exclude ''

    os::run '创建备份根目录' -- mkdir -p "${OS_ARCHIVE_DIR}"
    os::run '收紧备份根目录权限' -- chmod "${OS_BACKUP_DIR_MODE}" "${OS_BACKUP_DIR}"

    local -i has_remote=0 allow_plain=0
    if load_remote; then
        has_remote=1
        os::require_cmd rclone
        detect_crypt
        if [[ ${BK_REMOTE_CRYPT} -eq 1 ]]; then
            os::info "远端：${BK_REMOTE}:${BK_REMOTE_DIR}（rclone crypt，备份在远端是加密的）"
        else
            os::info "远端：${BK_REMOTE}:${BK_REMOTE_DIR}"
            os::warn '这个远端不是 crypt 类型，备份在对端是明文的（rclone config 里建一个 crypt remote 可以解决）'
        fi
    else
        os::info '没有配置远端（oneserver backup remote），本次只做本机备份'
    fi
    # 新名字。旧名 `--allow-plaintext-secrets` 保留一个主版本作为弃用别名
    # （§14 的兼容做法）——它描述的是「凭据」，而现在这条闸门管的是**全部**
    # 归档内容：站点包里的 wp-config.php、数据库转储里的业务数据，
    # 都不该因为名字里没有 secrets 就被当成可以明文外传的东西。
    os::flag --arg allow-plaintext-backup && allow_plain=1
    if os::flag --arg allow-plaintext-secrets; then
        allow_plain=1
        os::warn '--allow-plaintext-secrets 已更名为 --allow-plaintext-backup，旧名保留一个主版本'
    fi

    local type name source db
    local -i ok_n=0 fail_n=0 skip_n=0
    while IFS=${BK_FS} read -r type name source db subtype; do
        [[ -n ${type} ]] || continue
        os::section "备份 ${type}:${name}"

        # `oneserver:self` 里有 secure.conf —— 这台机器上所有自动生成的密码。
        # 明文推到别人家的存储上要显式点头；其余类型不拦（见下面的理由）。
        local -i sensitive=0
        [[ ${type} == oneserver ]] && sensitive=1

        if ! make_archive "${type}" "${name}" "${source}" "${db}" "${exclude}" "${subtype}"; then
            fail_n+=1
            continue
        fi
        ok_n+=1

        if [[ ${has_remote} -eq 1 ]]; then
            # 只有 `oneserver:self` 需要显式点头才明文外传 —— 它装着这台机器上
            # 全部自动生成的密码。
            #
            # **站点与数据库照常上传，这是维护者的决定。** 我一度把三类一起拦下
            # （理由是 site 包里的 wp-config.php 同样有凭据、db 是全站数据），
            # 结果是任何配了普通 rclone 远端的人，定时备份从此每轮报失败、远端
            # 一份都拿不到 —— 那不是加固，是把备份本身弄没了。不加密备份是明确
            # 的产品选择，非 crypt 远端的告警在 load_remote 里已经打过一次。
            if [[ ${sensitive} -eq 1 && ${BK_REMOTE_CRYPT} -eq 0 && ${allow_plain} -eq 0 ]]; then
                os::warn "${type}:${name} 含 secure.conf，不会上传到非加密远端；本机备份已生成"
                os::info '要么在 rclone 里建一个 crypt remote，要么显式加 --allow-plaintext-backup'
                skip_n+=1
            elif push_remote "${type}" "${name}" "${BK_ARCHIVE}"; then
                prune_remote "${type}" "${name}" "${remote_keep}"
            else
                # 远端失败不算这个目标白备了：本地那份是好的。但必须计入失败，
                # 否则定时任务天天报成功，而远端一份都没有
                os::err "${type}:${name} 上传远端失败，本机备份仍然可用：${BK_ARCHIVE}"
                fail_n+=1
            fi
        fi
        prune_local "${type}" "${name}" "${local_keep}"
        os::output_item target="${type}:${name}" archive="${BK_ARCHIVE}"
    done <<<"${BK_TARGETS}"

    local ts
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    if [[ ${fail_n} -gt 0 ]]; then
        os::state_set backup last="${ts}" last_status=fail
        os::output 1 ok="${ok_n}" failed="${fail_n}" skipped="${skip_n}"
        os::die 1 "${fail_n} 个目标没有完全成功"
    fi
    os::state_set backup last="${ts}" last_status=ok \
        local_keep="${local_keep}" remote_keep="${remote_keep}"
    os::ok "备份完成：${ok_n} 个目标"
    os::info "备份文件保存在 ${OS_ARCHIVE_DIR}/<类型>/<名字>/，每份旁边有一份同名 .sha256"
    os::info '要用它恢复：oneserver restore    ·    定期确认备份完好：oneserver backup verify'
    os::output 0 ok="${ok_n}" failed=0 skipped="${skip_n}" changed=yes
    return 0
}

# 把秒数说成人话。**给相对时间不给绝对时间**：要判断的是「离上次备份多久了」，
# 而不是让人拿着一个 ISO 时间戳去心算距今几天。
bk_ago() {
    local -i sec=${1}
    if ((sec < 3600)); then
        printf '%d 分钟前' $((sec / 60))
    elif ((sec < 86400)); then
        printf '%d 小时前' $((sec / 3600))
    else
        printf '%d 天前' $((sec / 86400))
    fi
}

# 多久没备算「已过期」。跟着定时周期走 —— 每天备的隔三天没动是事故，
# 每周备的隔三天很正常。没开定时就不判，免得凭空报警。
bk_stale_after() {
    case $(os::state_get backup schedule none) in
        daily) printf '%d' $((2 * 86400)) ;;
        weekly) printf '%d' $((14 * 86400)) ;;
        *) printf '0' ;;
    esac
}

# 总览。**一屏回答「我到底受不受保护」**，这是备份工具唯一必须答好的问题。
#
# 目标行的来源是**并集**：能发现的目标 ∪ 磁盘上有归档的目标。只看一边必漏 ——
# 只看前者会漏掉「已注销、归档还占着盘」，只看后者会漏掉「登记了但一次都没备过」，
# 而后者恰恰是最危险的那种，因为它看起来什么都没发生。
#
# 类型在这里**没有写死**：行来自 archives/<type>/<name>/ 与 resolve_targets。
# 将来加容器数据（volume: / compose: 之类）这种新目标，本函数一个字都不用改。
action_overview() {
    local sched at targets remote remote_dir last last_status local_keep remote_keep
    sched=$(os::state_get backup schedule none)
    at=$(os::state_get backup at '')
    targets=$(os::state_get backup targets "${OS_DEFAULT_BACKUP_TARGETS}")
    remote=$(os::state_get backup remote '')
    remote_dir=$(os::state_get backup remote_dir '')
    last=$(os::state_get backup last '')
    last_status=$(os::state_get backup last_status '')
    local_keep=$(os::state_get backup local_keep "${OS_DEFAULT_BACKUP_LOCAL_KEEP}")
    remote_keep=$(os::state_get backup remote_keep "${OS_DEFAULT_BACKUP_REMOTE_KEEP}")

    # --- 一、定时 ---
    os::section '定时备份'
    probe::unit_exists "${BK_TIMER}"
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::info '未开启（用「设置定时备份」开启）'
    else
        probe::timer_next "${BK_TIMER}"
        local next=${OS_PROBE_VALUE:-取不到}
        probe::unit_result "${BK_UNIT}"
        local result=${OS_PROBE_VALUE}
        local result_text='还没跑过'
        case ${result} in
            '') ;;
            success) result_text='成功' ;;
            *) result_text="失败（${result}）" ;;
        esac
        os::kv '频率' "${sched}${at:+ ${at}}" \
            '下次执行' "${next}" \
            '定时任务上次结果' "${result_text}" \
            '定时目标' "${targets}" \
            '本机保留' "每个目标 ${local_keep} 份" \
            '远端保留' "每个目标 ${remote_keep} 份"
        if [[ -n ${result} && ${result} != success ]]; then
            os::warn '上一次定时备份没有成功 —— 用「查看备份日志」看原因'
        fi
    fi
    os::kv '本工具记录的上次备份' "${last:-从未执行}${last_status:+（${last_status}）}"

    # --- 二、远端 ---
    os::section '远端'
    if [[ -z ${remote} ]]; then
        os::info '未配置，只做本机备份（用「配置 rclone 远端」添加）'
    else
        os::kv '远端' "${remote}:${remote_dir}"
        # 版本要显示出来：上传失败最常见的原因就是这台机器上的 rclone 太旧，
        # 而 rclone 自己的报错里看不出这一点（ensure_rclone 那段注释讲了现场）
        probe::component_version rclone
        if [[ -n ${OS_PROBE_VALUE} ]]; then
            os::kv 'rclone' "${OS_PROBE_VALUE}"
            detect_crypt
            if [[ ${BK_REMOTE_CRYPT} -eq 1 ]]; then
                os::kv '加密' 'rclone crypt —— 备份在对端是密文'
            else
                os::kv '加密' '无 —— 备份在对端是明文'
            fi
        fi
        os::info "对端实际有几份要联网查，总览不做：rclone lsf ${remote}:${remote_dir}"
    fi

    # --- 三、目标一览 ---
    os::section '目标'
    overview_targets "${sched}" "${targets}"

    # --- 四、容量 ---
    os::section '容量'
    os::query --timeout 60 -- du -sh "${OS_ARCHIVE_DIR}" || true
    local used=${OS_RUN_OUTPUT%%[[:space:]]*}
    probe::disk_free_kb "${OS_BACKUP_DIR}"
    os::kv '备份占用' "${used:-0}" \
        '所在分区可用' "$((${OS_PROBE_VALUE:-0} / 1048576)) GB" \
        '目录' "${OS_ARCHIVE_DIR}"

    os::output 0 count="${BK_OVERVIEW_N}"
    return 0
}

# 目标一览。拆出来只是因为 action_overview 已经够长了。
# 结果条数放 BK_OVERVIEW_N —— 不用 $( )，那是子 shell（D135）。
overview_targets() {
    local sched=${1} targets=${2}
    BK_OVERVIEW_N=0

    # 磁盘上每个目标的份数 / 最近一份的时间与大小。
    # **按目录聚合而不是按文件平铺**：平铺出来是一串文件名，回答不了
    # 「blog 这个站到底备没备上」这个唯一重要的问题。
    os::query --timeout 60 -- find "${OS_ARCHIVE_DIR}" -mindepth 3 -maxdepth 3 \
        -name '*.tar.gz' -printf '%h\t%T@\t%s\n' || true
    local rows=${OS_RUN_OUTPUT}

    local -A cnt=() newest=() nbytes=()
    local dir epoch bytes id
    while IFS=$'\t' read -r dir epoch bytes; do
        [[ -n ${dir} ]] || continue
        epoch=${epoch%%.*}
        cnt[${dir}]=$((${cnt[${dir}]:-0} + 1))
        if [[ ${epoch} -gt ${newest[${dir}]:-0} ]]; then
            newest[${dir}]=${epoch}
            nbytes[${dir}]=${bytes}
        fi
    done <<<"${rows}"

    # 定时清单里有哪些，用来标「不在定时清单里」
    local sched_ids=''
    if [[ ${sched} != none ]] && resolve_targets "${targets}"; then
        local t n r
        while IFS=${BK_FS} read -r t n r; do
            [[ -n ${t} ]] && sched_ids+="${t}:${n}"$'\n'
        done <<<"${BK_TARGETS}"
    fi

    # 并集：能发现的目标，加上只在磁盘上有归档的
    local ids=''
    if resolve_targets all; then
        local type name rest
        while IFS=${BK_FS} read -r type name rest; do
            [[ -n ${type} ]] && ids+="${type}:${name}"$'\n'
        done <<<"${BK_TARGETS}"
    fi
    # 取键要显式判空再展开。`${!cnt[@]+"${!cnt[@]}"}` 那种「空数组保护」写法
    # 在关联数组上会被 bash 当成**间接展开**：它拿数组的值去当变量名，
    # 报的是 `1 1 2: invalid variable name` —— 跟数组是空是满毫无关系。
    if [[ ${#cnt[@]} -gt 0 ]]; then
        for dir in "${!cnt[@]}"; do
            id=${dir#"${OS_ARCHIVE_DIR}/"}
            ids+="${id//\//:}"$'\n'
        done
    fi
    ids=$(printf '%s' "${ids}" | sort -u | grep -v '^[[:space:]]*$' || true)

    if [[ -z ${ids} ]]; then
        os::info '还没有任何目标'
        return 0
    fi

    local now
    printf -v now '%(%s)T' -1
    local -i stale_after
    stale_after=$(bk_stale_after)

    local ago state extra
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        BK_OVERVIEW_N=$((BK_OVERVIEW_N + 1))
        dir="${OS_ARCHIVE_DIR}/${id%%:*}/${id#*:}"
        if [[ -z ${cnt[${dir}]:-} ]]; then
            os::kv "${id}" '从未备份'
            os::output_item target="${id}" count=0 state=never
            continue
        fi
        ago=$(bk_ago $((now - newest[${dir}])))
        state='正常'
        if ((stale_after > 0 && now - newest[${dir}] > stale_after)); then
            state='已过期'
        fi
        extra=''
        [[ ${sched} != none && ${sched_ids} != *"${id}"$'\n'* ]] && extra=' · 不在定时清单里'
        os::kv "${id}" \
            "${cnt[${dir}]} 份 · 最近 ${ago} · $((nbytes[${dir}] / 1048576)) MB · ${state}${extra}"
        os::output_item target="${id}" count="${cnt[${dir}]}" \
            newest="${newest[${dir}]}" bytes="${nbytes[${dir}]}" state="${state}"
    done <<<"${ids}"

    # **「没列出来」不等于「不重要」，只等于「本工具不知道它存在」。**
    # 备份工具最危险的失败不是备份失败，是用户以为自己被保护着 —— 而手工建的库、
    # 手工放进 /var/www 的目录，这份清单一个都发现不了。说清楚它才是一份诚实的总览。
    os::info '这里只列本工具知道的东西：部署过的站点、mariadb create 建的库、登记过的 path。'
    os::info '手工建的库、手工放的目录不会自己出现 —— 用「登记要备份的目录或文件」把它们登记进来。'
    return 0
}

# 日志。**不做 tail -f** —— 理由同 caddy-manager：实时跟踪跟命令式工具不搭，
# 要跟就把命令打给用户自己敲。
#
# 两份日志都要给：手动跑的进 backup.log，定时跑的那次在 journal 里。
# 只看其中一份，恰好会漏掉「凌晨四点那次为什么没成」这个最常问的问题。
action_log() {
    local lines=''
    os::ask --match '^[1-9][0-9]*$' --hint '要正整数' --arg lines '显示最近多少行' lines '50'

    local f="${OS_LOG_DIR}/backup.log"
    os::section "手动执行的日志（最近 ${lines} 行）"
    if [[ -r ${f} ]]; then
        os::query --timeout 20 -- tail -n "${lines}" "${f}" || true
        os::info "${OS_RUN_OUTPUT}"
        os::info "文件：${f}"
    else
        os::info "还没有 ${f}"
    fi

    os::section "定时执行的日志（最近 ${lines} 行）"
    os::query --timeout 20 -- journalctl -u "${BK_UNIT}" --no-pager -n "${lines}" || true
    os::info "${OS_RUN_OUTPUT:-（没有记录，可能从未定时执行过）}"
    os::info "要实时跟踪：journalctl -u ${BK_UNIT} -f"
    os::output 0 lines="${lines}"
    return 0
}

# 校验本机备份。
#
# **归档只在上传那一刻被校验过一次**，此后躺在盘上再没人看它一眼。
# bit rot、磁盘故障、被误删一半 —— 等真要恢复才发现就已经晚了。
# 这是唯一能在「需要它之前」发现归档已经坏掉的手段。
action_verify() {
    os::query --timeout 60 -- find "${OS_ARCHIVE_DIR}" -mindepth 3 -maxdepth 3 \
        -name '*.tar.gz' || true
    local archives=${OS_RUN_OUTPUT}
    if [[ -z ${archives} ]]; then
        os::info '没有任何本机备份'
        os::output 0 checked=0 bad=0
        return 0
    fi

    local -i total=0
    total=$(printf '%s\n' "${archives}" | grep -c . || true)

    os::section '校验本机备份'
    local -i checked=0 bad=0 nosum=0
    local f want got
    while IFS= read -r f; do
        [[ -n ${f} ]] || continue
        if [[ ! -r ${f}.sha256 ]]; then
            os::warn "缺 SHA256 校验文件：${f#"${OS_ARCHIVE_DIR}/"}"
            nosum+=1
            continue
        fi
        checked+=1
        # 直接比哈希，不 `cd` 也不起内层 shell（同 restore.sh 的 verify_archive）。
        # 「.sha256 里存的是相对文件名」原本是 cd 的理由，而只取第一列就不需要
        # 它了 —— 顺带消掉「把路径拼进 `sh -c` 脚本文本」这条注入面。
        # `IFS=' '` 前缀的理由同 push_remote：文件级 IFS 里没有空格。
        want=''
        IFS=' ' read -r want _ <"${f}.sha256" 2>/dev/null || true
        got=''
        if os::query --timeout 300 -- sha256sum -- "${f}"; then
            got=${OS_RUN_OUTPUT%% *}
        fi
        if [[ -n ${want} && ${want} == "${got}" ]]; then
            os::debug "校验通过：${f}"
        else
            os::err "校验不通过：${f#"${OS_ARCHIVE_DIR}/"}"
            bad+=1
        fi
        os::progress "$((checked + nosum))" "${total}" '校验中'
    done <<<"${archives}"

    os::kv '已校验' "${checked} 份" '不通过' "${bad} 份" '缺校验文件' "${nosum} 份"
    if [[ ${bad} -gt 0 ]]; then
        os::output 1 checked="${checked}" bad="${bad}" nosum="${nosum}"
        os::die 1 "${bad} 份备份校验不通过，它们已经不可靠了"
    fi
    os::ok "全部 ${checked} 份备份校验通过"
    os::output 0 checked="${checked}" bad=0 nosum="${nosum}"
    return 0
}

# 注册一个目录/文件目标。**这是 path 类型存在的全部理由**：
# 定时任务不能每次问用户要路径，路径必须先被记下来。
action_add() {
    local name='' src='' exclude=''
    os::ask --validate bk_name_valid --hint '只能是小写字母数字与 . _ -' \
        --arg name '给这个 path 目标起个别名（以后用 path:<别名> 引用它）' name
    os::ask --validate bk_source_valid \
        --hint '要绝对路径、不能是根目录 /、且必须已经存在' \
        --arg source '要备份的目录或文件' src
    src=${src%/}
    os::ask --arg exclude '排除的模式（逗号分隔，可留空）' exclude ''

    os::state_set "backup-path:${name}" source="${src}" exclude="${exclude}"
    os::kv '别名' "${name}" '路径' "${src}" '排除' "${exclude:-（无）}"
    os::ok "已注册备份目标 path:${name}"
    os::info "现在可以：oneserver backup run --target=path:${name}"
    os::info "要让它进定时备份，把 path:${name} 加进 oneserver backup schedule --targets=..."
    os::output 0 target="path:${name}" source="${src}" changed=yes
    return 0
}

# 注销一个 path 目标。**已有归档不删** —— 注销的是「以后还备不备」，
# 不是「过去备的还要不要」。真要删归档，那是另一件事，用户自己动手最安全。
action_remove() {
    local name=''
    if [[ -z $(os::state_list backup-path) ]]; then
        os::die 3 '还没有登记任何 path 目标，没有可注销的'
    fi
    os::section '已登记的 path 目标'
    path_targets_show
    os::ask --validate bk_path_registered --hint '要是上面列出的别名之一' \
        --arg name '要注销哪个（只影响 path:<别名>，站点与数据库不在此列）' name

    if ! os::confirm --arg confirm-remove "注销 path:${name}？（已有备份不会删除）" n; then
        os::info '已取消'
        os::output 0 changed=no
        return 0
    fi
    os::state_del "backup-path:${name}"
    os::ok "已注销 path:${name}"
    os::info "它的备份还在：${OS_ARCHIVE_DIR}/path/${name}"
    os::output 0 changed=yes
    return 0
}

# rclone 装**官方最新版**，不用发行版源里那份（D238）。
#
# 源里那份太旧是实打实的故障，不是版本洁癖：rclone 的后端与配置格式跟着上游
# 走，而人配远端的常规做法是「在自己电脑上跑 rclone config 完成 OAuth 授权，
# 再把 rclone.conf 拷到服务器」—— 电脑上是当年的版本，服务器上是发行版停在
# 一两年前的那份，认不出配置里的后端或选项。现场表现是备份跑到上传那一步失败，
# 而屏幕上只有一句 rclone 的报错，没人会想到是版本差。
#
# 官方**没有 apt 源**，只发 .deb 和同目录的 SHA256SUMS —— 正好是规范给第三方
# 软件留的那条路（校验 SHA256），不必碰 `curl | bash` 的官方安装脚本。
# 包名仍是 `rclone`，dpkg 把发行版那份当升级覆盖掉，不需要 divert。
#
# **取不到官方版时不回落发行版源**：回落等于装上一个已知会失败的版本，
# 然后在几天后那次没人看着的定时备份里再失败一次。机器上已经有 rclone 就
# 沿用它并说清，一个都没有就当场失败。
readonly BK_RCLONE_DL='https://downloads.rclone.org'

ensure_rclone() {
    os::pkg_install ca-certificates curl
    os::require_cmd curl sha256sum

    probe::component_version rclone
    local current=${OS_PROBE_VALUE}

    # 版本号出自 version.txt（内容形如 "rclone v1.75.0"），不问 GitHub API：
    # 下载、校验和版本号出自同一个域名，否则会撞上「GitHub 已经打了 tag、
    # downloads 上还没有那个目录」的窗口期，表现是下载 404
    os::query --timeout 20 -- curl -fsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 "${BK_RCLONE_DL}/version.txt" || true
    local latest=''
    [[ ${OS_RUN_OUTPUT} =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && latest=${BASH_REMATCH[1]}

    if [[ -z ${latest} ]]; then
        [[ -n ${current} ]] || os::die 1 '取不到 rclone 官方版本号，且这台机器上没有 rclone'
        os::warn "取不到 rclone 官方版本号，继续用现有的 ${current}"
        return 0
    fi
    # 判据是「不低于」而不是「不等于」：用等号的话，手工装过 beta 或 rc 的机器
    # 每次都要重装一遍，而 apt 面对一个更低的版本什么都不做 —— 于是装完复验必然
    # 失败，一条来配远端的命令就此走不通。比较交给 dpkg，不自己拆点分段。
    if [[ -n ${current} ]] \
        && os::query --timeout 10 -- dpkg --compare-versions "${current}" ge "${latest}"; then
        os::ok "rclone ${current} 不低于官方最新版 ${latest}"
        return 0
    fi

    # 架构不认就不装，但**已有 rclone 时不当失败**：这条命令是来配远端的，
    # 不是来装 rclone 的，为一个跑得动的旧版本拦住整件事说不过去
    probe::arch
    local arch=''
    case ${OS_PROBE_VALUE} in
        x86_64) arch='amd64' ;;
        aarch64 | arm64) arch='arm64' ;;
        *)
            [[ -n ${current} ]] || os::die 4 "不支持的架构：${OS_PROBE_VALUE}（官方 deb 只取 amd64 / arm64）"
            os::warn "架构 ${OS_PROBE_VALUE} 没有对应的官方 deb，继续用现有的 rclone ${current}"
            return 0
            ;;
    esac

    local dir
    os::tmpdir dir || os::die 1 '创建临时目录失败'
    local name="rclone-v${latest}-linux-${arch}.deb"

    os::info "rclone 官方最新版 ${latest}（当前 ${current:-未安装}）"
    local -i failed=0
    os::retry 3 '下载 rclone 官方 deb' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 \
        -o "${dir}/${name}" "${BK_RCLONE_DL}/v${latest}/${name}" || failed=1
    if [[ ${failed} -eq 0 ]]; then
        os::retry 3 '下载 rclone 的 SHA256 清单' -- \
            curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 \
            -o "${dir}/SHA256SUMS" "${BK_RCLONE_DL}/v${latest}/SHA256SUMS" || failed=1
    fi
    if [[ ${failed} -eq 1 ]]; then
        [[ -n ${current} ]] || os::die 1 "下载 rclone ${latest} 失败，且这台机器上没有 rclone"
        os::warn "下载 rclone ${latest} 失败，继续用现有的 ${current}"
        return 0
    fi

    # 下载是副作用，dry-run 下没真跑，临时目录里是空的。诚实地停在这里
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 校验与安装无法预演：它们要的是真实下载到的文件'
        return 0
    fi

    # **不用 `sha256sum -c`**：官方那份 SHA256SUMS 是 PGP clearsign 的，前后各有
    # 一段 armor 行，`-c` 会判成格式错误并整份失败 —— 于是每次都「校验不过」。
    # 只取自己这一行来比。签名本身不验：仓库里没有 rclone 的公钥，而规范对第三方
    # 软件要的是 SHA256（它给的是完整性，不是真实性 —— 摘要和文件走同一条 TLS）。
    local want='' line
    while IFS= read -r line; do
        [[ ${line} == *"  ${name}" ]] || continue
        want=${line%% *}
        break
    done <"${dir}/SHA256SUMS"
    want=${want,,}

    os::query --timeout 120 -- sha256sum "${dir}/${name}" || os::die 1 '算不出 rclone deb 的 SHA256'
    local got=${OS_RUN_OUTPUT%% *}
    got=${got,,}
    if [[ -z ${want} || ${want} != "${got}" ]]; then
        os::debug "期望 ${want:-空}，实际 ${got}"
        os::die 1 'rclone deb 未通过 SHA256 校验，已丢弃（不会改用没有校验的来源）'
    fi
    os::ok "SHA256 校验通过（${got:0:16}…）"

    os::pkg_install_deb "${dir}/${name}" || os::die 1 "安装 rclone ${latest} 失败"

    # 复验的是 `rclone version` 而不是 apt 的退出码：这个函数存在的全部意义就是
    # 版本，「装完了」与「装完之后跑起来的确实是这个版本」必须分得开 ——
    # 不验的话，下一次失败会推迟到几天后那次没人看着的定时备份
    probe::component_version rclone
    [[ ${OS_PROBE_VALUE} == "${latest}" ]] \
        || os::die 1 "rclone 装完后版本仍是 ${OS_PROBE_VALUE:-空}，期望 ${latest}"
    os::ok "rclone 已装到 ${latest}${current:+（原 ${current}）}"
    return 0
}

# 配置 rclone 远端。**不代跑 `rclone config`** —— 那是一个自带交互界面的程序，
# 包进来只会两套交互打架（同 D149）。这里做的是「在已有的 remote 里挑一个」。
action_remote() {
    ensure_rclone
    os::require_cmd rclone

    os::query --timeout 30 -- rclone listremotes || true
    local remotes=${OS_RUN_OUTPUT}
    if [[ -z ${remotes} ]]; then
        os::warn '这台机器上还没有任何 rclone remote'
        os::info '在这台机器上建：rclone config    （OneDrive / S3 / B2 / WebDAV / Google Drive 都在里面）'
        os::info '服务器没有浏览器时：在自己电脑上装 rclone，跑 rclone config 完成授权，'
        os::info '  再把 rclone config file 指出的那份文件内容复制到服务器的 ~/.config/rclone/rclone.conf'
        os::info '想让备份在对端是加密的：再建一个 type=crypt 的 remote 包住前一个，这里选它'
        os::info '建好之后再跑一次：oneserver backup remote'
        os::die 3 '没有可用的 rclone remote'
    fi

    local -a names=()
    local r
    local IFS=$'\n'
    for r in ${remotes}; do
        [[ -n ${r} ]] || continue
        names+=("${r%:}")
    done
    IFS=$'\n\t'

    # 只有一个 remote 时也走 select：它天然只收清单里的值，填错原地重问。
    # 用 os::ask 的话就得在事后自己比对一遍，而那正是「答完才告诉你错了」。
    local chosen=''
    os::select --arg remote '选一个 rclone remote' chosen "${names[@]}"

    # 去掉尾斜杠后不能为空 —— 空目录会让清理逻辑指向整个远端
    local rdir=''
    os::ask --validate bk_remote_dir_valid \
        --hint '相对远端根的路径：不能为空、不能以 / 开头，也不能含 . 或 .. 段' \
        --arg remote-dir '远端目录' rdir 'oneserver/backups'
    while [[ ${rdir} == */ ]]; do rdir=${rdir%/}; done

    # 先验证真的连得上再落 state：不验的话，配错的 remote 要等到第一次定时备份
    # （可能是明天凌晨四点）才暴露，而那时没人看着
    os::query --timeout 60 -- rclone lsd "${chosen}:" \
        || os::die 1 "remote ${chosen} 连不上，配置未保存"

    os::state_set backup remote="${chosen}" remote_dir="${rdir}"
    BK_REMOTE=${chosen}
    detect_crypt
    os::kv 'remote' "${chosen}" '远端目录' "${rdir}" \
        '加密' "$([[ ${BK_REMOTE_CRYPT} -eq 1 ]] && printf '是（rclone crypt）' || printf '否（对端是明文）')"
    [[ ${BK_REMOTE_CRYPT} -eq 1 ]] \
        || os::warn '备份在对端是明文。里面有数据库转储与站点配置，建议改用 type=crypt 的 remote'
    os::ok '远端配置已保存'
    os::output 0 remote="${chosen}" remote_dir="${rdir}" crypt="${BK_REMOTE_CRYPT}" changed=yes
    return 0
}

# 定时：**systemd timer，不碰 crontab**（K6）
action_schedule() {
    local freq=''
    os::select --arg frequency '备份频率' freq 'daily=每天' 'weekly=每周'

    local at=''
    os::ask --match '^([01][0-9]|2[0-3]):[0-5][0-9]$' --hint '形如 04:00' --arg at '执行时间 HH:MM（本机时区）' at '04:00'

    local weekday=''
    os::ask --match '^[0-6]$' --hint '0-6' --arg weekday '每周几执行（0=周日 … 6=周六；仅选择“每周”时使用）' weekday '0'

    # 当场解析：配错的目标要在这里报，不要等到凌晨四点没人看着的时候
    local targets=''
    target_legend
    os::ask --validate resolve_targets --arg targets \
        '定时备份哪些目标？（多个用逗号分隔；把名字写成 * 表示该类全部，all 表示四类全部）' targets \
        "$(os::state_get backup targets "${OS_DEFAULT_BACKUP_TARGETS}")"

    # 定时任务不该暗中继承「上次手动备份」的保留数。在设置定时时显式确认，
    # 后续 timer 调用 backup run --non-interactive 时就从 state 取这两个值。
    local local_keep='' remote_keep=''
    os::ask --match '^[1-9][0-9]*$' --hint '要正整数' --arg local-keep \
        '每个目标的本机备份保留几份' local_keep \
        "$(os::state_get backup local_keep "${OS_DEFAULT_BACKUP_LOCAL_KEEP}")"
    os::ask --match '^[1-9][0-9]*$' --hint '要正整数' --arg remote-keep \
        '每个目标的远端备份保留几份' remote_keep \
        "$(os::state_get backup remote_keep "${OS_DEFAULT_BACKUP_REMOTE_KEEP}")"

    local oncal
    if [[ ${freq} == weekly ]]; then
        local -a dows=(Sun Mon Tue Wed Thu Fri Sat)
        oncal="${dows[weekday]} *-*-* ${at}:00"
    else
        oncal="*-*-* ${at}:00"
    fi

    local dir
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    os::install_template "${OS_UNIT_SRC_DIR}/${BK_TIMER}" "${dir}/${BK_TIMER}" \
        "ONCALENDAR=${oncal}" || os::die 1 '渲染 timer 失败'

    os::systemd_install "${OS_UNIT_SRC_DIR}/${BK_UNIT}" own || os::die 1 '安装 service 失败'
    os::systemd_install "${dir}/${BK_TIMER}" own || os::die 1 '安装 timer 失败'
    os::systemd_enable "${BK_TIMER}" --now own

    # unit 归属自己登记（D69：systemd.sh 不写 state，把动过的 unit 攒起来给调用方取）。
    # 用 os::state_unit_add 而不是 os::state_resource_add —— 后者不收 `unit` 类型。
    local u
    while IFS= read -r u; do
        [[ -n ${u} ]] && os::state_unit_add backup "${u}"
    done < <(os::systemd_touched)

    os::state_set backup schedule="${freq}" at="${at}" oncalendar="${oncal}" targets="${targets}" \
        local_keep="${local_keep}" remote_keep="${remote_keep}"
    os::kv '频率' "${freq}" '时间' "${at}" 'OnCalendar' "${oncal}" '目标' "${targets}" \
        '本机保留' "每个目标 ${local_keep} 份" '远端保留' "每个目标 ${remote_keep} 份" \
        '查看下次执行' 'systemctl list-timers oneserver-backup.timer'
    os::ok '定时备份已启用'
    os::output 0 frequency="${freq}" at="${at}" targets="${targets}" \
        local_keep="${local_keep}" remote_keep="${remote_keep}" changed=yes
    return 0
}

action_unschedule() {
    probe::unit_exists "${BK_TIMER}"
    [[ ${OS_PROBE_VALUE} == yes ]] || {
        os::info '本来就没有定时备份'
        os::output 0 changed=no
        return 0
    }

    if ! os::destroy_confirm --arg confirm-unschedule 'backup' -- \
        "定时器 ${BK_TIMER}" "服务 ${BK_UNIT}" '（已有的备份文件不会动）'; then
        os::info '已取消'
        os::output 0 changed=no
        return 0
    fi

    os::systemd_disable "${BK_TIMER}"
    os::systemd_remove "own:${BK_TIMER}"
    os::systemd_remove "own:${BK_UNIT}"
    os::state_set backup schedule=none
    os::ok '定时备份已停用'
    os::output 0 changed=yes
    return 0
}

# ==================================================================

main() {
    os::require_cmd tar gzip sha256sum find

    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_overview --arg action '操作' dispatch \
        'run=立即备份' 'log=查看备份日志' 'verify=校验本机备份' \
        'add=登记要备份的目录或文件' 'remove=取消目录或文件的备份登记' 'remote=配置 rclone 远端' \
        'schedule=设置定时备份' 'unschedule=取消定时备份'
}

dispatch() {
    case ${1} in
        overview) action_overview ;;
        run) action_run ;;
        log) action_log ;;
        verify) action_verify ;;
        add) action_add ;;
        remove) action_remove ;;
        remote) action_remote ;;
        schedule) action_schedule ;;
        unschedule) action_unschedule ;;
        *) os::die 2 "未知操作「${1}」，可用：overview run log verify add remove remote schedule unschedule" ;;
    esac
}

main "$@"
