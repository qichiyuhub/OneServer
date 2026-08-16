#!/bin/bash
#
# Compose 项目
#
# @command      podman compose
# @name         Compose 项目
# @group        container
# @order        50
# @requires     podman,compose-usable
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
# `podman compose` 起的容器不是 Quadlet 托管的：重启机器不会自己回来，
# 在 `oneserver podman ls` 里还会显示成「本工具托管：否」，与用户认知矛盾。
# 所以每个项目包一层 `oneserver-compose-<名>.service`（D196）——
# 开机自启、依赖顺序、失败处理全交给 systemd，而 unit 是 `own:`（文件是我们
# 写的，卸载连文件一起清），项目目录是 `path`（用户的东西，永不自动删）。
#
# ==================================================================
# 本工具不碰用户的项目文件（D198）
# ==================================================================
#
# **`--dir` 指向用户已有的项目目录，原地使用，一个字节都不复制。**
# 旧脚本是「粘贴 docker-compose.yml 内容 → 存进 /opt/podman-compose/<名>/」，
# 那条路在真实的 compose 项目上是断的：
#
#   * `.env`（compose 自动读项目目录下的它做变量插值）不会跟着过去
#   * `env_file:` 引用的文件、`secrets:` / `configs:` 引用的本地文件同理
#   * `./data:/data`、`./nginx.conf:/etc/nginx/nginx.conf` 这类**相对路径挂载**
#     指向的是新目录里不存在的东西
#   * `build:` 的上下文目录与 Dockerfile 根本不在
#
# 而且这些**都不报错** —— 容器起来了，配置是空的。原地使用之后相对路径天然
# 成立，用户还能继续用自己的编辑器与 git 管那个目录。
#
# 代价是项目目录不在统一位置，所以 `ls` 从 state 读而不是扫目录 ——
# state 本来就是真相源。
#
# ==================================================================
# provider：兼容度取决于它，所以要钉死并当面报告（D203）
# ==================================================================
#
# `podman compose` 只是个转发壳，真正解析 compose 文件的是外部 provider。
# podman 的默认发现顺序是 **docker-compose 优先、podman-compose 垫底**，
# 而两个发行版源里的 `docker-compose` 完全不是一个东西：
#
#   Debian 13     docker-compose 2.26.1  ← 真 Compose v2（Go），兼容度最高
#   Ubuntu 24.04  docker-compose 1.29.2  ← 已经死掉的 Python v1，不认现代规范
#
# 照 podman 的默认顺序，Ubuntu 上「装了 docker-compose 反而更不兼容」，
# 且用户看不出来。所以这里自己排序（v2 > podman-compose > v1），把选中的那个
# 用 `PODMAN_COMPOSE_PROVIDER=` 钉进 unit，并在 add 时把兼容度说出来。
#
# 想要最高兼容度的用户有明确出路：装官方 Compose v2 二进制，`up` 一次就切过去，
# 本工具一行代码都不用改。
#
# ==================================================================
# 兼容边界 —— 这些取决于 provider，不是本工具能修的
# ==================================================================
#
#   * `build:` 能不能跑、`profiles` / `extends` / `depends_on: condition:`
#     支持到什么程度 —— 看 provider（podman-compose 1.0.6 尤其弱）
#   * `deploy:`（Swarm 专用）一律被忽略
#   * 本工具跑 rootful，`user:` 与低端口的行为与 Docker Desktop 上试出来的不同
#
# ==================================================================
# uninstall 的能力缺口，写在这里免得日后当 bug 查（D202）
# ==================================================================
#
# `oneserver uninstall compose:<名>` 是零组件分支的（D184），它只会 disable +
# stop 那个 unit —— 走 ExecStop 把容器**停下来但不删**，项目目录也只打印位置。
# 要真正删干净必须走 `oneserver podman compose rm`。这句话同时印在 rm 的
# 输出与 ls 的提示里，不靠使用者猜。

readonly UNIT_PREFIX='oneserver-compose-'
readonly UNIT_DIR='/etc/systemd/system'

# **项目名禁止 `.`**（D199）：旧脚本把 `.` 归一成 `_` 再拼 unit 名，于是
# `foo.bar` 与 `foo_bar` 映射到同一个 unit，它为此专门写了一段冲突检测。
# 从根上禁掉比检测好。这个字符集同时满足 compose 对项目名的要求。
readonly NAME_RE='^[a-z0-9][a-z0-9_-]{0,62}$'

# compose 规范定义的文件搜索顺序，四个都认
readonly -a COMPOSE_NAMES=(compose.yaml compose.yml docker-compose.yaml docker-compose.yml)

# ------------------------------------------------------------------
# 名字与路径
# ------------------------------------------------------------------

unit_of() {
    local __pk_out=${1} __pk_name=${2}
    printf -v "${__pk_out}" '%s' "${UNIT_PREFIX}${__pk_name}.service"
    return 0
}

id_of() {
    local __pk_out=${1} __pk_name=${2}
    printf -v "${__pk_out}" '%s' "compose:${__pk_name}"
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
    local __pk_out=${1} __pk_dir=${2}
    local __pk_n
    printf -v "${__pk_out}" '%s' ''
    for __pk_n in "${COMPOSE_NAMES[@]}"; do
        if [[ -f "${__pk_dir}/${__pk_n}" ]]; then
            printf -v "${__pk_out}" '%s' "${__pk_dir}/${__pk_n}"
            return 0
        fi
    done
    return 0
}

# ------------------------------------------------------------------
# provider
# ------------------------------------------------------------------

# 结果写进这三个变量（D135：不用 $( ) 返回，子 shell 会把 probe 的来源标注吞掉）
PROVIDER_PATH=''
PROVIDER_KIND=''
PROVIDER_VERSION=''

# 挑 provider。候选清单与挑选顺序（v2 > podman-compose > v1，D203）都在
# probe::compose_provider 里 —— 注册表也要靠同一个事实决定菜单里显不显示这一项，
# 两处各探各的迟早出现「菜单里有、进去说没有」（§10：两个以上消费者就必须是 probe）
detect_provider() {
    PROVIDER_PATH=''
    PROVIDER_KIND=''
    PROVIDER_VERSION=''
    probe::compose_provider
    [[ -n ${OS_PROBE_VALUE} ]] || return 0
    IFS=$'\t' read -r PROVIDER_KIND PROVIDER_VERSION PROVIDER_PATH <<<"${OS_PROBE_VALUE}"
    return 0
}

provider_note() {
    local __pk_out=${1}
    local __pk_msg
    case ${PROVIDER_KIND} in
        compose-v2) __pk_msg='Compose v2（规范的原始实现，兼容度最高）' ;;
        podman-compose) __pk_msg='podman-compose（第三方实现，build / profiles / depends_on 的条件写法支持不完整）' ;;
        compose-v1) __pk_msg='Compose v1（**已停止维护**，不认现代 compose 规范 —— 强烈建议换 v2）' ;;
        *) __pk_msg='未知' ;;
    esac
    printf -v "${__pk_out}" '%s' "${__pk_msg}"
    return 0
}

# ------------------------------------------------------------------

PODMAN_BIN=''

require_podman() {
    probe::component_version podman
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Podman。先 oneserver install podman'
    os::require_cmd podman systemctl
    PODMAN_BIN=$(type -P podman || true)
    [[ -n ${PODMAN_BIN} ]] || os::die 3 '找不到 podman 的可执行文件路径'
    return 0
}

require_provider() {
    detect_provider
    [[ -n ${PROVIDER_PATH} ]] || os::die 3 \
        '这台机器上没有任何 compose provider。装一个：oneserver install podman --compose=y（或自己装官方的 Compose v2 二进制，兼容度更高）'
    if [[ ${PROVIDER_KIND} == compose-v1 ]]; then
        os::warn "只找到 Compose v1（${PROVIDER_PATH} ${PROVIDER_VERSION}）—— 它已停止维护且不认现代 compose 规范。装 podman-compose 或官方 Compose v2 会好得多"
    fi
    return 0
}

# 最终选定之后再查这一条 —— 查的是**真正要用的那个**，不是探到的最好的那个
#
# **Compose v2 需要 podman.socket，podman-compose 不需要。**
# v2 是照 Docker 的 API 说话的，走 podman 的 docker 兼容 socket；
# podman-compose 直接调 podman 的命令行。socket 没开时 v2 会报
# 「Cannot connect to the Docker daemon」—— 那句话里的 docker 字样
# 会把人带到完全错误的方向，所以这里当场说清楚缺的是什么。
ensure_provider_usable() {
    [[ ${PROVIDER_KIND} == compose-v2 ]] || return 0
    probe::service_active podman.socket
    [[ ${OS_PROBE_VALUE} == active ]] || os::die 3 \
        'provider 是 Compose v2，它要通过 podman 的 docker 兼容 socket 说话，而 podman.socket 没在跑。开它：oneserver install podman --compose=y'
    return 0
}

# ------------------------------------------------------------------
# provider 在 add 时钉住，之后不自动换（D204）
# ------------------------------------------------------------------
#
# **这条是容器验收撞出来的，而且推翻了 D203 的一个前提。** 原本以为「装上
# Compose v2，下次 up 就自动切过去，本项目一行代码不用改」—— 实测不成立：
#
#     network blog_default was found but has incorrect label
#     com.docker.compose.network set to ""
#
# podman-compose 与 Compose v2 给容器和网络打的**标签不通用**，对方建的东西
# 在自己眼里是「有但不对」。于是对一个正跑着的项目换 provider，`up` 直接失败
# （验收里 systemd 走完 restart 就 failed，框架回滚，看着像是本工具坏了）。
#
# 所以：**只在项目一个容器都没有的时候才重新挑 provider** —— 那时没有任何
# 别人建的东西会冲突。要切就先 `down` 再 `up`，这条路径写进提示里。
adopt_recorded_provider() {
    local __pk_id=${1}
    local __pk_p
    __pk_p=$(os::state_get "${__pk_id}" provider_path)
    [[ -n ${__pk_p} && -x ${__pk_p} ]] || return 1
    PROVIDER_PATH=${__pk_p}
    PROVIDER_KIND=$(os::state_get "${__pk_id}" provider)
    provider_version_of PROVIDER_VERSION "${__pk_p}"
    return 0
}

# ------------------------------------------------------------------
# 按 compose 打的项目标签找对象
# ------------------------------------------------------------------
#
# 两个标签都要认：podman-compose 打 `io.podman.compose.project`，
# docker compose 打 `com.docker.compose.project`。新版 podman-compose 两个都打，
# 所以结果要去重。

collect_labeled() {
    local __pk_out=${1} __pk_name=${2}
    shift 2
    local __pk_lbl __pk_line __pk_seen='' __pk_acc=''
    for __pk_lbl in io.podman.compose.project com.docker.compose.project; do
        os::query --timeout 20 -- "$@" --filter "label=${__pk_lbl}=${__pk_name}" || continue
        local IFS=$'\n'
        for __pk_line in ${OS_RUN_OUTPUT}; do
            [[ -n ${__pk_line} ]] || continue
            [[ ${__pk_seen} == *"|${__pk_line}|"* ]] && continue
            __pk_seen+="|${__pk_line}|"
            __pk_acc+="${__pk_line}"$'\n'
        done
    done
    printf -v "${__pk_out}" '%s' "${__pk_acc%$'\n'}"
    return 0
}

project_containers() {
    collect_labeled "${1}" "${2}" podman ps -a --format '{{.Names}}'
}

project_volumes() {
    collect_labeled "${1}" "${2}" podman volume ls --format '{{.Name}}'
}

# 同 project_containers，但只数**在跑的**（`podman ps` 不带 `-a`）。
# 两个标签都要认的理由同上——只查 io.podman.compose.project 会在 provider
# 是 Compose v2（打 com.docker.compose.project）时把在跑的容器数成 0，
# 这条是容器验收撞出来的：ls 显示「0/2」，而 curl 那两个端口明明是通的
project_containers_running() {
    collect_labeled "${1}" "${2}" podman ps --format '{{.Names}}'
}

# 一行行数（空串算 0）
count_lines() {
    local __pk_out=${1} __pk_s=${2}
    local -i __pk_n=0
    if [[ -n ${__pk_s} ]]; then
        local __pk_l
        local IFS=$'\n'
        for __pk_l in ${__pk_s}; do
            [[ -n ${__pk_l} ]] && __pk_n+=1
        done
    fi
    printf -v "${__pk_out}" '%s' "${__pk_n}"
    return 0
}

# ------------------------------------------------------------------

# 幂等的判据（D201）：**渲染之后的配置**的 sha256，不是 compose 文件本身的。
#
# 这个区别是验收撞出来的，不是设计时想到的：只改 `.env`（compose 文件一个字节
# 没动）时，按文件哈希判会得出「已是目标状态」并**跳过应用** —— 而用户明明改了
# 配置，屏幕上还告诉他没什么要做的。`.env` 只是最常见的一种，`env_file:`、
# `include:`、`extends:` 引用的文件全是同一类。
#
# 反过来，「把整个项目目录哈希一遍」更糟：`./data` 这类绑定挂载里的东西每跑一次
# 都在变，那样永远判不出「已是目标状态」，幂等直接失效。
#
# `compose config` 的输出正好是这两者之间那条线：compose 文件 + 全部被引用的
# 文件 + 插值的结果，且只有这些。顺带它也是**语法校验**——解析不了就没有输出。
#
# 失败时返回 1，错误在 OS_RUN_OUTPUT 里。
project_config_sha() {
    local __pk_out=${1} __pk_file=${2} __pk_name=${3}
    printf -v "${__pk_out}" '%s' ''

    os::query --timeout 60 --env "PODMAN_COMPOSE_PROVIDER=${PROVIDER_PATH}" -- \
        podman compose -f "${__pk_file}" -p "${__pk_name}" config || return 1

    local __pk_rendered=${OS_RUN_OUTPUT}
    local __pk_dir __pk_tmp
    os::tmpdir __pk_dir || return 1
    __pk_tmp="${__pk_dir}/config.rendered"
    printf '%s\n' "${__pk_rendered}" >"${__pk_tmp}"

    if os::query --timeout 20 -- sha256sum "${__pk_tmp}"; then
        printf -v "${__pk_out}" '%s' "${OS_RUN_OUTPUT%%[[:space:]]*}"
    fi
    return 0
}

# 镜像写没写全名。只警告不拒绝 —— 同 oneserver podman run 的口径：
# 拒绝会挡住 localhost/ 开头的本地镜像，而 ${VAR} 这类根本没法静态判断
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
            os::warn "镜像「${img}」没写仓库前缀，实际拉哪个取决于 registries.conf —— 同一份 compose 文件在两台机器上可能拉到不同的东西"
        fi
    done
    return 0
}

# ------------------------------------------------------------------
# unit 渲染
# ------------------------------------------------------------------
#
# 模板在 $OS_TEMPLATE_DIR 里（整份配置从模板落地）。渲染到临时文件，
# 与已装的那份比过之后才调 os::systemd_install —— 内容一样就一个字节都不写，
# 否则每次 up 都会重写 unit，「已是目标状态零变更」当场失效。
render_unit() {
    local __pk_out=${1} __pk_name=${2} __pk_dir=${3} __pk_file=${4}
    local __pk_unit __pk_tmpdir
    unit_of __pk_unit "${__pk_name}"
    os::tmpdir __pk_tmpdir || os::die 1 '无法创建临时目录'
    local __pk_tmp="${__pk_tmpdir}/${__pk_unit}"

    os::install_template --mode 0644 \
        "${OS_TEMPLATE_DIR}/compose-project.service" "${__pk_tmp}" \
        "NAME=${__pk_name}" "DIR=${__pk_dir}" "FILE=${__pk_file}" \
        "PODMAN=${PODMAN_BIN}" "PROVIDER=${PROVIDER_PATH}" \
        || os::die 1 '渲染 compose 项目的 unit 失败'

    printf -v "${__pk_out}" '%s' "${__pk_tmp}"
    return 0
}

# 装 unit，但只在内容确实要变时装
install_unit_if_changed() {
    local __pk_changed_out=${1} __pk_tmp=${2} __pk_unit=${3}
    local __pk_dst="${UNIT_DIR}/${__pk_unit}"
    printf -v "${__pk_changed_out}" '%s' 0

    if [[ -f ${__pk_dst} ]] && os::query --timeout 10 -- cmp -s "${__pk_tmp}" "${__pk_dst}"; then
        return 0
    fi
    os::systemd_install "${__pk_tmp}" own || os::die 1 "安装 ${__pk_unit} 失败"
    printf -v "${__pk_changed_out}" '%s' 1
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
        || os::die 2 "没有注册过叫 ${name} 的 compose 项目（oneserver podman compose ls 看有哪些）"

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
PK_LIST_READY=0
PK_NAMES=()
PK_DIRS=()
PK_STATUS=()
PK_COUNTS=()
PK_PROVIDERS=()

load_project_rows() {
    local -a ids=()
    mapfile -t ids < <(os::state_list compose)

    PK_NAMES=()
    PK_DIRS=()
    PK_STATUS=()
    PK_COUNTS=()
    PK_PROVIDERS=()
    PK_LIST_READY=1

    local id name dir unit kind containers running_list running total
    for id in ${ids[@]+"${ids[@]}"}; do
        [[ -n ${id} ]] || continue
        name=${id#compose:}
        dir=$(os::state_get "${id}" path)
        kind=$(os::state_get "${id}" provider)
        unit_of unit "${name}"
        probe::service_active "${unit}"
        PK_STATUS+=("${OS_PROBE_VALUE}")

        project_containers containers "${name}"
        count_lines total "${containers}"
        project_containers_running running_list "${name}"
        count_lines running "${running_list}"

        PK_NAMES+=("${name}")
        PK_DIRS+=("${dir}")
        PK_COUNTS+=("${running}/${total}")
        PK_PROVIDERS+=("${kind:-未记录}")
    done
    return 0
}

# 选一个已托管的项目：编号或项目名都收。
#
# **清单没上屏时先列一遍**：从命令行直接跑时总览不会显示（它只在交互的动作
# 清单里跑），让人对着一个看不见的清单输编号不行。
select_project() {
    local __pk_out=${1} __pk_prompt=${2}
    [[ ${PK_LIST_READY} -eq 1 ]] || action_ls
    [[ ${#PK_NAMES[@]} -gt 0 ]] || os::die 2 '没有已托管的项目可选'

    local picked=''
    os::ask --arg name "${__pk_prompt}（输入上方编号；命令行可传 --name）" picked
    if [[ ${picked} =~ ^[0-9]+$ ]]; then
        local -i sel=$((picked - 1))
        ((sel >= 0 && sel < ${#PK_NAMES[@]})) \
            || os::die 2 "没有编号为「${picked}」的项目"
        picked=${PK_NAMES[sel]}
    fi
    validate_name "${picked}"
    printf -v "${__pk_out}" '%s' "${picked}"
    return 0
}

action_ls() {
    require_podman
    detect_provider
    load_project_rows
    os::screen_heading 'Compose 项目'
    if [[ ${#PK_NAMES[@]} -eq 0 ]]; then
        os::info '一个都没有。注册一个：oneserver podman compose add --name=blog --dir=/srv/blog'
        os::output 0 count=0
        return 0
    fi

    local -a cells=()
    local -i i
    for ((i = 0; i < ${#PK_NAMES[@]}; i++)); do
        cells+=("[$((i + 1))]" "${PK_NAMES[i]}" "${PK_STATUS[i]}" "${PK_COUNTS[i]}"
            "${PK_PROVIDERS[i]}" "${PK_DIRS[i]}")
        os::output_item "name=${PK_NAMES[i]}" "path=${PK_DIRS[i]}" \
            "status=${PK_STATUS[i]}" "containers=${PK_COUNTS[i]}" "provider=${PK_PROVIDERS[i]}"
    done
    os::table '编号' '项目' '状态' '容器' 'provider' '目录' -- "${cells[@]}"

    # 每个项目用的是它自己钉住的那个（上面一列一个），这里报告的是
    # **这台机器上现在最好的那个** —— 两者不一致时上面那列会看出来
    local note=''
    if [[ -n ${PROVIDER_PATH} ]]; then
        provider_note note
        os::info "机器上最合适的 provider：${PROVIDER_PATH}（${PROVIDER_VERSION}）—— ${note}"
        os::info '项目用的是注册时钉住的那个，不会自己换（换要先 down 再 up）'
    fi
    os::info '项目目录是你的，本工具不改也不删它。要彻底注销一个项目走 oneserver podman compose rm'
    os::output 0 count="${#PK_NAMES[@]}"
    return 0
}

action_add() {
    require_podman
    require_provider

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
    # 所以要分清是「一切正常，你只是想改配置」还是「上次没跑完」——
    # 两种情况的下一步都是 up，但说法不一样，不说清楚等于让人自己猜
    if os::state_has "${id}"; then
        probe::service_active "${unit}"
        if [[ ${OS_PROBE_VALUE} == active ]]; then
            os::die 2 "已经注册过叫 ${name} 的项目，而且正在跑。改配置就直接编辑 ${file} 然后 oneserver podman compose up --name=${name}"
        fi
        os::die 2 "已经注册过叫 ${name} 的项目，但服务不在跑（${OS_PROBE_VALUE}）—— 上一次执行多半被中断了。把它起来：oneserver podman compose up --name=${name}"
    fi

    # unit 文件在、state 里却没有 —— 两种可能，处理方式完全相反
    #
    # 中断不回滚，因此进程可能在 unit 落地、state 登记前退出并留下孤儿 unit。
    # 判据是模板首行标记：有标记就是本工具可安全收敛的残留；没有标记则可能
    # 属于用户，必须拒绝覆盖。
    if [[ -e "${UNIT_DIR}/${unit}" ]]; then
        if os::query --timeout 5 -- \
            grep -q '^# 由 oneserver podman compose 生成' "${UNIT_DIR}/${unit}"; then
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
            && os::die 2 "目录 ${dir} 已经被项目 ${other#compose:} 注册了 —— 两个 unit 管同一批容器必然打架"
    done < <(os::state_list compose)

    ensure_provider_usable

    # --- 语法校验：用最终真正跑它的那个 provider，不用第二套解析器 ---
    local sha=''
    if ! project_config_sha sha "${file}" "${name}"; then
        os::err "${OS_RUN_OUTPUT}"
        os::die 2 "compose 文件没通过 ${PROVIDER_KIND} 的解析：${file}"
    fi
    os::ok "compose 文件语法通过（${file}）"

    warn_short_image_names "${file}"

    local note=''
    provider_note note
    os::info "provider：${PROVIDER_PATH}（${PROVIDER_VERSION}）—— ${note}"

    # --- unit ---
    os::record_change "注册了 compose 项目 ${name}"
    local tmp=''
    render_unit tmp "${name}" "${dir}" "${file}"

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（unit 没有真的写下去，服务也就起不来）'
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    # 这里不必走 install_unit_if_changed：上面已经确认过目标 unit 不存在
    os::systemd_install "${tmp}" own || os::die 1 "安装 ${unit} 失败"
    os::systemd_enable "${unit}" own
    os::systemd_start "${unit}"

    # **起来了不等于跑着**：oneshot + RemainAfterExit 下，`up -d` 失败会让
    # unit 直接 failed，而镜像拉不动、端口被占、依赖服务起不来都走这条路
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
    # 而这个目录是**用户的**，里面可能有 .env 与绑定挂载的数据 ——
    # 它属于规范「永不自动删除」那一栏，卸载只打印位置
    os::state_set "${id}" path="${dir}" compose_file="${file}" \
        config_sha="${sha}" provider="${PROVIDER_KIND}" \
        provider_path="${PROVIDER_PATH}" method=systemd
    # unit 是 own:：文件是我们写的，卸载连文件一起删
    os::state_unit_add "${id}" "own:${unit}"

    local containers=''
    project_containers containers "${name}"
    count_lines total "${containers}"

    os::ok "compose 项目 ${name} 已托管并启动"
    os::kv '项目目录' "${dir}" \
        'compose 文件' "${file}" \
        '服务' "${unit}" \
        'provider' "${PROVIDER_PATH}" \
        '容器' "${total} 个"
    os::info "改配置：直接编辑 ${file}，然后 oneserver podman compose up --name=${name}"
    os::info "看日志：journalctl -u ${unit}"
    os::output 0 name="${name}" path="${dir}" unit="${unit}" \
        provider="${PROVIDER_KIND}" containers="${total}" changed=yes
    return 0
}

# 把项目应用到目标状态。**幂等的判据是 compose 文件的 sha + 服务在不在跑**（D201）
action_up() {
    require_podman
    require_provider

    local name=''
    select_project name '要启动哪个项目'
    load_project "${name}"

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    # --- provider：钉住的优先，只有项目完全停着时才换（D204）---
    local best_path=${PROVIDER_PATH} best_kind=${PROVIDER_KIND}
    if adopt_recorded_provider "${id}" && [[ ${PROVIDER_PATH} != "${best_path}" ]]; then
        local live=''
        project_containers live "${name}"
        if [[ -z ${live} ]]; then
            os::info "项目当前一个容器都没有，本次换成更合适的 provider：${best_path}"
            PROVIDER_PATH=${best_path}
            PROVIDER_KIND=${best_kind}
            provider_version_of PROVIDER_VERSION "${best_path}"
        else
            os::info "这台机器上有 ${best_kind}（${best_path}），本次不切 —— 两个 compose 实现给容器与网络打的标签互不认，正跑着的项目换 provider 会起不来。要切：先 oneserver podman compose down --name=${name} 再 up"
        fi
    fi
    ensure_provider_usable

    local sha='' recorded=''
    if ! project_config_sha sha "${PRJ_FILE}" "${name}"; then
        os::err "${OS_RUN_OUTPUT}"
        os::die 2 "compose 配置现在解析不了了：${PRJ_FILE}（改坏了？先修好再 up）"
    fi
    recorded=$(os::state_get "${id}" config_sha)
    probe::service_active "${unit}"
    local status=${OS_PROBE_VALUE}

    # unit 本身也可能要变：provider 换了、compose 文件改名了、项目目录挪了
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

    os::state_set "${id}" compose_file="${PRJ_FILE}" config_sha="${sha}" \
        provider="${PROVIDER_KIND}" provider_path="${PROVIDER_PATH}"
    # **这一行不是多余的。** `add` 写 state 分两步（先 state_set 再 state_unit_add），
    # 中断落在两步之间时 unit 就没被登记 —— 而那种情况下的恢复路径正是 up。
    # 不在这里补，结果是 `uninstall compose:<名>` 报「没有登记任何资源」、
    # unit 文件留在 /etc/systemd/system 里没人管，也就是「装的时候不记，
    # 到时候就卸不掉」。登记是幂等的（重复值会被吞掉），无脑调即可
    os::state_unit_add "${id}" "own:${unit}"

    local containers='' total=0
    project_containers containers "${name}"
    count_lines total "${containers}"

    os::ok "项目 ${name} 已应用"
    os::kv 'compose 文件' "${PRJ_FILE}" '服务' "${unit}" '容器' "${total} 个"
    os::output 0 name="${name}" unit="${unit}" containers="${total}" changed=yes
    return 0
}

# 停止并移除项目的容器。**卷一律保留** —— 要删卷走 rm --with-volumes
# 或 oneserver podman volume rm，它们各自有完整的规范流程
action_down() {
    require_podman
    require_provider

    local name=''
    select_project name '要停止哪个项目'
    load_project "${name}"

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    # **必须用当初建它的那个 provider**（D204）：拿 v2 去 down 一个
    # podman-compose 建的项目，它认不出那些标签，容器会留在原地
    adopt_recorded_provider "${id}" || true
    ensure_provider_usable

    os::record_change "停止了 compose 项目 ${name}"
    # **disable 在前**：否则机器重启或别处触发会把项目又拉回来，
    # 而用户刚刚明确说了要它停（旧脚本踩过，这条继承它）
    os::systemd_disable "${unit}" || true
    os::systemd_stop "${unit}" || true
    os::run --allow-fail --env "PODMAN_COMPOSE_PROVIDER=${PROVIDER_PATH}" \
        '移除项目容器' -- podman compose -f "${PRJ_FILE}" -p "${name}" down || true

    local containers='' total=0
    project_containers containers "${name}"
    count_lines total "${containers}"

    os::ok "项目 ${name} 已停止，容器已移除"
    os::kv '服务' "${unit}" '残留容器' "${total} 个"
    os::info '卷没有动 —— compose 项目的数据都在卷里，down 不碰它'
    os::info "拉回来：oneserver podman compose up --name=${name}"
    os::output 0 name="${name}" remaining="${total}" changed=yes
    return 0
}

action_rm() {
    require_podman
    require_provider

    local name='' with_volumes=0
    select_project name '要注销哪个项目'
    os::flag --arg with-volumes && with_volumes=1
    load_project "${name}"

    local id unit
    id_of id "${name}"
    unit_of unit "${name}"

    # 同 down：拆项目要用当初建它的那个 provider（D204）
    adopt_recorded_provider "${id}" || true
    ensure_provider_usable

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

    local -a down=(down)
    [[ ${with_volumes} -eq 1 ]] && down+=(-v)
    os::run --allow-fail --env "PODMAN_COMPOSE_PROVIDER=${PROVIDER_PATH}" \
        '移除项目容器' -- podman compose -f "${PRJ_FILE}" -p "${name}" "${down[@]}" || true

    # own:：停止禁用之后连 unit 文件一起删（D36）
    os::systemd_remove "own:${unit}" || os::warn "移除 ${unit} 失败，检查 ${UNIT_DIR}/${unit}"
    os::state_del "${id}" || os::warn "从 state 里删除 ${id} 失败"

    os::ok "项目 ${name} 已注销"
    os::kv '项目目录' "${PRJ_DIR}（原封不动）" \
        '卷' "$([[ ${with_volumes} -eq 1 ]] && printf '已删除' || printf '保留')"
    os::info "要重新托管：oneserver podman compose add --name=${name} --dir=${PRJ_DIR}"
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
