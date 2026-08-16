#!/bin/bash
#
# Compose 项目
#
# @command      docker compose
# @name         Compose 项目
# @group        container
# @order        100
# @requires     docker,docker-compose-plugin
# @privilege    root
# @requires_lib >= 4.0
# @args         [--action=<ls|add|up|down|rm>] [--name=<项目名>] [--dir=<目录>] [--with-volumes] [--confirm-rm=<项目名>]
# @description  把 compose 项目交给 systemd 托管
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 一个 compose 项目 = 一个 own: 的 systemd wrapper unit
# ==================================================================
#
# 与 `podman_compose.sh` 是同一套逻辑（D196/D197/D198/D199/D201/D202 同样
# 适用），命令换成 `docker compose`。**没有 provider 选择这一段**——podman
# 那边要在 podman-compose / Compose v1 / Compose v2 之间挑并钉住（D203/D204），
# 是因为 podman 默认发现顺序会挑中过时的实现；docker 上 `docker compose`
# 本身就是官方 Compose v2 插件，只有装没装一种状态，不需要挑。
#
# 项目目录**原地使用，一个字节都不复制**（D198 同一条理由）：`.env`、
# `env_file:`、相对路径挂载、`build:` 上下文都得保持原样才成立。

readonly UNIT_PREFIX='oneserver-docker-compose-'
readonly UNIT_DIR='/etc/systemd/system'

# **项目名禁止 `.`**（同 D199）：点号归一化后与下划线名称可能撞上同一个 unit
readonly NAME_RE='^[a-z0-9][a-z0-9_-]{0,62}$'

# compose 规范定义的文件搜索顺序，四个都认
readonly -a COMPOSE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)

# ------------------------------------------------------------------
# 名字与路径
# ------------------------------------------------------------------

unit_of() {
    local __dk_out=${1} __dk_name=${2}
    printf -v "${__dk_out}" '%s' "${UNIT_PREFIX}${__dk_name}.service"
    return 0
}

# **state 命名空间与 podman 那边分开**（`docker-compose:` 不是 `compose:`）：
# 两个引擎各自独立，同一个项目名在 podman 与 docker 下各注册一份互不干扰，
# 也不会在 state 里撞车
id_of() {
    local __dk_out=${1} __dk_name=${2}
    printf -v "${__dk_out}" '%s' "docker-compose:${__dk_name}"
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "项目名「${name}」不合法：只收小写字母、数字、下划线与短横线，且以字母或数字开头。点号不行 —— 它会让两个不同的项目撞上同一个 systemd unit"
    return 0
}

# 目录里的 compose 文件，按规范顺序取第一个存在的；一个都没有时给空串
find_compose_file() {
    local __dk_out=${1} __dk_dir=${2}
    local __dk_n
    printf -v "${__dk_out}" '%s' ''
    for __dk_n in "${COMPOSE_NAMES[@]}"; do
        if [[ -f "${__dk_dir}/${__dk_n}" ]]; then
            printf -v "${__dk_out}" '%s' "${__dk_dir}/${__dk_n}"
            return 0
        fi
    done
    return 0
}

# ------------------------------------------------------------------

DOCKER_BIN=''

require_docker() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Docker。先 oneserver install docker'
    os::require_cmd docker systemctl
    probe::service_active docker.service
    [[ ${OS_PROBE_VALUE} == active ]] \
        || os::die 3 "dockerd 没在跑（当前 ${OS_PROBE_VALUE:-未知}）—— 先 systemctl start docker.service"
    DOCKER_BIN=$(type -P docker || true)
    [[ -n ${DOCKER_BIN} ]] || os::die 3 '找不到 docker 的可执行文件路径'
    return 0
}

# docker compose（v2 插件）装没装。**不像 podman 那边要挑最合适的实现**——
# 这里只有一种真正的 provider，装了就能用，没装就是没装
# 事实归 probe：注册表要靠同一件事决定菜单里显不显示这一项（@requires
# docker-compose-plugin），这里再自己探一遍就是第二份实现
require_compose() {
    probe::component_version docker-compose-plugin
    [[ -n ${OS_PROBE_VALUE} ]] \
        || os::die 3 '没有检测到 docker compose 插件。先 oneserver install docker --compose=y'
    return 0
}

# ------------------------------------------------------------------
# 按 compose 打的项目标签找对象
# ------------------------------------------------------------------

project_containers() {
    local __dk_out=${1} __dk_name=${2}
    os::query --timeout 20 -- docker ps -a --filter "label=com.docker.compose.project=${__dk_name}" --format '{{.Names}}'
    printf -v "${__dk_out}" '%s' "${OS_RUN_OUTPUT}"
    return 0
}

project_volumes() {
    local __dk_out=${1} __dk_name=${2}
    os::query --timeout 20 -- docker volume ls --filter "label=com.docker.compose.project=${__dk_name}" --format '{{.Name}}'
    printf -v "${__dk_out}" '%s' "${OS_RUN_OUTPUT}"
    return 0
}

# 一行行数（空串算 0）
count_lines() {
    local __dk_out=${1} __dk_s=${2}
    local -i __dk_n=0
    if [[ -n ${__dk_s} ]]; then
        local __dk_l
        local IFS=$'\n'
        for __dk_l in ${__dk_s}; do
            [[ -n ${__dk_l} ]] && __dk_n+=1
        done
    fi
    printf -v "${__dk_out}" '%s' "${__dk_n}"
    return 0
}

# ------------------------------------------------------------------

# 幂等的判据（同 D201）：**渲染之后的配置**的 sha256，不是 compose 文件本身的。
# 只改 `.env`（compose 文件一个字节没动）时，按文件哈希判会得出「已是目标
# 状态」并跳过应用，而用户明明改了配置。`docker compose config` 的输出正好是
# compose 文件 + 全部被引用的文件 + 插值结果，顺带也是语法校验。
#
# 失败时返回 1，错误在 OS_RUN_OUTPUT 里。
project_config_sha() {
    local __dk_out=${1} __dk_file=${2} __dk_name=${3}
    printf -v "${__dk_out}" '%s' ''

    os::query --timeout 60 -- "${DOCKER_BIN}" compose -f "${__dk_file}" -p "${__dk_name}" config || return 1

    local __dk_rendered=${OS_RUN_OUTPUT}
    local __dk_dir __dk_tmp
    os::tmpdir __dk_dir || return 1
    __dk_tmp="${__dk_dir}/config.rendered"
    printf '%s\n' "${__dk_rendered}" >"${__dk_tmp}"

    if os::query --timeout 20 -- sha256sum "${__dk_tmp}"; then
        printf -v "${__dk_out}" '%s' "${OS_RUN_OUTPUT%%[[:space:]]*}"
    fi
    return 0
}

# 镜像写没写全名。只警告不拒绝——拒绝会挡住 localhost/ 开头的本地镜像，
# 而 ${VAR} 这类根本没法静态判断
warn_short_image_names() {
    local file=${1}
    os::query --timeout 10 -- grep -nE '^[[:space:]]*image:[[:space:]]*' "${file}" || return 0
    local raw img first
    local IFS=$'\n'
    for raw in ${OS_RUN_OUTPUT}; do
        img=${raw#*image:}
        img=${img##[[:space:]]}
        img=${img//[[:space:]]/}
        img=${img//\"/}
        img=${img//\'/}
        [[ -n ${img} ]] || continue
        # 带变量插值的镜像名静态判不了，跳过
        [[ ${img} == *"\${"* ]] && continue
        first=${img%%/*}
        if [[ ${img} != */* ]] || [[ ${first} != *.* && ${first} != localhost ]]; then
            os::warn "镜像「${img}」没写仓库前缀，实际拉哪个取决于 dockerd 的默认仓库 —— 同一份 compose 文件在两台机器上可能拉到不同的东西"
        fi
    done
    return 0
}

# ------------------------------------------------------------------
# unit 渲染
# ------------------------------------------------------------------

render_unit() {
    local __dk_out=${1} __dk_name=${2} __dk_dir=${3} __dk_file=${4}
    local __dk_unit __dk_tmpdir
    unit_of __dk_unit "${__dk_name}"
    os::tmpdir __dk_tmpdir || os::die 1 '无法创建临时目录'
    local __dk_tmp="${__dk_tmpdir}/${__dk_unit}"

    os::install_template --mode 0644 \
        "${OS_TEMPLATE_DIR}/docker-compose-project.service" "${__dk_tmp}" \
        "NAME=${__dk_name}" "DIR=${__dk_dir}" "FILE=${__dk_file}" "DOCKER=${DOCKER_BIN}" \
        || os::die 1 '渲染 compose 项目的 unit 失败'

    printf -v "${__dk_out}" '%s' "${__dk_tmp}"
    return 0
}

# 装 unit，但只在内容确实要变时装
install_unit_if_changed() {
    local __dk_changed_out=${1} __dk_tmp=${2} __dk_unit=${3}
    local __dk_dst="${UNIT_DIR}/${__dk_unit}"
    printf -v "${__dk_changed_out}" '%s' 0

    if [[ -f ${__dk_dst} ]] && os::query --timeout 10 -- cmp -s "${__dk_tmp}" "${__dk_dst}"; then
        return 0
    fi
    os::systemd_install "${__dk_tmp}" own || os::die 1 "安装 ${__dk_unit} 失败"
    printf -v "${__dk_changed_out}" '%s' 1
    return 0
}

# ------------------------------------------------------------------
# 从 state 取一个已注册的项目，顺带把 dir / file 校验一遍
# ------------------------------------------------------------------

PRJ_DIR=''
PRJ_FILE=''

load_project() {
    local name=${1}
    local id
    id_of id "${name}"
    os::state_has "${id}" \
        || os::die 2 "没有注册过叫 ${name} 的 compose 项目（oneserver docker compose ls 看有哪些）"

    PRJ_DIR=$(os::state_get "${id}" path)
    [[ -n ${PRJ_DIR} ]] || os::die 1 "state 里 ${id} 没有记录项目目录 —— 用 oneserver state show ${id} 看看"
    [[ -d ${PRJ_DIR} ]] || os::die 2 "项目目录 ${PRJ_DIR} 不在了。本工具从不删它，所以它是被别处移走或删掉的"

    find_compose_file PRJ_FILE "${PRJ_DIR}"
    local IFS=' '
    [[ -n ${PRJ_FILE} ]] \
        || os::die 2 "${PRJ_DIR} 里找不到 compose 文件（认这四个：${COMPOSE_NAMES[*]}）"
    return 0
}

# ------------------------------------------------------------------

# 总览表的编号就是当前操作周期的选择符，避免把同一批项目再打印一遍。
# 与容器清单同一套：列表缓存进数组，总览按它渲染，动作按它把编号翻回项目名 ——
# 序号与清单同源，才不会出现「看到的 3 号」与「操作的 3 号」不是一个。
DK_LIST_READY=0
DK_NAMES=()
DK_DIRS=()
DK_STATUS=()
DK_COUNTS=()

load_project_rows() {
    local -a ids=()
    mapfile -t ids < <(os::state_list docker-compose)

    DK_NAMES=()
    DK_DIRS=()
    DK_STATUS=()
    DK_COUNTS=()
    DK_LIST_READY=1

    local id name dir unit containers running total
    for id in ${ids[@]+"${ids[@]}"}; do
        [[ -n ${id} ]] || continue
        name=${id#docker-compose:}
        dir=$(os::state_get "${id}" path)
        unit_of unit "${name}"
        probe::service_active "${unit}"
        DK_STATUS+=("${OS_PROBE_VALUE}")

        project_containers containers "${name}"
        count_lines total "${containers}"
        os::query --timeout 20 -- docker ps --filter "label=com.docker.compose.project=${name}" --format '{{.Names}}' || true
        count_lines running "${OS_RUN_OUTPUT}"

        DK_NAMES+=("${name}")
        DK_DIRS+=("${dir}")
        DK_COUNTS+=("${running}/${total}")
    done
    return 0
}

# 选一个已托管的项目：编号或项目名都收。
#
# **清单没上屏时先列一遍**：从命令行直接跑时总览不会显示（它只在交互的动作
# 清单里跑），让人对着一个看不见的清单输编号不行。
select_project() {
    local __dk_out=${1} __dk_prompt=${2}
    [[ ${DK_LIST_READY} -eq 1 ]] || action_ls
    [[ ${#DK_NAMES[@]} -gt 0 ]] || os::die 2 '没有已托管的项目可选'

    local picked=''
    os::ask --arg name "${__dk_prompt}（输入上方编号；命令行可传 --name）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        local -i sel=$((picked - 1))
        ((sel >= 0 && sel < ${#DK_NAMES[@]})) \
            || os::die 2 "没有编号为「${picked}」的项目"
        picked=${DK_NAMES[sel]}
    fi
    validate_name "${picked}"
    printf -v "${__dk_out}" '%s' "${picked}"
    return 0
}

action_ls() {
    require_docker
    load_project_rows
    os::screen_heading 'Compose 项目'
    if [[ ${#DK_NAMES[@]} -eq 0 ]]; then
        os::info '一个都没有。注册一个：oneserver docker compose add --name=blog --dir=/srv/blog'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#DK_NAMES[@]}; i++)); do
        cells+=("[$((i + 1))]" "${DK_NAMES[i]}" "${DK_STATUS[i]}" "${DK_COUNTS[i]}"
            "${DK_DIRS[i]}")
        os::output_item "name=${DK_NAMES[i]}" "path=${DK_DIRS[i]}" \
            "status=${DK_STATUS[i]}" "containers=${DK_COUNTS[i]}"
    done
    os::table '编号' '项目' '状态' '容器' '目录' -- "${cells[@]}"
    os::info '项目目录是你的，本工具不改也不删它。要彻底注销一个项目走 oneserver docker compose rm'
    os::output 0 count="${#DK_NAMES[@]}"
    return 0
}

action_add() {
    require_docker
    require_compose

    local name='' dir=''
    os::ask --arg name '项目名字（同时是 compose 的项目名与服务名）' name ''
    os::ask --arg dir 'compose 项目目录（**已经存在的那个**，本工具不复制它的任何文件）' dir ''

    [[ -n ${name} ]] || os::die 2 '要给出项目名字：--name=blog'
    validate_name "${name}"
    [[ -n ${dir} ]] || os::die 2 '要给出项目目录：--dir=/srv/blog'
    [[ ${dir} == /* ]] || os::die 2 "项目目录要写绝对路径，收到「${dir}」"
    dir=${dir%/}
    [[ -d ${dir} ]] || os::die 2 "目录 ${dir} 不存在。本工具不代劳创建（同 D194）—— 先把项目放好再来注册"

    local file=''
    find_compose_file file "${dir}"
    if [[ -z ${file} ]]; then
        local IFS=' '
        os::die 2 "${dir} 里没有 compose 文件（认这四个：${COMPOSE_NAMES[*]}）"
    fi

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    # 已经注册过。**上一次执行被中断也会走到这里**（state 写下去了、服务还没起来），
    # 所以要分清是「一切正常，你只是想改配置」还是「上次没跑完」
    if os::state_has "${id}"; then
        probe::service_active "${unit}"
        if [[ ${OS_PROBE_VALUE} == active ]]; then
            os::die 2 "已经注册过叫 ${name} 的项目，而且正在跑。改配置就直接编辑 ${file} 然后 oneserver docker compose up --name=${name}"
        fi
        os::die 2 "已经注册过叫 ${name} 的项目，但服务不在跑（${OS_PROBE_VALUE}）—— 上一次执行多半被中断了。把它起来：oneserver docker compose up --name=${name}"
    fi

    # unit 文件在、state 里却没有——中断留下的孤儿 unit，判据是模板首行标记
    if [[ -e "${UNIT_DIR}/${unit}" ]]; then
        if os::query --timeout 5 -- \
            grep -q '^# 由 oneserver docker compose 生成' "${UNIT_DIR}/${unit}"; then
            os::warn "${UNIT_DIR}/${unit} 是上一次被中断的执行留下的（state 里没有 ${id}），本次覆盖它"
        else
            os::die 2 "${UNIT_DIR}/${unit} 已经存在，而且不是本工具写的（文件里没有我们的标记）—— 先自己确认它是什么"
        fi
    fi

    # **同一个目录不许被两个项目注册**：两个 unit 会各自对同一批容器
    # up / stop，谁也不知道当前该是什么状态
    local other odir
    while IFS= read -r other; do
        [[ -n ${other} ]] || continue
        odir=$(os::state_get "${other}" path)
        [[ ${odir} == "${dir}" ]] \
            && os::die 2 "目录 ${dir} 已经被项目 ${other#docker-compose:} 注册了 —— 两个 unit 管同一批容器必然打架"
    done < <(os::state_list docker-compose)

    # --- 语法校验 ---
    local sha=''
    if ! project_config_sha sha "${file}" "${name}"; then
        os::err "${OS_RUN_OUTPUT}"
        os::die 2 "compose 文件没通过 docker compose 的解析：${file}"
    fi
    os::ok "compose 文件语法通过（${file}）"

    warn_short_image_names "${file}"

    # --- unit ---
    os::record_change "注册了 compose 项目 ${name}"
    local tmp=''
    render_unit tmp "${name}" "${dir}" "${file}"

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（unit 没有真的写下去，服务也就起不来）'
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    os::systemd_install "${tmp}" own || os::die 1 "安装 ${unit} 失败"
    os::systemd_enable "${unit}" own
    os::systemd_start "${unit}"

    probe::service_active "${unit}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::err "${unit} 没有进入 active"
        os::query --timeout 20 -- journalctl -u "${unit}" --no-pager -n 40
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 "项目 ${name} 没能起来，已撤销"
    fi

    # --- state ---
    #
    # `path` 不是资源清单里的 file：uninstall 对 file 是 rm -f（删不掉目录），
    # 而这个目录是**用户的**，属于规范「永不自动删除」那一栏，卸载只打印位置
    os::state_set "${id}" path="${dir}" compose_file="${file}" config_sha="${sha}" method=systemd
    # unit 是 own:：文件是我们写的，卸载连文件一起删
    os::state_unit_add "${id}" "own:${unit}"

    local containers='' total=0
    project_containers containers "${name}"
    count_lines total "${containers}"

    os::ok "compose 项目 ${name} 已托管并启动"
    os::kv '项目目录' "${dir}" \
        'compose 文件' "${file}" \
        '服务' "${unit}" \
        '容器' "${total} 个"
    os::info "改配置：直接编辑 ${file}，然后 oneserver docker compose up --name=${name}"
    os::info "看日志：journalctl -u ${unit}"
    os::output 0 name="${name}" path="${dir}" unit="${unit}" containers="${total}" changed=yes
    return 0
}

# 把项目应用到目标状态。**幂等的判据是 compose 文件的 sha + 服务在不在跑**（同 D201）
action_up() {
    require_docker
    require_compose

    local name=''
    select_project name '要启动哪个项目'
    load_project "${name}"

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    local sha='' recorded=''
    if ! project_config_sha sha "${PRJ_FILE}" "${name}"; then
        os::err "${OS_RUN_OUTPUT}"
        os::die 2 "compose 配置现在解析不了了：${PRJ_FILE}（改坏了？先修好再 up）"
    fi
    recorded=$(os::state_get "${id}" config_sha)
    probe::service_active "${unit}"
    local status=${OS_PROBE_VALUE}

    # unit 本身也可能要变：compose 文件改名了、项目目录挪了
    local tmp='' unit_changed=0
    render_unit tmp "${name}" "${PRJ_DIR}" "${PRJ_FILE}"

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（unit 没有真的写下去）'
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    install_unit_if_changed unit_changed "${tmp}" "${unit}"

    # 规范：已是目标状态**不产生任何变更，包括不重启服务**
    if [[ ${unit_changed} -eq 0 && ${sha} == "${recorded}" && ${status} == active ]]; then
        os::ok "项目 ${name} 已是目标状态（配置未变，服务在跑）"
        os::kv 'compose 文件' "${PRJ_FILE}" '服务' "${unit}"
        os::output 0 name="${name}" changed=no
        return 0
    fi

    os::record_change "应用了 compose 项目 ${name}"
    os::systemd_enable "${unit}" own
    if [[ ${status} == active ]]; then
        # restart 走 ExecStop(stop) → ExecStart(up -d)，这正是「应用配置变更」
        os::systemd_restart "${unit}"
    else
        os::systemd_start "${unit}"
    fi

    probe::service_active "${unit}"
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::err "${unit} 没有进入 active"
        os::query --timeout 20 -- journalctl -u "${unit}" --no-pager -n 40
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 "项目 ${name} 没能起来"
    fi

    os::state_set "${id}" compose_file="${PRJ_FILE}" config_sha="${sha}"
    os::state_unit_add "${id}" "own:${unit}"

    local containers='' total=0
    project_containers containers "${name}"
    count_lines total "${containers}"

    os::ok "项目 ${name} 已应用"
    os::kv 'compose 文件' "${PRJ_FILE}" '服务' "${unit}" '容器' "${total} 个"
    os::output 0 name="${name}" unit="${unit}" containers="${total}" changed=yes
    return 0
}

# 停止并移除项目的容器。**卷一律保留**——要删卷走 rm --with-volumes
# 或 oneserver docker volume rm，它们各自有完整的规范流程
action_down() {
    require_docker
    require_compose

    local name=''
    select_project name '要停止哪个项目'
    load_project "${name}"

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    os::record_change "停止了 compose 项目 ${name}"
    # **disable 在前**：否则机器重启或别处触发会把项目又拉回来，
    # 而用户刚刚明确说了要它停
    os::systemd_disable "${unit}" || true
    os::systemd_stop "${unit}" || true
    os::run --allow-fail '移除项目容器' -- "${DOCKER_BIN}" compose -f "${PRJ_FILE}" -p "${name}" down || true

    local containers='' total=0
    project_containers containers "${name}"
    count_lines total "${containers}"

    os::ok "项目 ${name} 已停止，容器已移除"
    os::kv '服务' "${unit}" '残留容器' "${total} 个"
    os::info '卷没有动 —— compose 项目的数据都在卷里，down 不碰它'
    os::info "拉回来：oneserver docker compose up --name=${name}"
    os::output 0 name="${name}" remaining="${total}" changed=yes
    return 0
}

action_rm() {
    require_docker
    require_compose

    local name='' with_volumes=0
    select_project name '要注销哪个项目'
    os::flag --arg with-volumes && with_volumes=1
    load_project "${name}"

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    # 规范：打印**具体清单**，不接受「将删除一个项目」这种概括
    local containers='' volumes=''
    project_containers containers "${name}"
    project_volumes volumes "${name}"

    local -a items=(
        "项目 ${name} 的 systemd 服务 ${unit}（含 ${UNIT_DIR}/${unit} 这个文件）"
        "项目的全部容器：${containers//$'\n'/ }"
    )
    if [[ ${with_volumes} -eq 1 ]]; then
        items+=("**项目的卷（数据，删了不可恢复，本工具不会替你先备份）**：${volumes//$'\n'/ }")
    else
        items+=("卷**不删**（${volumes//$'\n'/ }）—— 要连卷一起删得加 --with-volumes")
    fi
    items+=("项目目录 ${PRJ_DIR} **不删** —— 那是你的东西，本工具从来没往里写过")

    if ! os::destroy_confirm --arg confirm-rm "${name}" -- "${items[@]}"; then
        os::info '已取消，什么都没有动'
        os::output 130 name="${name}" removed=no
        return 130
    fi

    os::record_change "注销了 compose 项目 ${name}"
    os::systemd_disable "${unit}" || true
    os::systemd_stop "${unit}" || true

    local -a down=(compose -f "${PRJ_FILE}" -p "${name}" down)
    [[ ${with_volumes} -eq 1 ]] && down+=(-v)
    os::run --allow-fail '移除项目容器' -- "${DOCKER_BIN}" "${down[@]}" || true

    # own:：停止禁用之后连 unit 文件一起删（D36）
    os::systemd_remove "own:${unit}" || os::warn "移除 ${unit} 失败，检查 ${UNIT_DIR}/${unit}"
    os::state_del "${id}" || os::warn "从 state 里删除 ${id} 失败"

    os::ok "项目 ${name} 已注销"
    os::kv '项目目录' "${PRJ_DIR}（原封不动）" \
        '卷' "$([[ ${with_volumes} -eq 1 ]] && printf '已删除' || printf '保留')"
    os::info "要重新托管：oneserver docker compose add --name=${name} --dir=${PRJ_DIR}"
    os::output 0 name="${name}" removed=yes volumes_removed="${with_volumes}"
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
        'add=注册一个项目' 'up=启动/应用' \
        'down=停止' 'rm=注销项目'
}

dispatch() {
    case ${1} in
        ls) action_ls ;;
        add) action_add ;;
        up) action_up ;;
        down) action_down ;;
        rm) action_rm ;;
        *) os::die 2 "未知操作「${1}」，可用：ls add up down rm" ;;
    esac
}

main "$@"
