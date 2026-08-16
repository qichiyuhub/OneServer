#!/usr/bin/env bats
#
# lib/probe.sh 的单元测试
#
# 两条硬性要求各有一组用例：
#   * 每项都有超时（D18 / K14）—— 没超时的话 podman 一挂工具就开不了机
#   * 双数据路径必须标注来源与时间（D44）
#     其中最要紧的是：缓存缺失时**必须说出来**，禁止留空、禁止显示过期值而不告知

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log exec errors probe
    OS_LOG_DIR="${BATS_TEST_TMPDIR}/log"
    OS_LOG_MAIN="${OS_LOG_DIR}/oneserver.log"
    OS_LOG_JSONL="${OS_LOG_DIR}/oneserver.jsonl"
    OS_AUDIT_LOG="${OS_LOG_DIR}/audit.log"
    OS_PUBLIC_DIR="${BATS_TEST_TMPDIR}/public"
    OS_PROBE_SNAPSHOT="${OS_PUBLIC_DIR}/probe.tsv"
    OS_PROBE__KEYS=()
    OS_PROBE__VALS=()
    log::init test
    os_test_no_tty
}

os_is_root() { [ "$(id -u)" -eq 0 ]; }

os_have_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-system-running >/dev/null 2>&1 || [ "$(systemctl is-system-running 2>/dev/null)" = degraded ] || return 1
    return 0
}

# --- 基本探测 ---

# probe::* 不打印，结果在 OS_PROBE_VALUE 里 —— 用 $( ) 取值会丢掉
# OS_PROBE_SOURCE / OS_PROBE_AGE，那正是这个 API 要防的事。
@test "os_release 系列能拿到值，且标注为实时" {
    os_is_root || skip '非 root 走缓存路径，另有用例'
    probe::os_id
    [ -n "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [ "${OS_PROBE_SOURCE}" = 'live' ]
    [ "$(probe::describe)" = '实时' ]

    probe::os_pretty && [ -n "${OS_PROBE_VALUE}" ]
    probe::arch && [ -n "${OS_PROBE_VALUE}" ]
    probe::kernel && [ -n "${OS_PROBE_VALUE}" ]
}

@test "probe::* 一律不打印，避免调用方用 \$( ) 丢掉来源标注" {
    os_is_root || skip '非 root'
    run probe::os_id
    [ -z "${output}" ]
    run probe::mem_total_kb
    [ -z "${output}" ]
}

@test "内存与运行时长" {
    os_is_root || skip '非 root'
    probe::mem_total_kb
    [ "${OS_PROBE_VALUE}" -gt 0 ]
    probe::uptime_seconds
    [ "${OS_PROBE_VALUE}" -ge 0 ]
    probe::disk_free_kb /
    [ "${OS_PROBE_VALUE}" -gt 0 ]
}

@test "未安装的包返回空且 status=missing，不报错退出" {
    os_is_root || skip '非 root'
    probe::package_version 'this-package-does-not-exist'
    [ -z "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'missing' ]
    [ "$(probe::describe)" = '未安装' ]
    probe::package_installed 'this-package-does-not-exist'
    [ "${OS_PROBE_VALUE}" = 'no' ]
}

@test "已安装的包能拿到版本" {
    os_is_root || skip '非 root'
    probe::package_version 'bash'
    [ -n "${OS_PROBE_VALUE}" ]
    probe::package_installed 'bash'
    [ "${OS_PROBE_VALUE}" = 'yes' ]
}

@test "package_candidate 取到源里的候选版本，源里没有则为空" {
    os_is_root || skip '非 root'
    probe::package_candidate 'bash'
    [ -n "${OS_PROBE_VALUE}" ]
    # 只取第一个词，不能把后面的 Version table 一起带上
    case "${OS_PROBE_VALUE}" in *[[:space:]]*) return 1 ;; esac

    probe::package_candidate 'this-package-does-not-exist'
    [ -z "${OS_PROBE_VALUE}" ]
}

# 非 root 从快照读到的值，换行已被 snapshot_flush 压成空格 ——
# 按换行切分的实现会在这里把整张版本表当成版本号返回。
# 走缓存路径也是**验证「原始输出 → 值」那段解析**的唯一办法：本机装没装
# 被探的东西不由测试决定，而解析规则必须每次都被检到。
os_fake_snapshot() {
    mkdir -p "${OS_PUBLIC_DIR}"
    local now
    printf -v now '%(%s)T' -1
    printf '#ts\t%s\n%s\t%s\n' "${now}" "${1}" "${2}" >"${OS_PROBE_SNAPSHOT}"
    probe::_is_root() { return 1; }
}

@test "package_candidate 对压平成单行的缓存值也只取候选版本" {
    os_fake_snapshot 'pkg.fakepkg.candidate' 'fakepkg:   Installed: (none)   Candidate: 1.2.3-4   Version table:      1.2.3-4 500'
    probe::package_candidate 'fakepkg'
    [ "${OS_PROBE_VALUE}" = '1.2.3-4' ]
    [ "${OS_PROBE_SOURCE}" = 'cache' ]
}

@test "package_candidate 把 (none) 当成源里没有" {
    os_fake_snapshot 'pkg.fakepkg.candidate' 'fakepkg:   Installed: (none)   Candidate: (none)   Version table:'
    probe::package_candidate 'fakepkg'
    [ -z "${OS_PROBE_VALUE}" ]
}

# 认错 docker 命令的主人，后果是 apt 当场失败（两者都提供 /usr/bin/docker）。
# 三种取值各一条 —— 只测「有没有 docker」的话，podman 接管那种情况会被算成有。
@test "container_engine 认出 podman-docker 接管的 docker 命令" {
    os_fake_snapshot 'container.engine' 'podman version 5.4.1'
    probe::container_engine
    [ "${OS_PROBE_VALUE}" = 'podman' ]
}

@test "container_engine 认出真 Docker" {
    os_fake_snapshot 'container.engine' 'Docker version 27.5.1, build 9f9e405'
    probe::container_engine
    [ "${OS_PROBE_VALUE}" = 'docker' ]
}

# 第三方 apt 源的路径用的是代号，不是 VERSION_ID。写错的后果不是当场报错：
# apt 对不存在的 suite 只在末尾打一行警告并返回 0，失败推迟到装包才现形
@test "os_codename 给的是代号而不是版本号" {
    os_fake_snapshot 'os.codename' 'trixie'
    probe::os_codename
    [ "${OS_PROBE_VALUE}" = 'trixie' ]
}

# component_version docker 的判据是 dockerd 而不是 docker：
# 装了 podman-docker 的机器上 `docker --version` 打的是 podman 的版本，
# 拿它判断「装没装 Docker」会在最需要区分的那台机器上答错
@test "component_version docker 读的是 dockerd 的版本，且只给版本号" {
    os_fake_snapshot 'component.docker.version' 'Docker version 28.0.1, build bbd0a17'
    probe::component_version docker
    # 判据仍是 dockerd（不是 docker，那条在装了 podman-docker 的机器上会答错），
    # 但返回值是版本号本身：整行输出拿去和 state 里记的版本比对永远不等
    [ "${OS_PROBE_VALUE}" = '28.0.1' ]
}

# 两个引擎的容器互相看不见，探测键也必须分开 —— 串了的话，
# 菜单会把 podman 的容器数显示成 Docker 的
@test "docker 与 podman 的探测键不共用" {
    os_fake_snapshot 'component.podman.version' 'podman version 5.4.1'
    probe::component_version docker
    [ -z "${OS_PROBE_VALUE}" ]

    # 快照落盘时制表符被压成空格（见 snapshot_flush），所以缓存里就是这个形态
    os_fake_snapshot 'docker.ports' 'web 0.0.0.0:8080->80/tcp'
    probe::docker_ports
    [ "${OS_PROBE_VALUE}" = 'web 0.0.0.0:8080->80/tcp' ]
    probe::podman_ports
    [ -z "${OS_PROBE_VALUE}" ]
}

# 多键快照 —— os_fake_snapshot 每次重写整个文件，只能塞一个 key
os_fake_snapshot2() {
    mkdir -p "${OS_PUBLIC_DIR}"
    local now
    printf -v now '%(%s)T' -1
    printf '#ts\t%s\n%s\t%s\n%s\t%s\n' "${now}" "${1}" "${2}" "${3}" "${4}" >"${OS_PROBE_SNAPSHOT}"
    probe::_is_root() { return 1; }
}

# **两个引擎必须各用各的缓存 key**。共用一个的话后探的会覆盖先探的，
# 而这正是「装了 podman 和 docker、面板上却只看得见一个」的成因
@test "container_inventory: 每个引擎各用各的缓存 key" {
    os_fake_snapshot2 'container.inventory.podman' 'sub-store' \
        'container.inventory.docker' 'adguardhome'
    probe::container_inventory podman
    [ "${OS_PROBE_VALUE}" = 'sub-store' ]
    probe::container_inventory docker
    [ "${OS_PROBE_VALUE}" = 'adguardhome' ]
}

# container_engines 与 container_engine 答的是两个问题，key 也必须是两个：
# 前者「机器上有哪些引擎」，后者「docker 这个命令名归谁」。拿后者当前者用，
# 一台真 Docker 与 podman 并存的机器上，podman 里的容器会整个消失
@test "container_engines 与 container_engine 不共用 key" {
    os_fake_snapshot2 'container.engine' 'Docker version 27.5.1, build 9f9e405' \
        'container.engines' 'podman docker'
    probe::container_engine
    [ "${OS_PROBE_VALUE}" = 'docker' ]
    probe::container_engines
    [ "${OS_PROBE_VALUE}" = 'podman docker' ]
}

@test "container_engines: 没装任何引擎时是空值，不是失败" {
    os_is_root || skip '非 root 走缓存路径'
    command -v podman >/dev/null 2>&1 && skip '本机有 podman，不动它'
    command -v docker >/dev/null 2>&1 && skip '本机有 docker，不动它'
    probe::container_engines
    [ -z "${OS_PROBE_VALUE}" ]
}

@test "container_engine 在没有 docker 命令时是空值且 status=missing" {
    os_is_root || skip '非 root 走缓存路径，上面两条已覆盖'
    command -v docker >/dev/null 2>&1 && skip '本机有 docker 命令，不动它'
    probe::container_engine
    [ -z "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'missing' ]
}

# /etc/php 是硬编码路径（D72：路径不为测试而变得可被环境变量覆盖），
# 所以这条用例在一次性容器里写真的 /etc/php，跑完自己收拾。
@test "php_fpm_versions 只认有 fpm 目录的版本，且按版本序返回" {
    os_is_root || skip '要写 /etc/php'
    [ ! -d /etc/php ] || skip '本机已装 PHP，不动它'

    mkdir -p /etc/php/8.10/fpm /etc/php/8.9/fpm /etc/php/7.4/cli
    probe::php_fpm_versions
    local got=${OS_PROBE_VALUE}
    rm -rf /etc/php

    # 8.9 在 8.10 之前 —— 字典序会给出相反的答案，所以这里必须是版本序
    [ "${got}" = '8.9 8.10' ]
}

@test "component_version php 报最高的 FPM 版本，不去问 dpkg 要 php 包" {
    os_is_root || skip '要写 /etc/php'
    [ ! -d /etc/php ] || skip '本机已装 PHP，不动它'

    # **没有一个叫 `php` 的包一定在**：装的是 php8.3-fpm 这类。落到默认分支
    # 去问 dpkg 要 `php`，一台装着 PHP 的机器也会答空 —— 而空会被 @requires
    # 读成「没装」，于是 PHP 相关的条目整个从菜单上消失
    mkdir -p /etc/php/8.3/fpm /etc/php/8.4/fpm
    probe::component_version php
    local got=${OS_PROBE_VALUE}
    rm -rf /etc/php

    # 多版本共存时报最高的：`@requires php>=8.4` 问的是「有没有够新的 PHP」
    [ "${got}" = '8.4' ]
}

@test "php_fpm_versions 在没装 PHP 时是空值而不是失败" {
    os_is_root || skip '非 root'
    [ ! -d /etc/php ] || skip '本机已装 PHP，不动它'
    probe::php_fpm_versions
    [ -z "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'ok' ]
}

# 算不出来必须返回空，**不能返回 0**：面板拿 0 会显示成「0 B」，
# 一个几十 G 的卷于是看着像没占地方 —— 比不显示更糟。
@test "dir_size_kb 对不存在的路径返回空而不是 0" {
    os_is_root || skip '非 root 走缓存路径'
    run probe::dir_size_kb '/no/such/dir/for/oneserver-test'
    [ "${status}" -eq 0 ]
    probe::dir_size_kb '/no/such/dir/for/oneserver-test'
    [ -z "${OS_PROBE_VALUE}" ]
}

@test "dir_size_kb 对真实目录返回数字" {
    os_is_root || skip '非 root 走缓存路径'
    probe::dir_size_kb /etc
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]+$ ]]
}

# 没装 Caddy 的容器里跑：拿不到 build-info 时必须是「空值 + 结构化状态」，
# 而不是让调用方看见一个失败退出码。caddy-manager 的令牌流程靠它判断
# 「插件在不在」，探测一失败就把每个提供商都判成缺插件，等于永远弹告警。
@test "caddy_plugins 在没装 Caddy 时是空值而不是失败" {
    os_is_root || skip '非 root 走缓存路径'
    command -v caddy >/dev/null 2>&1 && skip '本机有 caddy，不动它'
    run probe::caddy_plugins
    [ "${status}" -eq 0 ]
    probe::caddy_plugins
    [ -z "${OS_PROBE_VALUE}" ]
}

@test "service_active 对不存在的 unit 不报错" {
    os_is_root || skip '非 root'
    run probe::service_active 'no-such-unit.service'
    [ "${status}" -eq 0 ]
    probe::unit_exists 'no-such-unit.service'
    [ "${OS_PROBE_VALUE}" = 'no' ]
}

# `systemctl is-active` 对**停着的** unit 返回退出码 3，对不存在的也非零。
# 只看退出码的话「装了没跑」会被写成「没装」—— 而这两件事在界面上完全不同。
# 所以这两个 probe 认的是 systemctl 打出来的状态词，不是退出码。
@test "service_active 拿到的是状态词，不是「探测失败」" {
    os_is_root || skip '非 root'
    probe::service_active 'no-such-unit.service'
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [ "${OS_PROBE_VALUE}" = 'inactive' ]
}

@test "service_enabled 对 disabled 的 unit 同样给出状态词" {
    os_is_root || skip '非 root'
    probe::service_enabled 'no-such-unit.service'
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [ -n "${OS_PROBE_VALUE}" ]
}

@test "--rc-ok 只在命令确实打了东西出来时才认，空输出仍算 missing" {
    os_is_root || skip '非 root'
    probe::_probe --rc-ok 'test.rcok' 3 -- sh -c 'exit 7'
    [ "${OS_PROBE_STATUS}" = 'missing' ]
}

# --- SSH 与系统更新（F4 批次 4 · safe 移植时新增）---

# **这条守的是一个真实的跨发行版差异**（两台真机实测）：
#   Ubuntu 24.04 / openssh 9.6   sshd -T 打全小写   `permitrootlogin yes`
#   Debian 13    / openssh 10.x  sshd -T 打驼峰     `PermitRootLogin yes`
# 按原样比对的话，同一份代码在其中一个发行版上永远读不到值，
# 而表现是「工具说密码登录已关闭，实际还开着」——正是 D65 那一类只在
# 一个发行版上暴露的 bug。这里造一个打驼峰的假 sshd 来守住 tolower。
@test "sshd_effective 认得驼峰与小写两种 sshd -T 输出" {
    os_is_root || skip '非 root'
    local fake="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${fake}"
    cat >"${fake}/sshd" <<'EOF'
#!/bin/sh
printf 'Port 2222\nPermitRootLogin prohibit-password\npasswordauthentication no\n'
EOF
    chmod 0755 "${fake}/sshd"
    PATH="${fake}:${PATH}"

    probe::sshd_effective PermitRootLogin
    [ "${OS_PROBE_VALUE}" = 'prohibit-password' ]
    probe::sshd_effective passwordauthentication
    [ "${OS_PROBE_VALUE}" = 'no' ]
    probe::sshd_effective port
    [ "${OS_PROBE_VALUE}" = '2222' ]
}

@test "sshd_effective 问一个不存在的项时是空值，不是失败" {
    os_is_root || skip '非 root'
    probe::sshd_effective nosuchkeyword
    [ -z "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'ok' ]
}

@test "ssh_authkeys 数得出公钥条数，没有文件时是 0 而不是空" {
    os_is_root || skip '非 root'
    probe::user_home root
    local home="${OS_PROBE_VALUE}"
    [ -n "${home}" ]
    [ ! -e "${home}/.ssh/authorized_keys" ] || skip '本机 root 已有 authorized_keys，不动它'

    probe::ssh_authkeys root
    [ "${OS_PROBE_VALUE}" = '0' ]

    mkdir -p "${home}/.ssh"
    printf '# 注释不算\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5 a@b\nssh-rsa AAAAB3Nza c@d\n' \
        >"${home}/.ssh/authorized_keys"
    probe::ssh_authkeys root
    local got="${OS_PROBE_VALUE}"
    rm -f "${home}/.ssh/authorized_keys"
    [ "${got}" = '2' ]
}

@test "ssh_authkeys 对不存在的用户返回 0，不报错退出" {
    os_is_root || skip '非 root'
    run probe::ssh_authkeys no-such-user-xyz
    [ "${status}" -eq 0 ]
    probe::ssh_authkeys no-such-user-xyz
    [ "${OS_PROBE_VALUE}" = '0' ]
}

@test "listening_ports 给出的是一串数字，且从小到大" {
    os_is_root || skip '非 root'
    probe::listening_ports
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    local prev=0 p
    local IFS=' '
    for p in ${OS_PROBE_VALUE}; do
        [[ "${p}" =~ ^[0-9]+$ ]]
        [ "${p}" -gt "${prev}" ]
        prev="${p}"
    done
}

@test "apt_upgrade_stats 给出制表符分隔的两个数字，安全更新数不超过总数" {
    os_is_root || skip '非 root'
    probe::apt_upgrade_stats
    [ "${OS_PROBE_STATUS}" != 'timeout' ]
    local total security
    IFS=$'\t' read -r total security <<<"${OS_PROBE_VALUE}"
    [[ "${total}" =~ ^[0-9]+$ ]]
    [[ "${security}" =~ ^[0-9]+$ ]]
    [ "${security}" -le "${total}" ]
}

@test "auto_upgrades 读的是 apt 自己的配置栈，没配就是空" {
    os_is_root || skip '非 root'
    run probe::auto_upgrades
    [ "${status}" -eq 0 ]
    probe::auto_upgrades
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]*$ ]]
}

@test "reboot_required 一定给出 yes/no，不留空" {
    os_is_root || skip '非 root'
    probe::reboot_required
    case "${OS_PROBE_VALUE}" in
        yes | no) ;;
        *) return 1 ;;
    esac
}

# --- 超时（D18 / K14）---

@test "超时不阻塞，status=timeout 且不报错退出" {
    os_is_root || skip '非 root'
    local start end
    start=$(date +%s)
    run probe::_probe 'test.slow' 1 -- sleep 20
    end=$(date +%s)
    [ "${status}" -eq 0 ]
    [ $((end - start)) -lt 5 ]
    probe::_probe 'test.slow' 1 -- sleep 20
    [ "${OS_PROBE_STATUS}" = 'timeout' ]
    [ "$(probe::describe)" = '探测超时' ]
}

@test "超时会进日志（排查时要看得到）" {
    os_is_root || skip '非 root'
    probe::_probe 'test.slow2' 1 -- sleep 20
    grep -q '超时' "${OS_LOG_MAIN}"
}

@test "每个探测项都传了超时参数" {
    # 静态检查：probe::_probe 的第二个参数不能空着
    run bash -c "grep -nE 'probe::_probe [^ ]+ (--|\\\$)' '${OS_TEST_REPO_ROOT}/lib/probe.sh'"
    [ "${status}" -ne 0 ]
}

# --- 双数据路径（D44）---

@test "root 探测后能落快照，且是 0644" {
    os_is_root || skip '非 root'
    probe::os_id
    probe::mem_total_kb
    probe::snapshot_flush
    [ -f "${OS_PROBE_SNAPSHOT}" ]
    [ "$(stat -c %a "${OS_PROBE_SNAPSHOT}")" = '644' ]
    grep -q '^#ts' "${OS_PROBE_SNAPSHOT}"
    grep -q '^os.id' "${OS_PROBE_SNAPSHOT}"
}

@test "OS_PROBE_NO_SNAPSHOT=1 时不落快照，也不把目录建回来" {
    os_is_root || skip '非 root'
    probe::os_id
    # 卸载器删完落点之后正是这个状态：目录没了，而钩子还要跑一次。
    # 没有这个开关的话，退出时 mkdir 会把刚删掉的目录原样造回来
    rm -rf "${OS_PUBLIC_DIR}"
    OS_PROBE_NO_SNAPSHOT=1
    probe::snapshot_flush
    [ ! -e "${OS_PUBLIC_DIR}" ]
    OS_PROBE_NO_SNAPSHOT=0
}

@test "快照落地前过脱敏 —— 它是 0644，本机任何用户都读得到" {
    os_is_root || skip '非 root'
    local pass='S3cr3t-P@ssw0rd-长密码'
    log::secret_add "${pass}"
    # 探测落的是命令**原始输出**，哪天有个探测项碰到含凭据的配置，
    # 明文就直接进了这个人人可读的文件
    probe::_remember 'test.raw' "user=root password=${pass}"
    probe::snapshot_flush

    run grep -F "${pass}" "${OS_PROBE_SNAPSHOT}"
    [ "${status}" -ne 0 ]
    grep -q '\*\*\*' "${OS_PROBE_SNAPSHOT}"
}

@test "缓存命中时标注来源与时间" {
    mkdir -p "${OS_PUBLIC_DIR}"
    local now
    printf -v now '%(%s)T' -1
    printf '#ts\t%d\nos.id\tdebian\n' "$((now - 120))" >"${OS_PROBE_SNAPSHOT}"

    # 强制走缓存路径
    probe::_is_root() { return 1; }
    probe::os_id
    [ "${OS_PROBE_VALUE}" = 'debian' ]
    [ "${OS_PROBE_SOURCE}" = 'cache' ]
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [ "${OS_PROBE_AGE}" -ge 110 ]
    [ "$(probe::describe)" = '缓存 · 2 分钟前' ]
}

@test "缓存过期时明确说过期，不静默用旧值" {
    mkdir -p "${OS_PUBLIC_DIR}"
    local now
    printf -v now '%(%s)T' -1
    printf '#ts\t%d\nos.id\tdebian\n' "$((now - 99999))" >"${OS_PROBE_SNAPSHOT}"

    probe::_is_root() { return 1; }
    probe::os_id
    [ "${OS_PROBE_STATUS}" = 'stale' ]
    [[ "$(probe::describe)" == *'过期'* ]]
}

@test "缓存缺失时必须说出来，禁止留空" {
    probe::_is_root() { return 1; }
    probe::os_id
    [ -z "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'unavailable' ]
    [ "$(probe::describe)" = '需要 root 权限，或面板采集未启用（oneserver web）' ]
}

@test "非 root 不写快照" {
    probe::_is_root() { return 1; }
    OS_PROBE__KEYS=('x')
    OS_PROBE__VALS=('y')
    probe::snapshot_flush
    [ ! -f "${OS_PROBE_SNAPSHOT}" ]
}

@test "describe 覆盖全部状态，不会输出空串" {
    local st
    for st in ok stale timeout missing unavailable none bogus; do
        OS_PROBE_STATUS=${st}
        OS_PROBE_SOURCE='live'
        [ -n "$(probe::describe)" ]
    done
}

# --- 分层与规范 ---

@test "probe.sh 不 source，也不依赖同层模块" {
    run grep -nE '^[[:space:]]*(source|\.)[[:space:]]' "${OS_TEST_REPO_ROOT}/lib/probe.sh"
    [ "${status}" -ne 0 ]
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/probe.sh' \
        | grep -nE '(os::state_|os::secure_|os::sql_|os::systemd_)'"
    [ "${status}" -ne 0 ]
}

@test "probe.sh 的探测一律经 os::query，不裸调外部命令" {
    # 除 probe::_probe 内部那一处，文件里不该再出现直接执行 systemctl/dpkg 等
    run bash -c "grep -v '^[[:space:]]*#' '${OS_TEST_REPO_ROOT}/lib/probe.sh' \
        | grep -nE '^[[:space:]]*(systemctl|dpkg-query|df|free|ss|podman|ufw) '"
    [ "${status}" -ne 0 ]
}

@test "快照里不含凭据相关的 key" {
    os_is_root || skip '非 root'
    probe::os_id
    probe::snapshot_flush
    run grep -iE 'pass|token|secret|key=' "${OS_PROBE_SNAPSHOT}"
    [ "${status}" -ne 0 ]
}

# --- systemd 相关 ---

@test "timer_next: 存在的 timer 给得出时间，不存在的为空且不报错" {
    os_is_root || skip '非 root'
    probe::timer_next 'this-timer-does-not-exist.timer'
    [ -z "${OS_PROBE_VALUE}" ]
}

# 定时任务成没成只有 systemd 说了算 —— state 里那句「上次执行 ok」
# 是脚本跑完才写的，中途被打断就永远停在上一次的成功上
@test "unit_result: 跑过的 unit 给得出结果，没跑过的为空" {
    os_is_root || skip '非 root'
    probe::unit_result 'this-unit-does-not-exist.service'
    [ -z "${OS_PROBE_VALUE}" ]

    # 系统上必然存在且必然跑过的一个 unit
    probe::unit_result 'systemd-journald.service'
    [ "${OS_PROBE_STATUS}" = 'ok' ]
}

# 「压根不存在的 unit」和「已装但没被 timer 触发过」是两条不同的路径
# （前者 LoadState=not-found，后者 loaded），而后者才是备份定时任务实际会
# 碰到的情况——已实测确认：只要 unit 被加载过，哪怕从没跑过，Result
# 就已经是 success，光查 Result 判断不出「跑没跑过」。
@test "unit_result: 已装但从未被 timer 触发过的真实 unit 判定为空（不能只查 Result）" {
    os_is_root || skip '非 root'
    os_have_systemd || skip '没有可用的 systemd'
    local svc='oneserver-bats-probe.service' timer='oneserver-bats-probe.timer'
    cat >"/etc/systemd/system/${svc}" <<EOF
[Unit]
Description=probe.bats fixture
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
    cat >"/etc/systemd/system/${timer}" <<EOF
[Unit]
Description=probe.bats fixture timer
[Timer]
OnCalendar=*-*-* 03:00:00
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "${timer}" >/dev/null

    probe::unit_result "${svc}"
    [ -z "${OS_PROBE_VALUE}" ]

    systemctl start "${svc}"
    probe::unit_result "${svc}"
    [ "${OS_PROBE_VALUE}" = 'success' ]

    systemctl disable --now "${timer}" >/dev/null
    rm -f "/etc/systemd/system/${svc}" "/etc/systemd/system/${timer}"
    systemctl daemon-reload
}

# 「起来之后有没有崩过」不能靠隔一秒查一次 is-active：RestartSec 默认 100 毫秒，
# 非 active 的窗口只有一两百毫秒，秒级采样几乎必然错过。NRestarts 是累加计数，
# 错不过去 —— 这条守的是它确实读得出来。
#
# **`0` 不能反过来当「这个 unit 存在」用**：systemd 对压根不存在的 unit 也答 0
# （它给的是 stub unit 的属性默认值）。消费者要判存在得另问 unit_exists 或
# service_active，这里把这个反直觉的形态钉住。
@test "unit_restarts: 没重启过的 unit 是 0，不存在的 unit 同样是 0" {
    os_is_root || skip '非 root'
    os_have_systemd || skip '没有可用的 systemd'

    probe::unit_restarts 'systemd-journald.service'
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [ "${OS_PROBE_VALUE}" = '0' ]

    probe::unit_restarts 'this-unit-does-not-exist.service'
    [ "${OS_PROBE_VALUE}" = '0' ]
}

@test "podman_ports: 没装 podman 或没有容器时是空值，不是失败" {
    os_is_root || skip '非 root'
    command -v podman >/dev/null 2>&1 || skip '本机没有 podman'
    probe::podman_ports
    [ "${OS_PROBE_STATUS}" = 'ok' ]
}

# --- 分档快照（面板采集器）---

@test "unit_exists 把规范化后的 yes/no 写回缓存" {
    os_is_root || skip '非 root'
    os_have_systemd || skip '本机没有可用的 systemd'
    probe::unit_exists 'definitely-not-a-real-unit.service'
    [ "${OS_PROBE_VALUE}" = 'no' ]
    probe::snapshot_flush
    # 快照里必须也是 no。留原始输出（空）的话，只读快照的消费者
    # 分不出「unit 不存在」和「探测失败」，而这两件事的处置完全不同
    grep -q '^unit.definitely-not-a-real-unit.service.exists	no$' "${OS_PROBE_SNAPSHOT}"
}

@test "disk_total_kb 给出分母且带超时" {
    os_is_root || skip '非 root'
    probe::disk_total_kb /
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [[ ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]]
    [ "${OS_PROBE_VALUE}" -gt 0 ]
}

@test "component_version 摘出版本号本身，不返回命令整行输出" {
    # 各分支输出格式不同，不统一的话拿它和 state 里记的版本比对永远不等，
    # 「版本漂移」就成了永不消失的假告警
    OS_PROBE_VALUE='podman version 5.8.3'
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = '5.8.3' ]

    OS_PROBE_VALUE='v22.1.0'
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = '22.1.0' ]

    OS_PROBE_VALUE='Valkey server v=8.0.1 sha=00000000:0 malloc=libc bits=64'
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = '8.0.1' ]

    OS_PROBE_VALUE='Docker version 24.0.7, build afdd53b'
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = '24.0.7' ]
}

@test "component_version nodejs 走受限 PATH 外的统一 alternatives 入口" {
    probe::_probe() {
        [ "${1}" = 'component.nodejs.version' ]
        [ "${3}" = '--' ]
        [ "${4}" = "${OS_LOCAL_BIN_DIR}/node" ]
        [ "${5}" = '--version' ]
        OS_PROBE_STATUS='ok'
        OS_PROBE_SOURCE='live'
        OS_PROBE_VALUE='v22.1.0'
    }

    probe::component_version nodejs
    [ "${OS_PROBE_STATUS}" = 'ok' ]
    [ "${OS_PROBE_VALUE}" = '22.1.0' ]
}

@test "Node 安装后的运行版本验证复用 component_version" {
    local source_file="${OS_TEST_REPO_ROOT}/script/install/install_nodejs.sh"
    grep -q 'probe::component_version nodejs' "${source_file}"
    run grep -nE 'os::query[^#]*(OS_LOCAL_BIN_DIR|NODE_LINK_DIR).*node.*--version' "${source_file}"
    [ "${status}" -ne 0 ]
}

@test "_version_token 对已经是版本号的值幂等，摘不到就原样留着" {
    OS_PROBE_VALUE='11.4.5'
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = '11.4.5' ]

    OS_PROBE_VALUE=''
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = '' ]

    # 摘不到版本号时保留原值，而不是清空 —— 清空会被读成「没装」
    OS_PROBE_VALUE='unknown'
    probe::_version_token
    [ "${OS_PROBE_VALUE}" = 'unknown' ]
}

@test "hostname 取得到且不含空白" {
    probe::hostname
    # 容器里 /etc/hostname 一定有内容；空值会让面板上每台机器都显示「未知主机」
    [ -n "${OS_PROBE_VALUE}" ]
    [[ ! ${OS_PROBE_VALUE} =~ [[:space:]] ]]
}

# --- 版本、内存、端口 ---

# os-release 的字段不是每个发行版都齐 —— Debian 的滚动版没有 VERSION_ID。
# 因此要守的不是「一定有值」，而是**没有值时不能报 ok**：空值配 ok 会让消费者
# 拿着空串接着往下拼，而拼出来的东西看起来是好的。
@test "os_version 要么有值且 ok，要么明确报 missing" {
    os_is_root || skip '非 root 走缓存路径'
    probe::os_version
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        [ "${OS_PROBE_STATUS}" = 'ok' ]
        [[ ! ${OS_PROBE_VALUE} =~ [[:space:]] ]]
    else
        [ "${OS_PROBE_STATUS}" = 'missing' ]
    fi
}

@test "mem_available_kb 是正数，且不大于总量" {
    os_is_root || skip '非 root'
    probe::mem_available_kb
    [ "${OS_PROBE_VALUE}" -gt 0 ]
    local avail=${OS_PROBE_VALUE}
    probe::mem_total_kb
    [ "${avail}" -le "${OS_PROBE_VALUE}" ]
}

@test "loadavg 是三个数，cpu_count 是正整数" {
    os_is_root || skip '非 root'
    probe::loadavg
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]+\.[0-9]+\ [0-9]+\.[0-9]+\ [0-9]+\.[0-9]+$ ]]
    probe::cpu_count
    [ "${OS_PROBE_VALUE}" -gt 0 ]
}

@test "cpu_model 从 cpuinfo 取得非空型号" {
    os_is_root || skip '非 root'
    probe::cpu_model
    [ "${OS_PROBE_STATUS}" = ok ]
    [ -n "${OS_PROBE_VALUE}" ]
    [[ ${OS_PROBE_VALUE} != *$'\n'* ]]
}

# 累计计数只有满足「空闲 ≤ 总量」才做得了差分：反过来的话消费者会算出
# 大于 100% 的使用率，而那种数字在图上是一根戳穿顶的假峰
@test "cpu_jiffies 给出总量与空闲两个累计数，且单调不减" {
    os_is_root || skip '非 root'
    probe::cpu_jiffies
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]+\ [0-9]+$ ]]
    local first=${OS_PROBE_VALUE}
    local t1=${first%% *} i1=${first##* }
    [ "${i1}" -le "${t1}" ]
    probe::cpu_jiffies
    local t2=${OS_PROBE_VALUE%% *}
    [ "${t2}" -ge "${t1}" ]
}

# 值只能是 yes / no —— 空值会让调用方的 `[[ x == yes ]]` 静默走进「没监听」，
# 而那正是「端口已被占用」这类判断要防的事
@test "port_listening 对没人监听的端口答 no，且从不返回空" {
    os_is_root || skip '非 root'
    probe::port_listening 59999
    [ "${OS_PROBE_VALUE}" = 'no' ]
    probe::port_listening 22
    [[ "${OS_PROBE_VALUE}" == 'yes' || "${OS_PROBE_VALUE}" == 'no' ]]
}

# 没人监听时地址族集合是空字符串，不是 'no' 这类占位词——调用方要用
# `for fam in ${want_families}` 遍历它，非数字/非法词会污染比对
@test "port_families 对没人监听的端口给空，值只由 v4/v6 组成" {
    os_is_root || skip '非 root'
    probe::port_families 59999
    [ -z "${OS_PROBE_VALUE}" ]
    local fam
    for fam in ${OS_PROBE_VALUE}; do
        [[ ${fam} == v4 || ${fam} == v6 ]]
    done
}

# --- 没装的东西：必须答得出来，不能崩 ---
#
# 容器里没有 podman / docker / ufw，而这几项恰恰是 K14 的来源：
# 探测一个不存在或挂起的命令，没有超时就会把整个工具拖住。
# 这里验的是另一半 —— 探不到时要有 status 标注，不是留个空值让调用方自己猜。

@test "podman 没装时不报错，来源被标注出来" {
    os_is_root || skip '非 root'
    run probe::podman_running
    [ "${status}" -eq 0 ]
    probe::podman_running
    [ -n "${OS_PROBE_STATUS}" ]
    [ -n "$(probe::describe)" ]
    probe::podman_total
    [ -n "${OS_PROBE_STATUS}" ]
}

@test "docker 没装时不报错，来源被标注出来" {
    os_is_root || skip '非 root'
    run probe::docker_running
    [ "${status}" -eq 0 ]
    probe::docker_running
    [ -n "${OS_PROBE_STATUS}" ]
    probe::docker_total
    [ -n "${OS_PROBE_STATUS}" ]
    [ -n "$(probe::describe)" ]
}

@test "ufw 的两项没装时也答得出来" {
    os_is_root || skip '非 root'
    run probe::ufw_active
    [ "${status}" -eq 0 ]
    probe::ufw_active
    [ -n "${OS_PROBE_STATUS}" ]
    run probe::ufw_rules
    [ "${status}" -eq 0 ]
}

# ufw_rules 只在防火墙**启用时**有内容：停用时 `ufw status numbered` 只打
# 一行 `Status: inactive`，规则一条都读不出来 —— 而它们全都还在 /etc/ufw 里。
# 面板据此显示过一份空规则表，与「停用不删规则」那句提示当场矛盾。
# 这一项是那条路的替代，容器里没装 ufw，能验的是「探不到时不崩、有 status」
@test "ufw_added_rules 没装时也答得出来" {
    os_is_root || skip '非 root'
    run probe::ufw_added_rules
    [ "${status}" -eq 0 ]
    probe::ufw_added_rules
    [ -n "${OS_PROBE_STATUS}" ]
    [ -n "$(probe::describe)" ]
}

# 防火墙界面拿它区分「启用后会被挡住」与「只听本地、根本不受影响」。
# 分错的后果是单向的坏：把 127.0.0.1 上的服务列进「将无法从外部访问」，
# 用户会照着提示去放行一个本来就进不来的端口 —— 真机上 12 个警告里 7 个是这么来的
@test "listening_scoped 把监听端口分成对外与仅本地两拨" {
    os_is_root || skip '非 root'
    run probe::listening_scoped
    [ "${status}" -eq 0 ]
    probe::listening_scoped
    [ -n "${OS_PROBE_STATUS}" ]

    # 拆分**不能用 `IFS=$'\t' read`**：TAB 是 IFS 空白，前导的那个会被吃掉，
    # 于是「一个对外端口都没有」时本地端口会被读进 pub 那一侧
    local pub=${OS_PROBE_VALUE%%$'\t'*} loc=''
    [[ ${OS_PROBE_VALUE} == *$'\t'* ]] && loc=${OS_PROBE_VALUE#*$'\t'}

    # 两边都只能是端口号。混进地址或 `[::1]` 这样的残片，
    # 说明地址与端口的拆分错了位。
    # **显式按空格切成数组**：这两侧是空格分隔的，而 lib 把 IFS 设成了
    # $'\n\t'，裸 `for p in ${pub}` 会把「22 80」当成一个词整体 ——
    # 单端口的机器上照样绿，多端口时才炸，是条会骗人的用例
    local -a pubs=() locs=()
    IFS=' ' read -ra pubs <<<"${pub}" || true
    IFS=' ' read -ra locs <<<"${loc}" || true

    local p
    for p in ${pubs[@]+"${pubs[@]}"} ${locs[@]+"${locs[@]}"}; do
        [[ ${p} =~ ^[0-9]+$ ]]
        ((p >= 1 && p <= 65535))
    done

    # 不相交：同一个端口既听 0.0.0.0 又听 127.0.0.1 时算对外 ——
    # 只要有一条对外的监听，防火墙的开关就影响得到它
    local q
    for p in ${pubs[@]+"${pubs[@]}"}; do
        for q in ${locs[@]+"${locs[@]}"}; do
            [ "${p}" != "${q}" ]
        done
    done
}

# 起一个真的只听 127.0.0.1 的监听器，验分类不是靠运气蒙对的。
# 没有 python3 就跳过 —— 这项验的是分类逻辑，不该为它引一个新依赖
@test "listening_scoped 把只听 127.0.0.1 的端口归进仅本地那一拨" {
    os_is_root || skip '非 root'
    command -v python3 >/dev/null 2>&1 || skip '没有 python3'

    python3 -c "
import socket, time, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 45671))
s.listen(1)
time.sleep(8)
" &
    local pid=$!
    sleep 2

    probe::listening_scoped
    # 拆分方式同上一条：`IFS=$'\t' read` 会吃掉前导 TAB，
    # 「一个对外端口都没有」时 loc 会被读进 pub，断言就成了自欺
    local pub=${OS_PROBE_VALUE%%$'\t'*} loc=''
    [[ ${OS_PROBE_VALUE} == *$'\t'* ]] && loc=${OS_PROBE_VALUE#*$'\t'}
    kill "${pid}" 2>/dev/null || true

    [[ " ${loc} " == *' 45671 '* ]]
    [[ " ${pub} " != *' 45671 '* ]]
}

@test "ssh_port 探不到时给空值加 status，不给一个瞎猜的 22" {
    os_is_root || skip '非 root'
    run probe::ssh_port
    [ "${status}" -eq 0 ]
    probe::ssh_port
    [ -n "${OS_PROBE_STATUS}" ]
    # 有值就必须是数字 —— 面板会拿它当端口显示，字符串会让人去连一个不存在的端口
    [[ -z ${OS_PROBE_VALUE} || ${OS_PROBE_VALUE} =~ ^[0-9]+$ ]]
}

# compose provider：注册表拿它决定「Compose 项目」这一条上不上菜单（@requires
# compose-provider），podman_compose.sh 拿它决定用哪个 provider。**同一个事实
# 两个消费者**，所以它必须在 probe 里而不是脚本里（§10）。
@test "compose_provider 没有任何 provider 时是空值而不是失败" {
    os_is_root || skip '非 root 走缓存路径'
    command -v docker-compose >/dev/null 2>&1 && skip '本机有 docker-compose，不动它'
    command -v podman-compose >/dev/null 2>&1 && skip '本机有 podman-compose，不动它'
    [ ! -x /usr/lib/docker/cli-plugins/docker-compose ] || skip '本机有 compose 插件，不动它'
    [ ! -x /usr/libexec/docker/cli-plugins/docker-compose ] || skip '本机有 compose 插件，不动它'

    run probe::compose_provider
    [ "${status}" -eq 0 ]
    probe::compose_provider
    [ -z "${OS_PROBE_VALUE}" ]
    [ "${OS_PROBE_STATUS}" = 'ok' ]
}

# **有值就必须是完整三列。** 少一列的话，detect_provider 的 read 会把版本读进
# 路径变量，然后 systemd wrapper 里写进一个不存在的 provider 路径 —— 项目起不来，
# 而报错指向的是 compose 文件
@test "compose_provider 有 provider 时给出「种类 版本 路径」三列" {
    os_is_root || skip '非 root 走缓存路径'
    probe::compose_provider
    [ -n "${OS_PROBE_VALUE}" ] || skip '本机没有任何 compose provider'

    local kind ver path
    IFS=$'\t' read -r kind ver path <<<"${OS_PROBE_VALUE}"
    case ${kind} in
        compose-v2 | podman-compose | compose-v1) ;;
        *) return 1 ;;
    esac
    [ -n "${path}" ]
    [ -x "${path}" ]
    # 版本可以探不到（老 podman-compose 不认 version --short），但探到就得是数字开头
    [[ -z ${ver} || ${ver} =~ ^[0-9] ]]
}

# 挑选顺序 v2 > podman-compose > v1 是 D203 定的，不是 podman 的默认顺序 ——
# v1 已停止维护，让它排前面等于默认用一个不认现代 compose 规范的实现
@test "compose_provider 有 Compose v2 时不会挑成 v1" {
    os_is_root || skip '非 root 走缓存路径'
    probe::compose_provider
    [ -n "${OS_PROBE_VALUE}" ] || skip '本机没有任何 compose provider'

    local kind ver
    IFS=$'\t' read -r kind ver _ <<<"${OS_PROBE_VALUE}"
    [ "${kind}" = 'compose-v1' ] || skip '本机挑到的不是 v1，这条约束无从检验'
    # 挑到 v1 就意味着一个 2.x 都没有；有的话上一段循环就先返回了
    [[ ${ver} =~ ^(0|1)([.]|$) ]]
}

# 与其余探测同一条硬性要求：必须带超时（D18 / K14）。compose provider 的
# 版本查询要执行外部二进制，一个挂住的 provider 会把菜单整个卡死
@test "compose_provider 带超时" {
    grep -A 4 'probe::compose_provider() {' "${OS_TEST_REPO_ROOT}/lib/probe.sh" \
        | grep -q 'OS_DEFAULT_PROBE_TIMEOUT'
}

# **判据是「现在真的能用」，不是「有没有 provider」。** 实测踩过：机器上有
# Docker 的 Compose v2 插件、podman.socket 是 disabled，菜单把「Compose 项目」
# 列了出来，而 Compose v2 说的是 Docker API，没有那个 socket 一个项目也起不了。
@test "component_version compose-usable 在 v2 provider 且 podman.socket 未启用时为空" {
    os_is_root || skip '非 root 走缓存路径'
    probe::compose_provider
    [ -n "${OS_PROBE_VALUE}" ] || skip '本机没有任何 compose provider'
    local kind
    IFS=$'\t' read -r kind _ _ <<<"${OS_PROBE_VALUE}"
    [ "${kind}" = 'compose-v2' ] || skip '本机 provider 不是 Compose v2'

    probe::service_enabled podman.socket
    local en=${OS_PROBE_VALUE}
    probe::service_active podman.socket
    local act=${OS_PROBE_VALUE}

    probe::component_version compose-usable
    if [ "${en}" = 'enabled' ] || [ "${act}" = 'active' ]; then
        [ -n "${OS_PROBE_VALUE}" ]
    else
        [ -z "${OS_PROBE_VALUE}" ]
    fi
}

# podman-compose 直接跟 podman 说话，不经 socket —— 它在就是能用
@test "component_version compose-usable 对 podman-compose 不要求 podman.socket" {
    os_is_root || skip '非 root 走缓存路径'
    probe::compose_provider
    [ -n "${OS_PROBE_VALUE}" ] || skip '本机没有任何 compose provider'
    local kind
    IFS=$'\t' read -r kind _ _ <<<"${OS_PROBE_VALUE}"
    [ "${kind}" = 'podman-compose' ] || skip '本机 provider 不是 podman-compose'

    probe::component_version compose-usable
    [ -n "${OS_PROBE_VALUE}" ]
}

# ==================================================================
# 零进程读 /proc（probe::_probe_proc）
# ==================================================================
#
# 这条路径存在的理由是实测：同一件事（读一次 /proc/loadavg）三种写法各 300 次，
# bash 内建 0 ms、子 shell 加 cat 220 ms、再套一层 timeout 510 ms。所以要守住的
# 不变量有两条 —— **结果必须与从前逐字相同**，以及**真的一个进程都不起**。

@test "_probe_proc: 五个 /proc 读数与外部命令的结果逐字相同" {
    os_is_root || skip '非 root'
    local want

    probe::mem_total_kb
    want=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    [ "${OS_PROBE_VALUE}" = "${want}" ]

    probe::mem_available_kb
    want=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    # 可用内存每时每刻都在变，比不了逐字，只比形态与量级
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]+$ ]]
    [ "${OS_PROBE_VALUE}" -gt 0 ]

    probe::uptime_seconds
    # 必须已经截掉小数：/proc/uptime 是 `12345.67 …`，带小数点的话消费者
    # 拿它做整数运算会直接报错
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]+$ ]]

    probe::loadavg
    want=$(cut -d' ' -f1-3 /proc/loadavg)
    [ "${OS_PROBE_VALUE}" = "${want}" ]

    probe::cpu_model
    [ -n "${OS_PROBE_VALUE}" ]

    probe::cpu_jiffies
    [[ "${OS_PROBE_VALUE}" =~ ^[0-9]+\ [0-9]+$ ]]
    local total=${OS_PROBE_VALUE%% *} idle=${OS_PROBE_VALUE##* }
    [ "${idle}" -le "${total}" ]
}

@test "_probe_proc: 真的没起子进程" {
    os_is_root || skip '非 root'
    # 子进程会让 $BASHPID 之后的 PID 往前跳。起一个进程至少消耗一个 PID，
    # 而 bash 内建读文件一个都不消耗 —— 连读 20 次前后的 PID 差能证明这件事
    local before after
    before=$(bash -c 'echo $BASHPID')
    local i
    for ((i = 0; i < 20; i++)); do
        probe::loadavg
        probe::mem_total_kb
        probe::cpu_model
    done
    after=$(bash -c 'echo $BASHPID')
    # 40 次探测若各起 3 个进程（子 shell + timeout + awk）就是 120 个 PID。
    # 放宽到 40：容器里别的进程也在消耗 PID，但差不出两个数量级
    [ "$((after - before))" -lt 40 ]
}

@test "_probe_proc: 文件读不到时降级为 missing，不留空也不假装成功" {
    os_is_root || skip '非 root'
    probe::_probe_proc 'test.absent' /proc/no-such-file-here 'field:1'
    [ "${OS_PROBE_STATUS}" = missing ]
    [ -z "${OS_PROBE_VALUE}" ]
}

@test "_probe_proc: 非 root 且无缓存时明确说不可用（同 _probe 的降级契约）" {
    os_is_root && skip '这条测的是非 root 分支'
    probe::mem_total_kb
    [ "${OS_PROBE_STATUS}" = unavailable ]
    [ "${OS_PROBE_SOURCE}" = none ]
}

# ==================================================================
# 批量 unit 状态（probe::services_active）
# ==================================================================

@test "services_active: 结果与逐个问一致，且顺序对得上" {
    os_is_root || skip '非 root'
    os_have_systemd || skip '没有可用的 systemd'

    probe::services_active 'no-such-a.service' 'no-such-b.service'
    [ "${OS_PROBE_STATUS}" = ok ]

    local line n=0
    while IFS=$'\t' read -r u st; do
        [ -n "${u}" ] || continue
        n=$((n + 1))
        [ -n "${st}" ]
    done <<<"${OS_PROBE_VALUE}"
    [ "${n}" -eq 2 ]

    # 第一行必须是第一个参数：错位不会报错，只会让面板长期显示错的服务状态
    line=$(head -n1 <<<"${OS_PROBE_VALUE}")
    [[ "${line}" == "no-such-a.service"$'\t'* ]]
}

# 批量结果要能按**单个 unit 的 key** 落进快照，否则非 root 的消费者（面板、
# doctor）拿到的是一个它不认识的 `unit.active.batch`，而不是它要的那几条。
@test "services_active: 每条按 unit.<名>.active 记进探测结果表" {
    os_is_root || skip '非 root'
    os_have_systemd || skip '没有可用的 systemd'

    OS_PROBE__KEYS=()
    OS_PROBE__VALS=()
    probe::services_active 'no-such-a.service' 'no-such-b.service'

    local found=0 i
    for ((i = 0; i < ${#OS_PROBE__KEYS[@]}; i++)); do
        case "${OS_PROBE__KEYS[i]}" in
            unit.no-such-a.service.active | unit.no-such-b.service.active)
                found=$((found + 1))
                [ -n "${OS_PROBE__VALS[i]}" ]
                ;;
        esac
    done
    [ "${found}" -eq 2 ]
}

@test "services_active: 不给参数时安静返回，不去起一条没有参数的 systemctl" {
    probe::services_active
    [ -z "${OS_PROBE_VALUE}" ]
}

# --- 防火墙判据 ----------------------------------------------------
#
# probe::ufw_port_guarded 是一条安全判据：install_mariadb 与 install_valkey
# 都拿它决定「能不能放宽监听地址」。它答错的两个方向都很糟——答 no 挡住合法
# 操作，答 yes 让一个没有传输加密的服务上公网。

# 三键快照。命令桩在这里没用：probe::_probe 经 `timeout` 执行，那是外部命令，
# 看不见 bash 函数 —— 用函数桩写的第一版「过了」，过的原因却是容器里根本没有
# ufw，探测失败后恰好落到期望值上。
os_fake_snapshot3() {
    mkdir -p "${OS_PUBLIC_DIR}"
    local now
    printf -v now '%(%s)T' -1
    printf '#ts\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n' "${now}" \
        "${1}" "${2}" "${3}" "${4}" "${5}" "${6}" >"${OS_PROBE_SNAPSHOT}"
    probe::_is_root() { return 1; }
}

@test "ufw_default_incoming: 认出 deny" {
    os_fake_snapshot 'ufw.default_incoming' \
        'Status: active Logging: on (low) Default: deny (incoming), allow (outgoing), disabled (routed)'
    probe::ufw_default_incoming
    [ "${OS_PROBE_VALUE}" = 'deny' ]
}

@test "ufw_default_incoming: 认出 allow —— 默认放行时端口规则不构成保护" {
    os_fake_snapshot 'ufw.default_incoming' \
        'Status: active Logging: on (low) Default: allow (incoming), allow (outgoing), disabled (routed)'
    probe::ufw_default_incoming
    [ "${OS_PROBE_VALUE}" = 'allow' ]
}

@test "ufw_port_guarded: 默认入站 allow 时判为不受保护（原来漏掉的正是这一条）" {
    os_fake_snapshot2 'ufw.status' 'Status: active' \
        'ufw.default_incoming' 'Status: active Default: allow (incoming), allow (outgoing)'
    probe::ufw_port_guarded 3306
    [ "${OS_PROBE_VALUE}" = 'no' ]
}

@test "ufw_port_guarded: 端口被无条件放行给 Anywhere 时判为不受保护" {
    os_fake_snapshot3 'ufw.status' 'Status: active' \
        'ufw.default_incoming' 'Status: active Default: deny (incoming), allow (outgoing)' \
        'ufw.rules' '[ 1] 3306/tcp ALLOW IN Anywhere'
    probe::ufw_port_guarded 3306
    [ "${OS_PROBE_VALUE}" = 'no' ]
}

@test "ufw_port_guarded: 三个条件都满足才判为受保护" {
    os_fake_snapshot3 'ufw.status' 'Status: active' \
        'ufw.default_incoming' 'Status: active Default: deny (incoming), allow (outgoing)' \
        'ufw.rules' '[ 1] 22/tcp ALLOW IN Anywhere'
    probe::ufw_port_guarded 3306
    [ "${OS_PROBE_VALUE}" = 'yes' ]
}

@test "ufw_port_guarded: 限定了来源的放行不算无条件放行" {
    os_fake_snapshot3 'ufw.status' 'Status: active' \
        'ufw.default_incoming' 'Status: active Default: deny (incoming), allow (outgoing)' \
        'ufw.rules' '[ 1] 3306/tcp ALLOW IN 10.0.0.0/8'
    probe::ufw_port_guarded 3306
    [ "${OS_PROBE_VALUE}" = 'yes' ]
}

# --- 容器网段 ------------------------------------------------------
#
# 「允许容器访问数据库」按这个结果放行。旧脚本写死 10.0.0.0/8：那是整个私有
# A 段，而 podman 实际只用 10.88.0.0/16、docker 默认的 172.17.0.0/16 根本
# 不在里面 —— 既开得过宽又对 docker 无效。所以这里必须是探测出来的真值。

@test "container_subnets: 只留 CIDR 行并去重" {
    os_fake_snapshot 'container.subnets' '172.17.0.0/16 172.17.0.0/16 10.88.0.0/16'
    probe::container_subnets
    [[ ${OS_PROBE_VALUE} == *'172.17.0.0/16'* ]]
    [[ ${OS_PROBE_VALUE} == *'10.88.0.0/16'* ]]
    [ "$(printf '%s\n' "${OS_PROBE_VALUE}" | grep -c '172.17.0.0/16')" -eq 1 ]
}

@test "container_subnets: 非 CIDR 的噪音被丢掉（host/none 网络给空行）" {
    os_fake_snapshot 'container.subnets' 'bridge  172.17.0.0/16'
    probe::container_subnets
    [ "${OS_PROBE_VALUE}" = '172.17.0.0/16' ]
}

@test "container_subnets: 一个网络都没有时返回空" {
    os_fake_snapshot 'container.subnets' ''
    probe::container_subnets
    [ -z "${OS_PROBE_VALUE}" ]
}
