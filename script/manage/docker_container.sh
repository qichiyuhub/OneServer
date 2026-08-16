#!/bin/bash
#
# Docker 容器管理
#
# @command      docker
# @name         Docker 容器
# @self_name    容器列表与操作
# @group        container
# @order        60
# @requires     docker
# @privilege    root
# @requires_lib >= 1.28
# @args         [--action=<ls|start|stop|restart|logs|rm|autoupdate|au-on|au-off|au-now>] [--name=<名字>] [--lines=<行数>] [--confirm-rm=<名字>]
# @description  创建、查看、启停、日志、删除与自动更新
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 本脚本只管**已有**容器：看、启停、看日志、删
# ==================================================================
#
# 建容器（粘 run 命令、补齐 -d/--name/--restart）在 `oneserver docker run` 里 ——
# 那部分的切词与校验逻辑跟这里的管理动作不是一类事，拆开维护。
#
# **容器本体没有第二份配置，dockerd 就是它们的唯一账本**，本工具不另记一份
# （不像 podman 那边有 Quadlet 文件可读）。
#
# ==================================================================
# 自动更新是**名单驱动**的，名单在本工具这边
# ==================================================================
#
# 更新器（Watchtower）有两种筛选模式：按容器标签筛，或者启动时直接给它一串
# 容器名、只盯这几个。**这里用名单模式**，因为 docker 不支持给已有容器改标签
# （`docker update` 只管资源限制与重启策略），标签模式下用户想给一个跑着的
# 容器开自动更新，唯一的路是删了重建 —— 而按 `docker inspect` 反推参数重建
# 覆盖不了自定义网络、复杂 mount 这些，重建出来的容器会悄悄走样。
#
# 名单存在 state 的 `docker` 组件下，改名单只需要重建**更新器自己那个容器**，
# 用户的业务容器一根汗毛都不动。于是 docker 侧终于也有了「随时可切」。
#
# 三条落地约束，每条都实测过：
#
#   1. **名单空时绝不能起更新器** —— 不带名单等于扫全机，与「不在名单里的
#      一概不动」正好相反。名单空就把更新器删掉。
#   2. **新起的常驻更新器会删掉机器上其它更新器容器**（它自带的单实例保护）。
#      对我们是好事：改名单靠重建，不会留下两个。但用户自己另装的更新器会被
#      我们的干掉，反之亦然，所以开启时要说这句。
#   3. **一次性实例不碰常驻实例**。所以「立即检查更新」用一个用完即弃的
#      `--run-once` 容器，不会打断常驻的那个，常驻的没部署时也照样能用。
#
# 开关服务用「建/删更新器容器」而不是「起/停」：名单是**启动参数**，停了再起
# 用的还是老名单。删了重建才能保证跑着的那个与名单永远一致。

readonly NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$'
readonly UNIT='docker.service'
readonly WATCHTOWER_NAME='oneserver-watchtower'

# 自动更新器镜像。**必须固定 digest，不能用可变 tag。**
#
# 这个容器挂着 `/var/run/docker.sock`，也就是说它在宿主上的能力等价于 root。
# 规范 §11 要求本工具装第三方软件一律走包管理器或校验 SHA256；容器镜像用
# 可变 tag 拉取两者都不满足 —— 每次 `docker pull` 拿到的字节都可能是新的，
# 而没有任何一处能发现它变了。固定 digest 之后，registry 在拉取时就会拒绝
# 内容对不上的响应，`docker pull` 本身就是那道校验。
#
# 固定的是**多架构 index digest**（OCI image index），不是某一架构的 manifest
# digest：前者在 amd64 与 arm64 上都能解析到对应的那一份，后者换个架构就拉不动。
#
# **它提供的是可复现性，不是真实性。** 说清楚买到了什么、没买到什么：
#
#   买到  所有机器装到同一份字节；这份字节此后不会在无人知晓时被换掉，
#         攻破发布者账号的人也改不了已经固定的引用（tag 劫持防不住的正是这个）
#   没买到 这份字节本身可不可信。它是某一刻的 `:latest`，没有签名可验，
#         也没有人逐行审过它 —— 换 digest 时的信任模型与用浮动 tag 完全一样，
#         区别只在频率，以及有没有一个可以插入人工审查的时机
#
# 这个容器挂着 Docker Socket，能力等价于宿主 root，而镜像来自个人命名空间的
# fork（源码见镜像标签 org.opencontainers.image.source）。固定 digest 缩小不了
# 这个爆炸半径，只是让"装的是哪一份"变成确定的。
# digest 的升级是人工步骤，见 docs/OPERATIONS.md。
readonly WATCHTOWER_REPO='docker.io/nickfedor/watchtower'
readonly WATCHTOWER_DIGEST='sha256:bee77696862e09521c49e5ab4904a4179accece6d561a2ef334c7589b84a2438'
readonly WATCHTOWER_IMAGE="${WATCHTOWER_REPO}@${WATCHTOWER_DIGEST}"
readonly WATCHTOWER_INTERVAL='86400'
readonly DOCKER_ID='docker'
# 标签模式留下的痕迹。**本工具不再打也不再认这个标签**，只在开启服务时扫一眼
# 提醒用户 —— 从网上抄来的 run 与 compose 命令常常自带它，而在名单模式下它
# 一点作用都没有，不说的话用户会以为自己已经开好了
readonly LEGACY_LABEL='com.centurylinklabs.watchtower.enable'

# ------------------------------------------------------------------

require_docker() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Docker。先 oneserver install docker'
    os::require_cmd docker

    # daemon 停着的话下面每一条命令都会以「Cannot connect to the Docker
    # daemon」失败 —— 那句话不会告诉人服务是停着的，只会让人去查网络与权限
    probe::service_active "${UNIT}"
    [[ ${OS_PROBE_VALUE} == active ]] \
        || os::die 3 "dockerd 没在跑（当前 ${OS_PROBE_VALUE:-未知}）—— Docker 的每条命令都要连它：systemctl start ${UNIT}"
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "容器名「${name}」不合法：以字母或数字开头，此后只收字母、数字、下划线、点与短横线"
    return 0
}

# 容器在不在。结果写进返回码，不打印（D135 同理：`$( )` 会吞掉 probe 的来源）
container_exists() {
    local name=${1} line
    os::query --timeout 20 -- docker ps -a --format '{{.Names}}'
    while IFS= read -r line; do
        [[ ${line} == "${name}" ]] && return 0
    done <<<"${OS_RUN_OUTPUT}"
    return 1
}

require_container() {
    local name=${1}
    container_exists "${name}" \
        || os::die 2 "没有叫 ${name} 的容器（oneserver docker ls 看看有哪些）"
    return 0
}

# ------------------------------------------------------------------
# 自动更新名单
# ------------------------------------------------------------------

# 名单是**空格分隔的一个值**，不是多值键：state 的多值键只有资源清单那五个
# （`unit` `pkg` `file` `divert` `alt`），而名单不是资源，卸载器对它无事可做。
# 容器名过了 NAME_RE 必然不含空格，所以空格是安全的分隔符。
#
# 全局 IFS 是 `\n\t`，**空格不在里面** —— 拆名单的每一处都要自己把 IFS 设成
# 空格，否则整份名单会当成一个词，判断「在不在名单里」永远为假。
au_list() {
    local __dc_out=${1} __dc_v
    __dc_v=$(os::state_get "${DOCKER_ID}" autoupdate '')
    printf -v "${__dc_out}" '%s' "${__dc_v}"
    return 0
}

au_has() {
    local name=${1} list one
    au_list list
    local IFS=' '
    for one in ${list}; do
        [[ ${one} == "${name}" ]] && return 0
    done
    return 1
}

# 加入或移出，结果写回 state。已经是目标状态时返回 1，让调用方走幂等分支
au_toggle() {
    local name=${1} want=${2} list one acc=''
    au_list list
    local IFS=' '
    for one in ${list}; do
        [[ ${one} == "${name}" ]] && continue
        acc+="${acc:+ }${one}"
    done
    if [[ ${want} == in ]]; then
        au_has "${name}" && return 1
        acc+="${acc:+ }${name}"
    else
        au_has "${name}" || return 1
    fi
    IFS=$'\n\t'
    os::state_set "${DOCKER_ID}" "autoupdate=${acc}" || os::die 1 '写入自动更新名单失败'
    return 0
}

# ------------------------------------------------------------------
# 更新器
# ------------------------------------------------------------------

watchtower_running() {
    os::query --timeout 10 -- docker inspect -f '{{.State.Status}}' "${WATCHTOWER_NAME}" || return 1
    [[ ${OS_RUN_OUTPUT} == running ]]
}

watchtower_remove() {
    container_exists "${WATCHTOWER_NAME}" || return 0
    os::record_change "移除了 ${WATCHTOWER_NAME}"
    os::run '移除自动更新器' -- docker rm -f -- "${WATCHTOWER_NAME}" \
        || os::die 1 "移除 ${WATCHTOWER_NAME} 失败（详情看日志）"
    return 0
}

# 按当前名单把更新器重建出来。名单空只删不建（见文件头第 1 条）
watchtower_apply() {
    local list
    au_list list
    watchtower_remove
    [[ -n ${list} ]] || return 0

    local -a names=()
    IFS=' ' read -r -a names <<<"${list}"

    # 这件事必须说出来：更新器要挂 Docker Socket，而能对那个 socket 说话就等于
    # 能在宿主上以 root 做任何事。用户有权在这一刻知道自己要放进来的是什么
    os::warn "自动更新器会挂载 /var/run/docker.sock —— 它在宿主上的能力等价于 root。镜像已固定在 ${WATCHTOWER_DIGEST:0:19}…，升级它是人工步骤"

    # 按 digest 拉取：内容对不上时 registry 与 docker 会直接拒绝，这一步本身
    # 就是校验，不需要事后再算一遍哈希
    os::run '拉取自动更新器镜像' -- docker pull "${WATCHTOWER_IMAGE}" \
        || os::die 1 "自动更新器镜像拉取失败（固定 digest ${WATCHTOWER_DIGEST:0:19}…，内容对不上也会失败）"

    # 复核一遍本地那一份确实带着我们要的 digest。**不能用 `.Id`** —— 那是镜像
    # config 对象的摘要，与 `repo@sha256:` 里的 registry manifest/index 摘要
    # 是两个东西，正常镜像上也对不上，拿它比会把每一次部署都判成失败。
    # `.RepoDigests` 记的才是拉取时用的那个引用。
    os::query --timeout 20 -- docker image inspect "${WATCHTOWER_IMAGE}" \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' \
        || os::die 1 '读不出自动更新器镜像的 digest'
    [[ ${OS_RUN_OUTPUT} == *"${WATCHTOWER_DIGEST}"* ]] \
        || os::die 1 "本地镜像的 digest 与固定值不符，拒绝部署一个持有 Docker Socket 的容器"

    os::record_change "部署了 ${WATCHTOWER_NAME}（镜像固定在 ${WATCHTOWER_DIGEST:0:19}…）"
    # `--cleanup` 换完镜像顺手删掉旧的那一层，不然每更新一次就多留一份
    os::run '部署自动更新器' -- docker run -d --name "${WATCHTOWER_NAME}" \
        --restart always \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "${WATCHTOWER_IMAGE}" --cleanup --interval "${WATCHTOWER_INTERVAL}" "${names[@]}" \
        || os::die 1 '自动更新器部署失败（详情看日志）'
    return 0
}

# 总览表的编号就是当前操作周期的选择符，避免把同一批容器再打印一遍。
DC_LIST_READY=0
DC_IDS=()
DC_NAMES=()
DC_IMAGES=()
DC_STATUS=()
DC_PORTS=()
DC_PROJECTS=()
DC_AU=()
DC_LEGACY=()
DC_RESTART=()

short_cell() {
    local text=${1-}
    local -i limit=${2:-32}
    if ((${#text} > limit)); then
        printf '%s…\n' "${text:0:limit-1}"
    else
        printf '%s\n' "${text}"
    fi
    return 0
}

load_container_rows() {
    os::query --timeout 20 -- \
        docker ps -a --format "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"${LEGACY_LABEL}\"}}"
    local list=${OS_RUN_OUTPUT}

    DC_IDS=()
    DC_NAMES=()
    DC_IMAGES=()
    DC_STATUS=()
    DC_PORTS=()
    DC_PROJECTS=()
    DC_AU=()
    DC_LEGACY=()
    DC_RESTART=()
    DC_LIST_READY=1

    local line line_safe id name image status ports project legacy restart au
    local IFS=$'\n'
    for line in ${list}; do
        [[ -n ${line} ]] || continue
        line_safe=${line//$'\t'/$'\x01'}
        IFS=$'\x01' read -r id name image status ports project legacy <<<"${line_safe}"
        os::query --timeout 10 -- docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${name}"
        restart=${OS_RUN_OUTPUT:-no}
        au=no
        au_has "${name}" && au=yes
        DC_IDS+=("${id}")
        DC_NAMES+=("${name}")
        DC_IMAGES+=("${image}")
        DC_STATUS+=("${status}")
        DC_PORTS+=("${ports}")
        DC_PROJECTS+=("${project}")
        DC_AU+=("${au}")
        DC_LEGACY+=("${legacy}")
        DC_RESTART+=("${restart}")
    done
    return 0
}

# 名单里有、机器上却没有的容器名。用户绕过本工具删容器就会留下这种孤儿名。
# 实测更新器对不存在的名字是安静跳过的，不影响其余，所以这里只提示不自动清 ——
# 自动清会在容器临时删掉重建的窗口里把用户的设置一起抹掉
au_orphans() {
    local __dc_out=${1} list one acc='' found
    au_list list
    local -i i
    local IFS=' '
    for one in ${list}; do
        found=0
        for ((i = 0; i < ${#DC_NAMES[@]}; i++)); do
            [[ ${DC_NAMES[i]} == "${one}" ]] && found=1 && break
        done
        ((found == 0)) && acc+="${acc:+ }${one}"
    done
    printf -v "${__dc_out}" '%s' "${acc}"
    return 0
}

select_container() {
    local __dc_out=${1} prompt=${2}
    if [[ ${DC_LIST_READY} -ne 1 ]]; then
        action_ls
    fi
    [[ ${#DC_NAMES[@]} -gt 0 ]] || os::die 2 '没有 Docker 容器可选'

    local picked=''
    os::ask --arg name "${prompt}（输入上方编号；命令行可传 --name）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        local -i selected=$((picked - 1))
        ((selected >= 0 && selected < ${#DC_NAMES[@]})) \
            || os::die 2 "没有编号为「${picked}」的容器"
        picked=${DC_NAMES[selected]}
    fi
    validate_name "${picked}"
    printf -v "${__dc_out}" '%s' "${picked}"
    return 0
}

# ------------------------------------------------------------------

action_ls() {
    require_docker

    load_container_rows
    os::screen_heading '当前容器'
    if [[ ${#DC_NAMES[@]} -eq 0 ]]; then
        os::info '一个都没有。建一个：oneserver docker run'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local restart_label autoupdate_label
    local -i i any_autoupdate=0
    for ((i = 0; i < ${#DC_NAMES[@]}; i++)); do
        restart_label="${DC_RESTART[i]}"
        [[ ${restart_label} == no ]] && restart_label='—'
        [[ ${restart_label} != '—' ]] && restart_label="✔ ${restart_label}"
        autoupdate_label='—'
        if [[ ${DC_AU[i]} == yes ]]; then
            autoupdate_label='✔ 在名单'
            any_autoupdate=1
        fi
        cells+=("[$((i + 1))]" "${DC_IDS[i]:0:12}" "${DC_NAMES[i]}"
            "$(short_cell "${DC_IMAGES[i]}" 34)" "$(short_cell "${DC_STATUS[i]}" 18)"
            "${restart_label}" "${autoupdate_label}")
        os::output_item "id=${DC_IDS[i]}" "name=${DC_NAMES[i]}" "image=${DC_IMAGES[i]}" \
            "status=${DC_STATUS[i]}" "ports=${DC_PORTS[i]}" "restart=${DC_RESTART[i]}" \
            "compose_project=${DC_PROJECTS[i]}" "auto_update=${DC_AU[i]}"
    done
    os::table '编号' 'ID' '名称' '镜像' '状态' '自启' '自动更新' -- "${cells[@]}"

    # 服务状态与名单状态是两件事，都要说：名单里有东西而服务没开，等于设了不生效
    local svc='未开启'
    watchtower_running && svc='已开启'
    os::kv '自动更新服务' "${svc}"
    if ((any_autoupdate == 1)) && [[ ${svc} == 未开启 ]]; then
        os::warn '名单里有容器，但自动更新服务没开 —— 名单不会生效，用「开启自动更新服务」把它起来'
    fi

    local orphans=''
    au_orphans orphans
    [[ -n ${orphans} ]] \
        && os::warn "名单里这些容器已经不在了：${orphans}（用「切换自动更新」把它们移出去）"

    os::output 0 count="${#DC_NAMES[@]}" auto_update_service="${svc}"
    return 0
}

# start / stop / restart 共用一段：它们的区别只有一个动词
action_power() {
    local verb=${1}
    require_docker

    local name='' prompt=''
    case ${verb} in
        start) prompt='选择要启动的容器' ;;
        stop) prompt='选择要停止的容器' ;;
        restart) prompt='选择要重启的容器' ;;
    esac
    select_container name "${prompt}"
    require_container "${name}"

    # 启停一个可能是用户既有资产的容器，属「禁止自动回滚」类：它原来是开是关，
    # 这里并不知道，猜着还原比不还原破坏更大。只记进变更清单。
    #
    # 三个动词各写一条 desc 而不是拼字符串：规范要求 desc 是固定字符串 [CI]，
    # 拼出来的 desc 在日志与审计里就成了模板，grep 不到具体某一次操作
    os::record_change "对容器 ${name} 执行了 ${verb}"
    local -i rc=0
    case ${verb} in
        start) os::run '启动容器' -- docker start "${name}" || rc=$? ;;
        stop) os::run '停止容器' -- docker stop "${name}" || rc=$? ;;
        restart) os::run '重启容器' -- docker restart "${name}" || rc=$? ;;
    esac
    ((rc == 0)) || os::die 1 "docker ${verb} ${name} 失败（详情看日志）"

    local status='dry-run'
    if [[ ${OS_DRYRUN} -ne 1 ]]; then
        os::query --timeout 20 -- docker inspect -f '{{.State.Status}}' "${name}"
        status=${OS_RUN_OUTPUT}
    fi
    os::ok "${name}：${status}"
    os::output 0 name="${name}" action="${verb}" status="${status}"
    return 0
}

action_logs() {
    require_docker
    local name='' lines=''
    select_container name '选择要查看日志的容器'
    os::ask --arg lines '显示最近多少行' lines '50'
    [[ ${lines} =~ ^[0-9]+$ ]] || os::die 2 "--lines 要是正整数，收到「${lines}」"
    require_container "${name}"

    # `docker logs` 把容器的 stderr 原样打在自己的 stderr 上，而 os::query
    # 默认只取 stdout —— 不合流的话，nginx、postgres 这些把日志全写 stderr 的
    # 镜像在这里会打出一片空白。合流用框架现成的 `--want-stderr`，不起内层
    # shell：`sh -c "… ${name} 2>&1"` 靠的是「上游校验过这两个值」，而那是一条
    # 会在重构中静默失效的保证；经 argv 传值则从结构上不存在这个问题。
    os::query --timeout 30 --want-stderr -- docker logs --tail "${lines}" "${name}"
    os::section "${name} 最近 ${lines} 行"
    os::info "${OS_RUN_OUTPUT}"
    os::info "要实时跟：docker logs -f ${name}"
    os::output 0 name="${name}" lines="${lines}"
    return 0
}

action_rm() {
    require_docker
    local name=''
    select_container name '选择要删除的容器'
    require_container "${name}"

    # 删容器不可逆：容器里没写进卷的东西删了就没了。
    # 但**卷本身不删** —— 那是数据，规范禁止自动删除
    if ! os::destroy_confirm --arg confirm-rm "${name}" -- \
        "容器 ${name}（正在跑的会被强制停止）" \
        '容器内未写入卷的数据（卷本身不会被删）'; then
        os::info '已取消，什么都没有动'
        os::output 130 name="${name}" removed=no
        return 130
    fi

    os::record_change "删除了容器 ${name}"
    os::run '删除容器' -- docker rm -f -- "${name}" \
        || os::die 1 "删除容器 ${name} 失败（详情看日志）"

    # 顺手从名单里摘掉，不然它就成了一个孤儿名，下次列表页要报一句
    if au_toggle "${name}" out; then
        os::info "已把 ${name} 从自动更新名单里摘掉"
        if watchtower_running; then
            watchtower_apply
        fi
    fi

    os::ok "容器 ${name} 已删除"
    os::info '它用过的卷与镜像都还在：oneserver docker volume（卷）· oneserver docker image（镜像）'
    os::output 0 name="${name}" removed=yes
    return 0
}

# 把一个容器加进名单或移出名单。**动的只有名单和更新器自己那个容器**，
# 用户的业务容器不重启、不重建 —— 这正是名单模式换来的东西
action_autoupdate() {
    require_docker
    local name=''
    select_container name '选择要切换自动更新的容器'
    require_container "${name}"

    local want='in' verb='加入'
    if au_has "${name}"; then
        want='out'
        verb='移出'
    fi

    if ! au_toggle "${name}" "${want}"; then
        os::ok "容器 ${name} 已经是目标状态，未改动"
        os::output 0 name="${name}" auto_update="$([[ ${want} == in ]] && printf yes || printf no)" changed=no
        return 0
    fi
    os::ok "容器 ${name} 已${verb}自动更新名单"
    # 加入名单的人下一步会被引导去启用更新器，代价要在他点头之前说，
    # 不能等到那一步才第一次听见（同 docker_create 建容器时那一问）
    [[ ${want} == in ]] \
        && os::info '提醒：执行更新的更新器容器要挂载 /var/run/docker.sock —— 那等价于宿主 root 权限'

    # 名单是更新器的启动参数，服务开着就得重建它，新名单才算数；
    # 服务没开就只改名单，等开启时自然带上
    if watchtower_running; then
        os::info '正在让新名单生效（重建自动更新器，不影响你的容器）'
        watchtower_apply
        os::ok '自动更新器已按新名单重建'
    else
        os::info '自动更新服务没开，名单先记下了 —— 用「开启自动更新服务」让它生效'
    fi

    os::output 0 name="${name}" auto_update="$([[ ${want} == in ]] && printf yes || printf no)" changed=yes
    return 0
}

action_au_on() {
    require_docker
    local list=''
    au_list list
    [[ -n ${list} ]] \
        || os::die 2 '自动更新名单是空的，起来也没有任何容器要更新 —— 先用「切换自动更新」把容器加进名单'

    # 标签模式的残留：这个标签在名单模式下毫无作用，不说的话用户会以为已经开好了
    local -i i
    local legacy=''
    load_container_rows
    for ((i = 0; i < ${#DC_NAMES[@]}; i++)); do
        [[ ${DC_LEGACY[i]} == true && ${DC_AU[i]} == no ]] \
            && legacy+="${legacy:+ }${DC_NAMES[i]}"
    done
    [[ -n ${legacy} ]] \
        && os::warn "这些容器带着 ${LEGACY_LABEL} 标签，但本工具只认名单，标签不起作用：${legacy}"

    os::warn "更新器只允许机器上跑一个 —— 起它会删掉你自己另装的更新器容器（如果有）"
    watchtower_apply

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 更新器没有真的部署，状态无从确认'
        os::output 0 changed=dry-run
        return 0
    fi
    watchtower_running \
        || os::die 1 "${WATCHTOWER_NAME} 没能起来，详情看 docker logs ${WATCHTOWER_NAME}"

    os::ok "自动更新服务已开启，只更新名单里的容器：${list}"
    os::output 0 auto_update_service=on names="${list}"
    return 0
}

action_au_off() {
    require_docker
    if ! container_exists "${WATCHTOWER_NAME}"; then
        os::ok '自动更新服务本来就没开，未改动'
        os::output 0 auto_update_service=off changed=no
        return 0
    fi

    # 删而不是停：停下来的容器带着 --restart always，重启机器它自己就回来了，
    # 用户以为关掉了其实没有。删掉之后名单还在 state 里，再开启时原样带上
    watchtower_remove
    os::ok '自动更新服务已关闭（名单留着，再开启时照旧生效）'
    os::output 0 auto_update_service=off changed=yes
    return 0
}

action_au_now() {
    require_docker
    local list=''
    au_list list
    [[ -n ${list} ]] \
        || os::die 2 '自动更新名单是空的，没有容器要检查 —— 先用「切换自动更新」把容器加进名单'

    local -a names=()
    IFS=' ' read -r -a names <<<"${list}"

    # 用完即弃的一次性实例。实测它不会碰常驻的那个，所以服务开着也能随时手动
    # 跑一轮；服务没开时这条同样可用 —— 只想手动更新、不想要定时的人正需要它
    # **socket 那件事在这里也要说。** 这条路不需要先开服务，它自己 `docker run`
    # 一个一次性更新器 —— 一样挂 Docker Socket、一样等价宿主 root。从前只警告
    # 了「业务容器会短暂中断」，于是「我没开自动更新服务」的人会以为自己没暴露过，
    # 而实际上点一次这里就已经让那个镜像以 root 跑过一轮了。
    os::warn "更新器容器会挂载 /var/run/docker.sock —— 它在宿主上的能力等价于 root；本次是用完即弃的一次性实例，不需要开启服务"
    os::warn "要检查的容器：${list}。有新镜像的会被拉取并重建，期间这些容器会短暂中断"
    os::record_change "对名单里的容器执行了一次自动更新检查"
    os::run_out '执行一次自动更新检查' -- docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "${WATCHTOWER_IMAGE}" --run-once --cleanup "${names[@]}" \
        || os::die 1 '自动更新检查失败（详情看日志）'

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 检查没有真的执行，结果无从确认'
        os::output 0 names="${list}" changed=dry-run
        return 0
    fi
    os::section '检查结果'
    os::info "${OS_RUN_OUTPUT}"
    os::output 0 names="${list}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_ls --arg action '操作' dispatch \
        'start=启动' 'stop=停止' 'restart=重启' \
        'logs=查看日志' 'rm=删除容器' \
        'autoupdate=切换自动更新' \
        'au-on=开启自动更新服务' 'au-off=关闭自动更新服务' 'au-now=立即检查更新'
}

dispatch() {
    case ${1} in
        ls) action_ls ;;
        start) action_power start ;;
        stop) action_power stop ;;
        restart) action_power restart ;;
        logs) action_logs ;;
        rm) action_rm ;;
        autoupdate) action_autoupdate ;;
        au-on) action_au_on ;;
        au-off) action_au_off ;;
        au-now) action_au_now ;;
        *) os::die 2 "未知操作「${1}」，可用：ls start stop restart logs rm autoupdate au-on au-off au-now" ;;
    esac
}

main "$@"
