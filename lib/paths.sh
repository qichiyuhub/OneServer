# lib/paths.sh —— L0 常量层：路径的单一来源
#
# L0 零依赖，只有变量赋值。本文件里不得出现函数、条件、命令调用。
# 本文件被 source，不直接执行，因此没有 shebang，也不需要执行位。
#
# 两条不显然的约定：
#
# 1. 不用 `readonly`。lib 模块会被 bootstrap.sh 与单元测试分别 source，
#    `readonly` 让第二次 source 直接报错并被 set -e 带走。规范没有要求
#    readonly，而「重复 source 会炸」是实打实的坑。
#
# 2. **不引入 /etc/oneserver/paths.conf**（D25）。路径可覆盖是为「将来做 deb
#    打包」而设，而 deb 打包在明确不做的列表里。为不存在的需求引入一个 root
#    读取的配置文件，等于凭空增加攻击面。
#
# 这个文件的存在是为了消灭现状里的四种命名（CORE_DIR / ONESERVER_DIR /
# oneserver_DIR / CONFIG_DIR，全都指同一个目录）。

# shellcheck disable=SC2034  # 理由：L0 常量文件的全部变量都由别的模块消费，本文件内必然「未使用」

# --- 程序目录 ---

OS_ROOT='/opt/oneserver'
OS_BIN_DIR="${OS_ROOT}/bin"
OS_LIB_DIR="${OS_ROOT}/lib"
OS_SCRIPT_DIR="${OS_ROOT}/script"
OS_TEMPLATE_DIR="${OS_ROOT}/templates"

# --- 数据目录 ---

OS_STATE_DIR="${OS_ROOT}/state"

# 组件清单。行式格式（D39），一行一个「组件标识 + 键 + 值」三元组。
# `.bak` 是上一版，全文件不可读时回退它。
OS_STATE_FILE="${OS_STATE_DIR}/components.tsv"
OS_STATE_BAK="${OS_STATE_FILE}.bak"
OS_STATE_FILE_MODE='0640'

# 工具自己的持久运行数据，**与 state 分开**：state 是组件清单，卸载按它反向
# 执行、doctor 校验它的权限，往里塞一个与组件无关的文件是拿卸载语义冒险。
# 这里放的是「丢了只是可惜，不影响正确性」的东西。
#
# 在 OS_ROOT 下而不是 /var/lib：更新切换器只 rename lib/templates/packaging/
# script/bin 五个顶层目录，这里和 state 一样不在其中，更新不碰；卸载时随
# OS_ROOT 一起走，不必再记一处系统落点。
OS_DATA_DIR="${OS_ROOT}/data"
OS_DATA_DIR_MODE='0750'

# 面板的历史曲线与告警去重基线。**两个脚本共用**（采集器读、持久化步骤写），
# 所以路径必须在这里定一次，不能各拼各的。
#
# NAME 单列一个常量：public/ 里那份要用它当 os::write_public 的文件名，
# 盘上那份要用它拼路径 —— 两处必须是同一个名字，写两遍迟早写岔。
OS_WEB_HISTORY_NAME='history.tsv'
OS_WEB_HISTORY_FILE="${OS_DATA_DIR}/${OS_WEB_HISTORY_NAME}"
OS_WEB_ALERT_BASELINE="${OS_DATA_DIR}/telegram-alerts.tsv"

# 非 root 可读的只读数据（probe 快照等，D44）。唯一放宽到 0755 的目录，
# 因此权限值写在这里，而不是散在写它的模块里。
#
# **在 tmpfs 上，不在 OS_ROOT 下**：这里每一项都是「此刻的快照」，重启之后
# 上一秒的内存占用、容器状态、监听端口全部作废，采集器几秒内重建。实测面板
# 每天往盘上写 676 MB，买的全是一个没人需要的持久性。挂在 /run 下而不是自己
# 挂一个 tmpfs：/run 本来就是 tmpfs，不用新增挂载点，也没有「挂载失败就静默
# 落到盘上」这种查不出来的退路。
#
# 与 /run/oneserver 平级而不是它的子目录：那个是 0750（里面有凭据临时文件），
# 跑 Caddy 的用户连遍历都进不去。
OS_PUBLIC_DIR='/run/oneserver-public'
OS_PUBLIC_DIR_MODE='0755'

# probe 快照：root 跑任何命令时框架顺手落一份，非 root 时读它（D44）。
# 放在 public 里就是为了让非 root 读得到 —— 这也是它必须 0644 且**永不含凭据**的原因。
OS_PROBE_SNAPSHOT="${OS_PUBLIC_DIR}/probe.tsv"

# --- 凭据 ---

OS_SECURE_CONF="${OS_ROOT}/secure.conf"
OS_SECURE_CONF_MODE='0600'

# --- 系统目录 ---

OS_LOCAL_BIN_DIR='/usr/local/bin'

# 两个落在 OS_ROOT 之外的系统文件：装的时候写进去，卸的时候要删掉。
# 定成完整路径而不是所在目录 —— 消费方要的就是这一个文件，给目录只会让
# 「文件名叫 oneserver」这个知识在每个调用点各写一遍。
#
# install.sh 不用它们：那是自包含例外，跑在还没有 lib/ 的机器上。
OS_COMPLETION_FILE='/etc/bash_completion.d/oneserver'
OS_LOGROTATE_FILE='/etc/logrotate.d/oneserver'

OS_LOG_DIR='/var/log/oneserver'
OS_LOG_DIR_MODE='0750'

# 三个落点各有分工，别在 log.sh 里另起一套命名：
#   主日志   人读的时间线，全部命令混在一起
#   JSONL    机器读的同一条时间线，供只读面板（`oneserver web`）读取
#   审计     os::run 自动产生，定位是**事故追溯**，不是防篡改审计
OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"

OS_BACKUP_DIR='/var/backups/oneserver'
OS_BACKUP_DIR_MODE='0700'

# 归档目录的布局是 `<type>/<name>/<时间戳>.tar.gz`，**分层而不是把三段拼进
# 文件名**。拼名字的写法（`site-my-blog-20260803-040000.tar.gz`）拆不回来 ——
# 站点名里合法地带着 `-`。分层之后「某个目标有哪些归档」就是列一个目录，
# 保留策略里一条正则都不需要。远端用同一套布局，两边可以直接对照。
#
# 这个布局与归档内的 manifest 一起构成对外承诺：改它 = 已有归档恢复不了。
OS_ARCHIVE_DIR="${OS_BACKUP_DIR}/archives"

# --- 自有 systemd unit 的源文件目录（`own:` 的源在 packaging/systemd/）---
OS_UNIT_SRC_DIR="${OS_ROOT}/packaging/systemd"

# 锁放 /run 不放 /tmp（D23 / K5）：root 用 `>` 打开 /tmp 下的路径会跟随符号链接。
# 单一全局锁，不分域（D27）——apt 本就被 dpkg 串行化，分域只会引入锁顺序问题。
OS_RUN_DIR='/run/oneserver'
OS_RUN_DIR_MODE='0750'
OS_LOCK_FILE="${OS_RUN_DIR}/oneserver.lock"

# 二级菜单选「返回主菜单」时留下的记号，菜单读到就跳过「按回车返回菜单」。
# 放 /run：它是一次派发的瞬时状态，重启即消失，永远不该留在磁盘上。
#
# **按菜单进程 PID 分文件**：这是 root 工具，同时开两个 SSH 会话是常态，而共用
# 一个路径时 A 选「返回上一层」写下的记号会被 B 的派发读走并删掉 —— B 那一条
# 命令跑完就直接跳回列表，用户来不及看输出。OS_FROM_MENU 由菜单置成自己的 PID
# 并导出，子进程继承同一个值，因此两边算出同一个路径。
#
# **非数字一律剔掉**：这个变量来自环境，而框架拿它拼路径再 `: >` 截断。
# 原样代入的话 `OS_FROM_MENU=../../etc/xxx` 就是一条穿出 /run/oneserver 的
# 路径穿越，被截断的是攻击者点名的那个文件。L0 只许赋值，所以用参数展开
# 过滤而不是写判断。
OS_FROM_MENU_ID="${OS_FROM_MENU:-0}"
OS_FROM_MENU_ID="${OS_FROM_MENU_ID//[!0-9]/}"
OS_MENU_BACK_FLAG="${OS_RUN_DIR}/.menu-back.${OS_FROM_MENU_ID:-0}"

# 临时目录在**磁盘**上，不在 /run（D244）。
#
# 从前分两条：默认落 /run 的 tmpfs（理由是「凭据临时文件永不落盘」），要现场
# 执行的走 /var/tmp。两条都撤了，因为那个理由站不住 ——
#
#   * 凭据的**真身**就明文躺在 secure.conf 上（0600 root，无加密，业界常规）。
#     同一个密码的临时副本避不避开磁盘，不改变任何攻击者的处境。
#   * tmpfs 的页面**照样会被换出到 swap**，落到一个既定位不了也擦不掉的地方。
#     「放 /run 就永不落盘」这个前提本身就不成立。
#
# 而代价是实打实的：systemd 默认只给 /run 内存的 10%，1 GB 的机器上 104 MB，
# 装不下 WordPress 解包（90 MB）、Node.js 发布包、备份暂存区（可能几 GB）——
# 同一个坑 restore.sh 绕开过一次、deploy_wordpress.sh 炸过一次、backup.sh
# 还等着。用一层象征性的保护换三个真实故障，不划算。
#
# **落在程序目录下，不在 /var/tmp 或 /tmp。** 那两个都是 1777 sticky，任何本地
# 用户都能抢先把 `oneserver` 这个目录名建出来 —— os::tmpdir 的属主校验会因此
# 拒绝使用它（不 chown 抢过来，那只是给攻击者控制的目录换个主人），可后果就是
# **几乎每条命令都停摆**。从前这条路只有 `--exec` 走，影响面小；落点合并之后
# 它是唯一通道，那个抢占就从「装 Caddy 失败」放大成「工具整个不能用」。
# `/opt/oneserver` 是 root 拥有的 0755，本地用户建不进去，`mkdir -p` 出来的属主
# 天然正确；systemd 的 tmpfiles 也不会像清 /var/tmp 那样定期清它。
#
# 更新切换器只替换 lib/templates/packaging/script/bin 五个目录，不碰这里；
# 卸载删掉整棵 OS_ROOT，也就顺带收走了它。
OS_TMP_ROOT="${OS_ROOT}/tmp"

# --- 用户可覆盖的配置 ---
#
# 这两个文件都是**可选**的，缺失是正常状态。加载与校验在 bootstrap.sh（L4），
# 不在这里——校验需要条件判断与命令调用，L0 不允许。

OS_ETC_DIR='/etc/oneserver'
OS_CONF_FILE="${OS_ETC_DIR}/oneserver.conf"
# 名字是 OS_CONF_THEME 而不是 OS_THEME_CONF：规范禁止脚本引用任何
# `OS_THEME_*` 变量，而那条是 [CI] 强制的静态检查。一个叫 OS_THEME_CONF 的
# **路径**会让那条检查要么误伤、要么得为它开个特例 —— 两者都不该为一个命名付。
OS_CONF_THEME="${OS_ETC_DIR}/theme.conf"

# --- 版本与注册表 ---

OS_VERSION_FILE="${OS_ROOT}/VERSION"
OS_API_VERSION_FILE="${OS_LIB_DIR}/API_VERSION"
OS_GROUPS_CONF="${OS_TEMPLATE_DIR}/groups.conf"
