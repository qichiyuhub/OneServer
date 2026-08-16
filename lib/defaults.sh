# lib/defaults.sh —— L0 常量层：可调参数的单一来源
#
# L0 零依赖，只有变量赋值。不得出现函数、条件、命令调用。
#
# 判断标准：**改一个下载源地址只改一个文件。** 现在要翻 19 个。
#
# --- 覆盖规则 ---
#
# 本文件的每一项都可被 /etc/oneserver/oneserver.conf 覆盖，规则：
#
#   * 配置文件里的 key **就是**这里的变量名（`OS_DEFAULT_DOWNLOAD_RETRIES=3`）。
#     不做「配置名 → 变量名」的映射表——映射表是第二份真相，迟早对不上。
#   * 因此白名单也不需要单独维护：**能被覆盖的 key = 本文件里已定义的 OS_DEFAULT_\***。
#     配置里出现没在这里定义过的 key，视为未知 key，忽略并告警。
#   * 加载前强制校验：属主必须 root、权限 ≤ 0644，否则拒绝启动。
#   * 严格 `key=value` 解析，**不 source**（K12 是 source 配置文件的直接教训）。
#
# 加载与校验的实现在 bootstrap.sh（L4）——它需要条件判断与命令调用，L0 不允许。
# /etc/oneserver/*.conf 的 key 只增不删，删一个 key 是破坏性变更。

# shellcheck disable=SC2034  # 理由：L0 常量文件的全部变量都由别的模块消费，本文件内必然「未使用」

# --- 分发源 ---

OS_DEFAULT_REPO_URL='https://github.com/qichiyuhub/OneServer'
OS_DEFAULT_RAW_BASE='https://raw.githubusercontent.com/qichiyuhub/OneServer'

# `<owner>/<repo>` 形式，`oneserver update` 用它拼 release 与源码包的地址。
# 单独一项而不是从上面那个 URL 里截：截字符串意味着改一个地方要保证另一处的
# 截法仍然成立，而 fork 出去自建分发的人只需要改这一行（D51：conf 可覆盖它）。
OS_DEFAULT_UPDATE_REPO='qichiyuhub/OneServer'

# --- 运行期模式 ---
#
# **前缀不是 `OS_DEFAULT_`，因此 conf 覆盖不到它**（D51：白名单按前缀判），
# 这是有意的 —— 「默认就是预演模式」不该是一个可配置项。
#
# 放在 L0 而不是 exec.sh：`exec.sh` 与 `errors.sh` 同在 L2，而两者都要读它
# （前者跳过命令，后者跳过备份与文件替换）。归属放在任一个 L2 模块里，
# 另一个就成了同层依赖。它本来也不是谁的私产 ——
# 它是整个进程的模式。
OS_DRYRUN=0

# --- 下载 ---

OS_DEFAULT_DOWNLOAD_RETRIES=5
OS_DEFAULT_DOWNLOAD_CONNECT_TIMEOUT=15
OS_DEFAULT_DOWNLOAD_MAX_TIME=300
OS_DEFAULT_DOWNLOAD_PARALLEL=8

# --- 系统探测（D18）---
#
# 每个 probe 必须有超时。菜单每次进都跑 probe，podman 一挂工具就开不了机（K14）。
OS_DEFAULT_PROBE_TIMEOUT=3

# 非 root 读 $OS_PUBLIC_DIR 里的快照时，超过这个秒数就标注为「陈旧」（D44）。
# 不是删除，是标注——诚实标注来源与时间，好过假装数据是新的。
OS_DEFAULT_PROBE_SNAPSHOT_MAX_AGE=300

# 空间清理的目录扫描超时。**比 probe 的 3 秒宽得多**：`du -sk /var/log` 在
# 一台攒了半年日志的机器上十几秒很正常，而 probe 那个值是按「读一个 /proc
# 文件」定的。用 3 秒的后果是清理页在真正需要清理的机器上全部显示为 0，
# 也就是**越该清的越看不见**。
OS_DEFAULT_SCAN_TIMEOUT=60

# --- 重试---
#
# 指数退避：第 n 次失败后等 BASE * 2^(n-1) 秒，封顶 MAX。
# 固定间隔对「对端正在重启」这类情况无效 —— 五次 1 秒等于白重试五次。
OS_DEFAULT_RETRY_BASE_WAIT=1
OS_DEFAULT_RETRY_MAX_WAIT=30

# --- 并发（D27）---

OS_DEFAULT_LOCK_WAIT=30

# `root-trylock` 的等待。**必须是秒级**：这一档的意义就是「拿不到就下一轮再来」，
# 等满 30 秒与直接失败没有区别，只会把一轮的间隔整个吃掉（周期最短的采集是
# 3 秒）。给 1 秒而不是 0，是为了不让一次正常的短暂交接（上一条命令正在退出、
# fd 还没关）被当成「锁被长期占着」。
OS_TRYLOCK_WAIT=1

# --- 凭据 ---
#
# 凭据的最短长度。**前缀不是 `OS_DEFAULT_`，因此 conf 覆盖不到它**（同
# OS_DRYRUN）—— 这不是一条口味参数，调低它等于重新打开下面这个洞。
#
# 它同时是三处的单一来源：`log::secret_add` 的登记下限、`os::run --secret-val`
# 的拒绝下限、`os::ask_secret` / `os::secure_set` 的入口下限。三者必须同源：
# 短于这个长度的值**登记不进脱敏表**（全局字符串替换会把日志正文打成马赛克，
# 等于毁掉排查证据），而入口若不拦，一个 5 位的手输密码就会全程明文穿过
# 日志、JSONL 与面板 —— 从前正是这么漏的：下限只写在出口，入口一个字都不查。
OS_SECRET_MIN_LEN=6

# --- 日志 ---

OS_DEFAULT_LOG_LEVEL='info'
OS_DEFAULT_LOG_KEEP_DAYS=30

# --- 备份 ---

OS_DEFAULT_BACKUP_LOCAL_KEEP=10
OS_DEFAULT_BACKUP_REMOTE_KEEP=10

# **backup 的「站点」是什么，由这一行定义，不由脚本里的 `wordpress` 字面量定义。**
#
# 判据：state 里类型在这份清单内、且带 `path` 键的组件，就是一个可备份的站点；
# 再带 `db` 键就连库一起备。将来加 `deploy_static` / `deploy_laravel`，
# 只要它往 state 写 `path`（和可选的 `db`），在这里加一个词，
# backup 与 restore **一行都不用改**。这是这两个脚本唯一的扩展点。
#
# 反过来说：把 `wordpress` 写进 backup.sh 里，等于「本工具永远只能备份
# WordPress」——那正是旧脚本的形态（K7 的土壤）。
OS_DEFAULT_BACKUP_SITE_TYPES='wordpress'

# 不指定 `--target` 时备份什么。定时任务用的也是它。
#
# 默认含 `oneserver:self`：那是 `/etc/oneserver` + state + secure.conf。
# **今天没有任何东西备份 secure.conf**，而丢了它等于丢掉这台机器上所有
# 由本工具自动生成的密码（站点库密码、Redis 密码）。它很小，代价接近零。
#
# 默认**不含** `db:*`：站点的库已经跟着 `site:*` 备了，再单独备一遍是重复；
# 手工建的库要备份就显式写进来。
OS_DEFAULT_BACKUP_TARGETS='site:*,oneserver:self'

# --- 数据库 ---

OS_DEFAULT_DB_CHARSET='utf8mb4'
OS_DEFAULT_DB_COLLATE='utf8mb4_unicode_ci'

# `os::sql_query` 的超时。比 probe 的 3 秒宽得多：数据库在负载下响应慢是
# 常态，按 probe 的尺度会把一次正常查询判成「挂了」。
OS_DEFAULT_SQL_TIMEOUT=30

# 默认 localhost，不是 '%'。现状是 `'user'@'%'` + GRANT ALL（K3）——
# 把库账号暴露给任意来源。降低安全性的选项默认必须为否。
OS_DEFAULT_DB_USER_HOST='localhost'

# --- 组件默认版本 ---

# 空 = 用 APT 源里可用的最新版。写死一个版本号意味着源里出新版时这里就过期了。
OS_DEFAULT_PHP_VERSION=''

OS_DEFAULT_NODE_LTS_VERSIONS='20 22 24'
OS_DEFAULT_NODE_CURRENT_VERSION='25'

# --- Caddy 插件清单 ---
#
# **这里是维护插件的唯一地方**：加一个插件 = 在这行里加一个模块路径，
# 脚本一个字都不用改。用户在 `/etc/oneserver/oneserver.conf` 里覆盖它，
# `oneserver update` 不会动 `/etc` 下的东西（D51 D53）。
#
# 插件是**编译期**决定的，所以「换插件」= 换一个二进制。官方按需构建接口
# 能按任意组合现场编译，因此它是第一顺序；本项目仓库里的预构建只覆盖
# 「这份清单原样」的组合，作兜底（D106）。
#
# 格式 `<模块路径>=<说明>`，逗号分隔。**说明是清单的一部分，不是注释** ——
# 安装时的编号选单直接显示它，写在注释里程序读不到，而两份数据迟早对不上。
# 因此说明里**禁止出现英文逗号**（逗号是项分隔符），中文顿号与破折号随意。
# 不带 `=` 的项说明为空，老格式的覆盖照样能用。
#
# 模块路径第一段不含点时自动补 `github.com/`，所以 `caddy-dns/cloudflare`
# 与全路径都认。清单里的项**逐个 + 整体**都要能在官方接口上编译，且构建仓库
# 的预构建里也得有同一组 —— 少一个，verify_binary 就会把兜底那条路整个拒掉。
#
# **两个换过路径的**（原选项在官方接口上 400，写在这里免得下次又踩）：
#   caddy-dns/dnspod    → caddy-dns/tencentcloud   官方构建持续失败
#   poepas/caddy-geoip2 → zhangjiayin/caddy-geoip2 未登记在 Caddy 的插件注册表里
OS_DEFAULT_CADDY_PLUGINS='github.com/caddy-dns/cloudflare=Cloudflare DNS 验证 —— 泛域名证书、无 80/443 也能签,github.com/caddy-dns/alidns=阿里云 DNS 验证,github.com/caddy-dns/tencentcloud=腾讯云 DNS 验证（DNSPod 已并入腾讯云）,github.com/mholt/caddy-ratelimit=按 IP / 路径限流 —— 防刷接口、防暴力破解,github.com/greenpau/caddy-security=给没有登录功能的内网服务加 Web 登录 / OAuth2,github.com/mholt/caddy-l4=四层 TCP/UDP 代理 —— 443 复用与伪装、转发 SSH/数据库,github.com/mholt/caddy-dynamicdns=DDNS，公网 IP 变了自动同步到 DNS 服务商,github.com/mholt/caddy-webdav=WebDAV 网盘 —— Obsidian / Zotero 同步,github.com/caddyserver/cache-handler=边缘缓存，降后端与数据库负载,github.com/zhangjiayin/caddy-geoip2=GeoIP 分流 —— 按国家阻断或路由,github.com/WeidiDeng/caddy-cloudflare-ip=自动更新 Cloudflare 回源 IP 段清单 —— 给 trusted_proxies 用、免去手工维护'

# 官方按需构建要现场编译，慢是常态。超过这个秒数就当它够不着，
# 回落到仓库的预构建 —— 「官方慢就跳过」的自动版本。
OS_DEFAULT_CADDY_BUILD_TIMEOUT=600

# --- Valkey --------------------------------------------------------
#
# `--maxmemory=auto` 时取物理内存的百分之几。25 是「缓存不该把机器吃穷」的
# 一个保守取值，不是什么公认最优 —— 谁的机器谁清楚，改这里就是。
OS_DEFAULT_VALKEY_MAXMEMORY_PCT=25

# auto 算出来的下限（MB）。小内存 VPS 上 25% 可能只有二三十 MB，
# 那点空间连 WordPress 的对象缓存都装不下，还不如不设。
OS_DEFAULT_VALKEY_MAXMEMORY_MIN_MB=64

# 缓存用途的淘汰策略。**只在 --purpose=cache 时用**；store 用途一律 noeviction，
# 那是「宁可写失败也不许悄悄丢数据」，不给可配项。
OS_DEFAULT_VALKEY_CACHE_POLICY='allkeys-lru'

# --- PHP -----------------------------------------------------------
#
# 装 PHP 时一起装的扩展。格式与 Caddy 插件清单一致：`<扩展名>=<说明>`，逗号
# 分隔，说明里禁止英文逗号。写扩展名（不带 `php<版本>-` 前缀）——
# 版本前缀由脚本按实际装的版本拼，所以这份清单跨版本通用。
#
# 用户在 /etc/oneserver/oneserver.conf 里增删，脚本一个字都不用改。
#
# **`fpm` 必须在里面**：它不是可选扩展，是这个组件本身；脚本会无条件补上它。
# 在 Debian 13 的 PHP 8.4 上逐个确认过 apt 源里都有。
OS_DEFAULT_PHP_EXTENSIONS='fpm=FastCGI 进程管理器 —— 组件本体,mysql=连 MariaDB/MySQL,redis=对象缓存（配合 install valkey —— Valkey 协议兼容 扩展仍叫 php-redis）,gd=图像处理 —— WordPress 缩略图靠它,imagick=ImageMagick 绑定，比 gd 强，WordPress 优先用,intl=国际化：本地化排序、数字与日期格式,zip=插件/主题的安装与更新要解压,xml=RSS、SOAP、sitemap,curl=几乎所有对外 HTTP 请求,mbstring=多字节字符串 —— 中文站不装这个到处是乱码,igbinary=php-redis 扩展的高效序列化后端,opcache=字节码缓存 —— 不开等于白扔一半性能'

# 自动生成的密码长度（十六进制字符数，必须是偶数）。32 位十六进制 = 128 bit 熵。
# 用 hex 不用 base64：`/` `+` `=` 在 valkey.conf 里其实不需要引号，
# 但它们在复制粘贴、URL、环境变量里各有各的麻烦，而这里不缺那点长度。
OS_DEFAULT_VALKEY_PASS_LEN=32

# --- WordPress -----------------------------------------------------
#
# **只从 wordpress.org 的国际版下载，因为只有它有校验和。**
# 实测：`wordpress.org/latest.tar.gz.sha1` 存在且对得上，
# 而本地化包 `cn.wordpress.org/latest-zh_CN.tar.gz.sha1` 是 404 ——
# 走本地化包就等于放弃校验，而规范不允许默认走无校验的路。
#
# 语言不会因此丢：WordPress 的安装向导第一步就是选语言，core 会自己去拉
# 对应的语言包。所以「用国际版 + 装完选中文」与「直接下中文包」结果一样，
# 只是前者能校验。
OS_DEFAULT_WP_URL='https://wordpress.org/latest.tar.gz'

# 校验文件。WordPress 官方只发布 .md5 与 .sha1，没有 sha256 ——
# SHA-1 抗碰撞已经不能算强，但它仍然拦得住传输损坏与不做定向攻击的篡改，
# 而且这是上游给的最好的东西。**有比没有强，但别把它当成签名。**
OS_DEFAULT_WP_SHA1_URL='https://wordpress.org/latest.tar.gz.sha1'

# 站点根目录的父目录。站点各自落在 <父目录>/<站点名> 下 ——
# 旧脚本把整个路径写死成 /var/www/wordpress，于是第二个站点无处可去（K7）。
OS_DEFAULT_WP_ROOT='/var/www'
