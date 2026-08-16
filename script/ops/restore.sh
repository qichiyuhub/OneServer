#!/bin/bash
#
# 从备份归档恢复
#
# @command      restore
# @name         恢复管理
# @group        backup
# @order        20
# @privilege    root
# @requires_lib >= 4.3
# @args         [--from=<local|remote|external>] [--target=<类型:名字>] [--into=<类型:名字>] [--file=<备份文件名>] [--mode=<all|db|files>] [--only=<备份内相对路径>] [--source=<路径[,路径]>] [--subdir=<来源内相对路径>] [--site-url=<地址>] [--strip-db-statements=<y|n>] [--confirm-restore=<类型:名字>]
# @description  从本机、远端或外部备份恢复，覆盖前自动留副本
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
# ## 一、恢复的依据是归档里的 manifest，不是 secure.conf，也不是文件名
#
# 旧脚本第一件事是 `source "$SECURE_CONF"` 取 `DB_NAME` / `DB_USER` / `DB_PASS`，
# 也就是说：**归档本身不知道自己是什么**，得靠这台机器上恰好还在的一份配置
# 才解释得了。于是换一台机器就用不了 —— 而「换一台机器」正是要恢复的场合。
#
# 现在每个归档根下有一个 `manifest`（`backup.sh` 写的），里面有类型、名字、
# 源路径、库名、归档内的根目录名。**restore 只读它**：从别人那儿拷来一个归档，
# 在一台干净机器上照样恢复得了。
#
# ## 二、K4 —— 全项目最严重的一条，在这里消失
#
# 旧脚本用 `eval` 拼 `sed` 去改 wp-config.php 里的密码：
#
#     run_command "sudo sed -i \"s/...'${db_pass_esc}'.../\" '$wp_config_path'"
#     ...
#     if eval "$command_str"; then
#
# 密码先明文进日志文件，再经 `eval` 进 shell —— 一个含 `$(...)` 的密码
# 就是 **root RCE**。而这一整段的目的是「让恢复出来的 wp-config 匹配当前环境」。
#
# **那个目的本身是对的，错的是实现方式。** 归档里的 wp-config.php 存的是
# 备份那一刻的数据库密码，而恢复只重建库里的数据 —— MySQL 账号的密码用的
# 还是活系统上那个。两边对不上，恢复完站点就连不上库，现场表现是白屏。
# 所以 `fixup_credentials` 仍然要改那几行，只是换了做法：
#
#   * 走 `os::replace_line`（同目录临时文件 + `mv` 换 inode），**没有 `eval`、
#     没有 `sed -i`**，密码不进 shell 命令行、不参与任何字符串求值。
#   * 密码经 `os::secure_load` 取出，**脱敏在读出来那一刻就登记了**，
#     此后它进不了日志、进不了 dry-run 预览。
#   * 只改 DB 那四行与缓存密码一行；盐不动 —— 盐只影响登录 cookie，
#     保留归档里的反而让已登录用户不掉线。
#
# 本机没有这份凭据时（换机器恢复）**不猜、不改**，原样保留并说清怎么办。
#
# ## 三、K8 的最后一处 —— 失败必须看得见
#
# 旧脚本的 `run_command` 把 stdout 与 stderr 整体重定向进日志文件，
# 失败时终端上只有一句「命令失败」，真正的错误躺在日志里。
# 现在错误一律经 `os::err` 走 stderr，调用栈才进日志。
#
# ## 四、覆盖之前一律先落副本
#
# 同 D140：人是会打对全名然后后悔的。
#   库   —— 先 mysqldump 一份到 $OS_BACKUP_DIR/pre-restore/
#   目录 —— 先整个 mv 到 $OS_BACKUP_DIR/pre-restore/，不是删
# **副本失败就中止**，不给「备份没成也照样覆盖」的可能。
#
# ## 五、`oneserver:self` 只解出来，不自动覆盖
#
# 它装的是 `/etc/oneserver` + state + secure.conf —— 而这三样正是**当前这个
# 进程正在使用**的东西。在自己运行的时候替换自己的 state 与凭据库，
# 是 K13 那一类问题（覆盖运行中的文件）。所以这里只解压到一个目录、
# 把清单打出来，由人对照着合并。这不是偷懒，是这件事本来就该有人看着。
#
# ## 六、外部导入（`--from=external`）为什么也在这个文件里
#
# 别处（宝塔、cPanel、另一台主机、手工 mysqldump）来的备份过不了上面三道门：
# 没有 `.sha256`、没有 `manifest`、更没有 schema 版本。但它要做的事
# **与恢复一字不差** —— 覆盖一个库、替换一个目录、校对 wp-config 里的凭据。
#
# 单独写一个 `import.sh` 意味着把 `snapshot_db` / `restore_db` /
# `stash_current` / `fixup_credentials` 复制一份 —— 而脚本之间不能互相 source
# （不变量 2），复制是唯一的实现方式。**这四个函数是全项目破坏力最大的地方，
# 不能有第二份。** 把它们提到 `lib/` 也不对：`lib/` 不该知道 WordPress 是什么。
#
# 所以外部导入是 `--from` 的第三个取值，与 local / remote 并列。两条路各有各的
# 前段（一条选归档校验读 manifest，一条选来源审查清单），**写入动作全部落回
# 同一批函数**。
#
# 三道门在这条路上换成了另外四条：来源由人当场指定而不是从远端列表里挑出来的、
# 解包前审查完整清单、解包只落 staging 不碰落点、覆盖前照旧强制留副本。
# 剩下的可信性由使用者负责，这句话会打进确认清单里。
#
# ## 七、归档说得出「它是什么」，说不出「该往哪写」
#
# manifest 里的 `db_name` 与 `source_path` 是**备份那一刻源机器上的事实**，
# 不是这台机器上的落点。同名回滚时两者恰好重合，于是很容易把它们当成同一件事
# —— 换台机器恢复、或者站点换过名字时，照 manifest 写的下场是：凭空建出一个
# 归档里那个名字的库、把文件铺到归档里那个路径，而本机真正在跑的那个站纹丝不动。
# 每一步都会报成功。
#
# 所以落点先按归档类型规划：站点只能落到本机 state 中完整成立的站点；
# 数据库可覆盖现有库，或按归档原名通过 `oneserver mariadb create` 创建后恢复；
# 路径可落回 manifest 的原路径，或本机已登记的备份路径。其他显式 `--into`
# 仍经 `ex_resolve_dest` 用同一套 `site:`/`db:`/`path:` 标识解析。这样恢复站点不会
# 凭归档猜本机配置，纯数据库与纯路径归档也不再被 WordPress 的落点模型绑死。
#
# ## 八、恢复出来的配置一律以活系统为准
#
# 范围比密码大：wp-config 里的库名、账号、密码、主机，以及缓存的主机、端口、
# 密码、前缀，**每一项在新机器上都可能与归档里那份不同**。
# 「归档里的数据 + 本机的配置」才是一个能跑起来的站点，两边混着来的都不是。
#
# 因此对齐配置是恢复的**必经步骤**，不是「取得到就顺手改一下」：凭据取不到就
# 在动手之前停（`fixup_credentials --check`），已经写完了才发现改不了的话，
# 用户看到的是「恢复成功」加一句警告，而站点是坏的。

readonly RS_PRE_DIR="${OS_BACKUP_DIR}/pre-restore"

# 函数之间的返回通道（D135）
RS_ENTRIES=''
RS_ARCHIVE=''
RS_MF_TYPE=''
RS_MF_NAME=''
RS_MF_SOURCE=''
RS_MF_ROOT=''
RS_MF_DB=''
RS_MF_CREATED=''
RS_MF_HOST=''
# 具体站点类型（wordpress …）。恢复后要不要校对凭据、怎么校对，全看它
RS_MF_SITE_TYPE=''
# 只有真正留下了恢复前副本才为 1。用它控制结束提示，避免新建空库
# 的恢复也声称 pre-restore 里有旧数据。
RS_PRE_CREATED=0

RS_REMOTE=''
RS_REMOTE_DIR=''

# 落点与来源，同样是函数之间的返回通道。
#
# **落点这四个变量两条路共用**（见文件头第七点）：它们记的是「本机这次要往哪写」，
# 由落点规划或 `ex_resolve_dest` 填充，记的始终是本机真正要写入的位置。
# 名字保留 EX_ 前缀是因为通用解析函数在外部导入那一段，换前缀要动的调用点
# 远多于它带来的清晰度。
EX_DEST_DIR=''
EX_DEST_DB=''
# 落点是站点时才非空：具体站点类型与 state 实例名，决定要不要校对凭据
EX_SITE_TYPE=''
EX_SITE_NAME=''
# 落点的标识原文（`site:blog` 这种）。归档那条路要拿它当不可逆确认串 ——
# 让人照着打的必须是**将被覆盖的那个东西**的名字，不是归档自称的名字
EX_DEST_SPEC=''
# 数据库归档按原名恢复、而本机还没有这个库时为 1。真正创建推迟到不可逆确认
# 之后，并调用 `oneserver mariadb create`，不在恢复脚本里复制账号与凭据逻辑。
RS_DEST_DB_CREATE=0
EX_SRC_FILES=''
EX_SRC_SQL=''
# tar | zip | dir | file
EX_KIND=''
# 来源内的站点根（相对路径，无首尾斜杠）。空 = 整个来源就是根
EX_ROOT=''
EX_MEMBERS=''
EX_SIZE_KB=0
EX_SQL_HITS=''
EX_SQL_CHARSET=''
EX_STRIP=0

# ==================================================================
# manifest 字段校验 —— manifest 来自归档，归档可能来自别的机器或远端对象存储
# ==================================================================
#
# SHA256 只证明「归档没在传输中被改」，不证明「归档的作者是谁」（verify_archive
# 头注释与规范 §13 都点出了这一点）。一个被攻破的备份桶就能塞进一份 manifest
# 字段被动过手脚的归档，而 db_name / source_path / archive_root 这三个字段
# 此前直接决定了「以 root 身份执行什么」与「往哪个路径解包/覆盖」——
# 相当于把 shell 命令的一部分交给了归档的作者。

# valid_db_name <值>   与 db_manager.sh 的 valid_name 同一条规则：
# 只收小写字母数字下划线短横、以字母数字开头。任何引号/分号/管道/反引号
# 都落在这条规则之外，db_name 一旦通过校验就不可能再拼出一段新命令。
valid_db_name() {
    [[ ${1} =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# valid_archive_root <值>   归档内的顶层目录名，只收单段路径
valid_archive_root() {
    [[ -n ${1} && ${1} != '.' && ${1} != '..' && ${1} != */* && ${1} =~ ^[A-Za-z0-9._-]+$ ]]
}

# valid_source_path <值>   本机要写入/挪走的绝对路径
#
# 白名单挡不住：站点目录允许自定义 --path（deploy_wordpress 只校验 `^/`），
# 合法值本来就可以是任意绝对路径。改用黑名单挡系统关键目录 —— 挡不住
# 全部攻击面，但「把 /etc/ssh 整个挪到 pre-restore 再用归档内容覆盖」
# 这类现实场景能被拦下。
valid_source_path() {
    local p=${1}
    [[ ${p} == /* ]] || return 1

    # **字面黑名单看不见符号链接。** `/var/www/mysite` 过检，而 `/var/www` 若是
    # 指向 `/etc` 的链接，`tar -C "${parent}"` 就写进了 /etc —— 判据必须建立在
    # 解析后的真实路径上，不是用户/manifest 给的那串字符。
    #
    # 两步都要：
    #   1. 逐级 lstat，**任意一级祖先是符号链接就拒绝**。只查最后一段不够，
    #      也不能只查直接父目录。
    #   2. 拿 `realpath -m` 归一化（-m 容许尾段还不存在——恢复到一台干净机器上
    #      时落点本来就不存在）再比黑名单。
    local cur='' seg
    local IFS='/'
    for seg in ${p}; do
        [[ -n ${seg} ]] || continue
        cur="${cur}/${seg}"
        # 尚不存在的层级没有链接可言，到此为止
        [[ -e ${cur} || -L ${cur} ]] || break
        [[ ! -L ${cur} ]] || return 1
    done
    unset IFS

    local real=''
    real=$(realpath -m -- "${p}" 2>/dev/null) || return 1
    [[ -n ${real} && ${real} == /* ]] || return 1
    [[ ${real} != *'/../'* && ${real} != *'/..' ]] || return 1

    local bad
    for bad in /etc /usr /bin /sbin /lib /lib64 /boot /root /run /sys /proc /dev /var/lib "${OS_ROOT}"; do
        [[ ${real} == "${bad}" || ${real} == "${bad}/"* ]] && return 1
    done
    # 根目录本身也不是合法落点
    [[ ${real} != '/' ]] || return 1
    return 0
}

# rs_within <根> <路径>   路径解析后是否落在根之内（根自身算在内）
#
# 给 stash_current 与 `--only` 用。**完整恢复允许两者相等**（挪走的就是那个根），
# 部分恢复才要求严格位于其下 —— 一刀切成「必须严格在根之下」会把正常的完整
# 恢复直接打挂。
rs_within() {
    local root=${1} p=${2} rroot='' rp=''
    rroot=$(realpath -m -- "${root}" 2>/dev/null) || return 1
    rp=$(realpath -m -- "${p}" 2>/dev/null) || return 1
    [[ ${rp} == "${rroot}" || ${rp} == "${rroot}/"* ]]
}

# ==================================================================
# 找归档
# ==================================================================

load_remote() {
    RS_REMOTE=$(os::state_get backup remote)
    RS_REMOTE_DIR=$(os::state_get backup remote_dir)
    [[ -n ${RS_REMOTE} && -n ${RS_REMOTE_DIR} ]]
}

# 本地有哪些「类型:名字」，一行一个
# **值不拼进 `sh -c` 的脚本文本。** 这四个列举函数原来都是
# `sh -c "… '${值}' … | grep | sort"`，而其中两个的值来自远端目录名 ——
# 一个名为 `x'; <命令>; :'` 的远端目录能闭合那对单引号，于是「谁能往备份桶里
# 写东西」就等于「谁能在恢复机上以 root 执行命令」。§10 禁 eval 是同一条思路，
# 只是 `sh -c` 绕开了那条静态检查。
#
# 改法不是加转义，是让内层 shell 根本不存在：命令经 os::query 的 argv 直接执行，
# 过滤与去重在 bash 里做，排序经 `os::query --stdin` 把数据从 stdin 送进 sort。
#
# **喂给 `--stdin` 的文本一律去掉末尾换行**（下面四处都是 `${out%$'\n'}`）：
# 那头是 `printf '%s\n'`，自带换行的话 sort 会多读到一个空行。升序时它排在
# 最前面，于是选择列表的第一项是个空白选项；降序时它落在末尾、恰好被
# `$( )` 的尾换行剥除而看不出来 —— 后者只是碰巧不发作，不是没这个问题。
# backup.sh 的 prune_local 是同一个坑发作的样子：删除循环拿到空文件名。
local_targets() {
    os::query --timeout 30 -- \
        find "${OS_ARCHIVE_DIR}" -mindepth 3 -maxdepth 3 -name '*.tar.gz' -printf '%h\n' \
        || return 1
    local line out=''
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        line=${line#"${OS_ARCHIVE_DIR}/"}
        out+="${line/\//:}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -n ${out} ]] || return 1
    os::query --timeout 10 --stdin "${out%$'\n'}" -- sort -u || return 1
    RS_ENTRIES=${OS_RUN_OUTPUT}
    [[ -n ${RS_ENTRIES} ]]
}

remote_targets() {
    load_remote || return 1
    os::require_cmd rclone
    os::query --timeout 300 -- \
        rclone lsf "${RS_REMOTE}:${RS_REMOTE_DIR}" --dirs-only -R --max-depth 2 \
        || return 1
    local line out=''
    while IFS= read -r line; do
        line=${line%/}
        # 只要「类型/名字」这一层，类型那一层自己不是目标
        [[ ${line} == */* ]] || continue
        out+="${line/\//:}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -n ${out} ]] || return 1
    os::query --timeout 10 --stdin "${out%$'\n'}" -- sort || return 1
    RS_ENTRIES=${OS_RUN_OUTPUT}
    [[ -n ${RS_ENTRIES} ]]
}

# 某个目标下有哪些归档，新的在前
local_archives() {
    local type=${1} name=${2}
    os::query --timeout 30 -- \
        find "${OS_ARCHIVE_DIR}/${type}/${name}" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' \
        || return 1
    local line out=''
    while IFS= read -r line; do
        # 文件名形态在 bash 里判，不外包给 grep —— 判据与 backup 侧的命名规则同源
        [[ ${line} =~ ^[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] || continue
        out+="${line}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -n ${out} ]] || return 1
    os::query --timeout 10 --stdin "${out%$'\n'}" -- sort -r || return 1
    RS_ENTRIES=${OS_RUN_OUTPUT}
    [[ -n ${RS_ENTRIES} ]]
}

# 一份归档在选择列表里显示成什么样：`<时间戳>.tar.gz   YYYY-MM-DD HH:MM · 26 MB`
#
# 远端的大小要联网一份份问，太慢，所以只从文件名还原时间 —— 文件名本身就是
# 时间戳，这不是猜测。
archive_desc() {
    local from=${1} type=${2} name=${3} file=${4}
    local stamp=${file%.tar.gz}
    local when="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}"
    if [[ ${from} != local ]]; then
        printf '%s' "${when}"
        return 0
    fi
    local f="${OS_ARCHIVE_DIR}/${type}/${name}/${file}"
    os::query --timeout 10 -- stat -c '%s' "${f}" || {
        printf '%s' "${when}"
        return 0
    }
    printf '%s · %s MB' "${when}" "$((OS_RUN_OUTPUT / 1048576))"
}

remote_archives() {
    local type=${1} name=${2}
    os::query --timeout 300 -- \
        rclone lsf "${RS_REMOTE}:${RS_REMOTE_DIR}/${type}/${name}" --files-only \
        || return 1
    local line out=''
    while IFS= read -r line; do
        [[ ${line} =~ ^[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] || continue
        out+="${line}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -n ${out} ]] || return 1
    os::query --timeout 10 --stdin "${out%$'\n'}" -- sort -r || return 1
    RS_ENTRIES=${OS_RUN_OUTPUT}
    [[ -n ${RS_ENTRIES} ]]
}

# ==================================================================
# 取回并校验
# ==================================================================

# **校验不通过就一个字节都不解。** 一个损坏或被改过的归档解到站点目录上，
# 造成的破坏比「这次恢复不了」大得多。
verify_archive() {
    local file=${1}
    if [[ ! -f ${file}.sha256 ]]; then
        os::err "缺少校验文件：${file}.sha256"
        os::info '本工具生成的备份文件旁边一定有一份同名 .sha256，从别处拷过来时要两个文件一起拷。'
        os::info '如果这本来就是别处（宝塔 / cPanel / 手工打包）来的备份，那条路是：'
        os::info '  oneserver restore --from=external'
        return 1
    fi
    # 两条都没有管道，直接走 argv——file 经参数传给 awk/sha256sum 而不是拼进
    # shell 脚本文本，不管它由 --file= 拼出的内容里有没有 shell 元字符都安全
    os::query --timeout 3600 -- awk "{print \$1}" "${file}.sha256" || return 1
    local expected=${OS_RUN_OUTPUT}
    os::query --timeout 3600 -- sha256sum "${file}" || return 1
    local actual=${OS_RUN_OUTPUT%%[[:space:]]*}
    if [[ -z ${expected} || ${expected} != "${actual}" ]]; then
        os::err "校验失败：备份已损坏或被改动（期望 ${expected:-空}，实得 ${actual}）"
        return 1
    fi
    os::ok '备份校验通过'
    return 0
}

# 把选中的归档准备到本地，路径放 RS_ARCHIVE
fetch_archive() {
    local from=${1} type=${2} name=${3} file=${4}
    if [[ ${from} == local ]]; then
        RS_ARCHIVE="${OS_ARCHIVE_DIR}/${type}/${name}/${file}"
        [[ -f ${RS_ARCHIVE} ]] || {
            os::err "本机没有这份备份：${RS_ARCHIVE}"
            return 1
        }
        return 0
    fi

    local dir src
    os::tmpdir dir || return 1
    src="${RS_REMOTE}:${RS_REMOTE_DIR}/${type}/${name}"
    os::info "从远端下载 ${file}"
    os::query --timeout 3600 -- rclone copy "${src}/${file}" "${dir}" || return 1
    os::query --timeout 300 -- rclone copy "${src}/${file}.sha256" "${dir}" || return 1
    RS_ARCHIVE="${dir}/${file}"
    [[ -f ${RS_ARCHIVE} ]] || {
        os::err '下载完成但文件不在，远端可能被改动过'
        return 1
    }
    return 0
}

# 只解 manifest 一个文件出来读。
#
# 归档可能有好几个 G，为了知道「这是什么」而整份解开是不必要的；
# 而且**在用户确认之前不该往磁盘上铺任何东西**。
read_manifest() {
    local file=${1}
    local dir
    os::tmpdir dir || return 1
    os::query --timeout 300 -- tar -xzf "${file}" -C "${dir}" manifest || {
        os::err '备份中没有信息文件 manifest —— 它不是 oneserver 生成的备份，或者版本太老'
        return 1
    }
    [[ -f ${dir}/manifest ]] || {
        os::err '备份中没有信息文件 manifest'
        return 1
    }

    local k v schema=''
    RS_MF_TYPE='' RS_MF_NAME='' RS_MF_SOURCE='' RS_MF_ROOT=''
    RS_MF_DB='' RS_MF_CREATED='' RS_MF_HOST='' RS_MF_SITE_TYPE=''
    while IFS='=' read -r k v; do
        case ${k} in
            schema) schema=${v} ;;
            type) RS_MF_TYPE=${v} ;;
            name) RS_MF_NAME=${v} ;;
            source_path) RS_MF_SOURCE=${v} ;;
            archive_root) RS_MF_ROOT=${v} ;;
            db_name) RS_MF_DB=${v} ;;
            created) RS_MF_CREATED=${v} ;;
            host) RS_MF_HOST=${v} ;;
            site_type) RS_MF_SITE_TYPE=${v} ;;
        esac
    done <"${dir}/manifest"

    # 版本比自己新的 manifest **拒绝处理**：字段含义可能已经变了，
    # 按旧理解去恢复比不恢复危险
    if [[ ${schema} =~ ^[0-9]+$ ]] && ((schema > 1)); then
        os::err "这份备份的 manifest 版本是 ${schema}，本机的 restore 只认到 1 —— 请先更新 oneserver"
        return 1
    fi
    [[ -n ${RS_MF_TYPE} ]] || {
        os::err 'manifest 里没有类型字段，备份信息不完整'
        return 1
    }

    # 三个字段此前直接拼进 shell 命令/路径操作：db_name 决定
    # mysqldump/mysql 命令行的一部分，source_path 决定 mv/tar 解到哪，
    # archive_root 决定归档内解哪个顶层目录。归档来自别的机器或远端对象
    # 存储，SHA256 只保证没被传输改动，不保证内容可信——一份被动过手脚的
    # manifest 不该有能力执行任意命令或覆盖 /etc 之类的系统目录。
    if [[ -n ${RS_MF_DB} ]] && ! valid_db_name "${RS_MF_DB}"; then
        os::err "manifest 里的 db_name「${RS_MF_DB}」不是合法的数据库名，拒绝处理（备份可能被篡改）"
        return 1
    fi
    if [[ -n ${RS_MF_ROOT} ]] && ! valid_archive_root "${RS_MF_ROOT}"; then
        os::err "manifest 里的 archive_root「${RS_MF_ROOT}」不是合法的单段目录名，拒绝处理（备份可能被篡改）"
        return 1
    fi
    if [[ -n ${RS_MF_SOURCE} ]] && ! valid_source_path "${RS_MF_SOURCE}"; then
        os::err "manifest 里的 source_path「${RS_MF_SOURCE}」不是可接受的路径（相对路径、路径穿越或系统目录），拒绝处理（备份可能被篡改）"
        return 1
    fi
    return 0
}

# ==================================================================
# 恢复
# ==================================================================

# 覆盖之前落副本。**副本失败就中止**（D140）。
snapshot_db() {
    local db=${1}
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${RS_PRE_DIR}/${db}-${ts}.sql.gz"
    os::run '创建恢复前副本目录' -- mkdir -p "${RS_PRE_DIR}"
    os::run '收紧恢复前副本目录权限' -- chmod 0700 "${RS_PRE_DIR}"
    os::info "先把当前的 ${db} 备一份"
    # 凭据零参与：D121，OS root 走 unix_socket
    # db/charset/out 经位置参数（"$1"/"$2"/"$3"）传给内层 shell，不拼进脚本文本——
    # read_manifest 已经把 db 校验成 [a-z0-9_-]，这里再加一层：不管校验是否
    # 有漏网之鱼，值都不会被当成 shell 语法解释。
    #
    # 用 bash -c 而不是 sh -c，理由与 restore_db 完全相同：sh 在 Debian 上是
    # dash，没有 pipefail，于是 mysqldump 失败时退出码取自管道末端的 gzip ——
    # 恒为 0。现场是「恢复前副本：…」照常打印，而那份 .sql.gz 里是空的，
    # 紧接着 restore_db 就在这个假象上把现有的库 DROP 掉。**这一步的全部意义
    # 就是留退路，它报成功而实际没留，比不备份更危险。**
    # shellcheck disable=SC2016  # 理由：$1/$2/$3 是内层 bash 的位置参数，故意不让外层展开
    os::run '备份恢复前的数据库' -- bash -c \
        'set -o pipefail; mysqldump --single-transaction --routines --triggers --events --quick --hex-blob --default-character-set="$1" "$2" | gzip > "$3"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${db}" "${out}" \
        || {
            os::err "当前数据库备份失败，恢复中止（不在没有退路的情况下覆盖数据）"
            return 1
        }
    RS_PRE_CREATED=1
    os::ok "恢复前副本：${out}"
    return 0
}

# stash_current <当前路径> <副本名>   把将被覆盖的东西整个挪走，不是删（D140）
#
# 归档恢复与外部导入共用。**这是文件侧唯一的「让现有内容消失」的地方**，
# 只有一份，出错时人只要去 pre-restore 里找就行，不必先判断是哪条路径干的。
# stash_current <要挪走的路径> <副本名> [允许的根]
#
# 给了第三个参数就断言路径确实落在那个根之内。**这是最后一道闸**：`--only`
# 的子路径由用户给、归档成员名由归档给，两者拼出来的 live 路径若能穿出站点
# 目录，这里 `mv` 走的就是攻击者点名的那个系统路径。
stash_current() {
    local live=${1} label=${2} root=${3-}
    if [[ -n ${root} ]] && ! rs_within "${root}" "${live}"; then
        os::err "拒绝挪走 ${live}：它不在 ${root} 之内"
        return 1
    fi
    os::run '创建恢复前副本目录' -- mkdir -p "${RS_PRE_DIR}"
    os::run '收紧恢复前副本目录权限' -- chmod 0700 "${RS_PRE_DIR}"
    [[ -e ${live} ]] || return 0
    os::run '移走当前内容作为恢复前副本' -- mv "${live}" "${RS_PRE_DIR}/${label}" || return 1
    RS_PRE_CREATED=1
    os::ok "恢复前副本：${RS_PRE_DIR}/${label}"
    return 0
}

# rs_audit_tree <目录> [会不会整体改权限]   解包**之后**在文件系统上审查这棵树
#
# **它只剥特权位，其余一律告警不拒绝。** 维护者定的硬要求是「以前能恢复的
# 归档现在必须还能恢复」，所以这里不做否决 —— 剥 setuid/setgid 是唯一的例外，
# 因为它不会让任何一次合法恢复失败，而留着它就是一条现成的提权。
# 真正挡住「写到站点目录外面」的是路径包含判定（valid_source_path / rs_within
# / stash_current 的断言），那几条同样不会让合法归档失败。
#
# **不解析 `tar -tvf` 的文本。** 那是给人看的格式：文件名可以含空格、换行、
# 甚至 ` -> `，而 ex_read_members 正是按「前五列之后是名字」再剥 ` -> ` 取的名 ——
# 一个名字里带 ` -> ` 的成员会被截短，审计看到的是截短后那个安全的名字，
# tar 解出来的却是完整的那个。判据必须建立在**解包后的真实 inode** 上：
# 类型、链接数、权限位、链接目标，全都是内核说了算，不是文本说了算。
#
# 这条路上的归档与 external 那条同样不可信：`verify_archive` 校验的 `.sha256`
# 与归档来自同一个远端（文件头第一节已经写明这一点），能改归档的人同样能改
# 那个哈希。所以「本工具生成的归档」不是信任的理由。
# 第二个参数是**「这棵树随后会不会被整体改权限」**，不是落点类型 —— 判据就是
# 这个：会改的话硬链接才有害。self 与外部导入随后也各有一次递归 chown。
rs_audit_tree() {
    local root=${1} will_chown=${2-no}

    # 1) 特殊文件（设备节点、FIFO、socket）：**告警，不拒绝**。
    #    以 root 解包时它们会被真的创建出来，值得说一声；但它们落在站点目录
    #    之内，而「以前能恢复的归档现在必须还能恢复」是维护者定的硬要求。
    os::query --timeout 600 -- \
        find "${root}" ! -type f ! -type d ! -type l -print || return 1
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        os::warn '备份中含设备节点/FIFO/socket 这类特殊文件，已按原样恢复：'
        os::info "${OS_RUN_OUTPUT}"
    fi

    # 2) 硬链接。**只对随后要跑递归 chmod/chown 的落点拒绝**（站点），
    #    其余类型只告警。
    #
    #    判据是「这棵树接下来会不会被整体改权限」：会的话，一个硬链接意味着
    #    改这个名字的权限就改了另一个名字的，而另一个名字可能是用户的资产；
    #    不会的话，归档内部两个成员指向同一 inode 是**合法且常见**的
    #    （Maildir、去重过的目录、构建产物），一律拒绝会把正常备份挡在门外。
    #    tar 不会把硬链接指到解包根之外，所以「链到树外」这条不成立。
    os::query --timeout 600 -- find "${root}" -type f -links +1 -print || return 1
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        if [[ ${will_chown} == yes ]]; then
            os::warn '备份中含硬链接，而这棵树落地时要整体改权限——改一个名字的权限会带到另一个名字上：'
        else
            os::warn '备份中含硬链接，已按原样保留：'
        fi
        os::info "${OS_RUN_OUTPUT}"
    fi

    # 3) setuid / setgid。**只管普通文件**：目录上的 sticky 与 setgid 是合法用法
    #    （共享目录靠它继承属组），一刀切会把正常备份挡在门外。
    #    普通文件上的特权位一律剥掉而不是拒绝：站点里偶尔有第三方带进来的东西，
    #    剥掉它不影响站点跑，而放进去就是一条 root 提权。
    os::query --timeout 600 -- find "${root}" -type f -perm /6000 -print || return 1
    if [[ -n ${OS_RUN_OUTPUT} ]]; then
        os::warn '备份中有带 setuid/setgid 位的文件，已剥掉那些位：'
        os::info "${OS_RUN_OUTPUT}"
        os::run '剥掉特权位' -- find "${root}" -type f -perm /6000 -exec chmod a-s -- {} + || return 1
    fi

    # 4) 越界符号链接。站点内部的相对链接是合法的，指向树外的不是 ——
    #    后者会让随后的 chown -R / 站点访问穿到树外去。
    os::query --timeout 600 -- find "${root}" -type l -print || return 1
    local link='' escaped=''
    while IFS= read -r link; do
        [[ -n ${link} ]] || continue
        rs_within "${root}" "$(realpath -m -- "${link}" 2>/dev/null)" && continue
        escaped+="${link}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    if [[ -n ${escaped} ]]; then
        # 同样只告警。递归 chown/chmod 默认不跟随符号链接，所以这些链接不会
        # 让权限变更穿到树外；真正跟随它们的是随后访问站点的那个进程，
        # 那是站点内容的事，不该由恢复命令替用户否决。
        os::warn '备份中有指向树外的符号链接，已按原样恢复：'
        os::info "${escaped}"
    fi

    return 0
}

# rs_safe_extract <归档> <归档内顶层目录> <落点父目录> <site_type> <输出变量>
#
# 解到**落点旁边的隔离目录**（0700），审查通过之后再由调用方整个改名过去。
#
# 隔离目录放落点旁边而不是 os::tmpdir：后者在 /run 上，那是内存——一个几 GB
# 的站点归档会把机器的内存吃光。同一个文件系统还让最后那一步是 rename 而不是
# 跨设备复制。**代价是恢复期间落点所在文件系统要能同时放下新旧两份**，
# 空间不够时 tar 在这里失败，而此刻现有内容还一个字节都没动。
#
# **属主与权限的处理按落点类型分档**：
#
#   wordpress  `--no-same-owner --no-same-permissions`，随后由 rs_normalize_owner
#              按 deploy_wordpress 那套定死。站点的属主模型由本工具定义，
#              归档里记的是源机的数字 uid，本机同号用户可能是另一个人。
#   其他类型   **忠实还原归档记的属主与权限**。`path:` 目标是用户用
#              `backup add` 注册的任意目录（证书、密钥、数据目录），
#              「原样恢复」正是备份的意义 —— 拿站点的模型去套它，
#              一次恢复就会把 0600 的私钥变成 0644 的 www-data 文件。
#
# 两条路都跑 rs_audit_tree：安全控制是审计（特殊文件、越界链接、特权位），
# 不是抹掉属主。抹属主既挡不住已经被审计拦下的东西，又会毁掉合法数据。
#
# **本函数的局部变量一律带 `__rs_` 前缀**（同 install_caddy 的 `__cd_`、
# db_manager 的 `__db_`）。回写走的是 `printf -v "${出参名}"`，而 `local` 在
# bash 里是动态作用域：局部变量与出参同名时，写进去的是自己这个副本，
# 函数一返回就没了 —— 调用方拿到空串，而且**没有任何报错**。
# 这里踩过的形态是调用方写 `local stage=''; rs_safe_extract … stage`：
# 隔离目录建了、归档解了，回到调用方 `${stage}` 仍是空，于是下一步
# `chown -R -- "${stage}/${root}"` 作用在 `/test` 上，报「No such file」。
rs_safe_extract() {
    local __rs_archive=${1} __rs_root=${2} __rs_parent=${3} __rs_type=${4} __rs_out=${5}
    local __rs_stage=''
    __rs_stage=$(mktemp -d "${__rs_parent}/.oneserver-restore.XXXXXXXX") || {
        os::err "无法在 ${__rs_parent} 下创建隔离目录"
        return 1
    }
    chmod 0700 "${__rs_stage}" 2>/dev/null || true
    # 先登记再解 —— 解到一半失败时隔离目录里已经有半棵树了。
    # **成功路径由调用方显式清理**：os::defer 只在失败时回放。
    os::defer rm -rf -- "${__rs_stage}"

    # 有属主模型的类型才抹属主；也只有它们随后会被整体改权限
    local -a __rs_tar_opts=()
    local __rs_will_chown='no'
    if [[ ${__rs_type} == wordpress ]]; then
        __rs_tar_opts=(--no-same-owner --no-same-permissions)
        __rs_will_chown='yes'
    fi
    if ! os::run '解出备份到隔离目录' -- \
        tar -xzf "${__rs_archive}" ${__rs_tar_opts[@]+"${__rs_tar_opts[@]}"} -C "${__rs_stage}" "${__rs_root}"; then
        # 空间不足是这一步最常见的失败，而 tar 的报错指向的是文件不是磁盘。
        # 把可用空间说出来，省掉一轮「为什么解不开」的排查
        probe::disk_free_kb "${__rs_parent}"
        [[ -z ${OS_PROBE_VALUE} ]] \
            || os::info "${__rs_parent} 所在文件系统可用 $((OS_PROBE_VALUE / 1024)) MB —— 恢复期间需要同时放下新旧两份"
        return 1
    fi
    rs_audit_tree "${__rs_stage}" "${__rs_will_chown}" || return 1

    printf -v "${__rs_out}" '%s' "${__rs_stage}"
    return 0
}

# rs_stage_valid <隔离目录>   取回来的路径必须真的是个目录，否则立刻停
#
# 隔离目录是靠出参回写拿到的，而回写失败是**静默**的（变量同名、将来有人
# 在中途 `return` 之前忘了写）。拿到空串之后，后面每一步都会把 `${stage}/…`
# 当成绝对路径用：`chown -R -- /test`、`mv -T -- /test /var/www/test` ——
# 目标机上恰好有那个目录时，这条路径会改掉甚至挪走一棵与恢复毫无关系的树。
# 一次判空把这条路径整个堵死，代价是一行。
rs_stage_valid() {
    [[ -n ${1} && -d ${1} ]] && return 0
    os::err '隔离目录没有取回来，已中止恢复（现有内容一个字节都没动）'
    return 1
}

# rs_drop_stage <隔离目录>   成功路径上收掉它
#
# os::defer 只在**失败**时回放（errors.sh 明写），所以成功之后没有任何人删它。
# 不加这一步的现场是：每成功恢复一次，站点父目录里多一个空的
# `.oneserver-restore.XXXXXXXX` —— 正是 os::tmpdir 注释里点名的那类
# 「清理代码看上去一直在跑」。
rs_drop_stage() {
    local stage=${1}
    [[ -n ${stage} && -d ${stage} ]] || return 0
    os::run --allow-fail '清理隔离目录' -- rm -rf -- "${stage}" || true
    return 0
}

# rs_normalize_owner <目录> <self|站点类型>   属主与权限按落点类型定
#
# **只有本工具定义过属主模型的类型才动它。** `path:` 目标是用户注册的任意
# 目录，它的属主与权限就是备份的内容本身；把站点那套 www-data + 0755/0644
# 套上去，恢复 /etc/letsencrypt 会把私钥从 0600 变成 0644 —— 那不是加固，
# 是数据损坏。将来加 deploy_static / deploy_laravel 时在这里加分支即可，
# 与 fixup_credentials 用的是同一条判据（site_type）。
rs_normalize_owner() {
    local dir=${1} kind=${2}
    if [[ ${kind} == self ]]; then
        os::run '把解出的配置归还 root' -- chown -R root:root -- "${dir}" || return 1
        return 0
    fi
    if [[ ${kind} != wordpress ]]; then
        os::debug "恢复目标类型 ${kind:-未声明} 没有属主模型，按备份记录保留属主与权限"
        return 0
    fi
    # 站点：与 deploy_wordpress 落地时同一套
    os::run '设置站点属主' -- chown -R www-data:www-data -- "${dir}" || return 1
    os::run '设置目录权限' -- find "${dir}" -type d -exec chmod 0755 -- {} + || return 1
    os::run '设置文件权限' -- \
        find "${dir}" -type f -not -name wp-config.php -exec chmod 0644 -- {} + || return 1
    if [[ -d "${dir}/wp-content" ]]; then
        os::run --allow-fail '放宽 wp-content 目录权限' -- \
            find "${dir}/wp-content" -type d -exec chmod 0775 -- {} + || true
        os::run --allow-fail '放宽 wp-content 文件权限' -- \
            find "${dir}/wp-content" -type f -exec chmod 0664 -- {} + || true
    fi
    [[ ! -f "${dir}/wp-config.php" ]] \
        || os::run '收紧 wp-config.php 权限' -- chmod 0640 -- "${dir}/wp-config.php" || return 1
    return 0
}

# restore_db <库名> <sql 文件> [剥离库级语句] [目标库是本次刚创建的]
#
# sql 文件可以是 `.sql` 或 `.sql.gz`；第三个参数为 1 时把 `USE` /
# `CREATE DATABASE` / `DROP DATABASE` 三类语句在管道里注释掉（外来 dump 才需要，
# 判断在 sql_scan，**用户的原文件一个字节不动**）。
restore_db() {
    local db=${1} sqlfile=${2} strip=${3:-0} fresh=${4:-0}
    # 刚通过数据库管理创建出来的是空库，没有旧数据需要留副本；其余覆盖仍严格
    # 执行 D140，快照失败就不碰目标库。
    [[ ${fresh} -eq 1 ]] || snapshot_db "${db}" || return 1

    local ident
    ident=$(os::sql_ident "${db}")
    os::sql_exec '重建目标数据库' -- \
        "DROP DATABASE IF EXISTS ${ident}; CREATE DATABASE ${ident} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE};" \
        || return 1
    # 同 snapshot_db：位置参数传值，不拼进脚本文本。
    #
    # 用 bash -c 而不是 sh -c，是为了 `set -o pipefail`：sh 在 Debian 上是 dash，
    # 没有这个选项，于是解压中途失败时 mysql 照样以 0 退出 —— 现场是
    # 「导入成功了，但库里只有半份数据」，比直接失败危险得多。
    # shellcheck disable=SC2016  # 理由：$1..$4 是内层 bash 的位置参数，故意不让外层展开
    os::run '导入数据库转储' -- bash -c \
        'set -o pipefail; case "$3" in *.gz) gunzip -c -- "$3" ;; *) cat -- "$3" ;; esac | if [ "$4" = 1 ]; then sed -E "s@^(USE[[:space:]]|CREATE[[:space:]]+DATABASE|DROP[[:space:]]+DATABASE)@-- oneserver-import: \1@"; else cat; fi | mysql --default-character-set="$1" "$2"' \
        _ "${OS_DEFAULT_DB_CHARSET}" "${db}" "${sqlfile}" "${strip}" \
        || {
            if [[ ${fresh} -eq 1 ]]; then
                os::err '导入失败。新建的恢复目标可能只含部分数据，将通过失败回滚撤销'
            else
                os::err "导入失败。当前库已被清空，用上面那份恢复前副本可以回到原状"
            fi
            return 1
        }
    os::ok "数据库 ${db} 已恢复"
    return 0
}

# fixup_credentials [--check] <站点类型> <实例名> [站点目录]   把恢复出来的配置对齐到活系统
#
# **这是「恢复完站点反而挂了」的唯一成因。**
#
# 归档里的 wp-config.php 存的是**备份那一刻源机器上**的配置，而恢复只重建了库
# 里的数据 —— MySQL 账号的密码用的还是活系统上那个。两边对不上，站点连不上库。
# 缓存同理，而且更隐蔽：连不上时每个请求都要等一次连接超时，表现是「能打开但
# 慢得没法用」，比白屏难查得多。
#
# **以活系统为准，不是以归档为准**（文件头第八点）。MySQL 里的账号、凭据库里的
# 密码、本机装没装 Valkey 都是活的，归档里那份是历史快照。让配置去迁就活系统，
# 而不是把活账号的密码改回历史值 —— 后者等于拿备份里的明文密码去覆盖现有账号。
#
# 校对范围是**整套连接参数**，不只是密码：库名与账号在换名恢复时会变（`--into`），
# 缓存的主机、端口、前缀在换机器时会变。前缀尤其不能漏 —— deploy 写进去的是
# `<站点名>:`，两个站点共用一个 Valkey 而前缀相同，缓存键会互相覆盖，
# 表现是「另一个站点的内容串到这个站点上」。
#
# 数据库那四行**必须存在**，缺一行就是硬失败：一份没有 DB_NAME 的 wp-config
# 本来就跑不起来，这时报成功等于把问题往后推。缓存那几行相反，归档里没有就
# 不加（见 fixup_cache）—— 没配过缓存的站点不该因为一次恢复就凭空多出缓存配置。
#
# 盐**不动**：它只影响登录 cookie，保留归档里的反而让已登录用户不掉线。
#
# `--check` 只判断「本机有没有对齐所需的凭据」，不碰任何文件。**它必须在动手
# 之前跑**：这个判断在读完 manifest 那一刻就已经成立，而写入之后才发现的话，
# 库已经建好、文件已经就位，用户看到的是「恢复成功」加一行警告，而站点是坏的。
fixup_credentials() {
    local check=0
    if [[ ${1-} == --check ]]; then
        check=1
        shift
    fi
    local site_type=${1} name=${2} source=${3-}
    [[ ${site_type} == wordpress ]] || return 0

    local id="wordpress:${name}"
    # 与 deploy_wordpress.sh 用同一条规则算 key（§11：命名空间由框架统一
    # 生成，脚本不能各拼各的——两处算法不一样，恢复时就永远读不到密码）
    local secret_key
    secret_key="$(os::secure_ns "${id}").db_pass"
    local db db_user db_host pass=''
    db=$(os::state_get "${id}" db)
    db_user=$(os::state_get "${id}" db_user)
    db_host=$(os::state_get "${id}" db_host localhost)

    # 本机没有这份凭据 = 落点站不是本工具部署的，或者凭据库丢了。
    # **这时不能继续**：改不了配置就只剩「归档里的历史配置 + 本机的库」这种
    # 半套组合，站点起不来，而前面每一步都会报成功。
    if [[ -z ${db} || -z ${db_user} ]] || ! os::secure_load "${secret_key}" pass; then
        os::err "本机凭据库里没有 ${id} 的数据库账号或密码，无法把配置对齐到这台机器"
        os::info '先跑 oneserver deploy wordpress 部署好这个站，再恢复；'
        os::info '或者用 --into=site:<本机已有的站点> 指定恢复目标'
        return 1
    fi
    [[ ${check} -eq 0 ]] || return 0

    local conf="${source}/wp-config.php"
    if [[ ! -f ${conf} ]]; then
        os::err "恢复出来的站点里没有 wp-config.php：${conf}"
        os::info "备份中本来就不含它。恢复前副本在 ${RS_PRE_DIR}"
        return 1
    fi

    os::section '校对站点配置里的凭据'
    os::record_change "改写 ${conf} 里的数据库与缓存凭据"
    # **每个值都过 os::php_str。** wp-config.php 是 PHP 源码，这几行写的是
    # 单引号字符串字面量；模板渲染与逐行替换都不认目标语言、不会自动转义。
    # 部署路径一直是转义的，恢复路径从前一个字都没转 —— 同一个文件、同一条
    # 威胁（含 `'` 的密码破坏语法让站点白屏，构造过的值落成可执行 PHP），
    # 两条写入路径只有一条设防。db/db_user 经 manifest 校验、db_host 来自
    # state，照样一起转：判据是「值要放进 PHP 字符串」，不是「这个值可信吗」。
    os::replace_line --backup "${conf}" "^define\( *'DB_NAME'" \
        "define( 'DB_NAME', '$(os::php_str "${db}")' );" || return 1
    os::replace_line "${conf}" "^define\( *'DB_USER'" \
        "define( 'DB_USER', '$(os::php_str "${db_user}")' );" || return 1
    os::replace_line "${conf}" "^define\( *'DB_PASSWORD'" \
        "define( 'DB_PASSWORD', '$(os::php_str "${pass}")' );" || return 1
    os::replace_line "${conf}" "^define\( *'DB_HOST'" \
        "define( 'DB_HOST', '$(os::php_str "${db_host}")' );" || return 1
    os::ok "数据库凭据已对齐到本机当前值（库 ${db}，账号 ${db_user}@${db_host}）"

    fixup_cache "${conf}" "${name}" || return 1
    return 0
}

# wp_has_define <wp-config 路径> <常量名>   文件里有没有这一行 define
#
# 判据与 os::replace_line 的正则同源，**先问存在性再替换**：那个接口一行都没
# 匹配到时会报错（它防的是「正则写错却往文件末尾塞一行」），拿它的返回值当
# 存在性判断，代价是每恢复一个从没配过缓存的站点就刷几行红字 —— 而那是完全
# 正常的情况。
wp_has_define() {
    local conf=${1} const=${2} line
    while IFS= read -r line; do
        [[ ${line} =~ ^define\(\ *\'${const}\' ]] || continue
        return 0
    done <"${conf}"
    return 1
}

# fixup_cache <wp-config 路径> <落点站的实例名>   缓存配置同样对齐到活系统
#
# 常量名与取值都跟 deploy_wordpress.sh 的 build_extra 一一对应 —— 那边写什么，
# 这边就把归档带来的那份改成什么。两处分叉的表现是「部署的站点缓存正常、
# 恢复的站点缓存不正常」，而且只在高并发时才看得出来。
#
# **归档里没有的行一律不加**：没配过缓存的站点不该因为一次恢复就凭空多出缓存
# 配置（见 fixup_credentials 的头注释）。
fixup_cache() {
    local conf=${1} name=${2}

    local cpass=''
    probe::component_version valkey
    if [[ -n ${OS_PROBE_VALUE} ]] && os::secure_load valkey.password cpass; then
        # 常量名与新行用 `|` 分隔：常量名里不可能有它，而 `${one#*|}` 取的是
        # 第一个 `|` 之后的全部，密码里恰好带 `|` 也拆不坏
        #
        # 前缀带的是**落点站的名字**，不是归档里那个：换名恢复之后两个站点
        # 会共用一个 Valkey，前缀不跟着换就互相覆盖对方的缓存键
        local -a want=(
            "WP_REDIS_HOST|define( 'WP_REDIS_HOST', '127.0.0.1' );"
            "WP_REDIS_PORT|define( 'WP_REDIS_PORT', 6379 );"
            "WP_REDIS_PASSWORD|define( 'WP_REDIS_PASSWORD', '$(os::php_str "${cpass}")' );"
            "WP_REDIS_PREFIX|define( 'WP_REDIS_PREFIX', '$(os::php_str "${name}:")' );"
        )
        local one const
        local -i hit=0
        for one in "${want[@]}"; do
            const=${one%%|*}
            wp_has_define "${conf}" "${const}" || continue
            os::replace_line "${conf}" "^define\( *'${const}'" "${one#*|}" || return 1
            hit=1
        done
        # 一行都没命中就是「这个站从来没配过缓存」，那时**什么都不说** ——
        # 报一句「已对齐」而文件里根本没有这几行，是在给没发生的动作发回执
        [[ ${hit} -eq 0 ]] || os::ok "缓存配置已对齐到本机当前值（前缀 ${name}:）"
        return 0
    fi

    # 本机没有可用的 Valkey，而归档里那份配置指着源机器上的一台。
    # **留着比没有更糟**：连不上时 WordPress 每个请求都要等一次连接超时，
    # deploy 那边「装了才写」防的就是这件事，恢复这条路同样得防。
    if wp_has_define "${conf}" WP_CACHE; then
        os::replace_line "${conf}" "^define\( *'WP_CACHE'" \
            "define( 'WP_CACHE', false );" || return 1
        os::warn '本机没有可用的 Valkey，备份带来的缓存配置已停用（WP_CACHE = false）'
    fi

    # **WP_CACHE 关不掉对象缓存**，所以这一步不能因为上面没改成而跳过：那个
    # 开关管的是页面缓存，而 Redis Object Cache 的 drop-in 一旦躺在 wp-content
    # 下就会自己去连，连不上照样每请求超时一次。别处迁来的站点常常有 drop-in
    # 却没有 WP_CACHE 这一行，两者的有无互不蕴含。
    # 它是站点文件不是配置，所以**挪走而不是删**，与其它覆盖动作同一条纪律。
    local drop="${conf%/*}/wp-content/object-cache.php"
    [[ -f ${drop} ]] || return 0
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    stash_current "${drop}" "object-cache-${ts}.php" || return 1
    os::warn '对象缓存 drop-in 已挪走 —— 本机连不上它要连的那台缓存，留着会让每个请求都等一次超时'
    os::info '装上 Valkey 之后重新启用缓存插件即可'
    return 0
}

# 恢复文件。
#
# `tar -x` 以 root 执行时默认还原归档里记录的属主与权限，所以
# **不需要 chown/chmod 那一串 find**：站点目录里的 www-data 归属是打包时
# 就记进去的。旧脚本那六条 `find -exec chmod` 是在补「打包时没保住属主」的洞，
# 而那个洞来自它用 `tar -cf` 之后又经过一次解包再打包。
restore_files() {
    local archive=${1} source=${2} root=${3} only=${4}

    [[ -n ${root} ]] || {
        os::err '这份备份中没有文件（只有数据库）'
        return 1
    }
    [[ -n ${source} ]] || {
        os::err '恢复目标没有目录，无法确定写入位置'
        return 1
    }

    local parent=${source%/*}
    [[ -n ${parent} ]] || parent='/'

    # **父目录在目标机器上可能根本不存在。** A 机的 /var/www 是部署 WordPress
    # 时建的，B 机是干净系统 —— 而「拿归档在另一台机器上重建站点」正是这个
    # 命令存在的理由。不建的话 `tar -C /var/www` 直接以 2 退出，**而数据库
    # 那一半已经恢复完了**，留下的是「库是新的、文件还是旧的（或者根本没有）」。
    #
    # 0755 而不是 umask 027 给的 0750：站点父目录必须让 www-data 进得去，
    # 0750 的表现是恢复报成功、浏览器 403（deploy_wordpress 那句
    # 「确保站点父目录可进入」防的是同一件事）。
    #
    # 归类「必须回滚」：只在本次确实不存在时才建，撤销用 rmdir 不是 rm -rf ——
    # 后面几步真失败时目录里已经有站点了，rmdir 会失败并把它留下，这是对的。
    if [[ ! -d ${parent} ]]; then
        os::run '创建站点父目录' -- mkdir -p "${parent}" || return 1
        os::defer rmdir -- "${parent}"
        os::run '确保站点父目录可进入' -- chmod 0755 "${parent}" || return 1
    fi

    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1

    if [[ -z ${only} ]]; then
        # 先解到隔离目录并审查，通过之后才动现有的站点。反过来的话，一份坏的
        # 归档会先把用户的站点挪走，再在解包中途失败
        local stage=''
        rs_safe_extract "${archive}" "${root}" "${parent}" "${RS_MF_SITE_TYPE}" stage || return 1
        rs_stage_valid "${stage}" || return 1
        rs_normalize_owner "${stage}/${root}" "${RS_MF_SITE_TYPE}" || return 1
        # 完整恢复：挪走的就是站点根本身，允许 live == root
        stash_current "${source}" "${root}-${ts}" "${source}" || return 1
        os::run '就位站点文件' -- mv -T -- "${stage}/${root}" "${source}" || return 1
        rs_drop_stage "${stage}"
        os::ok "文件已恢复到 ${source}"
        return 0
    fi

    # 只恢复归档内的某个子路径（典型场景：wp-content/uploads）
    local sub=${only#/}
    sub=${sub%/}
    local live="${source}/${sub}"

    # **先确认归档里真有这个子路径，再动现有的东西。** 反过来的话，一个拼错的
    # `--only` 会先把用户的 uploads 挪走，然后 tar 报「找不到」——现场是
    # 「恢复失败，而且媒体库不见了」
    os::query --timeout 600 -- tar -tzf "${archive}" "${root}/${sub}" || {
        os::err "备份中没有这个子路径：${sub}"
        return 1
    }
    # `--only` 是部分恢复：live 必须**严格落在站点目录之内**。子路径由用户给、
    # 成员名由归档给，两者拼出来的路径穿出去时挪走的就是别处的东西
    # 与完整恢复同一条纪律：先解到隔离目录、审查、定属主，再动现有的东西
    local stage=''
    rs_safe_extract "${archive}" "${root}/${sub}" "${parent}" "${RS_MF_SITE_TYPE}" stage || return 1
    rs_stage_valid "${stage}" || return 1
    rs_normalize_owner "${stage}/${root}/${sub}" "${RS_MF_SITE_TYPE}" || return 1

    stash_current "${live}" "${root}-${sub//\//_}-${ts}" "${source}" || return 1
    os::run '创建子目录的父级' -- mkdir -p "${live%/*}"
    os::run '就位指定子路径' -- mv -T -- "${stage}/${root}/${sub}" "${live}" || return 1
    rs_drop_stage "${stage}"
    os::ok "已恢复 ${live}"
    return 0
}

# `oneserver:self`：只解出来，不覆盖。理由见文件头第五点。
restore_self() {
    local archive=${1} root=${2}
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local out="${RS_PRE_DIR}/oneserver-config-${ts}"
    os::run '创建解出目录' -- mkdir -p "${out}"
    os::run '收紧解出目录权限' -- chmod 0700 "${out}"
    # **同样按不可信输入解包**。这条路只解不覆盖（见文件头第五点），但解出来的
    # 东西随后要由人 diff 与合并 —— 一个 setuid 的文件或指向 /etc 的符号链接
    # 躺在那儿等着被合并回去，比直接覆盖更隐蔽。
    os::run '解出 oneserver 配置' -- \
        tar -xzf "${archive}" --no-same-owner --no-same-permissions -C "${out}" "${root}" \
        || return 1
    # 随后有一次 chown -R root:root，所以硬链接在这里是硬失败
    rs_audit_tree "${out}" yes || return 1
    rs_normalize_owner "${out}" self || return 1
    # 凭据库解出来必须还是 0600 —— 上面那步把普通文件统一成了 root:root，
    # 权限则由归档记的 --no-same-permissions 归零成 umask，这里显式定死
    [[ ! -f "${out}/${root}/secure.conf" ]] \
        || os::run '收紧解出的凭据库权限' -- chmod 0600 -- "${out}/${root}/secure.conf" || return 1

    os::section '已解出，但没有覆盖任何东西'
    os::kv '解到' "${out}/${root}"
    os::info 'state 与 secure.conf 正被当前进程使用，在运行中替换它们属于 K13 那一类问题。'
    os::info '请人工对照后合并，例如：'
    os::info "  diff ${out}/${root}/secure.conf ${OS_SECURE_CONF}"
    os::info "  diff -r ${out}/${root}/state ${OS_STATE_DIR}"
    os::ok '恢复素材已就绪'
    os::output 0 extracted="${out}/${root}" changed=yes
    return 0
}

# ==================================================================
# 外部导入 —— 来源解析
# ==================================================================

# ex_split_source <spec>   一个 --source 吃两样东西：文件来源与 SQL 转储
#
# 整站迁移天生是「一个包 + 一份 dump」。拆成两条命令意味着两次打全名确认、
# 两个覆盖窗口，中间那段时间站点是「文件是新的、库还是旧的」。所以这里接受
# 逗号分隔，次序不限，同类给两份即拒绝。**代价是路径里不能含逗号。**
#
# 同时当 os::ask 的 --validate 用：填错在原地重问，而不是把前面填过的作废。
ex_split_source() {
    local spec=${1-} item
    [[ -n ${spec} ]] || return 1
    local -a items=()
    local IFS=','
    read -ra items <<<"${spec}"
    IFS=$'\n\t'

    EX_SRC_FILES='' EX_SRC_SQL='' EX_KIND=''
    for item in ${items[@]+"${items[@]}"}; do
        [[ -n ${item} ]] || continue
        if [[ ${item} != /* ]]; then
            os::err "来源要给绝对路径，收到「${item}」"
            return 1
        fi
        if [[ ! -e ${item} ]]; then
            os::err "来源不存在：${item}"
            return 1
        fi
        # 先判目录，不看名字：一个恰好叫 dump.sql 的目录不是转储
        if [[ -d ${item} ]]; then
            [[ -n ${item%/} ]] || {
                os::err '来源不能是根目录 /'
                return 1
            }
            [[ -z ${EX_SRC_FILES} ]] || {
                os::err '文件来源只能给一份'
                return 1
            }
            EX_SRC_FILES=${item%/}
            EX_KIND=dir
            continue
        fi
        case ${item} in
            *.sql | *.sql.gz)
                [[ -z ${EX_SRC_SQL} ]] || {
                    os::err 'SQL 转储只能给一份'
                    return 1
                }
                EX_SRC_SQL=${item}
                continue
                ;;
            # 明摆着是转储、只是压缩格式不认识。不落到下面的「当单个文件处理」——
            # 那会把一个 .sql.bz2 原样拷进站点目录，报成功，而库一个字节没变
            *.sql.*)
                os::err "转储只支持 .sql 与 .sql.gz，收到 ${item##*/}"
                os::info '先解开再导入，例如：bunzip2 / unxz / unzstd / 7z x'
                return 1
                ;;
        esac
        [[ -z ${EX_SRC_FILES} ]] || {
            os::err '文件来源只能给一份'
            return 1
        }
        EX_SRC_FILES=${item}
        case ${item} in
            *.tar.gz | *.tgz | *.tar) EX_KIND=tar ;;
            *.zip) EX_KIND=zip ;;
            # 明摆着是归档、只是压缩格式不认识。同 *.sql.* 那条：落到下面的
            # 「当单个文件处理」会把 .tar.zst 原样拷进站点目录、报成功，而站点是空的
            *.tar.* | *.txz | *.tbz | *.tbz2 | *.tzst)
                os::err "压缩备份只支持 .tar / .tar.gz / .tgz / .zip，收到 ${item##*/}"
                os::info '先解开再导入，例如：unxz / bunzip2 / unzstd'
                return 1
                ;;
            *.rar | *.7z)
                os::err '不支持 .rar / .7z —— 解它们要装第三方运行时，本工具不引入运行时依赖'
                os::info '先在别处解开成目录，再把那个目录作为来源'
                return 1
                ;;
            # 认不出扩展名就是单个文件：用户要导入的就是这一个文件本身
            *) EX_KIND='file' ;;
        esac
    done
    [[ -n ${EX_SRC_FILES} || -n ${EX_SRC_SQL} ]]
}

# ex_db_exists <库名>   手工建的库也该能当落点，但得先确认它真的存在 ——
# 否则一个拼错的库名会让数据灌进一个刚被 restore_db 建出来的空库，而且返回成功
ex_db_exists() {
    local quoted
    quoted=$(os::sql_str "${1}")
    os::sql_query '查询数据库是否存在' -- "SHOW DATABASES LIKE ${quoted}" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

# ex_resolve_dest <类型:名字>   落点复用与 backup 同一套标识，不引入新词
#
# `path:` 后面以 `/` 开头就是直接路径，否则是 `backup add` 登记过的别名 ——
# 判据是一个字符，不是一个新概念。直接路径这一形态顺带解决了「只迁 wp-content」：
# `--target=path:/var/www/blog/wp-content`，不必再发明一个「落到站点内哪一层」的参数。
#
# 同样当 --validate 用。
ex_resolve_dest() {
    local spec=${1-}
    EX_DEST_DIR='' EX_DEST_DB='' EX_SITE_TYPE='' EX_SITE_NAME=''
    if [[ ${spec} != *:* ]]; then
        os::err "恢复目标要写成 <类型>:<名字>，收到「${spec}」"
        os::info 'site:<站点名> 整站 · db:<库名> 只灌库 · path:<别名或绝对路径> 任意目录或文件'
        return 1
    fi
    local type=${spec%%:*} name=${spec#*:}
    [[ -n ${name} ]] || {
        os::err '恢复目标缺少名字'
        return 1
    }

    case ${type} in
        site)
            local -a types=()
            local t
            local IFS=$', \t\n'
            read -ra types <<<"${OS_DEFAULT_BACKUP_SITE_TYPES}"
            IFS=$'\n\t'
            for t in ${types[@]+"${types[@]}"}; do
                [[ -n ${t} ]] || continue
                os::state_has "${t}:${name}" || continue
                EX_SITE_TYPE=${t}
                break
            done
            [[ -n ${EX_SITE_TYPE} ]] || {
                os::err "state 里没有站点「${name}」"
                os::info '先 oneserver deploy wordpress 部署一个空站，或改用 path:<绝对路径>'
                return 1
            }
            EX_SITE_NAME=${name}
            EX_DEST_DIR=$(os::state_get "${EX_SITE_TYPE}:${name}" path)
            EX_DEST_DB=$(os::state_get "${EX_SITE_TYPE}:${name}" db)
            [[ -n ${EX_DEST_DIR} ]] || {
                os::err "state 里的 ${EX_SITE_TYPE}:${name} 没有 path 键，定不出恢复目录"
                return 1
            }
            ;;
        db)
            valid_db_name "${name}" || {
                os::err "数据库名「${name}」不合法（只收小写字母数字与 _ -，以字母数字开头）"
                return 1
            }
            os::require_cmd mysql
            ex_db_exists "${name}" || {
                os::err "数据库 ${name} 不存在"
                os::info "先建库：oneserver mariadb create --name=${name}"
                return 1
            }
            EX_DEST_DB=${name}
            ;;
        path)
            if [[ ${name} == /* ]]; then
                EX_DEST_DIR=${name%/}
            else
                os::state_has "backup-path:${name}" || {
                    os::err "没有登记过路径别名「${name}」"
                    os::info '要么先 oneserver backup add 登记，要么直接给绝对路径'
                    return 1
                }
                EX_DEST_DIR=$(os::state_get "backup-path:${name}" source)
            fi
            [[ -n ${EX_DEST_DIR} ]] || {
                os::err '解析不出恢复目标路径'
                return 1
            }
            ;;
        *)
            os::err "未知的恢复目标类型「${type}」，可用：site db path"
            return 1
            ;;
    esac

    # 落点是本机将被覆盖的路径，与 manifest 的 source_path 同一条规则：
    # 挡掉相对路径、路径穿越与系统关键目录
    if [[ -n ${EX_DEST_DIR} ]] && ! valid_source_path "${EX_DEST_DIR}"; then
        os::err "恢复目标路径不可接受：${EX_DEST_DIR}（相对路径、路径穿越，或系统关键目录）"
        return 1
    fi
    return 0
}

# ==================================================================
# 外部导入 —— 解包前的审查
# ==================================================================

# ex_read_members   读来源清单：不解包、不落盘
#
# 几个 G 的 .tar.gz 要完整解压一遍才列得出清单，慢。但**用户确认之前不往磁盘上
# 铺任何东西**优先于快 —— 解错地方的代价比多等两分钟大得多。
ex_read_members() {
    EX_MEMBERS='' EX_SIZE_KB=0
    case ${EX_KIND} in
        tar)
            os::query --timeout 3600 -- tar -tvf "${EX_SRC_FILES}" || {
                os::err "读不出备份文件清单：${EX_SRC_FILES}（不是 tar 包，或者已损坏）"
                return 1
            }
            # `tar -tv` 一行是「权限 属主/组 大小 日期 时间 名字」。名字可能带空格，
            # 所以按「前五列之后全是名字」取，不按第 6 列取；符号链接的 ` -> 目标`
            # 在这里去掉，它不是路径的一部分（链接本身另有 ex_audit_symlinks 管）。
            local raw=${OS_RUN_OUTPUT}
            local size rest name names='' total=0
            local IFS=$' \t'
            while read -r _ _ size rest; do
                [[ ${size} =~ ^[0-9]+$ ]] || continue
                total=$((total + size))
                # rest 是「日期 时间 名字」
                name=${rest#* }
                name=${name#* }
                name=${name%% -> *}
                name=${name#./}
                name=${name%/}
                [[ -n ${name} ]] && names+="${name}"$'\n'
            done <<<"${raw}"
            IFS=$'\n\t'
            EX_SIZE_KB=$((total / 1024))
            EX_MEMBERS=${names}
            ;;
        zip)
            # zip 的清单在中央目录里，读它不用解压，所以这里不心疼两次调用
            os::pkg_install unzip || return 1
            os::require_cmd unzip
            os::query --timeout 600 -- unzip -Z1 "${EX_SRC_FILES}" || {
                os::err "读不出 zip 清单：${EX_SRC_FILES}（不是 zip 包，或者已损坏）"
                return 1
            }
            local m names=''
            while IFS= read -r m; do
                m=${m#./}
                m=${m%/}
                [[ -n ${m} ]] && names+="${m}"$'\n'
            done <<<"${OS_RUN_OUTPUT}"
            EX_MEMBERS=${names}
            # `unzip -Zt` 形如「42 files, 1234567 bytes uncompressed, …」
            os::query --timeout 600 -- unzip -Zt "${EX_SRC_FILES}" || return 1
            local b=${OS_RUN_OUTPUT#*, }
            b=${b%% bytes*}
            [[ ${b} =~ ^[0-9]+$ ]] && EX_SIZE_KB=$((b / 1024))
            ;;
        dir)
            os::query --timeout 600 -- find "${EX_SRC_FILES}" -mindepth 1 -printf '%P\n' || {
                os::err "读不出目录内容：${EX_SRC_FILES}"
                return 1
            }
            EX_MEMBERS=${OS_RUN_OUTPUT}
            probe::dir_size_kb "${EX_SRC_FILES}"
            [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]] && EX_SIZE_KB=${OS_PROBE_VALUE}
            ;;
    esac
    [[ -n ${EX_MEMBERS} ]] || {
        os::err '来源里是空的'
        return 1
    }
    return 0
}

# ex_audit_members   解包前审查清单，一个字节都不解
#
# GNU tar 默认会剥掉前导 `/` 也会拒绝 `..`，unzip 不会（zip slip）。
# **不指望解包工具替我们把关**，两种包同一条规则。
ex_audit_members() {
    local m sql='' bad=''
    local -i n=0
    while IFS= read -r m; do
        [[ -n ${m} ]] || continue
        if [[ ${m} == /* || ${m} == ../* || ${m} == */../* || ${m} == */.. || ${m} == '..' ]]; then
            n=$((n + 1))
            [[ ${n} -le 5 ]] && bad+="${m}"$'\n'
            continue
        fi
        case ${m} in
            *.sql | *.sql.gz) [[ -n ${sql} ]] || sql=${m} ;;
        esac
    done <<<"${EX_MEMBERS}"

    if [[ ${n} -gt 0 ]]; then
        os::err "来源里有 ${n} 个条目带绝对路径或 .. 路径段，拒绝导入（路径穿越 / zip slip）"
        while IFS= read -r m; do
            [[ -n ${m} ]] && os::info "  ${m}"
        done <<<"${bad}"
        return 1
    fi

    # 站点目录下的 .sql 是能被公网直接下载的 —— 里面有全站数据
    [[ -z ${sql} ]] || {
        os::warn "来源里含 SQL 转储：${sql}"
        os::info '它会跟着解到恢复目录里。要灌库请把它单独指给 --source（逗号分隔），'
        os::info '并在导入后删掉解出来的那一份。'
    }
    return 0
}

# ex_depth <相对路径>   路径有几段
ex_depth() {
    local p=${1} n=1
    while [[ ${p} == */* ]]; do
        p=${p#*/}
        n=$((n + 1))
    done
    printf '%s' "${n}"
}

# ex_locate_root <--subdir 的值>   来源里哪一层才是要导入的内容
#
# 按标志文件定位，不猜层数。判据：同一目录下 `wp-config.php`、`wp-includes/`、
# `wp-admin/` **至少中两项** —— 只要一项的话，一个恰好叫 wp-admin 的普通目录
# 就能把根定到错的地方。
#
# 取最浅的候选；**同深度出现多个才拒绝**。只有一个最浅候选时不该多问一句。
#
# 一项都不命中**不是错误**：只迁 wp-content 的包本来就没有标志文件，
# 那时整个来源就是根，落到哪里由 --target 决定。
ex_locate_root() {
    local wanted_subdir=${1-}
    EX_ROOT=''

    if [[ -n ${wanted_subdir} ]]; then
        local w=${wanted_subdir#/}
        w=${w%/}
        if [[ -z ${w} || ${w} == *..* ]]; then
            os::err "--subdir 只收来源内的相对路径，收到「${wanted_subdir}」"
            return 1
        fi
        local m found=''
        while IFS= read -r m; do
            [[ ${m} == "${w}" || ${m} == "${w}/"* ]] || continue
            found=1
            break
        done <<<"${EX_MEMBERS}"
        [[ -n ${found} ]] || {
            os::err "来源里没有这个子路径：${w}"
            return 1
        }
        EX_ROOT=${w}
        return 0
    fi

    # 先用 case 把绝大多数条目挡在外面：十万个文件里带标志名的通常只有几百个，
    # 剩下的才做字符串切分。前缀一律以 `/` 结尾，段数因此等于其中 `/` 的个数。
    #
    # 来源根目录记成 `.` 而不是空串：**bash 的关联数组不接受空下标**
    # （`bad array subscript`），而「站点根就在来源根目录」恰恰是最常见的一种包。
    # 清单里的条目都已经去掉了前导 `./`，所以 `.` 不可能与真实前缀撞上。
    local m p mark
    local -A marks=() cnt=()
    while IFS= read -r m; do
        case ${m} in
            wp-config.php)
                mark='wp-config.php'
                p='.'
                ;;
            */wp-config.php)
                mark='wp-config.php'
                p=${m%wp-config.php}
                ;;
            wp-includes | wp-includes/*)
                mark='wp-includes'
                p='.'
                ;;
            */wp-includes | */wp-includes/*)
                mark='wp-includes'
                p="${m%%/wp-includes*}/"
                ;;
            wp-admin | wp-admin/*)
                mark='wp-admin'
                p='.'
                ;;
            */wp-admin | */wp-admin/*)
                mark='wp-admin'
                p="${m%%/wp-admin*}/"
                ;;
            *) continue ;;
        esac
        [[ -z ${marks["${p}|${mark}"]:-} ]] || continue
        marks["${p}|${mark}"]=1
        cnt["${p}"]=$((${cnt["${p}"]:-0} + 1))
    done <<<"${EX_MEMBERS}"

    # 键展开必须写成 `"${!cnt[@]}"`：`${!cnt[@]+…}` 会被 bash 当成**间接引用**
    # 而不是「数组为空时给个默认」，现场表现是循环一次都不进、每份包都被判成
    # 「没有标志文件」。数组空时用 ${#} 先挡一道，不依赖 set -u 的版本行为。
    local d t bd=-1
    local -a ties=()
    if [[ ${#cnt[@]} -gt 0 ]]; then
        for p in "${!cnt[@]}"; do
            [[ ${cnt["${p}"]} -ge 2 ]] || continue
            d=0
            t=${p}
            [[ ${t} == . ]] && t=''
            while [[ ${t} == */* ]]; do
                t=${t#*/}
                d=$((d + 1))
            done
            if [[ ${bd} -lt 0 || ${d} -lt ${bd} ]]; then
                bd=${d}
                ties=("${p}")
            elif [[ ${d} -eq ${bd} ]]; then
                ties+=("${p}")
            fi
        done
    fi

    if [[ ${bd} -lt 0 ]]; then
        if [[ -n ${EX_SITE_TYPE} ]]; then
            os::warn '来源里没有 WordPress 标志文件，整份内容将按普通目录覆盖站点目录'
            os::info '只迁 wp-content 之类的部分内容时，恢复目标应当写成 path:<那个子目录的绝对路径>'
        fi
        return 0
    fi

    if [[ ${#ties[@]} -gt 1 ]]; then
        os::err '来源里有多个同样深的站点根，无法替你选：'
        for t in "${ties[@]}"; do
            [[ ${t} == . ]] && t='（来源根目录）'
            os::info "  ${t}"
        done
        os::info '用 --subdir=<其中一个> 指定'
        return 1
    fi
    [[ ${ties[0]} == . ]] || EX_ROOT=${ties[0]%/}
    return 0
}

# ex_check_space   解包会在落点所在文件系统上多占一份来源的大小
ex_check_space() {
    [[ ${EX_SIZE_KB} -gt 0 ]] || return 0
    local parent=${EX_DEST_DIR%/*}
    [[ -n ${parent} ]] || parent='/'
    [[ -d ${parent} ]] || return 0
    probe::disk_free_kb "${parent}"
    [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]] || return 0
    local -i free=${OS_PROBE_VALUE}
    local -i need=$((EX_SIZE_KB + EX_SIZE_KB / 10))
    if ((free < need)); then
        os::err "空间不够：${parent} 可用 $((free / 1024)) MB，解包需要约 $((need / 1024)) MB"
        return 1
    fi
    return 0
}

# ==================================================================
# 外部导入 —— SQL 转储
# ==================================================================

# sql_scan <转储文件>   看清楚这份 dump 会往哪个库写、按什么字符集写
#
# dump 里的 `USE 老库` 会把数据写进另一个库，而 `mysql` 仍以 0 退出 ——
# **静默灌错库比失败危险得多。**
#
# 但命中不等于拒绝：phpMyAdmin、宝塔、`mysqldump --databases` 导出的 dump
# 几乎都带 `CREATE DATABASE` + `USE`。一律拒绝等于这个功能对大多数真实迁移
# 不可用，用户只能回去手工编辑几个 G 的文本。所以这里只负责**看见并说清**，
# 剥不剥由调用方问用户，而剥离发生在导入管道里，**原文件一个字节不动**。
sql_scan() {
    local f=${1}
    EX_SQL_HITS='' EX_SQL_CHARSET=''
    os::require_cmd zgrep

    # 一遍扫完两件事：库级语句与字符集声明。
    #
    # **用 zgrep 而不是 `gunzip -c | grep`** —— 后者要一条管道，而管道只能经
    # `sh -c` 表达，那是一条不必要的注入面（也是一条要写理由的 disable）。
    # zgrep 对 `.sql` 与 `.sql.gz` 一视同仁，一条命令、一个 argv。
    #
    # 正则全部锚在行首的完整语句形态：mysqldump 的 INSERT 把换行转义成了 `\n`，
    # 数据行不可能以这几个词开头 —— 正文里写着「USE …」不会被误判成语句。
    local -i rc=0
    os::query --timeout 3600 -- zgrep -n -E \
        '^(USE[[:space:]]|CREATE[[:space:]]+DATABASE|DROP[[:space:]]+DATABASE|(/\*![0-9]+ )?SET NAMES)' \
        "${f}" || rc=$?
    # zgrep 的 1 是「一条都没匹配上」，那是正常结果；2 才是真读不了
    if [[ ${rc} -gt 1 ]]; then
        os::err "读不出转储内容：${f}"
        return 1
    fi

    local line hits=''
    local -i n=0
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        if [[ ${line} == *'SET NAMES'* ]]; then
            [[ -z ${EX_SQL_CHARSET} ]] || continue
            EX_SQL_CHARSET=${line#*'SET NAMES '}
            EX_SQL_CHARSET=${EX_SQL_CHARSET%%[^A-Za-z0-9_]*}
            continue
        fi
        n=$((n + 1))
        [[ ${n} -le 20 ]] && hits+="${line}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ ${n} -le 20 ]] || hits+="…（还有 $((n - 20)) 条同类语句）"$'\n'
    EX_SQL_HITS=${hits}
    return 0
}

# ex_read_prefix <wp-config 路径>   读出 $table_prefix，读不到就打印空串
ex_read_prefix() {
    local line
    while IFS= read -r line; do
        [[ ${line} =~ \$table_prefix[[:space:]]*=[[:space:]]*[\'\"]([A-Za-z0-9_]+)[\'\"] ]] || continue
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    done <"${1}"
    return 0
}

# ex_check_prefix <wp-config 路径> <库名>
#
# **导入之后最容易撞、又最看不出原因的一件事。**
#
# 外来站点的表前缀常常不是 `wp_`。三种组合会撞上：只灌了库而文件是本机的、
# 来源包里没有 wp-config 于是沿用了本机那份、有人手工换过 wp-config。
# 撞上之后 WordPress 连得上库、却一张表都认不出 —— 表现是**跳回安装向导**。
# 用户看到的是「导入成功了，然后站点要我重新安装一遍」，几乎不可能想到是前缀。
#
# 所以这里主动核对，并且把库里真实存在的前缀列出来：只说一句「对不上」
# 等于把问题原样丢回给用户。
ex_check_prefix() {
    local conf=${1} db=${2}
    [[ -f ${conf} ]] || return 0
    local prefix
    prefix=$(ex_read_prefix "${conf}")
    [[ -n ${prefix} ]] || return 0

    # 一次查完：既判断有没有 `<前缀>options`，也拿到库里实际的前缀。
    # LIKE 用 `%options` 而不是 `<前缀>options` —— 后者里的 `_` 在 LIKE 里
    # 是通配符，`wp_options` 会连 `wpXoptions` 一起匹上，白白放过真正的不匹配。
    os::sql_query '核对站点表前缀' -- \
        "SHOW TABLES FROM $(os::sql_ident "${db}") LIKE '%options'" || return 0
    local t found='' others=''
    while IFS= read -r t; do
        [[ -n ${t} ]] || continue
        if [[ ${t} == "${prefix}options" ]]; then
            found=1
            break
        fi
        others+="  库里实际有 ${t}（前缀是 ${t%options}）"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    [[ -z ${found} ]] || return 0

    os::warn "站点配置里的表前缀是「${prefix}」，但库 ${db} 里没有 ${prefix}options 这张表"
    if [[ -n ${others} ]]; then
        while IFS= read -r t; do
            [[ -n ${t} ]] && os::info "${t}"
        done <<<"${others}"
        os::info "改法：编辑 ${conf}，把 \$table_prefix 改成上面那个前缀，再刷新站点"
    else
        os::info "库 ${db} 里连一张 %options 表都没有 —— 这份转储可能不是 WordPress 的，或者没真正导进去"
    fi
    os::warn '不处理的话，打开站点会是 WordPress 的安装向导，而不是你的站'
    return 0
}

# post_restore_hints <站点类型> <站点目录>   恢复/导入完之后该看哪几项
#
# **不自动重启服务、不自动清缓存**：PHP-FPM 上跑着的可能不止这一个站，
# 替用户重启一个正在服务别人的进程不是本命令该做的决定。只把该看的列出来。
post_restore_hints() {
    local site_type=${1}
    [[ ${site_type} == wordpress ]] || return 0
    os::section '接下来自己检查这几项'
    os::info '1. 用浏览器打开站点，别只看这里报的成功'
    os::info '2. 打开后是 WordPress 安装向导 → 表前缀对不上，照上面的提示改 wp-config.php'
    os::info '3. 白屏或 500 → journalctl -u caddy -n 50，以及对应的 php*-fpm 服务日志；'
    os::info '   老站点跑在比本机更旧的 PHP 上时也会白屏，先确认版本对不对得上'
    os::info '4. 图片、样式丢失 → 库里还留着旧域名。WP-CLI：wp search-replace 旧地址 新地址 --all-tables --precise'
    os::info '5. 域名还没指到这台机器 → oneserver caddy'
    os::info '6. 全部确认正常之后再清理恢复前副本，不要提前删'
    return 0
}

# set_site_url <wp-config 路径> <库名> <新地址>
#
# siteurl / home 存在 `<前缀>options` 两行里。**表前缀不写死 `wp_`** ——
# 外来站点常改过它，猜一个前缀去 UPDATE，命中的可能是别的站点的表。
set_site_url() {
    local conf=${1} db=${2} url=${3}
    url=${url%/}

    [[ -f ${conf} ]] || {
        os::err "找不到 ${conf}，读不出表前缀，siteurl / home 未改动"
        return 1
    }
    local prefix
    prefix=$(ex_read_prefix "${conf}")
    if [[ -z ${prefix} ]]; then
        os::err "从 ${conf} 里读不出 \$table_prefix，siteurl / home 未改动"
        os::info '手工改：登录数据库，UPDATE <前缀>options SET option_value=... WHERE option_name IN ('"'"'siteurl'"'"','"'"'home'"'"')'
        return 1
    fi

    # 只恢复数据库时，落点原有 wp-config 的前缀不一定属于刚导入的库。直接拿
    # 它 UPDATE 的结果有两种：表不存在，数据库已经重建后才报失败；或者同库里
    # 恰好有那张表，于是改到另一个站点。先看库里的事实，再决定写哪张表。
    os::sql_query '定位站点地址表' -- \
        "SHOW TABLES FROM $(os::sql_ident "${db}") LIKE '%options'" || return 1
    local configured="${prefix}options" options_table='' candidate
    local -a candidates=()
    while IFS= read -r candidate; do
        [[ -n ${candidate} ]] || continue
        candidates+=("${candidate}")
        [[ ${candidate} != "${configured}" ]] || options_table=${candidate}
    done <<<"${OS_RUN_OUTPUT}"

    if [[ -z ${options_table} ]]; then
        if [[ ${#candidates[@]} -eq 1 ]]; then
            options_table=${candidates[0]}
            os::warn "配置前缀是「${prefix}」，刚导入的库里唯一的 options 表是 ${options_table}"
            os::info "siteurl / home 将改在 ${options_table}；恢复完成后仍要把 ${conf} 的 \$table_prefix 对齐"
        else
            os::err "配置前缀是「${prefix}」，无法在库 ${db} 里唯一定位要改的 options 表"
            if [[ ${#candidates[@]} -gt 0 ]]; then
                for candidate in "${candidates[@]}"; do
                    os::info "  候选：${candidate}"
                done
            else
                os::info "库 ${db} 里没有任何 %options 表"
            fi
            os::info '为避免改到另一个站点，siteurl / home 未改动'
            return 1
        fi
    fi

    local table val
    table="$(os::sql_ident "${db}").$(os::sql_ident "${options_table}")"
    val=$(os::sql_str "${url}")

    os::sql_query '读取当前站点地址' -- \
        "SELECT option_name, option_value FROM ${table} WHERE option_name IN ('siteurl','home');" \
        || return 1
    os::info "改前：${OS_RUN_OUTPUT//$'\n'/ · }"

    os::record_change "把 ${db} 的 siteurl / home 改成 ${url}"
    os::sql_exec '改写站点地址' -- \
        "UPDATE ${table} SET option_value = ${val} WHERE option_name IN ('siteurl','home');" \
        || return 1
    os::ok "siteurl / home 已改为 ${url}"

    # **只有这两行。** 文章正文、主题与插件设置里的绝对 URL 不会跟着变，而它们
    # 大多躺在序列化字符串里（`s:23:"http://旧域名/x"`）—— 用正则替换会让长度与
    # 声明对不上，整条设置作废。那正是 wp search-replace 存在的理由，本工具不自造。
    os::warn '只改了 siteurl 与 home，文章正文与插件设置里的旧域名不受影响'
    os::info '要全库替换请用 WP-CLI：wp search-replace 旧地址 新地址 --all-tables --precise'
    return 0
}

# ==================================================================
# 外部导入 —— 落地
# ==================================================================

# ex_unpack <staging>   把来源解到暂存目录
#
# 不用 `--strip-components` 直落落点：那时旧目录已经被挪去 pre-restore 了，
# 解到一半失败的现场是「半个新站点，旧的在别处」。而且 unzip 根本没有这个选项，
# 直落等于要写两条危险写入路径。**解到隔壁再整个改名**让两种包共用一条路，
# 失败时落点一个字节没动。
ex_unpack() {
    local staging=${1}
    local raw="${staging}.raw"

    case ${EX_KIND} in
        tar | zip)
            local -a cmd=()
            if [[ ${EX_KIND} == tar ]]; then
                # --no-same-owner：归档里记的是**源机的**数字 uid，本机的同号
                # 用户可能是另一个人。解出来先归 root，属主由 ex_apply_ownership
                # 按落点类型定。
                cmd=(tar -xf "${EX_SRC_FILES}" --no-same-owner -C)
            else
                cmd=(unzip -q -o "${EX_SRC_FILES}" -d)
            fi
            if [[ -z ${EX_ROOT} ]]; then
                os::run '解出来源' -- "${cmd[@]}" "${staging}" || return 1
            else
                # tar 不会替你建 -C 的目录（unzip -d 会），少这一步整包必挂。
                # 0700 与 staging 同：解包中途 /var/www 下不该有一份 web 可读的站点副本
                os::run '创建解包目录' -- mkdir -m 0700 -p "${raw}" || return 1
                # 先登记再解 —— 解到一半失败时 raw 里已经有半个站点了
                os::defer rm -rf -- "${raw}"
                os::run '解出来源' -- "${cmd[@]}" "${raw}" || return 1
                # staging 此刻还是空的，腾掉它再把站点根整个改名过来 —— 比逐项 mv
                # 少一个「点开头的文件被 * 漏掉」的坑（.htaccess / .user.ini）
                os::run '腾出暂存目录' -- rmdir "${staging}" || return 1
                os::run '取出来源里的站点根' -- mv -- "${raw}/${EX_ROOT}" "${staging}" || return 1
                os::run '清理解包残留' -- rm -rf -- "${raw}" || return 1
            fi
            ;;
        dir)
            # 结尾的 `/.` 才会把点开头的文件一起拷过去
            os::run '拷入来源' -- \
                cp -a "${EX_SRC_FILES}/${EX_ROOT:+${EX_ROOT}/}." "${staging}/" || return 1
            ;;
    esac
    return 0
}

# ex_link_target_escapes <staging> <链接绝对路径> <链接目标>   目标落在 staging 外面吗
#
# 直接拒绝一切带 `..` 的目标要简单得多，但站点内部的相对链接
# （`wp-content/uploads/x -> ../y`）是合法的 —— 一刀切会把正常备份挡在门外，
# 而迁移这件事用户往往只有一次机会。所以这里逐段规范化，真算一遍它落在哪。
ex_link_target_escapes() {
    local staging=${1} link=${2} target=${3}
    [[ ${target} != /* ]] || return 0
    local -a segs=() out=()
    local seg path
    local IFS='/'
    read -ra segs <<<"${link%/*}/${target}"
    IFS=$'\n\t'
    for seg in ${segs[@]+"${segs[@]}"}; do
        case ${seg} in
            '' | .) ;;
            ..)
                # 已经在根上还要往上：无论后面接什么都出界了
                [[ ${#out[@]} -gt 0 ]] || return 0
                unset 'out[-1]'
                ;;
            *) out+=("${seg}") ;;
        esac
    done
    IFS='/'
    path="/${out[*]}"
    IFS=$'\n\t'
    [[ ${path} != "${staging}" && ${path} != "${staging}/"* ]]
}

# ex_audit_symlinks <staging>   解包后再查一遍符号链接
#
# 清单审查挡的是「写到 staging 外面去」，这里挡的是「留在 staging 里、但指向
# 外面」—— 一个 `wp-content/x.php -> /etc/shadow` 搬进站点目录之后，
# PHP 就能读它。
ex_audit_symlinks() {
    local staging=${1}
    os::query --timeout 600 -- find "${staging}" -type l -printf '%p -> %l\n' || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0

    local line p t bad=''
    local -i n=0
    while IFS= read -r line; do
        [[ -n ${line} ]] || continue
        p=${line%% -> *}
        t=${line#* -> }
        ex_link_target_escapes "${staging}" "${p}" "${t}" || continue
        n=$((n + 1))
        [[ ${n} -le 5 ]] && bad+="${line#"${staging}/"}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"

    [[ ${n} -gt 0 ]] || return 0
    os::err "来源里有 ${n} 个指向自身之外的符号链接，拒绝导入"
    while IFS= read -r line; do
        [[ -n ${line} ]] && os::info "  ${line}"
    done <<<"${bad}"
    return 1
}

# ex_apply_ownership <staging>   属主与权限
#
# 解出来的东西现在归 root。往下分两条：
#   site 落点 —— 站点的权限模型由本工具定义，套 deploy_wordpress 那一套
#   path 落点 —— 任意路径可能是任何东西，替用户猜属主是在做他没要求的决定，
#                保持 root:root 并说清楚
#
# `chown -Rh` 的 `-h` 是硬要求：来源里可以有符号链接，跟着链接改属主等于改到
# 链接指向的地方去 —— 那可能是站点之外的文件。
ex_apply_ownership() {
    local staging=${1}
    if [[ -z ${EX_SITE_TYPE} ]]; then
        os::run '设置导入内容属主' -- chown -Rh root:root "${staging}" || return 1
        os::info '导入内容的属主是 root:root，需要别的属主请自行 chown'
        # 权限位保留来源里的：那是来源带来的事实，改它是替用户做决定。
        # 但世界可写必须说一声，它是实打实的风险。
        os::query --timeout 600 -- find "${staging}" -perm -0002 -printf '%P\n' || return 0
        [[ -n ${OS_RUN_OUTPUT} ]] || return 0
        local -i n=0
        local line
        while IFS= read -r line; do
            [[ -n ${line} ]] && n=$((n + 1))
        done <<<"${OS_RUN_OUTPUT}"
        os::warn "来源里有 ${n} 个任何人都可写的文件或目录，权限位按原样保留了"
        os::info "要收紧：chmod -R o-w ${EX_DEST_DIR}"
        return 0
    fi

    os::run '设置站点目录属主' -- chown -Rh www-data:www-data "${staging}" || return 1
    os::run '设置目录权限' -- find "${staging}" -type d -exec chmod 0755 {} + || return 1
    os::run '设置文件权限' -- \
        find "${staging}" -type f -not -name wp-config.php -exec chmod 0644 {} + || return 1
    if [[ -d ${staging}/wp-content ]]; then
        os::run '放宽 wp-content 目录权限' -- \
            find "${staging}/wp-content" -type d -exec chmod 0775 {} + || return 1
        os::run '放宽 wp-content 文件权限' -- \
            find "${staging}/wp-content" -type f -exec chmod 0664 {} + || return 1
    fi
    [[ -f ${staging}/wp-config.php ]] \
        && { os::run '收紧 wp-config.php 权限' -- chmod 0640 "${staging}/wp-config.php" || return 1; }
    return 0
}

# ex_keep_wp_config <staging>
#
# 不少备份出于安全不含 wp-config.php。整目录换过去之后站点就没有配置文件了，
# 现场是白屏 —— 而本机 deploy 出来的那份恰好是对的（库、账号、密码都是本机的）。
ex_keep_wp_config() {
    local staging=${1}
    [[ -n ${EX_SITE_TYPE} ]] || return 0
    [[ ! -f ${staging}/wp-config.php ]] || return 0

    if [[ -f ${EX_DEST_DIR}/wp-config.php ]]; then
        os::run '沿用本机现有的 wp-config.php' -- \
            cp -a "${EX_DEST_DIR}/wp-config.php" "${staging}/wp-config.php" || return 1
        os::ok '来源里没有 wp-config.php，沿用本机站点目录里的那份'
        return 0
    fi
    os::err '来源里没有 wp-config.php，本机站点目录里也没有 —— 导入后站点起不来'
    os::info "先跑 oneserver deploy wordpress 生成一份，再导入"
    return 1
}

# import_files   外部来源的文件落地。顺序见函数体，失败点与退路见文件头第六点。
import_files() {
    local ts
    printf -v ts '%(%Y%m%d-%H%M%S)T' -1
    local parent=${EX_DEST_DIR%/*}
    [[ -n ${parent} ]] || parent='/'
    local base=${EX_DEST_DIR##*/}

    # 落点父目录在本机可能根本不存在（path: 指向一个全新的位置）。
    # 0755 而不是 umask 027 给的 0750：站点父目录必须让 www-data 进得去。
    # 归「必须回滚」：撤销用 rmdir 不是 rm -rf —— 后面真失败时目录里已经有内容了，
    # rmdir 会失败并把它留下，这是对的。
    if [[ ! -d ${parent} ]]; then
        os::run '创建恢复目标的父目录' -- mkdir -p "${parent}" || return 1
        os::defer rmdir -- "${parent}"
        os::run '确保恢复目标的父目录可进入' -- chmod 0755 "${parent}" || return 1
    fi

    # 单个文件：没有清单、没有站点根，直接换掉
    if [[ ${EX_KIND} == file ]]; then
        stash_current "${EX_DEST_DIR}" "${base}-${ts}" || return 1
        os::run '放入文件' -- cp -a "${EX_SRC_FILES}" "${EX_DEST_DIR}" || return 1
        os::ok "已导入 ${EX_DEST_DIR}"
        return 0
    fi

    # staging 必须与落点同一个文件系统，最后那步 mv 才是改名而不是拷贝
    local staging="${parent}/.oneserver-import-${ts}"
    os::run '创建暂存目录' -- mkdir -p "${staging}" || return 1
    os::defer rm -rf -- "${staging}"
    os::run '收紧暂存目录权限' -- chmod 0700 "${staging}" || return 1

    ex_unpack "${staging}" || return 1
    # **解包后再在文件系统上审一遍**，不只靠解包前那次文本审查。
    # ex_read_members 是按 `tar -tvf` 的人读格式解析的：文件名含空格、换行或
    # ` -> ` 时会被截短或拆行，于是 ex_audit_members 看到的是一个安全的名字、
    # 而 tar 解出来的是完整的那个。这一遍看的是真实 inode（类型、链接数、
    # 特权位、链接目标），文本怎么写都绕不过去。
    # ex_apply_ownership 随后会整体改属主，硬链接同样是硬失败
    rs_audit_tree "${staging}" yes || return 1
    ex_audit_symlinks "${staging}" || return 1
    ex_apply_ownership "${staging}" || return 1
    ex_keep_wp_config "${staging}" || return 1

    stash_current "${EX_DEST_DIR}" "${base}-${ts}" || return 1
    os::run '就位导入的内容' -- mv "${staging}" "${EX_DEST_DIR}" || return 1
    os::ok "文件已导入 ${EX_DEST_DIR}"
    return 0
}

# ex_preview <落点标识>   动手之前把结论摆出来
ex_preview() {
    local target=${1}
    os::section '这次要导入什么'

    local -a kv=()
    [[ -n ${EX_SRC_FILES} ]] && kv+=('文件来源' "${EX_SRC_FILES}")
    if [[ -n ${EX_SRC_FILES} && ${EX_KIND} != file ]]; then
        kv+=('来源内的根' "${EX_ROOT:-（整份来源）}" '解包后约' "$((EX_SIZE_KB / 1024)) MB")
    fi
    [[ -n ${EX_SRC_SQL} ]] && kv+=('SQL 转储' "${EX_SRC_SQL}")
    kv+=('恢复目标' "${target}")
    [[ -n ${EX_DEST_DIR} ]] && kv+=('恢复目录' "${EX_DEST_DIR}")
    [[ -n ${EX_DEST_DB} ]] && kv+=('恢复数据库' "${EX_DEST_DB}")
    os::kv "${kv[@]}"

    # 路径打错一个字母就会静静地建出一个新目录，导入「成功」而站点纹丝不动。
    # 在确认之前把这件事说出来，是唯一能拦住它的时机。
    if [[ -n ${EX_DEST_DIR} && ! -e ${EX_DEST_DIR} ]]; then
        os::warn "恢复目标 ${EX_DEST_DIR} 当前不存在，导入时会新建它 —— 路径没写错吧？"
    fi

    if [[ -n ${EX_SRC_FILES} && ${EX_KIND} != file ]]; then
        local m rel tops='' prefix=''
        local -i n=0
        local -A seen=()
        [[ -n ${EX_ROOT} ]] && prefix="${EX_ROOT}/"
        while IFS= read -r m; do
            [[ -z ${prefix} || ${m} == "${prefix}"* ]] || continue
            rel=${m#"${prefix}"}
            rel=${rel%%/*}
            # 空下标是 bash 关联数组的硬错误，先挡住再查重
            [[ -n ${rel} ]] || continue
            [[ -z ${seen["${rel}"]:-} ]] || continue
            seen["${rel}"]=1
            n=$((n + 1))
            [[ ${n} -le 12 ]] && tops+="${rel} · "
        done <<<"${EX_MEMBERS}"
        os::kv '将解出' "${tops% · }（共 ${n} 个顶层项）"
    fi

    if [[ -n ${EX_SRC_SQL} ]]; then
        if [[ -z ${EX_SQL_CHARSET} ]]; then
            os::warn "转储里没有字符集声明，将按 ${OS_DEFAULT_DB_CHARSET} 导入"
            os::info '原库是 gbk / latin1 的话先用 iconv 转成 UTF-8，否则导进来是乱码'
        elif [[ ${EX_SQL_CHARSET} != "${OS_DEFAULT_DB_CHARSET}" ]]; then
            os::info "转储声明的字符集是 ${EX_SQL_CHARSET}，本机默认是 ${OS_DEFAULT_DB_CHARSET}"
            os::info '按转储声明的走（mysql 会执行 dump 里的 SET NAMES），这里只是说明一声'
        fi
    fi

    if [[ -n ${EX_SQL_HITS} ]]; then
        os::warn '转储里有库级语句，它们会让数据写进转储自己指定的库，而 mysql 仍以 0 退出：'
        local line
        while IFS= read -r line; do
            [[ -n ${line} ]] && os::info "  ${line}"
        done <<<"${EX_SQL_HITS}"
    fi
    return 0
}

# import_external   `--from=external` 的完整流程
import_external() {
    local spec=''
    os::ask --validate ex_split_source \
        --hint '压缩包 .tar/.tar.gz/.tgz/.zip · 已解开的目录 · 单个文件 · 转储 .sql/.sql.gz；两者可用逗号一次给全' \
        --arg source '外部备份的路径' spec ''

    local target=''
    os::ask --validate ex_resolve_dest \
        --hint 'site:<站点名> 整站 · db:<库名> 只灌库 · path:<别名或绝对路径> 任意目录或文件' \
        --arg target '导入到哪里' target ''

    # 来源与落点要配得上
    [[ -z ${EX_SRC_SQL} || -n ${EX_DEST_DB} ]] \
        || os::die 2 "恢复目标 ${target} 没有数据库，SQL 转储无处可灌"
    [[ -z ${EX_SRC_FILES} || -n ${EX_DEST_DIR} ]] \
        || os::die 2 "恢复目标 ${target} 只有数据库，文件来源无处可放"

    # 单个文件落到一个已经存在的目录上：现有做法会把整个目录挪进 pre-restore、
    # 再放一个文件进去，而用户十有八九想的是「放进这个目录里」。
    # **这种破坏性歧义不猜**，让他把话说全。
    if [[ ${EX_KIND} == 'file' && -d ${EX_DEST_DIR} ]]; then
        os::err "恢复目标 ${EX_DEST_DIR} 是一个已存在的目录，而来源是单个文件"
        os::die 2 "把恢复目标写成完整的文件路径，例如：--target=path:${EX_DEST_DIR}/${EX_SRC_FILES##*/}"
    fi

    if [[ -n ${EX_SRC_FILES} && ${EX_KIND} != 'file' ]]; then
        # 先把来源读出来、审查完，再问子路径 —— 反过来的话，一个根本读不开的
        # 压缩包会让用户先白答一道题
        ex_read_members || os::die 1 '读不出来源清单，未做任何改动'
        ex_audit_members || os::die 1 '来源清单未通过审查，未做任何改动'
        local subdir=''
        os::ask --arg subdir \
            '来源里哪一层是要导入的内容？（多数情况直接回车，让它自己找）' subdir ''
        ex_locate_root "${subdir}" || os::die 2 '定位不出要导入的内容，未做任何改动'
        ex_check_space || os::die 1 '空间不够，未做任何改动'
    fi

    [[ -z ${EX_SRC_SQL} ]] || sql_scan "${EX_SRC_SQL}" || os::die 1 '读不出 SQL 转储，未做任何改动'

    # 与归档那条路同一个判断、同一个函数：改不了配置就别开始。
    # 条件与下面真正调用 fixup_credentials 的那一处一致 —— 只灌库不换文件时
    # 站点目录里的配置本来就是本机的，没有要对齐的东西
    [[ -z ${EX_SITE_TYPE} || -z ${EX_SRC_FILES} ]] \
        || fixup_credentials --check "${EX_SITE_TYPE}" "${EX_SITE_NAME}" \
        || os::die 3 '恢复目标站点的凭据不全，未做任何改动'

    local site_url=''
    if [[ -n ${EX_SITE_TYPE} ]]; then
        os::ask --match '^$|^https?://[^[:space:]]+$' \
            --hint '迁移后仍使用原地址就留空' \
            --arg site-url '站点的新地址（含 http:// 或 https://；留空则保留备份中的地址）' site_url ''
    fi

    ex_preview "${target}"

    if [[ -n ${EX_SQL_HITS} ]]; then
        if os::confirm --arg strip-db-statements \
            '把上面这些语句剥离后导入？（只在导入管道里跳过，不改动你的原文件）' n; then
            EX_STRIP=1
        else
            os::die 2 '已停止，未做任何改动。留着这些语句导入，数据会进转储里写的那个库'
        fi
    fi

    local -a items=()
    [[ -n ${EX_SRC_SQL} ]] \
        && items+=("数据库 ${EX_DEST_DB} 的现有内容将被 ${EX_SRC_SQL##*/} 覆盖（会先自动备一份）")
    [[ -n ${EX_SRC_FILES} ]] \
        && items+=("${EX_DEST_DIR} 将被 ${EX_SRC_FILES##*/} 的内容替换（会先整个挪到 ${RS_PRE_DIR}）")
    # 改配置也是覆盖，与归档那条路同一条纪律：按确认之前必须看得见
    [[ -z ${EX_SITE_TYPE} || -z ${EX_SRC_FILES} ]] \
        || items+=("${EX_DEST_DIR}/wp-config.php 里的数据库与缓存配置（改成本机 ${EX_SITE_NAME} 的值）")
    [[ -n ${site_url} ]] \
        && items+=("${EX_DEST_DB} 里的 siteurl 与 home 将改为 ${site_url}")
    # 三道门在这条路上不存在，这件事必须让人在按下确认之前看见
    items+=('这份备份没有 sha256、没有 manifest —— 它是否完整、是否被人动过，只有你自己知道')

    if ! os::destroy_confirm --arg confirm-restore "${target}" -- "${items[@]}"; then
        os::info '已取消，未做任何改动'
        os::output 0 changed=no
        return 0
    fi

    os::critical_begin '导入外部备份'
    local rc=0
    if [[ -n ${EX_SRC_SQL} ]]; then
        restore_db "${EX_DEST_DB}" "${EX_SRC_SQL}" "${EX_STRIP}" || rc=1
    fi
    if [[ ${rc} -eq 0 && -n ${EX_SRC_FILES} ]]; then
        import_files || rc=1
    fi
    # 凭据以活系统为准：外来 wp-config 里是源站的库名账号密码，本机是另一套
    if [[ ${rc} -eq 0 && -n ${EX_SITE_TYPE} && -n ${EX_SRC_FILES} ]]; then
        fixup_credentials "${EX_SITE_TYPE}" "${EX_SITE_NAME}" "${EX_DEST_DIR}" || rc=1
    fi
    if [[ ${rc} -eq 0 && -n ${site_url} ]]; then
        set_site_url "${EX_DEST_DIR}/wp-config.php" "${EX_DEST_DB}" "${site_url}" || rc=1
    fi
    os::critical_end

    if [[ ${rc} -ne 0 ]]; then
        os::output 1 target="${target}"
        os::die 1 "导入未完成。覆盖前的副本在 ${RS_PRE_DIR}"
    fi

    # 灌过库的站点一律核对前缀。**这一步不能因为「导入成功了」就省掉** ——
    # 前缀对不上时前面每一步都会报成功，只有打开站点才看得出来
    [[ -z ${EX_SITE_TYPE} || -z ${EX_SRC_SQL} ]] \
        || ex_check_prefix "${EX_DEST_DIR}/wp-config.php" "${EX_DEST_DB}"

    os::ok "导入完成：${target}"
    [[ ${RS_PRE_CREATED} -eq 0 ]] \
        || os::info "覆盖前的副本留在 ${RS_PRE_DIR}，确认站点正常后可以自行清理"
    post_restore_hints "${EX_SITE_TYPE}"
    os::output 0 target="${target}" source="${EX_SRC_FILES:-${EX_SRC_SQL}}" changed=yes
    return 0
}

# ==================================================================
# 落点 —— 归档这条路
# ==================================================================

# rs_site_dest_candidates   本机现有的站点，一行一个 `site:<名字>=<说明>`
#
# 认站点的判据与 backup.sh 的 bk_sites 同源（类型在 OS_DEFAULT_BACKUP_SITE_TYPES
# 里、state 中有 path 键）——**能被备份的就该能被恢复到**，两边判据分叉的表现是
# 某个站点备得出来却选不上作落点。
rs_site_dest_candidates() {
    RS_ENTRIES=''
    local -a types=()
    local IFS=$', \t\n'
    read -ra types <<<"${OS_DEFAULT_BACKUP_SITE_TYPES}"
    IFS=$'\n\t'

    local type id n path db entries_text=''
    for type in ${types[@]+"${types[@]}"}; do
        [[ -n ${type} ]] || continue
        while IFS= read -r id; do
            [[ -n ${id} ]] || continue
            n=${id#*:}
            path=$(os::state_get "${id}" path)
            [[ -n ${path} ]] || continue
            db=$(os::state_get "${id}" db)
            entries_text+="site:${n}=本机站点 ${n}（库 ${db:-（无）} · 目录 ${path}）"$'\n'
        done < <(os::state_list "${type}")
    done
    RS_ENTRIES=${entries_text%$'\n'}
    [[ -n ${RS_ENTRIES} ]]
}

# rs_db_dest_candidates   除归档原库外，本机现有的用户数据库。
#
# 第一层菜单只显示「按原名恢复 / 覆盖本机数据库」两项；真正的库清单放到用户选中
# 第二项之后，避免十几个库把第一层选择淹没。系统库永远不列。
rs_db_dest_candidates() {
    RS_ENTRIES=''
    os::require_cmd mysql
    os::sql_query '列出可用的恢复数据库' -- \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys')
         ORDER BY schema_name;" || return 1

    local name entries_text=''
    while IFS= read -r name; do
        [[ -n ${name} && ${name} != "${RS_MF_DB}" ]] || continue
        valid_db_name "${name}" || continue
        entries_text+="db:${name}=${name}"$'\n'
    done <<<"${OS_RUN_OUTPUT}"
    RS_ENTRIES=${entries_text%$'\n'}
    [[ -n ${RS_ENTRIES} ]]
}

# rs_path_dest_candidates   已登记的路径落点，不含与归档原路径完全相同的那项。
rs_path_dest_candidates() {
    RS_ENTRIES=''
    local id name path entries_text=''
    while IFS= read -r id; do
        [[ -n ${id} ]] || continue
        name=${id#*:}
        path=$(os::state_get "${id}" source)
        [[ -n ${path} && ${path} != "${RS_MF_SOURCE}" ]] || continue
        entries_text+="path:${name}=${name}（${path}）"$'\n'
    done < <(os::state_list backup-path)
    RS_ENTRIES=${entries_text%$'\n'}
    [[ -n ${RS_ENTRIES} ]]
}

# rs_remove_created_database <库名>   失败时撤销 rs_create_database 的完整产物。
#
# 创建是通过项目命令完成的，撤销也必须通过项目命令：这样库、账号、凭据与 state
# 仍由数据库管理的一份逻辑处理。删除命令会先为可能已经部分导入的数据留快照。
# 回滚发生时父进程通常重新持有全局锁，先释放，否则子命令会等自己超时。
rs_remove_created_database() {
    local db=${1}
    local -i held=${OS_LOCK_HELD} rc=0
    os::lock_release
    "${OS_BIN_DIR}/oneserver" mariadb delete \
        "--name=${db}" "--confirm-drop=${db}" \
        --force-destroy --non-interactive --output=json \
        >/dev/null 2>&1 || rc=$?
    if [[ ${held} -eq 1 ]]; then
        os::lock_acquire --try "${OS_DEFAULT_LOCK_WAIT}" || return 1
    fi
    return "${rc}"
}

# 调项目自己的数据库创建命令。父进程持着全局锁，直接派发会让子进程等锁超时，
# 所以只在这条受控边界暂时释放；子命令结束后无论成功失败都先重新取锁。
rs_create_database() {
    local db=${1}
    [[ ${RS_DEST_DB_CREATE} -eq 1 ]] || return 0

    os::info "数据库 ${db} 不存在，先通过数据库管理创建数据库与账号"
    # 创建命令走它自己的完整校验、凭据与 state 流程；这里显式采用那条命令的
    # 安全默认值（同名账号、仅 localhost、自动密码），避免把子命令的交互提示
    # 重定向进 run_out 日志后形成一个屏幕上看不见的等待点。
    local -a cmd=(
        "${OS_BIN_DIR}/oneserver" mariadb create
        "--name=${db}" "--user=${db}"
        --allow-any-host=n --auto-password=y
        --non-interactive --output=json
    )

    os::lock_release
    local -i rc=0
    os::run_out --allow-fail '通过数据库管理创建恢复目标' -- "${cmd[@]}" || rc=$?
    local -i skipped=${OS_RUN_SKIPPED}
    # 子命令已经成功，此刻即使重新取锁失败，父进程的 EXIT trap 也必须知道系统
    # 发生了什么并能撤销。登记不能放到 lock_acquire 之后。
    if [[ ${rc} -eq 0 && ${skipped} -ne 1 ]]; then
        os::record_change "通过数据库管理创建了恢复目标 db:${db}"
        os::defer rs_remove_created_database "${db}"
    fi
    os::lock_acquire

    [[ ${rc} -eq 0 ]] || {
        os::err "数据库管理未能创建 ${db}，恢复尚未开始"
        return 1
    }
    if [[ ${skipped} -eq 1 ]]; then
        os::info "[dry-run] 将通过 oneserver mariadb create --name=${db} 创建恢复目标"
        return 0
    fi
    ex_db_exists "${db}" || {
        os::err "数据库创建命令结束后仍找不到 ${db}，恢复尚未开始"
        return 1
    }
    os::ok "数据库 ${db} 与关联账号已由数据库管理创建"
    return 0
}

# rs_plan_dest   定这次恢复往哪写，结果落在 EX_DEST_* / EX_SITE_*
#
# 见文件头第七点：manifest 说得出归档是什么，说不出这台机器上该往哪写。
# 落点解析与外部导入共用 `ex_resolve_dest`，唯一的例外写在函数体里。
rs_plan_dest() {
    local self="${RS_MF_TYPE}:${RS_MF_NAME}"
    local -i self_ok=1
    RS_DEST_DB_CREATE=0

    # 站点归档：归档自身的落点只有在本机**完全成立**时才算数 —— 站点在 state 里、
    # 库名与目录都对得上。差一项就说明本机这个站与归档讲的不是同一个东西，
    # 照 manifest 写的结果是一套谁也用不到的孤儿库与孤儿目录，而每一步都报成功。
    if [[ ${RS_MF_TYPE} == site ]]; then
        # site_type 缺失的归档（字段是后加的）说不出自己是哪一类站点，
        # 也就无从和 state 里的实例对上号 —— 这种归档没有「自身落点」可言，
        # 一律让人显式指一个，而不是拿一个猜出来的类型去查 state
        if [[ -n ${RS_MF_SITE_TYPE} ]] && os::state_has "${RS_MF_SITE_TYPE}:${RS_MF_NAME}"; then
            local sdb spath
            sdb=$(os::state_get "${RS_MF_SITE_TYPE}:${RS_MF_NAME}" db)
            spath=$(os::state_get "${RS_MF_SITE_TYPE}:${RS_MF_NAME}" path)
            if [[ ${sdb} != "${RS_MF_DB}" || ${spath} != "${RS_MF_SOURCE}" ]]; then
                self_ok=0
                os::warn "本机站点 ${RS_MF_NAME} 与备份记录对不上"
                os::kv '本机' "库 ${sdb:-（无）} · 目录 ${spath}" \
                    '备份' "库 ${RS_MF_DB:-（无）} · 目录 ${RS_MF_SOURCE:-（无）}"
            fi
        elif [[ -z ${RS_MF_SITE_TYPE} ]]; then
            self_ok=0
            os::warn "这份备份没有记录站点类型，对不上本机的任何站点"
        else
            self_ok=0
            os::warn "本机没有登记站点 ${RS_MF_NAME}（这份备份属于 ${self}）"
            os::info '按备份中记录的位置恢复，只会建出一套与本机任何站点都无关的库和目录，站点不会因此运行'
        fi
    fi

    local -a opts=() nested=()
    local line dest_prompt='恢复到哪里'
    case ${RS_MF_TYPE} in
        site)
            dest_prompt='恢复到哪个本机站点'
            [[ ${self_ok} -eq 0 ]] \
                || opts+=("${self}=本机同名站点 ${RS_MF_NAME}（库 ${RS_MF_DB:-（无）} · 目录 ${RS_MF_SOURCE:-（无）}）")
            if rs_site_dest_candidates; then
                while IFS= read -r line; do
                    [[ -n ${line} ]] || continue
                    # 自身那一项已经在首位时不再重复；不成立时仍列本机那一项，
                    # 让用户明确选择本机真实的库与目录。
                    [[ ${line%%=*} != "${self}" || ${self_ok} -eq 0 ]] || continue
                    opts+=("${line}")
                done <<<"${RS_ENTRIES}"
            fi
            ;;
        db)
            dest_prompt='恢复到哪个数据库'
            [[ -n ${RS_MF_DB} ]] || {
                os::err '数据库备份的信息里没有数据库名'
                return 1
            }
            os::require_cmd mysql
            if ex_db_exists "${RS_MF_DB}"; then
                opts+=("${self}=本机同名数据库 ${RS_MF_DB}（覆盖现有内容）")
            else
                opts+=("${self}=本机同名数据库 ${RS_MF_DB}（将新建）")
                RS_DEST_DB_CREATE=1
            fi
            if rs_db_dest_candidates; then
                while IFS= read -r line; do
                    [[ -n ${line} ]] && nested+=("${line}")
                done <<<"${RS_ENTRIES}"
                [[ ${#nested[@]} -eq 0 ]] || opts+=('__pick_db__=本机其他数据库（下一步选择）')
            fi
            ;;
        path)
            dest_prompt='恢复到哪个路径'
            [[ -n ${RS_MF_SOURCE} ]] || {
                os::err '路径备份的信息里没有源路径'
                return 1
            }
            opts+=("${self}=备份中记录的路径 ${RS_MF_SOURCE}")
            if rs_path_dest_candidates; then
                while IFS= read -r line; do
                    [[ -n ${line} ]] && nested+=("${line}")
                done <<<"${RS_ENTRIES}"
                [[ ${#nested[@]} -eq 0 ]] || opts+=('__pick_path__=本机其他已登记路径（下一步选择）')
            fi
            ;;
        *)
            os::err "备份类型 ${RS_MF_TYPE} 没有可用的恢复目标"
            return 1
            ;;
    esac
    [[ ${#opts[@]} -gt 0 ]] || {
        os::err '本机没有任何可用的恢复目标'
        return 1
    }
    [[ ${#opts[@]} -gt 1 ]] || os::info '只有下面这一项可选'

    # 自身落点成立时它是首项，非交互下取首项即「原样恢复」，是安全的默认。
    # 不成立时**没有**安全默认：非交互下必须以 2 停下，绝不能替用户从清单里
    # 挑一个站点覆盖掉 —— 那是不可逆的，而他压根没提过这个站的名字。
    local -a req=()
    [[ ${self_ok} -eq 1 ]] || req=(--required)
    local into=''
    os::select ${req[@]+"${req[@]}"} --arg into "${dest_prompt}" into "${opts[@]}"
    if [[ ${into} == __pick_db__ ]]; then
        os::select --reask --required --arg into '选择要覆盖的本机数据库' into "${nested[@]}"
    elif [[ ${into} == __pick_path__ ]]; then
        os::select --reask --required --arg into '选择要恢复到的本机路径' into "${nested[@]}"
    fi
    EX_DEST_SPEC=${into}

    # `db:` 与 `path:` 归档的原样恢复不走 ex_resolve_dest：那边要求库或路径别名
    # 事先存在，而这类归档在一台干净机器上恢复时，库与目录本来就该由本次恢复
    # 建出来 —— 「换台机器重建」正是备份存在的理由。站点归档没有这个例外，
    # 它的落点身份必须来自 state，否则凭据无从对齐。
    if [[ ${into} == "${self}" && ${self_ok} -eq 1 && ${RS_MF_TYPE} != site ]]; then
        EX_DEST_DB=${RS_MF_DB}
        EX_DEST_DIR=${RS_MF_SOURCE}
        return 0
    fi
    # 命令行显式 `--into=db:<归档原名>` 与交互第一项语义相同：干净机器上同样
    # 允许创建，且仍必须走数据库管理命令。
    if [[ ${RS_MF_TYPE} == db && ${into} == "db:${RS_MF_DB}" ]]; then
        EX_DEST_DB=${RS_MF_DB}
        [[ ${RS_DEST_DB_CREATE} -eq 1 ]] || ex_db_exists "${RS_MF_DB}" || RS_DEST_DB_CREATE=1
        return 0
    fi
    [[ ${RS_MF_TYPE} != db ]] || RS_DEST_DB_CREATE=0
    # 到这里的失败是 `--into`/交互选择本身无效，不是「机器缺依赖」。交给 main
    # 保留退出码 2；没有任何候选落点的那条分支仍返回 1，并由 main 映射成 3。
    ex_resolve_dest "${into}" || return 2
    return 0
}

# ==================================================================

main() {
    os::require_cmd tar gzip sha256sum find

    local from=''
    os::select --arg from '选择备份来源' from \
        'local=本机备份' 'remote=rclone 远端备份' 'external=外部备份（从其他工具或主机迁入）'
    case ${from} in
        local | remote | external) ;;
        *) os::die 2 "--from 只能是 local / remote / external，收到「${from}」" ;;
    esac

    # 外来备份过不了下面那三道门（sha256 / manifest / schema），走自己的前段；
    # 写入动作仍然落回同一批函数，理由见文件头第六点
    if [[ ${from} == external ]]; then
        import_external
        return $?
    fi

    # --- 1. 选目标 ---
    if [[ ${from} == remote ]]; then
        load_remote || os::die 3 '还没有配置远端，先跑 oneserver backup remote'
        remote_targets || os::die 3 "远端 ${RS_REMOTE}:${RS_REMOTE_DIR} 下没有任何备份"
    else
        local_targets || os::die 3 "本机没有任何备份（${OS_ARCHIVE_DIR}）"
    fi

    local -a targets=()
    mapfile -t targets <<<"${RS_ENTRIES}"
    local target=''
    os::select --arg target '选择要恢复的备份项目' target "${targets[@]}"

    local ok=''
    local t
    for t in "${targets[@]}"; do
        [[ ${t} == "${target}" ]] && ok=1
    done
    [[ -n ${ok} ]] || {
        local IFS=' '
        os::die 2 "没有这个备份项目：${target}（可用：${targets[*]}）"
    }
    local type=${target%%:*} name=${target#*:}

    # --- 2. 选归档 ---
    if [[ ${from} == remote ]]; then
        remote_archives "${type}" "${name}" || os::die 3 "远端 ${target} 下没有备份"
    else
        local_archives "${type}" "${name}" || os::die 3 "本机 ${target} 下没有备份"
    fi
    local -a archives=()
    mapfile -t archives <<<"${RS_ENTRIES}"

    # **把每一份都列出来，带上时间与大小。** 原来只问一句「共 N 份」再给个
    # 默认值，另外几份长什么样、多大、什么时候的，用户一个都看不见。
    #
    # 顺带说清「为什么只有这么几份」：份数是保留策略的结果，不是 bug ——
    # 备了十次却只看到两份的人，第一反应必然是工具出错了。
    local keep
    keep=$(os::state_get backup local_keep "${OS_DEFAULT_BACKUP_LOCAL_KEEP}")
    [[ ${from} == remote ]] \
        && keep=$(os::state_get backup remote_keep "${OS_DEFAULT_BACKUP_REMOTE_KEEP}")
    os::info "共 ${#archives[@]} 份（保留策略是 ${keep} 份，更早的已按策略清理）"

    local -a choices=()
    local t desc
    for t in "${archives[@]}"; do
        desc=$(archive_desc "${from}" "${type}" "${name}" "${t}")
        choices+=("${t}=${desc}")
    done
    # 选项天然只收清单里的值，填错原地重问；非交互下取第一项，也就是最新那份
    local file=''
    os::select --arg file '选择备份版本（最新的在前）' file "${choices[@]}"

    # --- 3. 取回 + 校验 + 读 manifest ---
    fetch_archive "${from}" "${type}" "${name}" "${file}" || os::die 1 '取回备份失败'
    verify_archive "${RS_ARCHIVE}" || os::die 1 '备份校验未通过，未做任何改动'
    # **说清这次校验证明了什么、没证明什么。** `.sha256` 与归档来自同一个地方，
    # 能改归档的人同样能改那个哈希 —— 它保证的是「传输过程中没坏」，不是
    # 「内容可信」。挡住恶意归档的是解包时那道成员审查，不是这一步。
    [[ ${from} == local ]] \
        || os::warn '注意：校验用的 .sha256 与备份来自同一个远端，它只证明传输完整，不证明内容可信'
    read_manifest "${RS_ARCHIVE}" || os::die 1 '读不出备份信息，未做任何改动'

    os::section '这份备份的信息'
    os::kv '备份项目' "${RS_MF_TYPE}:${RS_MF_NAME}" \
        '生成于' "${RS_MF_CREATED}" \
        '来自主机' "${RS_MF_HOST}" \
        '源路径' "${RS_MF_SOURCE:-（无文件）}" \
        '数据库' "${RS_MF_DB:-（无）}"

    # 归档的自我声明与「用户挑的是哪个目录」不一致时停下：多半是目录被人手工
    # 挪过归档，按 manifest 恢复会写到一个用户没预期的地方
    if [[ ${RS_MF_TYPE} != "${type}" || ${RS_MF_NAME} != "${name}" ]]; then
        os::warn "备份记录的项目是 ${RS_MF_TYPE}:${RS_MF_NAME}，但文件位于 ${target} 下"
        os::info '以 manifest 为准继续，源路径见上'
    fi

    # --- 4. oneserver:self 走单独一条路 ---
    if [[ ${RS_MF_TYPE} == oneserver ]]; then
        restore_self "${RS_ARCHIVE}" "${RS_MF_ROOT}"
        return 0
    fi

    # --- 5. 定落点 ---
    #
    # **在选模式之前**：模式选项取决于「归档里有什么」与「落点接得住什么」
    # 两件事，而后者到这一步才知道。
    local -i dest_rc=0
    rs_plan_dest || dest_rc=$?
    case ${dest_rc} in
        0) ;;
        2) os::die 2 '指定的恢复目标无效，未做任何改动' ;;
        *) os::die 3 '无法确定恢复目标，未做任何改动' ;;
    esac

    # --- 6. 选模式 ---
    #
    # **选项按这份归档里真有什么、落点又接得住什么来给。** 原来三个选项固定
    # 摆着，而一份只有库的归档选「仅文件」的下场是当场报错退出 —— 把一个工具
    # 自己知道不成立的选择摆到人面前，等他选错再纠正他。
    local -a modes=()
    [[ -n ${RS_MF_DB} && -n ${EX_DEST_DB} && -n ${RS_MF_ROOT} && -n ${EX_DEST_DIR} ]] \
        && modes+=('all=数据库与文件')
    [[ -n ${RS_MF_DB} && -n ${EX_DEST_DB} ]] && modes+=('db=仅数据库')
    [[ -n ${RS_MF_ROOT} && -n ${EX_DEST_DIR} ]] && modes+=('files=仅文件')
    [[ ${#modes[@]} -gt 0 ]] \
        || os::die 3 '这份备份的内容与恢复目标对不上（备份只有数据库而目标只有目录，或者反过来）'
    [[ ${#modes[@]} -gt 1 ]] || os::info '当前只有下面这一种恢复内容可选'

    local mode=''
    # os::select 天然只收清单里的值：填错原地重问，命令行给错的值以 2 停下。
    # 因此这里不需要再补一遍「mode 是不是合法」的判断。
    os::select --arg mode '选择要恢复的内容' mode "${modes[@]}"

    local only=''
    if [[ ${mode} != db ]]; then
        os::ask --arg only '只恢复备份中的某个子路径（留空 = 整份，例：wp-content/uploads）' only ''
    fi
    # 库整份回到备份那一刻、文件只回一段，两边讲的就不是同一个时间点的事了。
    # 典型后果：文章在库里存在，附件却还是现在这份（或者反过来）。
    if [[ ${mode} == all && -n ${only} ]]; then
        os::warn "数据库会整份恢复，而文件只恢复 ${only} 这一段 —— 两边可能对不上"
        os::info '只想回滚一部分文件、不动数据库的话，选「仅文件」（--mode=files）'
    fi

    # 归档里的库带着**备份那一刻的域名**。换机器恢复十有八九连域名一起换，
    # 而 siteurl / home 不改的话，浏览器打开就被 301 到旧域名去 —— 站点看起来
    # 「恢复了但打不开」。外部导入一直问这一句，归档这条路才是跨机迁移的主入口，
    # 更不该少。只在库确实要被恢复、且落点是站点时问：其余情况没有要改的东西。
    local site_url=''
    if [[ -n ${EX_SITE_TYPE} && ${mode} != files ]]; then
        os::ask --match '^$|^https?://[^[:space:]]+$' \
            --hint '迁移后仍使用原地址就留空' \
            --arg site-url '站点的新地址（含 http:// 或 https://；留空则保留备份中的地址）' site_url ''
    fi

    # 这次会不会改配置，到这里才定得下来。完整文件恢复一定覆盖 wp-config；
    # 部分恢复通常不碰它，但 `--only=wp-config.php` 是明确例外，不能因为走了
    # `--only` 就把源机器凭据原样留在落点。要改就先确认改得成：凭据齐不齐在
    # **动手之前**就问得出来，
    # 留到恢复完再补一句警告的话，那时库已经重建、文件已经就位
    local fixup=0
    local only_path=${only#/}
    only_path=${only_path#./}
    only_path=${only_path%/}
    if [[ ${mode} != db && -n ${EX_SITE_TYPE} ]] \
        && [[ -z ${only} || ${only_path} == wp-config.php ]]; then
        fixup=1
    fi
    [[ ${fixup} -eq 0 ]] \
        || fixup_credentials --check "${EX_SITE_TYPE}" "${EX_SITE_NAME}" \
        || os::die 3 '恢复目标站点的凭据不全，未做任何改动'

    # --- 7. 确认。覆盖是不可逆的，走规范那一套 ---
    #
    # **清单里写的是落点，不是归档里那两个名字。** 归档自称什么已经在上面
    # 「这份备份的信息」里说过了；这里回答的是唯一要紧的那个问题：
    # 按下确认之后，这台机器上的哪个库、哪个目录会没。
    local -a items=()
    if [[ ${mode} == all || ${mode} == db ]] && [[ -n ${EX_DEST_DB} ]]; then
        if [[ ${RS_DEST_DB_CREATE} -eq 1 ]]; then
            items+=("通过数据库管理创建数据库 ${EX_DEST_DB} 与关联账号，再导入备份数据")
        else
            items+=("数据库 ${EX_DEST_DB} 的当前内容（会先自动备一份）")
        fi
    fi
    if [[ ${mode} == all || ${mode} == files ]] && [[ -n ${EX_DEST_DIR} ]]; then
        if [[ -n ${only} ]]; then
            items+=("目录 ${EX_DEST_DIR}/${only#/}（会先整个挪到 ${RS_PRE_DIR}）")
        else
            items+=("目录 ${EX_DEST_DIR}（会先整个挪到 ${RS_PRE_DIR}）")
        fi
    fi
    # 改配置同样是覆盖，同样要在按确认之前看得见 —— 它是恢复出来的站点能不能
    # 跑起来的那一步，不是收尾的小动作
    [[ ${fixup} -eq 0 ]] \
        || items+=("${EX_DEST_DIR}/wp-config.php 里的数据库与缓存配置（改成本机 ${EX_SITE_NAME} 的值）")
    [[ -z ${site_url} ]] \
        || items+=("${EX_DEST_DB} 里的 siteurl 与 home 将改为 ${site_url}")
    [[ ${#items[@]} -gt 0 ]] || os::die 2 '这个模式下没有任何可恢复的内容'

    # **确认串是落点，不是归档。** 让人照着打的那个名字必须指向即将被覆盖的
    # 东西 —— 换名恢复时打归档那个名字，等于为一件他没看清的事签字。
    # 同名回滚时两者本来就相同，`--confirm-restore` 的既有用法不受影响。
    if ! os::destroy_confirm --arg confirm-restore "${EX_DEST_SPEC}" -- "${items[@]}"; then
        os::info '已取消，未做任何改动'
        os::output 0 changed=no
        return 0
    fi

    # 创建数据库会暂时释放锁并启动独立的项目命令，不能放进不可中断区；同时
    # 必须在最终确认之后，避免用户只是浏览恢复选项就凭空多出一个数据库和账号。
    if [[ (${mode} == all || ${mode} == db) && ${RS_DEST_DB_CREATE} -eq 1 ]]; then
        rs_create_database "${EX_DEST_DB}" \
            || os::die 1 '创建数据库恢复目标失败，备份尚未导入'
    fi

    # --- 8. 解出内容并恢复 ---
    os::critical_begin '恢复数据'
    local rc=0
    if [[ ${mode} == all || ${mode} == db ]] && [[ -n ${EX_DEST_DB} ]]; then
        local dir
        os::tmpdir dir || os::die 1 '无法创建临时目录'
        os::query --timeout 3600 -- tar -xzf "${RS_ARCHIVE}" -C "${dir}" database.sql \
            || os::die 1 '备份中取不出 database.sql'
        restore_db "${EX_DEST_DB}" "${dir}/database.sql" 0 "${RS_DEST_DB_CREATE}" || rc=1
    fi
    if [[ ${rc} -eq 0 && (${mode} == all || ${mode} == files) ]] && [[ -n ${EX_DEST_DIR} ]]; then
        restore_files "${RS_ARCHIVE}" "${EX_DEST_DIR}" "${RS_MF_ROOT}" "${only}" || rc=1
        # 条件与上面那次 --check 完全一致：说了要改就一定改，改不成就是失败
        if [[ ${rc} -eq 0 && ${fixup} -eq 1 ]]; then
            fixup_credentials "${EX_SITE_TYPE}" "${EX_SITE_NAME}" "${EX_DEST_DIR}" || rc=1
        fi
    fi
    # 放在配置对齐之后：它要从 wp-config 读表前缀，而 mode=all 时那份文件
    # 这一步之前才刚落地。与外部导入同一个函数、同一个位置。
    if [[ ${rc} -eq 0 && -n ${site_url} ]]; then
        set_site_url "${EX_DEST_DIR}/wp-config.php" "${EX_DEST_DB}" "${site_url}" || rc=1
    fi
    os::critical_end

    if [[ ${rc} -ne 0 ]]; then
        os::output 1 target="${target}" mode="${mode}"
        if [[ ${RS_PRE_CREATED} -eq 1 ]]; then
            os::die 1 "恢复未完成。恢复前副本在 ${RS_PRE_DIR}"
        fi
        os::die 1 '恢复未完成；本次新建的恢复数据库将按已登记的回滚撤销'
    fi

    # 库来自归档、而文件这次没恢复（--mode=db）时，站点目录里的 wp-config
    # 仍是本机的那份，它的表前缀未必与归档里的库对得上
    [[ ${mode} != db || -z ${EX_SITE_TYPE} || -z ${EX_DEST_DIR} ]] \
        || ex_check_prefix "${EX_DEST_DIR}/wp-config.php" "${EX_DEST_DB}"

    # `target` 是这份归档的标识，不是落点 —— 落点由上面 restore_db 与
    # restore_files 各自报出实际写到了哪里，这里不重复一遍
    os::ok "恢复完成：${target}（${mode}）"
    [[ ${RS_PRE_CREATED} -eq 0 ]] \
        || os::info "恢复前的副本留在 ${RS_PRE_DIR}，确认站点正常后可以自行清理"
    post_restore_hints "${EX_SITE_TYPE}"
    os::output 0 target="${target}" mode="${mode}" archive="${file}" \
        dest_db="${EX_DEST_DB}" dest_dir="${EX_DEST_DIR}" changed=yes
    return 0
}

main "$@"
