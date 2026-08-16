# OneServer 接口参考

**本文件由 `make api` 从 `lib/` 生成，不要手工编辑。**

收录 `script/**` 与 `bin/**` 可以调用的全部接口。其余前缀（`ui::` `log::` `registry::`）
与名字含 `_` 前缀的函数是框架内部，脚本层禁止直接调用。

设计规则与行为语义见 `docs/TECHNICAL_SPEC.md`；本文件只回答“有什么、怎么调”。

## `lib/bootstrap.sh` · L4 装配

- `os::info <消息>` —— 进行中，走 stdout
- `os::ok <消息>` —— 成功，走 stdout
- `os::warn <消息>` —— 需注意，走 stderr
- `os::err <消息>` —— 失败，走 stderr
- `os::debug <消息>` —— 仅进日志，--verbose 时才上屏
- `os::section <标题>` —— 阶段标题
- `os::screen_heading <标题>` —— 管理屏顶部标题
- `os::kv <键> <值> [<键> <值>...]` —— 键值对，键按显示宽度右对齐
- `os::table <表头...> -- <单元格...>` —— 单元格按行优先铺，列数等于表头个数
- `os::box <标题> -- <行...>` —— 强调块
- `os::spacer` —— 一行呈现留白
- `os::prompt <提示> [固定列宽]` —— 提问一行，输入符另起一行，光标停在它后面
- `os::menu_render <条目...>` —— 菜单，编号原样打印不做连续重排
- `os::progress <当前> <总数> [标签]` —— 进度，非 TTY 降级为按比例打行
- `os::die <退出码> <消息>`
- `os::ask [--match <正则>] [--validate <函数名>] [--hint <说明>] [--multiline] --arg <name> <提示> <变量名> [默认值]`
- `os::ask_secret [--confirm] <提示> <变量名>`
- `os::confirm --arg <name> <提示> [y|n]`
- `os::flag --arg <name>` —— 命令行给了这个开关就返回 0
- `os::select [--required] [--reask] [--keep-screen] [--return <值>] --arg <name> <提示> <变量名> <选项>...` —— 从清单里挑一个；选项可写 `值=说明`，`__...__=说明` 不显示内部值
- `os::multiselect [--reask] --arg <name> <提示> <变量名> <选项>...` —— 从清单里挑一个子集，结果排序去重
- `os::action_menu [--overview <函数>] --arg <name> <提示> <分发函数> <选项>...` —— 动作型命令的常驻二级菜单
- `os::destroy_confirm --arg <name> <确认串> -- <清单行>...`
- `os::output_item <key=value>...` —— 往信封 data 的 items 数组里追加一条记录
- `os::output <退出码> [key=value...]` —— 打印信封并返回
- `os::pkg_installed_names` —— 列出本次真正装上的包
- `os::pkg_refresh` —— 刷新软件包索引
- `os::pkg_upgrade` —— 升级所有已安装的软件包
- `os::pkg_install <包>...` —— 安装，已装的自动跳过
- `os::pkg_install_deb <deb 文件>` —— 安装一个本地 .deb
- `os::pkg_purge <包>...` —— 卸载并清配置，没装的自动跳过
- `os::pkg_reinstall <包>...` —— 重装已装的包，把包自带的文件恢复回来
- `os::pkg_clean` —— 清空 apt 的包缓存
- `os::require_cmd <命令>...` —— 缺任一命令即以退出码 3 终止

## `lib/errors.sh` · L2 基础设施

- `os::defer <命令> [参数...]`
- `os::commit`
- `os::record_change <描述>`
- `os::backup_file <路径>`
- `os::replace_line [--append-if-missing] [--backup] <文件> <正则> <新行>` —— 按正则整行替换，是否写入见 OS_REPLACE_CHANGED
- `os::tmpdir <变量名> [--exec]` —— 新建 0700 临时目录，路径写进变量，退出时自动清理
- `os::critical_begin <描述>` —— 进入不可中断区段，区段内的信号记录并延后
- `os::critical_end` —— 离开不可中断区段，可嵌套

## `lib/exec.sh` · L2 基础设施

- `os::run [--allow-fail] [--env K=V] [--secret-val <值>] [--stdin-secret <值>] [--stdin <文本>] <desc> -- <命令...>` —— 有副作用且不需要 stdout；dry-run 下不执行
- `os::run_out [选项同 os::run] <desc> -- <命令...>` —— 有副作用且需要 stdout，结果写入 OS_RUN_OUTPUT
- `os::query [--timeout <秒>] [--env K=V...] [--stdin <文本>] [--want-stderr] -- <命令...>`
- `os::retry [--stop-on <码,码>] <次数> [选项同 os::run] <desc> -- <命令...>` —— 指数退避重试；dry-run 下只「跑」一次

## `lib/firewall.sh` · L3 能力

- `os::ufw_allowed <规则文本> <端口> <协议> [来源]` —— 这条放行在不在规则里
- `os::ufw_allow <端口> <协议> [来源]` —— 放行一条规则
- `os::ufw_reload` —— 重载 UFW 使规则生效

## `lib/lock.sh` · L2 基础设施

- `os::lock_acquire [--try] [超时秒]`
- `os::lock_report_holder` —— 打印当前持锁者的 PID、命令与起始时间
- `os::lock_release` —— 通常用不上（进程退出即释放），留给菜单这类长驻进程

## `lib/probe.sh` · L3 能力

- `probe::snapshot_flush` —— 把本次探测结果落盘为 /run/oneserver-public/probe.tsv，供非 root 读取
- `probe::describe` —— 把 OS_PROBE_STATUS/SOURCE/AGE 渲染成一行来源标注
- `probe::os_id` —— 发行版 ID（debian / ubuntu）
- `probe::os_version` —— 发行版版本号（VERSION_ID）
- `probe::os_pretty` —— 发行版完整名称（PRETTY_NAME）
- `probe::os_codename` —— 发行版代号（trixie / noble），第三方 apt 源的路径要用它
- `probe::hostname` —— 主机名
- `probe::arch` —— 机器架构
- `probe::kernel` —— 内核版本
- `probe::unit_exists <unit>` —— unit 文件是否存在
- `probe::service_active <unit>` —— 服务是否正在运行
- `probe::services_active <unit>...` —— 一次问多个 unit 的运行状态
- `probe::service_enabled <unit>` —— 服务是否开机自启
- `probe::package_version <包名>` —— 已装包的版本，未装为空
- `probe::package_installed <包名>` —— 包是否已安装，值为 yes / no
- `probe::timer_next <timer>` —— 下次触发时间，没装或没启用为空
- `probe::unit_result <unit>` —— 上次运行的结果（success / exit-code / timeout …），没跑过为空
- `probe::unit_restarts <unit>` —— systemd 至今为这个 unit 重启过几次，读不到为空
- `probe::package_candidate <包名>` —— apt 源里可安装的版本，源里没有为空
- `probe::component_version <组件类型>` —— 组件的运行版本
- `probe::php_fpm_versions` —— 已装的 PHP-FPM 版本列表，空格分隔
- `probe::caddy_plugins` —— 当前 Caddy 编进了哪些 Go 模块（模块路径，空格分隔）
- `probe::compose_provider` —— compose provider：`种类<制表符>版本<制表符>路径`，没有则空
- `probe::port_listening <端口>` —— 该 TCP 端口是否有进程监听
- `probe::port_families <端口>` —— 该 TCP 端口正在监听的地址族，空格分隔（v4 / v6）
- `probe::listening_ports` —— 全部监听中的 TCP 端口，空格分隔
- `probe::listening_scoped` —— 监听端口按「防火墙管不管得到」分成两拨
- `probe::dir_size_kb <路径>` —— 这个目录占多少（KB），算不出来为空
- `probe::disk_free_kb [路径]` —— 该路径所在文件系统的可用空间（KB），默认 /
- `probe::disk_total_kb [路径]` —— 该路径所在文件系统的总容量（KB），默认 /
- `probe::mem_total_kb` —— 物理内存总量（KB）
- `probe::mem_available_kb` —— 可用内存（KB）
- `probe::uptime_seconds` —— 系统已运行秒数
- `probe::loadavg` —— 1 / 5 / 15 分钟平均负载，空格分隔的三个数
- `probe::cpu_count` —— 在线 CPU 核心数
- `probe::cpu_model` —— CPU 型号
- `probe::cpu_jiffies` —— `总时间 空闲时间` 两个累计计数（单位 jiffy）
- `probe::podman_running` —— 运行中的容器数
- `probe::podman_total` —— 容器总数，含已停止
- `probe::podman_ports` —— 每个容器的端口映射，一行 `名字<制表符>映射`，没映射的也占一行
- `probe::docker_running` —— 运行中的 Docker 容器数
- `probe::docker_total` —— Docker 容器总数，含已停止
- `probe::docker_ports` —— 每个 Docker 容器的端口映射，一行 `名字<制表符>映射`
- `probe::container_engine` —— /usr/bin/docker 由谁提供：docker / podman / 空
- `probe::container_engines` —— 机器上真正装着的引擎，一行一个（podman / docker）
- `probe::container_inventory <engine>` —— 每个容器一行，制表符分隔十列：
- `probe::ssh_port` —— sshd 实际监听的端口
- `probe::sshd_effective <配置关键字>` —— sshd -T 的生效值，不是配置文件字面值
- `probe::user_home <用户>` —— 用户家目录
- `probe::ssh_authkeys <用户>` —— 该用户 authorized_keys 中的公钥条数，读不到为 0
- `probe::apt_upgrade_stats` —— 可升级的包数量，以及其中属于安全更新的数量
- `probe::auto_upgrades` —— APT::Periodic::Unattended-Upgrade 的生效值
- `probe::reboot_required` —— 是否需要重启，值为 yes / no
- `probe::ufw_rules` —— ufw 带编号的规则列表原文
- `probe::ufw_added_rules` —— 已添加的规则原文，**停用状态下也读得到**
- `probe::container_subnets` —— 两个引擎所有容器网络的网段，一行一个，已去重
- `probe::ufw_default_incoming` —— ufw 的默认入站策略，值为 deny / reject / allow / unknown
- `probe::ufw_port_guarded <端口>` —— 该端口是否真的被防火墙挡着，值为 yes / no
- `probe::ufw_active` —— ufw 是否已启用，值为 yes / no

## `lib/secure.sh` · L3 能力

- `os::secure_key_valid <key>` —— 凭据 key 是否带命名空间，只给返回码
- `os::secure_ns <组件标识>` —— 打印该组件的凭据命名空间前缀
- `os::secure_get <key> [默认值]`
- `os::secure_load [--not-secret] <key> <变量名>` —— 读进变量，**并在当前 shell 登记脱敏**
- `os::secure_require <key>...` —— 缺任何一个即以退出码 3 终止
- `os::secure_set [--not-secret] <key> <值>`
- `os::secure_del <key>`
- `os::secure_list` —— 打印全部 key（**不打印值**），供 doctor 与卸载使用

## `lib/sql.sh` · L3 能力

- `os::sql_ident <标识符>` —— 打印带反引号的安全标识符
- `os::sql_str <值>` —— 打印带单引号的安全字符串字面量
- `os::sql_defaults_file <变量名> <用户> <密码> [主机]` —— 写临时配置文件，路径写进变量
- `os::sql_exec [--defaults-file <路径>] [--allow-fail] <desc> -- <SQL>`
- `os::sql_query [--defaults-file <路径>] [--timeout <秒>] <desc> -- <SQL>`

## `lib/state.sh` · L3 能力

- `os::state_id_valid <组件标识>` —— 组件标识是否合法，只给返回码
- `os::state_type <组件标识>` —— 打印 type 部分
- `os::state_instance <组件标识>` —— 打印 instance 部分，单实例组件为空
- `os::state_health <变量名>` —— 返回 missing / empty / ok / recovered / corrupt
- `os::state_get <组件标识> <键> [默认值]`
- `os::state_has <组件标识>` —— state 中是否已登记该组件，只给返回码
- `os::state_list [type]` —— 列出组件标识，去重；给了 type 只列该 type 的实例
- `os::state_snapshot` —— 把整份 state 读进两个平行数组，同一下标是同一个组件
- `os::state_resources <组件标识> <键>` —— 列出该组件某个多值键的全部值
- `os::state_units <组件标识>` —— 列出该组件的 unit（带 own:/ext: 前缀）
- `os::state_resource_add <组件标识> <pkg|file|divert|alt> <值>`
- `os::state_resource_del <组件标识> <pkg|file|divert|alt> <值>`
- `os::state_set <组件标识> <键>=<值> [<键>=<值>...]`
- `os::state_unit_add <组件标识> <own:|ext:><unit>`
- `os::state_del <组件标识>`
- `os::version_cmp <a> <b>` —— 打印 -1 / 0 / 1

## `lib/systemd.sh` · L3 能力

- `os::systemd_touched` —— 打印本次执行动过的全部 unit
- `os::systemd_daemon_reload` —— 重新加载 systemd 配置
- `os::systemd_install <unit 文件路径> <own|ext>`
- `os::systemd_enable <unit> [--now] [own|ext]`
- `os::systemd_disable <unit>` —— 禁用开机自启
- `os::systemd_start <unit> / os::systemd_stop <unit>`
- `os::systemd_stop <unit>` —— 停止服务
- `os::systemd_kick <unit>` —— 让一个周期性 unit 提前跑一轮，不等它、不记变更
- `os::systemd_restart <unit>`
- `os::systemd_reload <unit>`
- `os::systemd_remove <own:|ext:><unit>`

## `lib/template.sh` · L3 能力

- `os::template_source <模板文件名> <输出变量>` —— 解析模板实际来源，路径写进变量
- `os::php_str <值>` —— 转义反斜杠与单引号，安全放进 PHP 单引号字符串
- `os::install_template [--backup] [--mode <八进制>] <模板> <目标> [KEY=VALUE...]`
- `os::install_file [--backup] [--quiet] [--mode <八进制>] <源文件> <目标>`
- `os::write_public <文件名> <内容>` —— 把只读产物原子写入 public/，0644
