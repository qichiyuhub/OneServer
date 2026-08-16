#!/bin/bash
#
# 安装 Podman 容器运行时
#
# @command      install podman
# @name         Podman
# @group        app
# @order        160
# @privilege    root
# @requires_lib >= 1.14
# @provides     podman
# @provides_unit ext:podman.socket
# @provides_unit ext:podman-auto-update.timer
# @args         [--compose=<y|n>] [--docker-alias=<y|n>] [--auto-update=<n|y>] [--network-mode=<公网|内网>] [--confirm-internal=<y|n>]
# @description  从发行版源装 Podman 与 Quadlet 环境
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 装 / 配 / 查 / 升 / 卸 —— 开工前答完的五问
# ==================================================================
#
# **装**：发行版源的 `podman`（+ 可选 `podman-compose`）。理由同 D110（redis）：
#   容器运行时的版本新旧，远不如「装的东西可被发行版审计、跟着安全更新走」重要。
#   Debian 13 是 podman 5.x，Ubuntu 24.04 是 4.9.x —— 两边都 ≥ 4.4，
#   而 4.4 是 **Quadlet 进入 podman 本体**的版本，本项目整套容器管理都建在它上面，
#   所以低于 4.4 直接拒绝，而不是退回 `podman generate systemd`（那东西在 5.x 已废弃）。
#   装了什么逐项记进 state：包、`/etc/containers/nodocker`（若本次创建）、动过的 unit。
#
# **配**：三个用户该选的，其余一律不动系统 ——
#   `--compose`      装不装 podman-compose（默认 y）
#   `--docker-alias` 把 `docker` 命令接管成 podman 的别名（默认 y，机器上有真
#                    Docker 时默认翻成 n，见下）
#   `--auto-update`  开不开 `podman-auto-update.timer`（**默认 n**，见下）
#
# **查**：装没装、什么版本 —— 全部经 `probe::component_version`。
#
# **升**：幂等。已装且版本够就一条命令都不跑；**版本升级交给 `safe updates`**
#   （apt 的事归 apt，同 D110）。
#
# **卸**：`oneserver uninstall podman` 按规范的资源清单反向执行。
#   **容器、镜像、卷不在这个组件的清单里** —— 容器各自属于 `container:<名>`
#   （下一个单元），而镜像是缓存、删了能重拉，本来就不该由卸载来管。
#
# ==================================================================
# docker 兼容：接管命令名，而不是设 alias
# ==================================================================
#
# **不设 `alias docker=podman`。** alias 只在交互式 shell 里生效 —— cron、
# systemd 的 ExecStart、`bash deploy.sh`、别人写的脚本里全都不生效，现场表现是
# 「我手敲能跑，脚本里说 docker: command not found」，而这是最难查的一类问题。
# 而且它要么改用户的 `.bashrc`（动的是用户的私人文件），要么落
# `/etc/profile.d`（对非登录 shell 依然无效），卸载时还清不干净。
#
# 官方给的东西就是对的：`podman-docker` 包提供**真的 `/usr/bin/docker`**，
# 所有场景一视同仁，由 dpkg 管理，卸载干净，还带 `/etc/containers/nodocker`
# 这个官方约定的静音开关。
#
# **它与真 Docker 必然冲突**：两个包都提供 `/usr/bin/docker`，dpkg 层面装不到
# 一起。所以检测到真 Docker 时直接拒绝，不给「你确认就装」的口子 ——
# 那不是危险，是装不上。反过来（先有 podman-docker、后装 Docker）由
# Docker 那侧负责先 purge 掉它，判据是 `probe::container_engine` 的实时值；
# **不为此在 state 里再记一份**，那就成了两个真相。
#
# **不装 podlet**：它是 GitHub Releases 上的 Rust 二进制，引进来就要么背一条
# 免校验下载链、要么维护一串硬编码 SHA256，而规范禁止免校验取第三方软件。
# `oneserver podman run` 自己把 `docker run` 翻成 Quadlet，翻译规则是一张显式的
# flag 表，认不出的 flag 当场拒绝而不是猜 —— 不需要它。
#
# **不装 jq**：podman 自己的 `--format` 就能输出我们要的每一个字段。
# 少一个依赖，少一处「这台机器上没有 jq」的分支。

readonly QUADLET_DIR='/etc/containers/systemd'
readonly REGISTRIES_CONF='/etc/containers/registries.conf'
readonly UFW_DEFAULTS='/etc/default/ufw'
# ufw 的输出在不同 locale 下措辞不同，而下面要靠文本判定结果
readonly UFW_ENV='LC_ALL=C'
# 网络定位落在 state 的这个组件下，两个引擎共用一份
readonly NETWORK_ID='network'
readonly NODOCKER_MARKER='/etc/containers/nodocker'
readonly DOCKER_SOCK='/run/docker.sock'
readonly PODMAN_DOCKER_TMPFILES='/usr/lib/tmpfiles.d/podman-docker.conf'
readonly PODMAN_MIN_VERSION='4.4'
readonly PODMAN_MIN_DEBIAN='13'
readonly PODMAN_MIN_UBUNTU='24.04'
readonly COMPONENT_ID='podman'

# ------------------------------------------------------------------

# 网络定位的**防火墙那一半**，只属于 podman：容器端口走 FORWARD 链，
# DEFAULT_FORWARD_POLICY 是它的兜底（公网 DROP、内网 ACCEPT）。Docker 不需要
# 这一半 —— dockerd 把自己的跳转插在 FORWARD 最前面，ufw 的任何规则都轮不到
# （D206），所以这段只在这里与 script/manage/network.sh 各一份，两处不提取。
#
# 没装 ufw 就只记录定位、不报错：转发本来就不受限制，没有可落实的东西。
apply_forward_policy() {
    local want=${1}
    probe::package_installed ufw
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::info '本机没有 ufw，转发不受限制，只记录定位'
        return 0
    fi
    local cur='DROP'
    if os::query --timeout 5 -- grep -oE '^DEFAULT_FORWARD_POLICY="[A-Z]+"' "${UFW_DEFAULTS}"; then
        cur=${OS_RUN_OUTPUT#*\"}
        cur=${cur%\"}
    fi
    [[ ${cur} == "${want}" ]] && return 0

    # 「先备份再改」类：/etc/default/ufw 是发行版的 conffile，不可重建
    os::record_change "把 ${UFW_DEFAULTS} 的 DEFAULT_FORWARD_POLICY 改成 ${want}"
    os::replace_line --backup "${UFW_DEFAULTS}" '^DEFAULT_FORWARD_POLICY=' \
        "DEFAULT_FORWARD_POLICY=\"${want}\"" \
        || os::die 1 "${UFW_DEFAULTS} 里找不到 DEFAULT_FORWARD_POLICY 行，配置文件可能已被大改"

    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        os::run --env "${UFW_ENV}" '重载 UFW 使转发策略生效' -- ufw reload
    else
        os::warn 'UFW 当前未启用，转发策略要等启用后才生效（oneserver firewall enable）'
    fi
    return 0
}

# podman 的版本号。`podman --version` 打的是 "podman version 5.4.1"，
# 取最后一个词；探不到时是空串。
#
# 用变量返回不用 `$( )`（D135）：子 shell 会把 probe 的来源标注一起吞掉。
podman_version() {
    local __ip_out=${1}
    # 版本号的提取归 probe::component_version，这里不再自己拆一遍 ——
    # 两处各拆各的，对同一个输出格式的理解迟早分叉
    probe::component_version podman
    printf -v "${__ip_out}" '%s' "${OS_PROBE_VALUE}"
    return 0
}

# 发行版自带的 Podman 必须已经包含 Quadlet。只在机器尚未安装 Podman 时用
# 发行版版本作安装门槛；已有自定义/回移植版本则以下面的实际版本检查为准。
podman_platform_supported() {
    local id=${1-} version=${2-} minimum=''
    case ${id} in
        debian) minimum=${PODMAN_MIN_DEBIAN} ;;
        ubuntu) minimum=${PODMAN_MIN_UBUNTU} ;;
        *) return 1 ;;
    esac
    [[ -n ${version} && $(os::version_cmp "${version}" "${minimum}") != '-1' ]]
}

# **先问 apt「这台机器装得到哪个版本」，问不出来才退回发行版号。**
#
# 「Debian ≥ 13 / Ubuntu ≥ 24.04」这条门槛说的其实是一件事：发行版源里的
# Podman 够不够 4.4。候选版本是对这件事的**直接测量**，发行版号只是它的代理
# 指标 —— 而代理指标在 Debian testing 上会失效：testing 与 sid 的
# /etc/os-release 里**根本没有 VERSION_ID**，于是一台源里摆着 Podman 5.x 的机器
# 被判成「版本未知」当场拒绝。换成先问候选版本，判据与门槛的本意一致，
# 而且不必为每个新代号维护一张表。
#
# 候选版本拿不到（apt 索引从没更新过、网络不通）才退回发行版号那条老路：
# 那时对这台机器一无所知，宁可按规范的保守门槛拒绝。
podman_source_candidate() {
    local __ip_out=${1}
    probe::package_candidate podman
    # 剥掉 Debian 的 epoch（`4:5.4.1-1` 里的 `4:`）。os::version_cmp 按 `.` 切段
    # 再剔非数字，`4:5` 会被搓成 45 —— 一个既不是 4 也不是 5 的数
    printf -v "${__ip_out}" '%s' "${OS_PROBE_VALUE#*:}"
    return 0
}

podman_platform_preflight() {
    local cand=''
    podman_source_candidate cand
    if [[ -n ${cand} ]]; then
        if [[ $(os::version_cmp "${cand}" "${PODMAN_MIN_VERSION}") == '-1' ]]; then
            os::die 4 "当前 apt 源里的 podman 是 ${cand}，低于 ${PODMAN_MIN_VERSION}；OneServer 的 Podman 容器由 Quadlet 托管，而 Quadlet 从 Podman ${PODMAN_MIN_VERSION} 才可用。此系统请改用兼容旧发行版的 Docker：oneserver install docker"
        fi
        os::info "apt 源里的 podman 是 ${cand}，满足 Quadlet 所需的 ${PODMAN_MIN_VERSION}+"
        return 0
    fi

    probe::os_id
    local id=${OS_PROBE_VALUE}
    probe::os_version
    local version=${OS_PROBE_VALUE}
    podman_platform_supported "${id}" "${version}" && return 0

    local required='Debian 13 / Ubuntu 24.04'
    os::die 4 "apt 源里查不到 podman（索引可能从没更新过，先跑 apt-get update），只能退回按发行版判断：当前 ${id:-未知} ${version:-版本未知} 无法保证 Podman ${PODMAN_MIN_VERSION}+；OneServer 的 Podman 容器由 Quadlet 托管，而 Quadlet 从 Podman ${PODMAN_MIN_VERSION} 才可用。Podman 安装要求 ${required} 或更新版本。此系统请改用兼容旧发行版的 Docker：oneserver install docker"
}

# ------------------------------------------------------------------

main() {
    local want_compose='' docker_alias='' want_autoupdate=''

    # 先判定能力再提问。旧发行版注定装不到可用版本时，不让用户答完三个问题
    # 才被拒绝；若机器已经自行装了新 Podman，则认实际能力，不因发行版误拒绝。
    local cur=''
    podman_version cur
    if [[ -n ${cur} ]]; then
        os::info "已装 podman ${cur}"
        if [[ $(os::version_cmp "${cur}" "${PODMAN_MIN_VERSION}") == '-1' ]]; then
            os::die 4 "podman ${cur} 低于 ${PODMAN_MIN_VERSION}，不支持本项目依赖的 Quadlet。请升级 Podman，或改用 Docker：oneserver install docker"
        fi
    else
        podman_platform_preflight
    fi

    # `docker` 这个命令名现在归谁，决定下面那个选项的默认值 ——
    # 有真 Docker 在场时把默认翻成「不接管」，否则用户一路回车就会撞上
    # 一次注定失败的 apt
    probe::container_engine
    local engine=${OS_PROBE_VALUE}

    os::select --arg compose '安装 podman-compose（跑 docker-compose.yml 要用它）' want_compose \
        'y=安装' 'n=不安装'

    local -a alias_opts=('y=接管，粘贴 docker 命令直接能用' 'n=不接管，只用 podman 命令')
    [[ ${engine} == docker ]] && alias_opts=('n=不接管，只用 podman 命令' 'y=接管，粘贴 docker 命令直接能用')
    os::select --arg docker-alias '让 podman 接管 docker 命令' docker_alias "${alias_opts[@]}"
    # 命令行上给裸 `--docker-alias`（不带 `=y`）时，框架把值记成 `1`。不认这个值的话，
    # 这种写法会静默地变成「不接管」——静默改变一条已经在用的调用的结果，
    # 比报错难查得多
    case ${docker_alias,,} in
        y | yes | 1 | true) docker_alias=y ;;
        *) docker_alias=n ;;
    esac

    # **默认 n**：这是稳定性权衡，不是 §15 那条安全默认值 —— §15 管的是开放
    # 监听、放宽来源、关闭校验这类真正削弱安全的选项，而自动更新是拿「半夜
    # 无人值守的一次变更」换「及时打上游补丁」。装的这一刻机器上一个容器都
    # 没有，开了也无事可做，所以默认不开，需要的人建容器时会被问到（那一问
    # 默认 y，选了就顺带把这个定时器开起来）
    os::select --arg auto-update '开启 podman-auto-update.timer（每天自动拉新镜像并重启容器）' want_autoupdate \
        'n=不开启' 'y=开启'

    # --- 网络定位：容器端口对谁开放 ---
    #
    # **在这里问，不在装完之后提示。** 它是使用容器的前提，而「装完自己想起来
    # 去设」的真实结果是永远没设 —— 那一档过去被静默当成公网处理，用户从头到尾
    # 不知道自己做过这个决定。**一台机器只定一次**：另一个引擎装的时候可能已经
    # 问过了，state 里有就沿用，要改走 oneserver network
    local netmode
    netmode=$(os::state_get "${NETWORK_ID}" mode '')
    if [[ -n ${netmode} ]]; then
        os::info "沿用已设定的网络定位：${netmode}（要改：oneserver network）"
    else
        os::select --arg network-mode '这台机器的容器端口对谁开放？' netmode \
            '公网=公网服务器 —— 端口只绑本机，一律走 Caddy 反代' \
            '内网=内网机器 —— 端口直接对局域网开放'
        os::info '以后要改：安全菜单里的「网络定位」，或敲 oneserver network'
        if [[ ${netmode} == 内网 ]]; then
            os::warn '内网定位会放开 ufw 的转发策略 —— 等于让本机转发它能路由的一切，不只是容器'
            os::confirm --arg confirm-internal '确认这台机器在可信内网？' n \
                || os::die 130 '已取消'
        fi
    fi

    # --- docker 命令名的冲突检查：不给「你确认就装」的口子 ---
    if [[ ${docker_alias} == y && ${engine} == docker ]]; then
        os::die 2 '这台机器上有真正的 Docker。它与 podman-docker 都提供 /usr/bin/docker，dpkg 层面装不到一起 —— 先卸掉 Docker，或者选「不接管」'
    fi
    if [[ ${docker_alias} == n && ${engine} == podman ]]; then
        os::info 'podman 已经接管着 docker 命令（podman-docker 装过了）。选「不接管」不会撤销它 —— 要撤销：apt purge podman-docker'
    fi

    # --- 装 ---
    #
    # **nftables 必须显式装。** podman 4+ 的网络后端是 netavark，它要调 `nft`
    # 才配得出容器网络，而 netavark 对 nftables 只是 `Recommends` ——
    # **偏偏 os::pkg_install 一律带 `--no-install-recommends`**（那是有意的：
    # 不让 apt 顺手拖进一堆没人要的东西）。两条一凑，任何机器上装完 podman
    # 都缺 `nft`：引擎装得好好的、`podman run` 却必然失败，现场只有一句
    # `status=127`，真正的原因 `netavark: unable to execute nft` 埋在
    # journalctl 里三层深。真机上就是这么撞出来的。
    #
    # **aardvark-dns 同理**：netavark 的另一条 `Recommends`，容器网络的 DNS
    # 解析靠它。缺了它容器之间没法按名字互访（`db` 连不上，只能写 IP），
    # 而单容器连宿主时又一切正常 —— 于是这个坑要等到建第二个容器才现形。
    #
    # 同类风险不止这一处：凡是靠 `Recommends` 才完整的组件，在本工具下都得
    # 显式列出来。加新组件时值得先 `apt-cache depends` 看一眼。
    local -a pkgs=(podman nftables aardvark-dns)
    [[ ${want_compose} == y ]] && pkgs+=(podman-compose)
    [[ ${docker_alias} == y ]] && pkgs+=(podman-docker)

    local IFS=' '
    os::pkg_install "${pkgs[@]}" || os::die 1 "安装失败：${pkgs[*]}"
    IFS=$'\n\t'

    podman_version cur
    if [[ -z ${cur} && ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（podman 尚未安装，版本与配置都问不出来）'
        os::output 0 changed=dry-run
        return 0
    fi
    [[ -n ${cur} ]] || os::die 1 'podman 装完之后仍然探测不到，安装没有真正成功'
    if [[ $(os::version_cmp "${cur}" "${PODMAN_MIN_VERSION}") == '-1' ]]; then
        os::die 4 "发行版源里的 podman 是 ${cur}，低于 Quadlet 需要的 ${PODMAN_MIN_VERSION}。请改用 Docker：oneserver install docker"
    fi
    os::ok "podman ${cur}"

    # --- Quadlet 目录 ---
    #
    # `/etc/containers/systemd` 是 Quadlet 的官方系统级搜索路径。建它不算
    # 「改用户配置」：目录本身是空的，podman 没有它也照常工作 —— 但下一个单元
    # （`oneserver podman`）往里放 `.container` 文件时它必须在
    if [[ ! -d ${QUADLET_DIR} ]]; then
        os::run '创建 Quadlet 目录' -- mkdir -p "${QUADLET_DIR}"
        os::run '设置 Quadlet 目录权限' -- chmod 0755 "${QUADLET_DIR}"
    fi

    # --- docker 命令名的静音标志 ---
    #
    # podman-docker(1) 的官方约定：`/etc/containers/nodocker` 存在时，
    # docker 命令不再每次往 stderr 打「Emulate Docker CLI using podman」。
    # 选了接管的人就是要直接粘贴 docker 命令，那句提示只会污染每一次输出
    local -i marker_created=0
    if [[ ${docker_alias} == y && ! -e ${NODOCKER_MARKER} ]]; then
        marker_created=1
        os::run '创建 docker 别名静音标志' -- touch "${NODOCKER_MARKER}"
        os::run '设置静音标志权限' -- chmod 0644 "${NODOCKER_MARKER}"
    fi

    # --- Compose v2 要的那个 socket ---
    #
    # **这条是 compose 单元的容器验收撞出来的。** podman-compose 直接调 podman
    # 的命令行，不需要任何 socket；而 Compose v2（docker-compose 二进制）是照
    # Docker 的 API 说话的，它走 podman 的 docker 兼容 socket。
    #
    # 装了 compose 支持却不开这个 socket，现场表现是 `podman compose` 报
    # 「Cannot connect to the Docker daemon at unix:///run/podman/podman.sock」——
    # 那句话里的 **docker** 字样会把人带到「是不是还得装个 Docker」这个完全
    # 错误的方向上去，而真正缺的只是一个 podman 自带的 socket。
    #
    # 接管了 docker 命令同样要开它：`docker` 这个命令名只是入口，**照 Docker API
    # 说话的东西（Compose v2、各种部署脚本、CI）走的是一个 socket 而不是命令**。
    if [[ ${want_compose} == y || ${docker_alias} == y ]]; then
        probe::unit_exists podman.socket
        if [[ ${OS_PROBE_VALUE} == yes ]]; then
            # ext:：包自带的 unit，卸载时只停止禁用，禁止删文件（D36）
            os::systemd_enable --now podman.socket ext
            os::ok '已启用 podman.socket（照 Docker API 说话的工具要通过它）'
        else
            os::warn '这个 podman 版本没有 podman.socket —— 只有 podman-compose 能用，Compose v2 与其他照 Docker API 说话的工具都用不了'
        fi
    fi

    # --- /run/docker.sock ---
    #
    # 照 Docker API 说话的工具找的是**写死的 `/run/docker.sock`**，podman-docker
    # 用 tmpfiles 把它软链到 podman 的 socket。**tmpfiles 要到下次开机才跑**，
    # 于是装完立刻用的人会撞上「/run/docker.sock 不存在」，再回头怀疑 podman
    # 是不是没装好 —— 而这里现跑一次就没这回事了。
    #
    # 建在 /run（tmpfs）上，重启即消失，因此不注册回滚、不登记为 file 资源。
    if [[ ${docker_alias} == y && ! -e ${DOCKER_SOCK} ]]; then
        if [[ -f ${PODMAN_DOCKER_TMPFILES} ]]; then
            os::run '建立 /run/docker.sock 软链' -- systemd-tmpfiles --create "${PODMAN_DOCKER_TMPFILES}"
            [[ -e ${DOCKER_SOCK} ]] \
                || os::warn "${DOCKER_SOCK} 仍然不在。docker 命令本身照常能用；照 Docker API 说话的工具请指 DOCKER_HOST=unix:///run/podman/podman.sock"
        else
            os::warn "这个 podman-docker 没带 ${DOCKER_SOCK} 的 tmpfiles 配置。docker 命令本身照常能用；照 Docker API 说话的工具请指 DOCKER_HOST=unix:///run/podman/podman.sock"
        fi
    fi

    # --- registries.conf：只看，不改 ---
    #
    # **这条继承旧脚本，它是对的**：`unqualified-search-registries` 决定
    # `podman pull nginx` 到底从哪个仓库拉。替用户改它 = 替他决定镜像来源，
    # 而拉错来源的镜像是供应链问题。所以只报告现状，并推荐写全名。
    if [[ -f ${REGISTRIES_CONF} ]] \
        && os::query --timeout 5 -- grep -qE '^[[:space:]]*unqualified-search-registries[[:space:]]*=' "${REGISTRIES_CONF}"; then
        os::info "${REGISTRIES_CONF} 启用了 short-name 搜索 —— 建议镜像写全名（docker.io/library/nginx:latest），本工具不替你改它"
    fi

    # --- compose 的 docker 兼容 socket ---
    #
    # **装了 compose 就得顺手开它。** provider 的挑选顺序是 v2 > podman-compose
    # （D203），而机器上只要有 Docker 的 Compose v2 插件，被挑中的就是它 ——
    # Compose v2 说的是 Docker API，要通过这个 socket 才够得着 podman。
    # 不开的话表现是「装完 compose，菜单里那一项仍然不出现」（`@requires
    # compose-usable` 判的正是这条路通不通），而用户完全想不到问题出在一个 socket。
    #
    # podman-compose 自己不需要它。开着的代价是多一个 root 的 unix socket
    # （不监听网络），换来的是两种 provider 都能用
    if [[ ${want_compose} == y ]]; then
        probe::unit_exists 'podman.socket'
        if [[ ${OS_PROBE_VALUE} == yes ]]; then
            # ext:：包自带的 unit，卸载时只停止禁用，禁止删文件（D36）
            os::systemd_enable --now 'podman.socket' ext
            os::ok 'podman.socket 已启用 —— Compose v2 当 provider 时要通过它跟 podman 说话'
        else
            os::warn '这个 podman 版本没有 podman.socket，Compose v2 将无法作为 provider（podman-compose 不受影响）'
        fi
    fi

    # --- 自动更新 timer ---
    local autoupdate_unit='podman-auto-update.timer'
    if [[ ${want_autoupdate} == y ]]; then
        probe::unit_exists "${autoupdate_unit}"
        if [[ ${OS_PROBE_VALUE} == yes ]]; then
            # ext:：包自带的 unit，卸载时只停止禁用，禁止删文件（D36）
            os::systemd_enable --now "${autoupdate_unit}" ext
            os::ok '已开启每日自动更新（只动带 io.containers.autoupdate 标签的容器）'
        else
            os::warn "这个 podman 版本没有 ${autoupdate_unit}，跳过"
        fi
    fi

    # --- 网络定位落实 ---
    #
    # **沿用已有定位时也要落实**：先装 docker 后装 podman 的机器上，转发策略
    # 那一半从来没人做过 —— 它是 podman 独有的，docker 的安装路径不碰它
    local want_policy='DROP'
    [[ ${netmode} == 内网 ]] && want_policy='ACCEPT'
    apply_forward_policy "${want_policy}"
    os::state_set "${NETWORK_ID}" mode="${netmode}" forward_policy="${want_policy}"

    # --- state---
    os::state_set "${COMPONENT_ID}" version="${cur}" method=apt

    # **只登记本次真正装上的包**（规范两层过滤）：机器上本来就有 podman 的话，
    # 卸载不该把它 purge 掉
    local p
    while IFS= read -r p; do
        [[ -n ${p} ]] || continue
        # **nftables 不登记**（D103：通用依赖不能因卸载一个组件被 purge）。
        # 上面为了 netavark 把它显式装上，但它同时是防火墙的一部分 ——
        # UFW 在 Debian 12+ 走的正是 nft 后端。卸载 podman 时把它 purge 掉，
        # 用户的防火墙会跟着塌，而那与「卸载容器引擎」毫无关系。
        [[ ${p} == nftables ]] && continue
        os::state_resource_add "${COMPONENT_ID}" pkg "${p}"
    done < <(os::pkg_installed_names)

    # 只登记**本次创建**的文件（改过的既有配置不算）。
    # **Quadlet 目录有意不登记**：卸载时它里面很可能躺着用户的 .container 文件，
    # 那些是下一个单元记在 `container:<名>` 名下的东西，不该被这里连锅端走
    ((marker_created == 1)) && os::state_resource_add "${COMPONENT_ID}" file "${NODOCKER_MARKER}"

    local u
    while IFS= read -r u; do
        [[ -n ${u} ]] || continue
        os::state_unit_add "${COMPONENT_ID}" "${u}"
    done < <(os::systemd_touched)

    os::section 'Podman'
    os::kv '版本' "${cur}" \
        'compose' "$([[ ${want_compose} == y ]] && printf '已安装' || printf '未安装')" \
        'docker 命令' "$([[ ${docker_alias} == y ]] && printf '由 podman 接管' || printf '未接管')" \
        '自动更新' "$([[ ${want_autoupdate} == y ]] && printf '已开启' || printf '未开启')" \
        '网络定位' "${netmode}" \
        'Quadlet 目录' "${QUADLET_DIR}"
    os::info '下一步：oneserver podman run 建容器；看日志、管镜像与卷见 oneserver podman'

    os::output 0 version="${cur}" compose="${want_compose}" \
        docker_alias="${docker_alias}" auto_update="${want_autoupdate}" \
        network_mode="${netmode}"
    return 0
}

main "$@"
