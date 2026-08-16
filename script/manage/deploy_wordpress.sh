#!/bin/bash
#
# 部署一个 WordPress 站点
#
# @command      deploy wordpress
# @name         部署 WordPress
# @group        web
# @order        12
# @privilege    root
# @requires_lib >= 4.3
# @provides     wordpress:<name>
# @args         [--name=<站点名>] [--path=<目录>] [--db-name=<库名>] [--db-user=<账号>] [--auto-password=<y|n>] [--confirm-overwrite=<站点名>]
# @description  部署多站点共存的 WordPress，自动建库配权限
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# K7 —— 这个脚本存在的全部理由
#
# 旧脚本把站点目录写死成 `/var/www/wordpress`，把凭据写成全局单数 key
# （`DB_NAME` / `DB_USER` / `DB_PASS`）。于是**部署第二个站点会删掉第一个的
# 凭据并写入自己的**，此后 cron 备份改去备份第二个站点的数据库 ——
# **第一个站点从此没有备份，而且不会有任何提示**。
#
# 它是 `secure.sh` 命名空间与组件实例标识（D35）两条设计的**直接动因**：
# 同一个错误在两层各发生一次，凭据层用命名空间解决，组件层用实例标识解决。
#
# 所以这里每一样东西都带站点名：
#
#   目录       <OS_DEFAULT_WP_ROOT>/<站点名>
#   组件标识   wordpress:<站点名>
#   凭据 key   site.<站点名>.db_pass
#   数据库     wp_<站点名>（可覆盖），并同时登记成 db:<库名> 让 oneserver mariadb 看得到
#   缓存前缀   <站点名>: —— **同一个错误在缓存层的第三次**：两个站点共用一个
#              Valkey 而不分前缀，缓存键会互相覆盖，表现是「另一个站点的内容
#              串到这个站点上」，比没有缓存难查得多
#
# ## 下载为什么用国际版
#
# 见 lib/defaults.sh 里 OS_DEFAULT_WP_URL 的说明：本地化包没有 .sha1（实测
# 404），走它就等于放弃校验。国际版装完在安装向导第一步选中文，core 自己
# 会去拉语言包，结果一样而多了一层校验。
#
# ## wp-config.php 为什么是模板不是 sed
#
# 旧脚本靠 `grep -n` 找注释标记的行号、再 `sed` 按行号插入。WordPress 改一次
# 注释就会错位，而错位的表现是站点白屏。改成整份从模板落地。
#
# 盐也不再向 api.wordpress.org 要 —— 它们只需要「足够随机且此后不变」，
# 本地 openssl 就能给，少一个网络依赖、少一个失败点、少一方知道你的盐。

readonly WP_TEMPLATE='wp-config.php'

# 函数之间的返回通道，不用 $( )（D135）
WP_SALTS=''
WP_EXTRA=''

# ------------------------------------------------------------------

# 站点名同时要当目录名、数据库名的一部分、state 实例标识、Redis 前缀。
# 四套语法各有各的忌讳，取交集最省事（同 db_manager 的 valid_name）。
valid_name() {
    [[ ${1} =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# 库名与账号名的校验。单独一个函数是因为它要先把下划线换成短横再比 ——
# os::ask 的 --validate 拿到的是用户原样输入的值，转换只能发生在这里面
db_ident_valid() {
    valid_name "${1//_/-}"
}

# 账号是否已存在（与 db_manager.sh 的 user_exists 同一条查询）
user_exists() {
    local qu qh
    qu=$(os::sql_str "${1}")
    qh=$(os::sql_str "${2}")
    os::sql_query '检查账号是否存在' -- \
        "SELECT User FROM mysql.global_priv WHERE User = ${qu} AND Host = ${qh};" || return 1
    [[ -n ${OS_RUN_OUTPUT} ]]
}

# 库名与账号名：MariaDB 的账号名上限 32 字符，站点名长了要截。
# 截断规则写死在这里而不是让用户自己算 —— 但截完可能撞名，所以撞了就报错，
# 不悄悄加后缀（悄悄加后缀 = 用户看到的名字和实际的对不上）。
derive_db_name() {
    local name=${1}
    local out="wp_${name//-/_}"
    printf '%s' "${out:0:32}"
}

# 八个盐。**本地生成**：它们只是「足够随机且此后不变」的字符串。
# base64 里没有 `'` 也没有 `\`，直接放进 PHP 单引号字符串里是安全的 ——
# 这不是巧合，是选 base64 而不是任意字节的原因。
generate_salts() {
    local -a keys=(
        AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY
        AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT
    )
    local k v out=''
    for k in "${keys[@]}"; do
        os::query --timeout 10 -- openssl rand -base64 48 || return 1
        v=${OS_RUN_OUTPUT}
        [[ ${#v} -ge 32 ]] || return 1
        out+="define( '${k}', '${v}' );"$'\n'
    done
    WP_SALTS=${out%$'\n'}
    return 0
}

# wp-config.php 里 oneserver 附加的那一段。
#
# 缓存只在**真的装了而且拿得到密码**时才写：写了却连不上的话，
# WordPress 每个请求都要等一次连接超时，比不配缓存慢得多。
#
# 常量名仍是 `WP_REDIS_*`：Valkey 协议兼容，WordPress 那边的 Redis Object
# Cache 插件认的就是这几个名字，改成 WP_VALKEY_* 它一个都读不到。
build_extra() {
    local site=${1}
    local out=''
    out+="define( 'FS_METHOD', 'direct' );"$'\n'

    probe::component_version valkey
    if [[ -z ${OS_PROBE_VALUE} ]]; then
        os::info '未检测到 Valkey，wp-config 里不写缓存配置（装了之后重跑本命令即可加上）'
        WP_EXTRA=${out%$'\n'}
        return 0
    fi

    local rpass=''
    if ! os::secure_load valkey.password rpass; then
        os::warn 'Valkey 装着但凭据库里没有它的密码，跳过缓存配置'
        WP_EXTRA=${out%$'\n'}
        return 0
    fi

    out+="define( 'WP_REDIS_HOST', '127.0.0.1' );"$'\n'
    out+="define( 'WP_REDIS_PORT', 6379 );"$'\n'
    out+="define( 'WP_REDIS_PASSWORD', '$(os::php_str "${rpass}")' );"$'\n'
    # **前缀必须带站点名。** 两个站点共用一个 Valkey 而不分前缀，缓存键会互相
    # 覆盖 —— 表现是「另一个站点的内容串到这个站点上」，比没有缓存难查得多。
    # 这是 K7 那个错误在缓存层的第三次。
    out+="define( 'WP_REDIS_PREFIX', '${site}:' );"$'\n'
    out+="define( 'WP_CACHE', true );"$'\n'
    WP_EXTRA=${out%$'\n'}
    return 0
}

# 下载 WordPress 并校验 SHA-1。
#
# 官方只发布 .md5 与 .sha1，没有 sha256。SHA-1 的抗碰撞已经不能算强，
# 但它拦得住传输损坏与不做定向攻击的篡改，而且这是上游给的最好的东西 ——
# **有比没有强，但别把它当成签名**（同规范对 Caddy 按需构建的处理）。
# 校验失败硬失败，不降级（D97）。
fetch_wordpress() {
    local dir=${1}
    local tarball="${dir}/wordpress.tar.gz"

    os::info "下载 WordPress（${OS_DEFAULT_WP_URL}）"
    os::run_out '下载 WordPress' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' \
        --retry 2 -o "${tarball}" "${OS_DEFAULT_WP_URL}" \
        || os::die 1 '下载 WordPress 失败'

    os::query --timeout 30 -- curl -fsSL --proto '=https' --proto-redir '=https' \
        "${OS_DEFAULT_WP_SHA1_URL}" \
        || os::die 1 '取不到 WordPress 的 SHA-1 校验值'
    local want=${OS_RUN_OUTPUT}
    want=${want//[^0-9a-f]/}
    [[ ${#want} -eq 40 ]] || os::die 1 "SHA-1 校验值格式不对：${want}"

    os::query --timeout 60 -- sha1sum "${tarball}" || os::die 1 '计算 SHA-1 失败'
    local got_hash=''
    got_hash=${OS_RUN_OUTPUT%% *}

    if [[ ${got_hash} != "${want}" ]]; then
        os::die 1 "WordPress 压缩包未通过 SHA-1 校验（期望 ${want}，实得 ${got_hash}），拒绝部署"
    fi
    os::ok 'SHA-1 校验通过'
    return 0
}

# ------------------------------------------------------------------

main() {
    # 三项前置检查，只有数据库是硬前提 —— 建库这一步现在就要连上去。
    # PHP 与 Valkey 缺了都只警告：文件放下去、库建好，它们之后装也行，
    # 拦住反而逼人为了「先装齐」而放弃这次部署。
    probe::service_active mariadb.service
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::die 3 'MariaDB 未在运行。先 oneserver install mariadb'
    fi
    os::require_cmd mysql curl tar sha1sum openssl

    # 没有 PHP 站点打不开
    probe::php_fpm_versions
    if [[ -z ${OS_PROBE_VALUE} ]]; then
        os::warn '没有检测到 PHP-FPM。站点文件会放好，但要跑起来还得 oneserver install php'
    fi

    # 没有 Valkey 站点照样跑，只是没有对象缓存。这里探到什么，
    # 下面 build_extra 就按什么写 wp-config —— 两处必须是同一个判断，
    # 否则会出现「检查说装了、配置里却一行缓存都没有」
    probe::component_version valkey
    if [[ -z ${OS_PROBE_VALUE} ]]; then
        os::warn '没有检测到 Valkey。站点能跑，但没有对象缓存 —— 要的话先 oneserver install valkey'
    fi

    # 校验交给 os::ask：打错一个字符就在原地重问，而不是整条命令结束 ——
    # 部署到这一步前面已经填过好几项，退出去等于全部重来。
    # 站点名不是域名：它要当目录名与库名的一部分用，`www.example.com` 里的点
    # 在库名里不合法，所以这里明说「只要一个短名字」
    local name=''
    os::ask --validate valid_name \
        --hint '只收小写字母、数字、下划线、短横，且以字母数字开头；用短名字如 blog，不要填域名' \
        --arg name '站点名（同时用作目录名与数据库名的一部分）' name

    local id="wordpress:${name}"
    # 凭据 key 必须走框架统一生成的命名空间（§11：脚本禁止自行拼接），
    # 不然卸载器按 os::secure_ns "${id}" 扫出的前缀对不上这个 key，
    # `oneserver uninstall wordpress:<name>` 会报「已卸载」而密码永久留在
    # secure.conf 里——没有任何报错，没有任何人会发现。
    local secret_key
    secret_key="$(os::secure_ns "${id}").db_pass"

    local path=''
    os::ask --match '^/' --hint '要绝对路径' \
        --arg path '站点目录' path "${OS_DEFAULT_WP_ROOT}/${name}"
    # **拿到就剥掉尾随斜杠。** 校验只要求以 `/` 开头，`/var/www/blog/` 是合法
    # 输入，而后面两处都受不了它：`${path%/*}` 推父目录会得到站点目录自己
    # （暂存目录于是建在站点里面），`mv -T ... "${path}/"` 在目标还不存在时
    # GNU mv 直接以「Not a directory」拒绝。归一化在这里做，后面全都一致。
    while [[ ${path} == */ && ${#path} -gt 1 ]]; do path=${path%/}; done

    local db_name=''
    os::ask --validate db_ident_valid --hint '只收字母数字下划线短横' \
        --arg db-name '数据库名' db_name "$(derive_db_name "${name}")"

    local db_user=''
    os::ask --validate db_ident_valid --hint '只收字母数字下划线短横' \
        --arg db-user '数据库账号' db_user "${db_name}"

    # 目录已存在且非空 = 要覆盖一个可能有内容的站点。删站点目录是不可逆操作
    # ：打全名确认、--yes 不生效、非交互要 --force-destroy。
    #
    # **这里不自动备份**（与 db delete 不同）：站点目录动辄几百 MB 到几个 G，
    # 悄悄复制一份可能把磁盘写满，那是另一种破坏。改成明确告知路径，让人自己决定。
    local -i overwrite=0
    if [[ -d ${path} ]] && [[ -n $(ls -A "${path}" 2>/dev/null || true) ]]; then
        if ! os::destroy_confirm --arg confirm-overwrite "${name}" -- \
            "目录 ${path} 及其中的全部文件（主题、插件、上传的媒体）" \
            "（数据库 ${db_name} 不在此列，会另行询问）" \
            "本命令不会替你备份这个目录 —— 需要的话先自己复制一份"; then
            os::info '已取消，未改动任何东西'
            os::output 0 name="${name}" changed=no
            return 0
        fi
        overwrite=1
    fi

    # 数据库：已存在就复用，不删。**旧脚本这里是 DROP DATABASE IF EXISTS**，
    # 也就是「重新部署一次，原站点的数据全没了」——而它问的那句
    # 「是否要删除并重建?」很容易被当成「是否继续」。
    local db_exists=0
    local qdb quser qhost
    qdb=$(os::sql_ident "${db_name}")
    quser=$(os::sql_str "${db_user}")
    qhost=$(os::sql_str "${OS_DEFAULT_DB_USER_HOST}")

    os::sql_query '检查数据库是否存在' -- "SHOW DATABASES LIKE $(os::sql_str "${db_name}");" || true
    [[ -n ${OS_RUN_OUTPUT} ]] && db_exists=1

    local pass=''
    if [[ ${db_exists} -eq 1 ]]; then
        os::info "数据库 ${db_name} 已存在，复用它（不会删除其中的数据）"
        if ! os::secure_load "${secret_key}" pass; then
            os::die 2 "数据库 ${db_name} 已存在，但凭据库里没有 ${secret_key} —— 无法生成能连上它的 wp-config，请换个库名或先删掉那个库"
        fi
    else
        if os::confirm --arg auto-password '自动生成数据库密码？（选否则手动输入）' y; then
            os::query --timeout 10 -- openssl rand -hex 16 || os::die 1 '生成密码失败'
            pass=${OS_RUN_OUTPUT}
            [[ ${#pass} -ge 16 ]] || os::die 1 '生成的密码长度异常，拒绝继续'
        else
            os::ask_secret --confirm "请输入 ${db_user} 的数据库密码" pass
        fi
        # 凭据 key 带站点名 —— K7 的正解
        os::secure_set "${secret_key}" "${pass}" || os::die 1 '保存数据库密码失败'
    fi

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将建库 ${db_name} 与账号 ${db_user}@${OS_DEFAULT_DB_USER_HOST}"
        os::info "[dry-run] 将下载 WordPress 并校验 SHA-1，解包到 ${path}"
        os::info '[dry-run] 后续步骤无法预演（压缩包尚未下载）'
        os::output 0 name="${name}" path="${path}" db="${db_name}" changed=dry-run
        return 0
    fi

    if [[ ${db_exists} -eq 0 ]]; then
        # 库不存在不代表账号也不存在：管理员可能手工建过这个账号并授权给
        # 别的库。不查就 CREATE USER 会在账号已存在时失败 → 触发下面的
        # DROP USER 回滚 → 把用户既有账号连同它对其它库的授权一起删掉，
        # 而失败报告显示的是「已自动撤销」。db_manager.sh 对同一件事是查了的
        # （user_exists → die 2），这里补齐同一条底线。
        user_exists "${db_user}" "${OS_DEFAULT_DB_USER_HOST}" \
            && os::die 2 "账号 ${db_user}@${OS_DEFAULT_DB_USER_HOST} 已存在但数据库 ${db_name} 不存在——不清楚这个账号原本授权给了什么，拒绝复用；换个 --db-user 或先手工处理这个账号"

        local qpass
        qpass=$(os::sql_str "${pass}")
        os::record_change "创建了数据库 ${db_name} 与账号 ${db_user}@${OS_DEFAULT_DB_USER_HOST}"
        os::defer os::sql_exec --allow-fail '回滚：删除刚建的账号' -- \
            "DROP USER IF EXISTS ${quser}@${qhost};"
        os::defer os::sql_exec --allow-fail '回滚：删除刚建的数据库' -- \
            "DROP DATABASE IF EXISTS ${qdb};"

        os::sql_exec '创建站点数据库' -- \
            "CREATE DATABASE ${qdb} CHARACTER SET ${OS_DEFAULT_DB_CHARSET} COLLATE ${OS_DEFAULT_DB_COLLATE};"
        os::sql_exec '创建站点数据库账号' -- \
            "CREATE USER ${quser}@${qhost} IDENTIFIED BY ${qpass};"
        os::sql_exec '授予单库权限' -- \
            "GRANT ALL PRIVILEGES ON ${qdb}.* TO ${quser}@${qhost}; FLUSH PRIVILEGES;"

        # 同时登记成 db:<库名>，这样数据库管理与统一备份都从同一份 state
        # 识别它，不会出现站点在而数据库清单里没有的分叉。
        os::state_set "db:${db_name}" engine=mariadb user="${db_user}" host="${OS_DEFAULT_DB_USER_HOST}" \
            charset="${OS_DEFAULT_DB_CHARSET}" collate="${OS_DEFAULT_DB_COLLATE}" \
            owner="${id}"
    fi

    # --- 落文件 ---
    # 覆盖之前，先把已有 wp-config.php 里的盐取出来（如果有）：下面的
    # 「移走旧目录」一旦执行，原文件就没了。**不重新生成盐**——重新部署
    # （比如脚本自己在装完 Valkey 后建议的重跑）会让全站已登录用户的
    # cookie 与密码重置链接同时失效，而这次调用的目的往往只是补一段配置。
    local existing_salts='' existing_salt_lines
    if [[ -f "${path}/wp-config.php" ]]; then
        existing_salts=$(grep -E "^define\( '(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)', " \
            "${path}/wp-config.php" 2>/dev/null || true)
    fi
    existing_salt_lines=$(printf '%s' "${existing_salts}" | grep -c '^define' || true)

    local dir
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    fetch_wordpress "${dir}"

    # 站点目录的父目录。**不是 OS_DEFAULT_WP_ROOT** —— `--path` 可以指到任何
    # 地方，只建默认根解决不了「`--path=/srv/web/blog` 而 /srv/web 不存在」，
    # 那时失败会推迟到下面的 mv，报出来的却是「就位站点目录失败」。
    local parent=${path%/*}
    [[ -n ${parent} ]] || parent='/'
    os::run '创建站点父目录' -- mkdir -p "${parent}" || os::die 1 "创建 ${parent} 失败"

    # **解包落在站点目录旁边，不落 os::tmpdir 的 tmpfs。**
    #
    # `/run` 是 tmpfs，systemd 默认只给它内存的 10% —— 1 GB 的机器上实测 104 MB，
    # 而压缩包约 25 MB 加上解包后的约 90 MB 正好塞不下：tar 写到一半以
    # 「No space left on device」失败、退出码 2，而屏幕上只有一句「解包失败」。
    # 真机上稳定复现，且内存越小越必然。
    #
    # 落在同一个文件系统还顺带修掉第二件事：从 tmpfs 挪到 /var/www 是**跨设备**
    # 的 mv，实际是复制加删除，既不是原子替换，也要再占一份 90 MB。
    #
    # 压缩包本身仍留在 tmpfs：它只有 25 MB 上下，1 GB 以上的机器放得下，而它是
    # 下载来的临时物，不落盘更干净。内存低到 /run 连它都装不下的机器，跑
    # WordPress + MariaDB + PHP 本来就不成立，不为那个场景把下载也搬到盘上。
    # `${parent%/}` 是给 parent 就是 `/` 的情形（`--path=/blog`）准备的：
    # 直接拼会得到 `//.oneserver-wp.<pid>`，能用，但日志里那个双斜杠很扎眼
    local staging="${parent%/}/.oneserver-wp.$$"
    os::record_change "在 ${path} 部署了 WordPress"
    os::run '创建解包暂存目录' -- mkdir -p "${staging}" || os::die 1 "创建 ${staging} 失败"
    os::defer os::run --allow-fail '回滚：清理解包暂存目录' -- rm -rf -- "${staging}"
    # --strip-components=1 剥掉包里那层 `wordpress/`，staging 本身就是站点内容。
    #
    # **`|| os::die 1` 不能省。** tar 用退出码 2 表示 fatal error，而 §8 里 2 是
    # 「参数错误 · 未变更」—— 让它穿到进程出口，框架就会认定什么都没发生而跳过
    # 回滚，此时库和账号已经建好了。框架现在会兜住这种矛盾（变更清单非空的
    # 2/3/4 一律归一为 1），但兜底是最后一道，不是免于在这里写对的理由。
    os::run '解包 WordPress' -- \
        tar -xzf "${dir}/wordpress.tar.gz" -C "${staging}" --strip-components=1 \
        || os::die 1 "解包 WordPress 失败（${staging} 所在文件系统的空间是否够？需要约 100 MB）"

    if [[ ${overwrite} -eq 1 ]]; then
        # 确认过了才走到这里（上面的 destroy_confirm）。
        #
        # **先挪旧目录、再挪新目录、最后才删旧的**，不是 rm 了再 mv：
        # 两步之间按 Ctrl+C，旧站点会在 rm 完成、mv 还没开始之间的窗口里
        # 彻底消失，而这个命令明确说过不会替用户备份这个目录。挪到一边的话，
        # 同样的中断只是留下一个 `.replaced.<pid>` 目录，数据还在。
        # os::critical_begin 把这段区间内的信号挂起到区段结束，进一步收窄
        # 「已经不完整」的窗口（虽然挪走这一步本身已经让最坏情况变得可恢复）。
        local stash="${path}.replaced.$$"
        os::critical_begin '替换站点目录'
        local -i rc=0
        os::run '暂存原有站点目录' -- mv -T "${path}" "${stash}" || rc=$?
        [[ ${rc} -eq 0 ]] && { os::run '就位站点目录' -- mv -T "${staging}" "${path}" || rc=$?; }
        [[ ${rc} -eq 0 ]] && { os::run '删除原站点目录的暂存副本' -- rm -rf -- "${stash}" || rc=$?; }
        os::critical_end
        if [[ ${rc} -ne 0 ]]; then
            os::err "替换站点目录失败；若 ${path} 已不在，原内容在 ${stash}"
            os::die 1 '部署中止'
        fi
    else
        os::run '就位站点目录' -- mv -T "${staging}" "${path}"
    fi

    # --- wp-config.php ---
    if [[ ${existing_salt_lines} -eq 8 ]]; then
        WP_SALTS=${existing_salts}
        os::info '沿用已有的 WordPress 盐（不重新生成，避免把已登录用户全部踢下线）'
    else
        generate_salts || os::die 1 '生成 WordPress 盐失败'
    fi
    build_extra "${name}"

    os::install_template --mode 0640 "${OS_TEMPLATE_DIR}/${WP_TEMPLATE}" "${path}/wp-config.php" \
        "DB_NAME=${db_name}" \
        "DB_USER=${db_user}" \
        "DB_PASSWORD=$(os::php_str "${pass}")" \
        "DB_HOST=localhost" \
        "DB_CHARSET=${OS_DEFAULT_DB_CHARSET}" \
        "DB_COLLATE=${OS_DEFAULT_DB_COLLATE}" \
        "TABLE_PREFIX=wp_" \
        "SALTS=${WP_SALTS}" \
        "EXTRA=${WP_EXTRA}" \
        || os::die 1 '生成 wp-config.php 失败'

    # --- 权限 ---
    #
    # 目录 755 / 文件 644 / wp-content 放宽到 775 与 664（插件与上传要写）。
    # 用 `-exec ... +` 而不是 `\;`：后者每个文件起一个进程，几千个文件的
    # WordPress 要跑好几分钟。
    #
    # **文件权限那条排除 wp-config.php**：它刚被 os::install_template 建成
    # 0640，混在这条无差别的 chmod 0644 里会让它在这一步之后、下面单独收紧
    # 之前世界可读——那段时间里任何本地用户（包括其它站点的 www-data）
    # 都能直接 cat 出数据库密码。排除之后它自始至终没有比 0640 更松过。
    os::run '设置站点目录属主' -- chown -R www-data:www-data "${path}"
    os::run '设置目录权限' -- find "${path}" -type d -exec chmod 0755 {} +
    os::run '设置文件权限' -- find "${path}" -type f -not -name wp-config.php -exec chmod 0644 {} +
    os::run '放宽 wp-content 目录权限' -- find "${path}/wp-content" -type d -exec chmod 0775 {} +
    os::run '放宽 wp-content 文件权限' -- find "${path}/wp-content" -type f -exec chmod 0664 {} +

    # wp-config.php 里有数据库密码，**不跟其他文件一样 644**
    os::run '收紧 wp-config.php 属主' -- chown www-data:www-data "${path}/wp-config.php"

    # wp-config.php 一律 0640，**不再提供「允许插件写入」这个选项**。
    #
    # 那个选项过不了 §15：放宽必须在同一步落实补偿控制，而它给的「补偿控制」
    # 只是复述放宽之后的现状（仍然 www-data 可读写），外加一句「装完插件建议
    # 手动改回」—— 后半句正是 §15 逐字禁止的「先开放，稍后提示用户自行加固」。
    # 措辞本身也不准确：caddy 已被加进 www-data 组，"其他用户无权限"不成立。
    #
    # 删掉而不是补一个真的补偿控制，是因为它换来的东西很少：`FS_METHOD=direct`
    # 已经免掉了插件要 FTP 凭据那条主要路径，而 wp-content 本来就是 0775/0664，
    # 主题与插件的安装、上传、更新都不需要写 wp-config.php。真正需要它的
    # 场景（少数插件写常量）可以由人自己临时改权限并改回来——那是一次有意识的
    # 决定，不该做成一个装站时顺手就点过去的问句。
    os::run '收紧 wp-config.php 权限' -- chmod 0640 "${path}/wp-config.php"

    # Caddy 以自己的用户跑，要读站点文件就得进 www-data 组。
    # 用家目录判存在：用户不在时 getent 取不到，返回空，与判 id -u 等价
    probe::user_home caddy
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        # 改的是既有系统用户的属组，不在本组件的资源清单里（uninstall 卸不掉
        # 这一条），至少记进变更清单，失败报告里能看见这台机器的 caddy
        # 被加进过 www-data 组
        os::record_change '把系统用户 caddy 加入了 www-data 组'
        os::run '把 caddy 加入 www-data 组' -- usermod -a -G www-data caddy
    fi
    os::run '确保站点父目录可进入' -- chmod 0755 "${OS_DEFAULT_WP_ROOT}"

    # --- state ---
    #
    # **站点目录不登记成 file 资源**：规范明列「站点目录」永不自动删除 ——
    # 那里面是用户的主题、插件和上传的媒体，卸载时只打印位置。
    os::state_set "${id}" path="${path}" db="${db_name}" db_user="${db_user}" \
        db_host="${OS_DEFAULT_DB_USER_HOST}"

    local php_hint='（未装 PHP）'
    probe::php_fpm_versions
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        local newest=${OS_PROBE_VALUE##* }
        php_hint="/run/php/php${newest}-fpm.sock"
    fi

    os::kv '站点名' "${name}" \
        '组件标识' "${id}" \
        '目录' "${path}" \
        '数据库' "${db_name}（账号 ${db_user}@${OS_DEFAULT_DB_USER_HOST}）" \
        '凭据键名' "${secret_key}" \
        'PHP-FPM socket' "${php_hint}"

    os::info "下一步：用 oneserver caddy 给 ${path} 配一个站点，然后浏览器打开完成安装向导（第一步就能选中文）"
    os::ok "WordPress 站点 ${name} 已部署（${id}）"
    os::output 0 name="${name}" path="${path}" db="${db_name}" \
        db_user="${db_user}" changed=yes
    return 0
}

main "$@"
