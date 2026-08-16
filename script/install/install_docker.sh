#!/bin/bash
#
# 安装 Docker CE
#
# @command      install docker
# @name         Docker
# @group        app
# @order        170
# @privilege    root
# @requires_lib >= 4.0
# @provides     docker
# @provides_unit ext:docker.service
# @provides_unit ext:docker.socket
# @provides_unit ext:containerd.service
# @args         [--compose=<y|n>] [--purge-podman-docker=<y|n>] [--restart-daemon=<y|n>] [--network-mode=<公网|内网>]
# @description  从 Docker 官方源装 Docker CE，处理命令名冲突
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
# **装**：Docker 官方源的 `docker-ce`。这里与 podman 走的是相反的路（podman 用
#   发行版源，D110），因为两件事在 Docker 上不成立：发行版的 `docker.io` 落后
#   一到两个大版本，而 `docker compose` 与 buildx 这两个几乎所有教程都在用的
#   子命令是 Docker 自己以插件形式发布的，跟着官方源走才配套。
#   代价照实付：多一条第三方源与一份签名密钥，两者都登记进资源清单，卸载带走。
#
# **配**：三个用户该选的 ——
#   `--compose`              装不装 docker-compose-plugin（默认 y）
#   `--purge-podman-docker`  撞上 podman-docker 时才问（默认 n）
#   端口默认绑哪个地址由网络定位决定，**装的时候就问**（没设过才问，一台机器
#   一次）。两处各问一半正是「端口发布了却连不上」与「以为只绑了本机」的成因。
#
# **查**：装没装、什么版本 —— 经 `probe::component_version docker`，判据是
#   `dockerd --version`（见 probe.sh 里的理由：`docker --version` 会被
#   podman-docker 冒充）。
#
# **升**：幂等。已装且是 docker-ce 就只补齐缺的包与配置；版本升级交给
#   `safe updates`（apt 的事归 apt，同 D110）。机器上已有别的来源装的 Docker
#   时**不换来源**，只做配置 —— 替用户把引擎换掉是他自己该做的决定。
#
# **卸**：`oneserver uninstall docker` 按资源清单反向执行：停用 unit → 删
#   密钥环、源定义与 daemon.json → purge 包。**容器、镜像、卷不在清单里**，
#   它们是数据，规范禁止卸载自动删除。
#
# ==================================================================
# 为什么公网定位这一半必须落在 daemon.json，而不是防火墙
# ==================================================================
#
# `oneserver network` 的定位对 podman 是靠 ufw 的 `DEFAULT_FORWARD_POLICY`
# 实现的：容器端口走 FORWARD 链，策略设成 DROP 就进不来。
#
# **这一套对 Docker 完全不成立。** dockerd 启动时把自己的 `DOCKER-USER` /
# `DOCKER` 跳转插在 FORWARD 链**最前面**，发布出去的端口在 ufw 的任何规则
# 之前就被 ACCEPT 了。现场表现是界面上写着「只绑本机」，而外网直接连得上 ——
# 一个看起来两边都对、实际完全没有防护的状态。
#
# 所以 Docker 这一侧的旋钮是 `/etc/docker/daemon.json` 的 `"ip"`：它决定
# `-p 8080:80` 这种不写宿主 IP 的映射绑到哪个地址（dockerd 的默认是
# `0.0.0.0`，即全网可达）。它比 podman 那一半更精确 —— 管的是绑定本身，
# 不是绑完再拦。
#
# 代价是**它只对新建的容器生效**：已有容器的绑定地址在 `docker run` 那一刻
# 就写进容器配置了。改完只能列出对不上的那几个，由人挑时间重建。
#
# ==================================================================
# 自动更新不在这里
# ==================================================================
#
# 自动更新是**名单驱动**的（名单里的容器才更新，见 docker_container.sh），
# 而**装 Docker 的这一刻名单必然是空的** —— 机器上一个容器都还没有。此时
# 部署更新器要么无事可做，要么只能不带名单起，而不带名单等于扫全机，正是
# 「不在名单里的一概不动」的反面。
#
# 所以这一步不问也不部署，装完指一句路。部署与开关都归 `oneserver docker`
# 那一屏，全项目只有那一处会创建更新器容器。

readonly APT_KEYRING_DIR='/etc/apt/keyrings'
readonly DOCKER_KEYRING='/etc/apt/keyrings/docker.gpg'
readonly DOCKER_LIST='/etc/apt/sources.list.d/docker.list'
readonly DOCKER_ETC_DIR='/etc/docker'
readonly DAEMON_JSON='/etc/docker/daemon.json'
readonly DOCKER_SOCK='/run/docker.sock'
readonly COMPONENT_ID='docker'
readonly PODMAN_ID='podman'

# ------------------------------------------------------------------

# Docker 的版本号，探不到时是空串。
#
# 版本号的提取归 `probe::component_version` —— 它对走命令输出的那几个分支
# 统一摘出版本号（"Docker version 28.0.1, build bbd0a17" → "28.0.1"）。
# 这里再解析一遍就是第二份真相，两边对同一个格式的理解迟早分叉。
#
# 用变量返回不用 `$( )`（D135）：子 shell 会把 probe 的来源标注一起吞掉。
docker_version() {
    local __id_out=${1}
    probe::component_version docker
    printf -v "${__id_out}" '%s' "${OS_PROBE_VALUE}"
    return 0
}

# apt 的架构名。`uname -m` 说 x86_64，源定义里要写 amd64 —— 直接拿探测值
# 去拼 `arch=x86_64`，apt 会认为这条源没有任何可用架构，然后**一声不响地
# 跳过它**，最后报的是「找不到 docker-ce 这个包」。
docker_arch() {
    local __id_out=${1}
    probe::arch
    local __id_a=''
    case ${OS_PROBE_VALUE} in
        x86_64 | amd64) __id_a='amd64' ;;
        aarch64 | arm64) __id_a='arm64' ;;
        armv7l | armhf) __id_a='armhf' ;;
    esac
    printf -v "${__id_out}" '%s' "${__id_a}"
    return 0
}

# Docker 的 APT 仓库没有 stable 这种会自动切换的别名。先确认当前代号是否已经
# 发布；testing 变成正式版后，这一步会自然切回它自己的 suite，免得回退表永远
# 把新系统钉在旧仓库上。
docker_repo_status() {
    local __id_out=${1} os_id=${2} codename=${3}
    os::query --timeout 15 -- \
        curl -sS --connect-timeout 10 -o /dev/null -w '%{http_code}' \
        "https://download.docker.com/linux/${os_id}/dists/${codename}/Release" || return 1
    printf -v "${__id_out}" '%s' "${OS_RUN_OUTPUT}"
    return 0
}

# 回退不是按「未知代号一律用旧版」猜出来的：每一条都必须能在 Docker 的 Debian
# 安装文档或其官方安装脚本中找到对应依据。没有条目的新 testing 代号宁可拒绝，
# 也不能让用户以为自己装到了兼容的 Docker CE。
docker_repo_fallback() {
    local __id_out=${1} os_id=${2} codename=${3} fallback=''
    case "${os_id}:${codename}" in
        debian:forky) fallback='trixie' ;;
    esac
    [[ -n ${fallback} ]] || return 1
    printf -v "${__id_out}" '%s' "${fallback}"
    return 0
}

# 这个文件是不是本组件登记过的 —— 也就是本工具自己放下的那一份
state_owns_file() {
    local path=${1} f
    while IFS= read -r f; do
        [[ ${f} == "${path}" ]] && return 0
    done < <(os::state_resources "${COMPONENT_ID}" file)
    return 1
}

# ------------------------------------------------------------------

# 密钥环与源定义是不是**本次从无到有建**的。用户按 Docker 官方文档手工配过
# 同样这两个路径是常见情况（先手工装过一次没装全、再用本工具补装）。那种情况
# 下它们不是「本项目创建的」，按 §12 登记成 file 会让 `uninstall docker`
# 把用户自己配的 apt 源删掉。判断只能在写之前做，所以用全局变量带出来
# （函数之间不用 $( )：那是子 shell，D135）。
DOCKER_KEYRING_CREATED=0
DOCKER_LIST_CREATED=0

setup_apt_repo() {
    local dir=${1} os_id=${2} codename=${3} arch=${4}

    [[ -f ${DOCKER_KEYRING} ]] || DOCKER_KEYRING_CREATED=1
    [[ -f ${DOCKER_LIST} ]] || DOCKER_LIST_CREATED=1

    # 密钥与源定义都先落到临时目录，再经模板/替换接口换 inode 放到位，
    # 不用 `curl | tee 目标` 那种就地截断的写法（§11）。
    #
    # 不是 `-1`（--tlsv1，只设最低版本为 1.0，不设上限）：这条取的是 apt
    # 仓库的签名密钥，它决定此后 apt 信任谁，理应用能拿到的最高版本。
    os::retry 3 '下载 Docker 仓库签名密钥' -- \
        curl -fsSL --tlsv1.2 --proto '=https' --proto-redir '=https' --connect-timeout 15 \
        -o "${dir}/docker.key" \
        "https://download.docker.com/linux/${os_id}/gpg" || return 1

    # dry-run 下上面那条根本没跑，临时目录里是空的 —— 再往下就是拿不存在的
    # 文件去落地。诚实地停在这里，由 main 打分叉声明。
    [[ ${OS_DRYRUN} -eq 1 ]] && return 0

    if [[ ! -d ${APT_KEYRING_DIR} ]]; then
        os::run '创建 apt 密钥环目录' -- mkdir -p "${APT_KEYRING_DIR}"
        os::run '设置密钥环目录权限' -- chmod 0755 "${APT_KEYRING_DIR}"
    fi

    os::run '转换签名密钥格式' -- \
        gpg --batch --yes --dearmor -o "${dir}/docker.gpg" "${dir}/docker.key" || return 1
    # `--backup`：这两个路径正是 Docker 官方文档教用户手工配的那两个，
    # 覆盖的可能是用户已有的配置（§10 第三类「先备份再改」）。内容没变时
    # install_* 会提前返回，不会每次执行都攒一份副本
    os::install_file --backup --mode 0644 "${dir}/docker.gpg" "${DOCKER_KEYRING}" || return 1
    local -i changed=${OS_TEMPLATE_CHANGED}

    os::install_template --backup --mode 0644 "${OS_TEMPLATE_DIR}/docker.list" "${DOCKER_LIST}" \
        "ARCH=${arch}" "KEYRING=${DOCKER_KEYRING}" "OS_ID=${os_id}" "CODENAME=${codename}" || return 1
    [[ ${OS_TEMPLATE_CHANGED} -eq 1 ]] && changed=1

    # 只有源真的变了才刷索引：第二次执行要零变更，而 apt-get update
    # 既是几秒钟，也是一条无谓的审计记录
    [[ ${changed} -eq 1 ]] && os::pkg_refresh
    return 0
}

# ------------------------------------------------------------------

main() {
    # --- 现状：三个事实决定下面每一个分支 ---
    #
    # `docker` 这个命令名归谁、引擎在不在、在的话是不是官方源装的。
    # 三个问题各有各的判据，合成一个「装没装 docker」会在最需要区分的
    # 那台机器上答错。
    probe::container_engine
    local engine=${OS_PROBE_VALUE}
    probe::package_installed podman-docker
    local has_podman_docker=${OS_PROBE_VALUE}

    local cur=''
    docker_version cur

    probe::package_installed docker-ce
    local ce_installed=${OS_PROBE_VALUE}

    # --- 交互全部前置 ---
    #
    # 非交互下缺参数以 2 终止，而退出码 2 承诺「未变更」——
    # 所以每一个交互点都必须排在任何副作用之前。
    local want_compose=''
    os::select --arg compose '安装 Docker Compose 插件（docker compose 子命令）' want_compose \
        'y=安装' 'n=不安装'

    # --- 冲突：docker 这个命令名现在归 podman ---
    #
    # podman-docker 提供的也是 `/usr/bin/docker`，与 docker-ce-cli 在 dpkg
    # 层面装不到一起。install_podman 撞上真 Docker 时是直接拒绝的（那一侧
    # 没有可撤销的东西，卸 Docker 是大事）；这一侧相反 —— podman-docker
    # 是本工具装的、state 里记着，撤销它只影响一个命令名，问一句就能往下走。
    if [[ ${engine} == podman || ${has_podman_docker} == yes ]]; then
        os::warn 'podman-docker 正占着 /usr/bin/docker —— 它与 docker-ce-cli 提供同一个文件，dpkg 装不到一起'
        os::info '撤销它只影响 docker 这个命令名：podman 本体与已有的容器、镜像、卷都不动'
        if ! os::confirm --arg purge-podman-docker '现在 purge 掉 podman-docker' n; then
            os::info '已取消，什么都没有动'
            os::output 130 changed=no
            return 130
        fi

        os::pkg_purge podman-docker \
            || os::die 1 'purge podman-docker 失败 —— 不清掉它就装不上 docker-ce-cli，先手动处理再重跑'

        # state 里那条 pkg 记录是 install_podman 登记的。包没了还留着，
        # 就是一条假事实 —— 而 state 是卸载的唯一依据（§12）
        os::state_resource_del "${PODMAN_ID}" pkg podman-docker \
            || os::warn "没能从 state 的 podman 清单里摘掉 podman-docker：日后卸 podman 会尝试 purge 一个不存在的包"

        # /run 是 tmpfs，podman-docker 的 tmpfiles 在这一轮开机里已经把
        # /run/docker.sock 软链到 podman 的 socket 了。**purge 不会带走它**
        # （文件是运行期建的，不归 dpkg 管），于是 dockerd 起来时发现路径
        # 已被占用，而照 Docker API 说话的工具会一声不响地连到 podman 上去
        if [[ -L ${DOCKER_SOCK} ]]; then
            os::run '清掉指向 podman 的 /run/docker.sock 软链' -- rm -f -- "${DOCKER_SOCK}"
        fi
    fi

    # --- 网络定位决定 dockerd 默认把 -p 绑到哪个地址 ---
    #
    # 与 network.sh 是同一张表（D206）：公网 → 127.0.0.1，
    # 内网 → 0.0.0.0。没设过按公网处理 —— `docker run -p 8080:80` 的原义是
    # 绑 0.0.0.0，粘一条网上抄来的命令就把服务挂在公网端口上，
    # 而用户根本不知道自己做过这个决定。
    # **在这里问，不在装完之后提示。** 装完自己想起来去设的真实结果是永远没设，
    # 而那一档过去被静默当成公网 —— 一个用户不知道自己做过的决定。
    # **一台机器只定一次**：podman 装的时候可能已经问过了，要改走 oneserver network。
    #
    # 这里不问「确认在可信内网」那一句：那道确认是给 ufw 转发策略的（放开它等于
    # 让本机转发一切，不只是容器），而 Docker 这一半只改绑定地址，没有那个后果
    local netmode
    netmode=$(os::state_get network mode '')
    if [[ -n ${netmode} ]]; then
        os::info "沿用已设定的网络定位：${netmode}（要改：oneserver network）"
    else
        os::select --arg network-mode '这台机器的容器端口对谁开放？' netmode \
            '公网=公网服务器 —— 端口只绑本机，一律走 Caddy 反代' \
            '内网=内网机器 —— 端口直接对局域网开放'
        os::info '以后要改：安全菜单里的「网络定位」，或敲 oneserver network'
    fi
    local bind_ip='127.0.0.1'
    [[ ${netmode} == 内网 ]] && bind_ip='0.0.0.0'

    # --- 用户自己的 daemon.json 不覆盖，但也不能装作没看见 ---
    #
    # 覆盖它等于删用户配置（§12 禁止）；装上就不管，则公网定位承诺的
    # 「端口只绑本机」是假的。§15 对这种情形说得很直白：补偿控制落实不了
    # 就拒绝执行，不能「先装上，回头再提示用户自行加固」。
    # 检查排在装包之前，退出码 2 才对得上「未变更」。
    local -i own_daemon_json=1
    if [[ -f ${DAEMON_JSON} ]] && ! state_owns_file "${DAEMON_JSON}"; then
        own_daemon_json=0
        if [[ ${bind_ip} == 127.0.0.1 ]] \
            && ! os::query --timeout 5 -- grep -qE '"ip"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' "${DAEMON_JSON}"; then
            os::die 2 "${DAEMON_JSON} 是你自己的配置，本工具不覆盖它；而公网定位要求容器端口默认只绑本机 —— 请在里面加一条 \"ip\": \"127.0.0.1\" 后重跑，或把网络定位改成内网（oneserver safe network）"
        fi
        os::info "${DAEMON_JSON} 已存在且不是本工具放的，保持原样"
    fi

    # --- 装 ---
    local -a pkgs=()
    local method='foreign'
    if [[ -z ${cur} || ${ce_installed} == yes ]]; then
        method='docker-ce'

        probe::os_id
        local os_id=${OS_PROBE_VALUE}
        probe::os_codename
        local codename=${OS_PROBE_VALUE}
        local docker_codename=${codename}
        local arch=''
        docker_arch arch
        [[ -n ${os_id} && -n ${codename} ]] \
            || os::die 4 '读不到发行版 ID 或代号，拼不出 Docker 官方源的地址'
        [[ -n ${arch} ]] \
            || os::die 4 '这个架构在 Docker 官方源里没有对应的包'

        # ca-certificates / curl / gnupg 是通用依赖，**有意不进资源清单**：
        # 卸 Docker 时把 curl 一起 purge 掉，后果比留下一个包严重得多
        os::pkg_install ca-certificates curl gnupg
        # dry-run 下上面那句什么都没装，这里再去 require 就是拿预演当真实执行 ——
        # 规范：预演遇到依赖未满足禁止报错退出
        [[ ${OS_DRYRUN} -eq 1 ]] || os::require_cmd curl gpg

        local repo_status=''
        docker_repo_status repo_status "${os_id}" "${codename}" \
            || os::die 1 '无法检查 Docker 官方仓库是否提供当前发行版代号'
        case ${repo_status} in
            200) ;;
            404)
                docker_repo_fallback docker_codename "${os_id}" "${codename}" \
                    || os::die 4 "Docker 官方仓库尚未支持 ${os_id} ${codename}；本工具不会猜测可用的旧版仓库"
                docker_repo_status repo_status "${os_id}" "${docker_codename}" \
                    || os::die 1 "无法检查 Docker 官方回退源 ${docker_codename}"
                [[ ${repo_status} == 200 ]] \
                    || os::die 1 "Docker 官方回退源 ${docker_codename} 不可用（HTTP ${repo_status}）"
                os::warn "Docker 官方仓库尚未提供 Debian ${codename}，按官方 testing 指引改用 Debian ${docker_codename} 源"
                ;;
            *) os::die 1 "Docker 官方仓库检查返回 HTTP ${repo_status}" ;;
        esac

        local tmp
        os::tmpdir tmp
        setup_apt_repo "${tmp}" "${os_id}" "${docker_codename}" "${arch}" \
            || os::die 1 '配置 Docker apt 源失败'

        pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
        [[ ${want_compose} == y ]] && pkgs+=(docker-compose-plugin)

        local IFS=' '
        os::pkg_install "${pkgs[@]}" || os::die 1 "安装失败：${pkgs[*]}"
        IFS=$'\n\t'
    else
        os::info "已装 Docker ${cur}，但不是官方源装的（没有 docker-ce 包）—— 本工具不替你换来源，只做配置"
        [[ ${want_compose} == y ]] \
            && os::info 'compose 请沿用它原来的来源（发行版的 docker-compose-v2 或你自己装的）'
    fi

    docker_version cur
    if [[ -z ${cur} && ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（Docker 尚未安装，版本与守护进程配置都问不出来）'
        os::output 0 changed=dry-run
        return 0
    fi
    [[ -n ${cur} ]] || os::die 1 '装完之后仍然探测不到 dockerd，安装没有真正成功'
    os::ok "Docker ${cur}"

    # ext:：包自带的 unit，卸载时只停止禁用，禁止删文件（D36）。
    # 包装完通常已经把它拉起来了，这一步是幂等的补齐
    os::systemd_enable --now docker.service ext

    # --- daemon.json ---
    local -i daemon_json_created=0 daemon_changed=0
    if [[ ${own_daemon_json} -eq 1 ]]; then
        [[ -f ${DAEMON_JSON} ]] || daemon_json_created=1
        if [[ ! -d ${DOCKER_ETC_DIR} ]]; then
            os::run '创建 /etc/docker' -- mkdir -p "${DOCKER_ETC_DIR}"
            os::run '设置 /etc/docker 权限' -- chmod 0755 "${DOCKER_ETC_DIR}"
        fi
        # 模板里除了绑定地址还带一段日志轮转：json-file 驱动**默认没有上限**，
        # 一个话多的容器能把根分区写满，而那一刻整台机器上所有服务一起坏
        os::install_template --backup --mode 0644 \
            "${OS_TEMPLATE_DIR}/docker-daemon.json" "${DAEMON_JSON}" \
            "BIND_IP=${bind_ip}" || os::die 1 "写入 ${DAEMON_JSON} 失败"
        daemon_changed=${OS_TEMPLATE_CHANGED}
    fi

    # --- 让配置生效 ---
    #
    # 不重启就是「写进去了但没生效」，而界面上看不出这个区别 —— 那正是
    # 「以为端口只绑了本机」的来源。有容器在跑时才问，因为那时重启是一次
    # 真实的服务中断；刚装完一个容器都没有，问了也只是噪音。
    if [[ ${daemon_changed} -eq 1 ]]; then
        probe::docker_running
        local running=${OS_PROBE_VALUE:-0}
        [[ ${running} =~ ^[0-9]+$ ]] || running=0
        local -i do_restart=1
        if ((running > 0)); then
            os::warn "重启 dockerd 会中断正在跑的 ${running} 个容器（带重启策略的会自己起回来）"
            os::confirm --arg restart-daemon '现在重启 dockerd 让配置生效' y || do_restart=0
        fi
        if ((do_restart == 1)); then
            os::systemd_restart docker.service
        else
            os::warn "${DAEMON_JSON} 已写入但尚未生效 —— dockerd 重启之前，新建容器的端口仍按旧的默认地址绑"
        fi
    fi

    # --- 与 podman 共存 ---
    probe::component_version podman
    if [[ -n ${OS_PROBE_VALUE} ]]; then
        os::info 'podman 也在这台机器上。两个引擎各有各的容器、镜像与卷，互相看不见 —— oneserver docker 与 oneserver podman 分别管各自那一套'
        os::info '网络定位对两边都生效，但落实方式不同：podman 靠 ufw 的转发策略，Docker 靠 dockerd 的默认绑定地址'
    fi

    # --- state 与资源清单 ---
    #
    # 网络定位**只记 mode，不记 forward_policy**：转发策略那一半是 podman 独有的
    # （dockerd 的跳转排在 ufw 之前，D206），这条路径一步都没做，记下来就是一条
    # 假事实 —— 而 network.sh 正是靠登记值与实际值的比对报「定位失效」
    os::state_set network mode="${netmode}"

    os::state_set "${COMPONENT_ID}" version="${cur}" method="${method}" \
        compose="${want_compose}" bind_ip="${bind_ip}"

    # 只登记**本次真正装上、且属于本组件**的包（规范两层过滤）
    local p q
    while IFS= read -r p; do
        [[ -n ${p} ]] || continue
        for q in ${pkgs[@]+"${pkgs[@]}"}; do
            if [[ ${p} == "${q}" ]]; then
                os::state_resource_add "${COMPONENT_ID}" pkg "${p}"
                break
            fi
        done
    done < <(os::pkg_installed_names)

    # 只登记本次真正建出来的那份（理由见 DOCKER_KEYRING_CREATED 的声明处），
    # 判据与下面 daemon.json 那条一致
    if [[ ${method} == docker-ce ]]; then
        ((DOCKER_KEYRING_CREATED == 1)) \
            && os::state_resource_add "${COMPONENT_ID}" file "${DOCKER_KEYRING}"
        ((DOCKER_LIST_CREATED == 1)) \
            && os::state_resource_add "${COMPONENT_ID}" file "${DOCKER_LIST}"
    fi
    # daemon.json 只在**本次创建**时登记：已经在的那份要么是用户的
    # （上面根本没写），要么上一轮已经登记过了
    ((daemon_json_created == 1)) && os::state_resource_add "${COMPONENT_ID}" file "${DAEMON_JSON}"

    local u
    while IFS= read -r u; do
        [[ -n ${u} ]] || continue
        os::state_unit_add "${COMPONENT_ID}" "${u}"
    done < <(os::systemd_touched)

    # --- 结果 ---
    local source_text='官方源 docker-ce'
    [[ ${method} == docker-ce ]] || source_text='本机已有，非本工具安装'
    local daemon_text=${DAEMON_JSON}
    [[ ${own_daemon_json} -eq 1 ]] || daemon_text="${DAEMON_JSON}（你自己的，未改动）"

    os::section 'Docker'
    os::kv '版本' "${cur}" \
        '来源' "${source_text}" \
        'compose' "$([[ ${want_compose} == y ]] && printf '已安装' || printf '未安装')" \
        '网络定位' "${netmode}" \
        '端口默认绑定' "${bind_ip}" \
        '守护进程配置' "${daemon_text}"

    # 这句不能省。ufw 在这台机器上多半是开着的，而「开着防火墙」会让人以为
    # 没放行的端口进不来 —— 对 Docker 发布的端口，那个推论是错的
    os::warn 'Docker 发布的端口绕过 ufw：dockerd 把自己的规则插在 FORWARD 链最前面，ufw 的放行与拒绝对它都不生效'
    if [[ ${bind_ip} == 127.0.0.1 ]]; then
        os::info '所以公网定位靠的是绑定地址：-p 8080:80 会绑到 127.0.0.1，对外请用 oneserver caddy 反代'
        os::info '显式写成 -p 0.0.0.0:8080:80 的端口就是对全网开放的，防火墙拦不住'
    fi
    os::info '下一步：oneserver docker run 建容器；看日志、启停与删除见 oneserver docker'
    os::info '要自动更新：建容器时选上，或事后在 oneserver docker 里切换，再「开启自动更新服务」'

    os::output 0 version="${cur}" method="${method}" compose="${want_compose}" \
        bind_ip="${bind_ip}" netmode="${netmode}"
    return 0
}

main "$@"
