#!/bin/bash
#
# 创建容器
#
# @command      podman run
# @name         创建容器
# @group        container
# @order        20
# @requires     podman
# @privilege    root
# @requires_lib >= 4.7
# @provides     container:<name>
# @provides_unit ext:<name>.service
# @args         --run-cmd=<整条 run 命令> [--name=<名字>] [--restart-policy=<always|on-failure|no>] [--auto-update=<y|n>] [--create-dirs=<y|n>]
# @description  粘贴 run 命令，翻译成 Quadlet 交给 systemd
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 一个容器 = 一个 Quadlet 文件 + 一个 systemd 服务
# ==================================================================
#
# **本工具建的容器一律走 Quadlet**（`/etc/containers/systemd/<名>.container`），
# 不用裸 `podman run`。三个理由，每一个都决定性：
#
#   1. **裸 `podman run` 起来的容器，重启机器就没了**（除非 `--restart=always`
#      再加一堆 podman 自己的重启逻辑）。Quadlet 生成的是标准 systemd 服务，
#      开机自启、依赖顺序、失败重启全都是 systemd 的既有能力
#   2. **文件就是真相**。容器的配置写在一个可读、可 diff、可备份的文本文件里；
#      而裸 run 出来的容器，配置只存在于当初那条命令行里 —— 那条命令行没人留着
#   3. 它天然落进本项目已有的模型：`.container` 文件是 `file` 资源，
#      生成出来的服务是 `ext:` unit（**文件是 Quadlet 生成的，不是我们放的**，
#      所以卸载时只停止禁用、不删文件，规范）
#
# 容器建好之后的查看、启停、删除见 `oneserver podman`（本脚本只管创建，
# 拆开是因为翻译一条 run 命令要的代码量，跟"看/启停/删已有容器"不是一类事）。
#
# ==================================================================
# 建容器的输入是**一条完整的 run 命令**
# ==================================================================
#
# 用户手上现成的东西是一条完整的 run 命令，不是十个拆开的字段。逐字段问的
# 代价不是麻烦：**拆的过程本身会掉东西** —— `--cap-add`、`--device`、
# `--health-cmd` 这些没有对应输入框的参数会被静默丢掉，而容器照样起得来，
# 只是行为不对。
#
# 于是这里收整条命令，自己翻译成 Quadlet。**不引入 podlet**：它是 GitHub
# Releases 上的 Rust 二进制，引进来就要背一条免校验下载链（D191）。
#
# **但首词必须指向 podman**（D223）。这里只读文本、不执行它，所以从前 `docker run`
# 照样能翻译成 Quadlet —— 代价是两个引擎都装着时，一条本要给 Docker 的命令会
# 无声无息地变成一个 podman 容器，而 `docker ps` 看不见它。首词是用户唯一
# 表达过的意图，读得到就不该丢。装了 podman-docker 时 `docker` 这个词指的就是
# podman，照收（见 check_named_engine）。
#
# 翻译要守住的三条：
#
#   1. **不 `eval`**（全项目禁令）。自己按 shell 词法切词，只认引号与反斜杠，
#      不做变量展开、不做 glob —— 粘进来的 `$HOME` 就是字面的 `$HOME`。
#   2. **认不出的 flag 不猜**。见 FLAG_TABLE 上方那段：猜错 arity 不会报错，
#      它安静地把镜像名当成参数值，然后整条命令全部错位。
#   3. **翻完仍然逐项校验**：端口是不是数字、宿主端口有没有被占、挂载的宿主
#      路径在不在、环境变量里有没有像凭据的东西。收整条命令换掉的是输入形态，
#      不是校验。

readonly QUADLET_DIR='/etc/containers/systemd'
readonly NAME_RE='^[a-z0-9][a-z0-9_-]{0,62}$'
readonly AUTOUPDATE_TIMER='podman-auto-update.timer'

# 报「已在运行」之前观察服务多少秒。取 5：入口脚本失败的容器通常在一两秒内
# 就死第一次，5 秒足够看到它掉出 active；再长就是让每次成功建容器都白等。
readonly SETTLE_SECONDS=5

# ------------------------------------------------------------------

# Quadlet 生成的服务名。`foo.container` → `foo.service`（Quadlet 的固定约定）
unit_of() {
    local __pc_out=${1} __pc_name=${2}
    printf -v "${__pc_out}" '%s' "${__pc_name}.service"
    return 0
}

quadlet_file_of() {
    local __pc_out=${1} __pc_name=${2}
    printf -v "${__pc_out}" '%s' "${QUADLET_DIR}/${__pc_name}.container"
    return 0
}

require_podman() {
    probe::component_version podman
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Podman。先 oneserver install podman'
    os::require_cmd podman systemctl
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "容器名「${name}」不合法：只收小写字母、数字、下划线与短横线，且以字母或数字开头"
    return 0
}

# ------------------------------------------------------------------
# 切词
# ------------------------------------------------------------------

# 把一条命令行切成词，结果写进 PC_TOKENS。引号没闭合时返回 1。
#
# 认三样东西，与 shell 一致：单引号（内部一律字面）、双引号（内部只有
# `\"` `\\` 是转义）、反斜杠（转义下一个字符）。**不做变量展开、不做 glob**：
# 粘进来的 `$HOME` 就是字面的 `$HOME` —— 展开它等于替用户改写他的命令，
# 而他多半是从一份文档里复制的，那里的 `$HOME` 本来就该原样交给容器。
#
# 不用 `xargs` 代劳：它的引号规则与 shell 有出入（反斜杠、单引号内的处理都不同），
# 用它会让「粘进来的命令」与「在终端里敲的同一条命令」有两种含义。
PC_TOKENS=()
tokenize() {
    local s=${1}
    local -i i n=${#s} started=0
    local cur='' ch quote=''
    PC_TOKENS=()
    for ((i = 0; i < n; i++)); do
        ch=${s:i:1}
        if [[ -n ${quote} ]]; then
            if [[ ${ch} == "${quote}" ]]; then
                quote=''
            elif [[ ${quote} == '"' && ${ch} == $'\\' ]]; then
                i+=1
                cur+=${s:i:1}
            else
                cur+=${ch}
            fi
            continue
        fi
        case ${ch} in
            "'" | '"')
                quote=${ch}
                started=1
                ;;
            $'\\')
                i+=1
                cur+=${s:i:1}
                started=1
                ;;
            # 换行与回车也算分隔：`--run-cmd=` 从命令行传进来的值可能带换行，
            # 而从 Windows 终端粘贴的文本会带 `\r` —— 不当空白的话，
            # `\r` 会粘在词尾变成 `nginx:alpine\r`，然后镜像拉不到
            ' ' | $'\t' | $'\n' | $'\r')
                if ((started == 1)); then
                    PC_TOKENS+=("${cur}")
                    cur=''
                    started=0
                fi
                ;;
            *)
                cur+=${ch}
                started=1
                ;;
        esac
    done
    [[ -z ${quote} ]] || return 1
    ((started == 1)) && PC_TOKENS+=("${cur}")
    return 0
}

# ------------------------------------------------------------------
# flag 表
# ------------------------------------------------------------------

# **一行一个 flag，四列写全。** 表驱动不是为了好看：解析一条命令行，
# 必须先知道每个 flag 吃不吃下一个词（arity）。`--name web -p 80:80` 里
# 少认一个「--name 带值」，后面全部错位 —— 而错位**不报错**，
# 它安静地把镜像名当成参数值，容器起不来时人只会去怀疑镜像。
# arity 与目标 key 是同一件事的两面，分两处写迟早对不上。
#
# 列：`flag|arity|动作|参数`
#   key         → `[Container]` 段写 `<参数>=<值>`
#   keytrue     → 同上，值固定 true（`--read-only` 这种不带值的开关）
#   name        → 容器名：它同时是 Quadlet 文件名与服务名，单独拿出来
#   restart     → 重启策略落在 `[Service]` 段，不在 `[Container]`
#   drop        → Quadlet 下无意义，丢掉并列出来（`-d`：systemd 本来就在后台跑它）
#   podmanargs  → podman 认、但没有专用 Quadlet key 的，原样透传给 `PodmanArgs=`
#
# **拿不准某个 key 是不是 4.4 就有，一律走 podmanargs。** `PodmanArgs=` 是
# Quadlet 的官方逃生口，它把参数原样交给 `podman run`，因此对每个 4.4+ 都成立；
# 而猜一个不存在的 key，Quadlet 会拒绝整份文件。少一点「地道」，多一点确定。
readonly FLAG_TABLE='
-p|1|key|PublishPort
--publish|1|key|PublishPort
-v|1|key|Volume
--volume|1|key|Volume
-e|1|key|Environment
--env|1|key|Environment
--env-file|1|key|EnvironmentFile
--name|1|name|
--network|1|key|Network
--net|1|key|Network
-u|1|key|User
--user|1|key|User
-w|1|key|WorkingDir
--workdir|1|key|WorkingDir
-h|1|key|HostName
--hostname|1|key|HostName
-l|1|key|Label
--label|1|key|Label
--annotation|1|key|Annotation
--cap-add|1|key|AddCapability
--cap-drop|1|key|DropCapability
--device|1|key|AddDevice
--tmpfs|1|key|Tmpfs
--read-only|0|keytrue|ReadOnly
--init|0|keytrue|RunInit
--tz|1|key|Timezone
--timezone|1|key|Timezone
--secret|1|key|Secret
--restart|1|restart|
-d|0|drop|
--detach|0|drop|
-i|0|drop|
--interactive|0|drop|
-t|0|drop|
--tty|0|drop|
--rm|0|drop|
--mount|1|podmanargs|
--entrypoint|1|podmanargs|
--privileged|0|podmanargs|
--pull|1|podmanargs|
--platform|1|podmanargs|
--runtime|1|podmanargs|
--gpus|1|podmanargs|
--group-add|1|podmanargs|
--userns|1|podmanargs|
--pod|1|podmanargs|
--ip|1|podmanargs|
--dns|1|podmanargs|
--add-host|1|podmanargs|
--security-opt|1|podmanargs|
--sysctl|1|podmanargs|
--ulimit|1|podmanargs|
--shm-size|1|podmanargs|
--cgroupns|1|podmanargs|
--pids-limit|1|podmanargs|
-m|1|podmanargs|
--memory|1|podmanargs|
--memory-swap|1|podmanargs|
--cpus|1|podmanargs|
--cpu-shares|1|podmanargs|
--log-driver|1|podmanargs|
--log-opt|1|podmanargs|
--stop-signal|1|podmanargs|
--stop-timeout|1|podmanargs|
--health-cmd|1|podmanargs|
--health-interval|1|podmanargs|
--health-retries|1|podmanargs|
--health-timeout|1|podmanargs|
--health-start-period|1|podmanargs|
--no-healthcheck|0|podmanargs|
'

FLAG_ARITY=''
FLAG_ACTION=''
FLAG_PARAM=''

# 表里有这个 flag 就填好三个全局量并返回 0，没有返回 1
flag_lookup() {
    local want=${1} line skip
    local IFS=$'\n'
    for line in ${FLAG_TABLE}; do
        [[ ${line} == "${want}|"* ]] || continue
        IFS='|' read -r skip FLAG_ARITY FLAG_ACTION FLAG_PARAM <<<"${line}"
        [[ -n ${skip} ]] || return 1
        return 0
    done
    return 1
}

# ------------------------------------------------------------------
# 解析
# ------------------------------------------------------------------

PC_NAME=''
PC_IMAGE=''
PC_RESTART=''
PC_KEYS=()
PC_PODMAN_ARGS=()
PC_EXEC=()
PC_DROPPED=()

# 把一个已识别的 flag 落进对应的桶
apply_flag() {
    local raw=${1} val=${2}
    case ${FLAG_ACTION} in
        key) PC_KEYS+=("${FLAG_PARAM}=${val}") ;;
        keytrue) PC_KEYS+=("${FLAG_PARAM}=true") ;;
        name) PC_NAME=${val} ;;
        restart) PC_RESTART=${val} ;;
        drop) PC_DROPPED+=("${raw}") ;;
        podmanargs)
            PC_PODMAN_ARGS+=("${raw}")
            [[ ${FLAG_ARITY} == 1 ]] && PC_PODMAN_ARGS+=("${val}")
            ;;
        *) os::die 1 "flag 表里「${raw}」的动作「${FLAG_ACTION}」没有实现" ;;
    esac
    return 0
}

# **认不出的 flag 一律不猜 arity。** 猜错的后果不是报错：`--foo bar nginx` 里
# 把 `--foo` 当成不带值的开关，`bar` 就成了镜像名，而真正的镜像名成了容器命令，
# 于是错误停在「拉不到镜像 bar」上，离真正的原因隔着三层。
#
# 只有两种情形能安全放行：写成 `--foo=bar`（自定界，值就在里面），
# 或者后面根本没有可被吞掉的词（下一个也是 flag，或者已经到头）。
# 其余情形停下来，并告诉用户改写成 `=` 形态 —— 那是他一秒钟就能做到的事。
unknown_flag() {
    local raw=${1} next=${2-} has_next=${3}
    if [[ ${has_next} == yes && ${next} != -* ]]; then
        os::die 2 "认不出参数「${raw}」，而它后面跟着「${next}」—— 分不清那是它的值还是镜像名。改写成 ${raw}=${next} 再来，本工具会原样交给 podman"
    fi
    PC_PODMAN_ARGS+=("${raw}")
    return 0
}

# 首词指名了别的引擎时，是拒还是照收。
#
# **装了 podman-docker 时 `docker` 不是别的引擎**：那个包提供的
# `/usr/bin/docker` 就是 `exec podman "$@"`，此时 `docker run …` 在这台机器上
# 本来就是一条 podman 命令，用户没有指错引擎，拒掉它等于要求他改写一条照样
# 跑得通的命令。判据用 probe::container_engine（问「docker 这个命令名由谁
# 提供」），不是 probe::component_version docker（问的是真 Docker 在不在
# —— 「podman 接管着」和「什么都没有」在它那里都是空，而这两种情形要给的
# 下一步完全相反）。
#
# **拒绝必须给出下一步**：只说「不接受」的话，用户手上那条命令还是没地方用，
# 而他多半会回头把首词删掉再粘一次 —— 那就绕过了这道拦截，还什么都没提示。
# 另一个引擎装着就指路过去，没装就明说改哪个词。
check_named_engine() {
    local named=${1}
    if [[ ${named} == docker ]]; then
        probe::container_engine
        [[ ${OS_PROBE_VALUE} == podman ]] && return 0
        if [[ -n ${OS_PROBE_VALUE} ]]; then
            os::die 2 '这是一条 docker 命令，而你正在用 Podman 建容器 —— 照粘会建成 podman 容器，而 docker ps 看不见它。要建 Docker 容器请走「Docker 容器 › 创建容器」（oneserver docker run）；确实要建 podman 容器就把开头的 docker 改成 podman'
        fi
    fi
    os::die 2 "这是一条 ${named} 命令，而本机没有 ${named}。要用 Podman 建这个容器，把开头的 ${named} 改成 podman 再粘一次，其余参数原样保留"
}

# 解析整条 run 命令，结果落在 PC_* 里
parse_run_cmd() {
    PC_NAME=''
    PC_IMAGE=''
    PC_RESTART=''
    PC_KEYS=()
    PC_PODMAN_ARGS=()
    PC_EXEC=()
    PC_DROPPED=()

    local -i n=${#PC_TOKENS[@]} i=0 j clen
    local tok fname fval chars c rest

    # 前缀：`sudo podman run …`、光秃秃的 `run …` 都收。
    # **必须找到 run/create**：找不到就说明粘错了东西（多半是 `podman ps`
    # 或半条命令），此时继续解析只会得出一个像模像样却完全不对的容器。
    #
    # **首词指名的引擎必须是 podman**，别的交给 check_named_engine 判。
    # 首词是用户唯一表达过的「这条命令给谁」，吃掉它等于把这个意图丢了。
    local named=''
    while ((i < n)); do
        case ${PC_TOKENS[i]} in
            sudo) i+=1 ;;
            podman | docker | nerdctl)
                named=${PC_TOKENS[i]}
                i+=1
                ;;
            run | create)
                i+=1
                break
                ;;
            *) break ;;
        esac
    done
    if ((i == 0)) || [[ ${PC_TOKENS[i - 1]} != run && ${PC_TOKENS[i - 1]} != create ]]; then
        os::die 2 '这不像一条 run 命令。要粘的是完整的 podman run … ，不是 podman ps 这类查询命令，也不是半条'
    fi
    [[ -z ${named} || ${named} == podman ]] || check_named_engine "${named}"

    while ((i < n)); do
        tok=${PC_TOKENS[i]}

        # 镜像名之后的一切都是容器里要跑的命令，不再当参数解析 ——
        # `nginx -g 'daemon off;'` 里的 `-g` 是 nginx 的参数，不是 podman 的
        if [[ -n ${PC_IMAGE} ]]; then
            PC_EXEC+=("${tok}")
            i+=1
            continue
        fi

        case ${tok} in
            --*=*)
                fname=${tok%%=*}
                fval=${tok#*=}
                if flag_lookup "${fname}"; then
                    [[ ${FLAG_ARITY} == 1 ]] \
                        || os::die 2 "「${fname}」是不带值的开关，却给了 =${fval}"
                    apply_flag "${fname}" "${fval}"
                else
                    # `=` 形态自定界，透传是安全的
                    PC_PODMAN_ARGS+=("${tok}")
                fi
                i+=1
                ;;
            --*)
                if flag_lookup "${tok}"; then
                    if [[ ${FLAG_ARITY} == 1 ]]; then
                        ((i + 1 < n)) || os::die 2 "「${tok}」要带一个值，但它是命令的最后一个词"
                        apply_flag "${tok}" "${PC_TOKENS[i + 1]}"
                        i+=2
                    else
                        apply_flag "${tok}" ''
                        i+=1
                    fi
                else
                    if ((i + 1 < n)); then
                        unknown_flag "${tok}" "${PC_TOKENS[i + 1]}" yes
                    else
                        unknown_flag "${tok}" '' no
                    fi
                    i+=1
                fi
                ;;
            -?*)
                # 短参数簇：`-itd` 是三个开关，`-p8080:80` 是带值的 `-p`，
                # `-dp 80:80` 两者都有。规则与 getopt 一致：逐字符走，
                # 遇到带值的那个就把**这个词剩下的部分**当成值，没有剩下的才吃下一个词
                chars=${tok#-}
                clen=${#chars}
                for ((j = 0; j < clen; j++)); do
                    c=${chars:j:1}
                    if ! flag_lookup "-${c}"; then
                        [[ ${tok} == "-${c}" ]] \
                            && os::die 2 "认不出短参数「-${c}」。写成长参数的 --xxx=值 形态，本工具会原样交给 podman"
                        os::die 2 "认不出短参数「-${c}」（在「${tok}」里）。写成长参数的 --xxx=值 形态，本工具会原样交给 podman"
                    fi
                    if [[ ${FLAG_ARITY} == 1 ]]; then
                        rest=${chars:j+1}
                        if [[ -n ${rest} ]]; then
                            apply_flag "-${c}" "${rest}"
                        else
                            ((i + 1 < n)) || os::die 2 "「-${c}」要带一个值，但它是命令的最后一个词"
                            i+=1
                            apply_flag "-${c}" "${PC_TOKENS[i]}"
                        fi
                        break
                    fi
                    apply_flag "-${c}" ''
                done
                i+=1
                ;;
            *)
                PC_IMAGE=${tok}
                i+=1
                ;;
        esac
    done

    [[ -n ${PC_IMAGE} ]] || os::die 2 '这条命令里没有镜像名'
    return 0
}

# 镜像补全成全名。规则取自 distribution 的官方解析：第一段含 `.`（域名）
# 或 `:`（端口）或等于 `localhost` 才算仓库主机名，否则它是 docker.io 上的用户名。
#
# **为什么要补**：`nginx` 到底从哪个仓库拉，取决于 registries.conf 的
# `unqualified-search-registries` —— 同一条命令在两台机器上可能拉到不同的东西，
# 这是供应链问题。补成全名之后这条命令在哪台机器上都拉同一个东西。
#
# 补 `docker.io/` **不会绕开镜像加速**：registries.conf 里的 mirror 是挂在
# `location="docker.io"` 上的，全名照样命中。
#
# 局部变量一律带 `__pc_` 前缀：`printf -v` 写的是调用方给的变量名，
# 而调用方多半就叫 `image`／`img`。撞名时 `local` 把它遮住，函数写回的是自己的
# 局部量，调用方拿到空串 —— 而空串会一路走到「这条命令里没有镜像名」，
# 错误信息指向的地方与真正的原因毫无关系。
normalize_image() {
    local __pc_out=${1} __pc_img=${2} __pc_first
    case ${__pc_img} in
        */*)
            __pc_first=${__pc_img%%/*}
            case ${__pc_first} in
                *.* | *:* | localhost) ;;
                *) __pc_img="docker.io/${__pc_img}" ;;
            esac
            ;;
        *) __pc_img="docker.io/library/${__pc_img}" ;;
    esac
    printf -v "${__pc_out}" '%s' "${__pc_img}"
    return 0
}

# ------------------------------------------------------------------
# 原始命令存档
# ------------------------------------------------------------------

# Quadlet 文件是这个容器的权威配置，但它是**翻译结果** —— 想改一个参数再重建，
# 手上有当初那条 run 命令要方便得多（改一个词重新粘，而不是学一遍 Quadlet 的
# key 名）。所以把它掩码后写进文件头的注释里，跟着配置走。
#
# **为什么掩码**：同一份文件里 `Environment=` 那几行确实是明文（Quadlet 就是
# 这么工作的，建容器时已经警告过），所以掩码在这个文件内部不多挡什么。它挡的是
# 另一件事 —— 这行注释是整份文件里最可能被整条复制出去的一行（贴进工单、
# 聊天窗口、笔记），掩码之后随手一复制不会把密码带走。代价是它不能原样重跑，
# 重跑前要把值补回来，所以注释里把这句写明。

# 环境变量名看着像不像凭据。先转小写再比，否则 `Password`、`apiKey` 这类
# 大小写混写的名字两边模式都不命中，而它们恰恰是最常见的写法
cred_key() {
    local k=${1,,}
    case ${k} in
        *pass* | *token* | *secret* | *key*) return 0 ;;
    esac
    return 1
}

# 三种写法都要认：`-e KEY=V`（值在下一个词）、`--env=KEY=V`、`-eKEY=V`。
# 掩码后**保持原来的形态**，存下来的命令才跟用户粘进来的那条对得上
PC_SAFE=()
mask_tokens() {
    local -i k
    local t prefix kv key
    PC_SAFE=()
    for ((k = 0; k < ${#PC_TOKENS[@]}; k++)); do
        t=${PC_TOKENS[k]}
        prefix=''
        case ${t} in
            -e | --env)
                PC_SAFE+=("${t}")
                k=$((k + 1))
                [[ ${k} -lt ${#PC_TOKENS[@]} ]] || break
                kv=${PC_TOKENS[k]}
                ;;
            --env=*)
                prefix='--env='
                kv=${t#--env=}
                ;;
            -e?*)
                prefix='-e'
                kv=${t#-e}
                ;;
            *)
                PC_SAFE+=("${t}")
                continue
                ;;
        esac
        key=${kv%%=*}
        if [[ ${kv} == *=* ]] && cred_key "${key}"; then
            PC_SAFE+=("${prefix}${key}=***")
        else
            PC_SAFE+=("${prefix}${kv}")
        fi
    done
    return 0
}

# systemd 的值是空白分隔的，含空白的词要带引号才不会被拆开
quote_words() {
    local __pc_out=${1}
    shift
    local __pc_one __pc_acc=''
    for __pc_one in "$@"; do
        case ${__pc_one} in
            *[[:space:]]*) __pc_acc+="${__pc_acc:+ }\"${__pc_one//\"/\\\"}\"" ;;
            *) __pc_acc+="${__pc_acc:+ }${__pc_one}" ;;
        esac
    done
    printf -v "${__pc_out}" '%s' "${__pc_acc}"
    return 0
}

# PC_KEYS 里某个 key 的全部值，一行一条
keys_of() {
    local want=${1} one
    local -i k
    for ((k = 0; k < ${#PC_KEYS[@]}; k++)); do
        one=${PC_KEYS[k]}
        [[ ${one} == "${want}="* ]] && printf '%s\n' "${one#*=}"
    done
    return 0
}

# 一条 run 命令不能为空、不能是断行的半条
validate_run_cmd() {
    local v=${1}
    [[ -n ${v} ]] || return 1
    # 续行由 `os::ask --multiline` 接完，走到这里还挂着反斜杠只有一种可能：
    # 粘到一半断了。半条命令照样能解析出一个「像那么回事」的容器，所以要拒绝
    [[ ${v} != *\\ ]] || return 1
    return 0
}

# ------------------------------------------------------------------

# 建容器：粘命令 → 翻译 → 校验 → 生成 Quadlet → daemon-reload → 起服务 → 确认真的在跑
main() {
    require_podman

    local cmdline='' name='' policy='' autoupdate=0
    os::ask --arg run-cmd --multiline --validate validate_run_cmd \
        '粘贴完整的 run 命令（带 \ 换行的多行命令直接整段粘）' cmdline ''

    tokenize "${cmdline}" || os::die 2 '命令里的引号没有闭合'
    parse_run_cmd

    # 名字：命令里给了就用它，没给才问。它同时是 Quadlet 文件名与服务名，
    # 所以比 podman 自己的规则严（podman 允许大写与点，systemd unit 名不合适）
    name=${PC_NAME}
    [[ -n ${name} ]] || os::ask --arg name '这条命令没写 --name，容器叫什么（同时是服务名）' name ''
    [[ -n ${name} ]] || os::die 2 '要给出容器名字：--name=web'
    validate_name "${name}"

    # 重启策略：`--restart` 给了就照办。没给的话**必须问** —— Quadlet 的默认是
    # 不重启，而一个 crash 了就再也不起来的服务，systemd 只会安静地记成 inactive
    if [[ -n ${PC_RESTART} ]]; then
        case ${PC_RESTART} in
            always) policy=always ;;
            unless-stopped)
                # systemd 没有「除非人手动停过」这个概念：它只知道要不要拉起来。
                # 按 always 落，因为那是这两者里更接近用户意图的一个
                policy=always
                os::info '--restart=unless-stopped 按 always 落 —— systemd 没有「除非手动停过」这个状态'
                ;;
            on-failure | on-failure:*)
                policy=on-failure
                [[ ${PC_RESTART} == *:* ]] \
                    && os::info "--restart 里的重试次数 ${PC_RESTART#*:} 不生效：systemd 用 StartLimitBurst 表达它，与 docker 的计数方式不是一回事"
                ;;
            no | '') policy=no ;;
            *) os::die 2 "认不出重启策略「${PC_RESTART}」" ;;
        esac
    else
        os::select --arg restart-policy '这条命令没写 --restart，失败后怎么办' policy \
            'always=总是重启' 'on-failure=仅异常退出时重启' 'no=不自动重启'
    fi
    # **默认 y**：容器不跟着上游镜像走，跑的就是一个再也不打补丁的东西。
    # 选了 y 之后还要有定时器在跑标签才算数，所以下面会顺手把它开起来 ——
    # 只打标签不开定时器正是「切了自动更新却什么都没发生」的来源
    os::confirm --arg auto-update '开启自动更新（镜像有新版本时自动拉取并重启这个容器）' y \
        && autoupdate=1

    local qfile unit
    quadlet_file_of qfile "${name}"
    unit_of unit "${name}"

    if [[ -f ${qfile} ]]; then
        os::die 2 "已经有一个叫 ${name} 的容器（${qfile}）。改配置就先删了重建：oneserver podman rm --name=${name}"
    fi

    # --- 镜像 ---
    local image=''
    normalize_image image "${PC_IMAGE}"
    [[ ${image} == "${PC_IMAGE}" ]] || os::info "镜像补全成 ${image}（原文 ${PC_IMAGE}）"

    # **没写 tag 等于 :latest，而 latest 是会动的**。容器由 systemd 托管，
    # 下一次重启就可能换成另一个版本的镜像，而现场看不出发生过版本变化。
    # 开了自动更新更是每天一次。这里只提醒不拒绝：拉一个 latest 是合法选择
    local tail_part=${image##*/}
    case ${image} in
        *@sha256:*) ;;
        *) case ${tail_part} in
            *:latest) os::warn "镜像用的是 :latest —— 重启即可能换版本，生产环境建议写死版本号或 @sha256:" ;;
            *:*) ;;
            *) os::warn "镜像没写 tag，等同 :latest —— 重启即可能换版本，生产环境建议写死版本号" ;;
        esac ;;
    esac

    # --- 端口 ---
    #
    # `-p` 有三种写法：`容器端口`、`宿主:容器`、`宿主IP:宿主:容器`。
    # 宿主端口在哪一段取决于有几个冒号，数错就会拿着容器端口去查占用。
    #
    # **没写宿主 IP 时绑哪里，由这台机器的网络定位决定**（oneserver network）：
    #   公网 → 补 127.0.0.1，只本机可达，对外走 Caddy 反代
    #   内网 → 保持 docker 原义的 0.0.0.0，建完就能从局域网访问
    # 定位在那条命令里同时把 ufw 的转发策略配套设好，所以**建容器这一步
    # 不需要再动任何防火墙** —— 两处各设一半正是「端口发布了却连不上」的成因。
    #
    # 没设过定位时按公网处理：`docker run -p 8080:80` 默认绑 0.0.0.0，粘一条
    # 网上抄来的命令就把服务暴露在公网端口上，而用户根本不知道自己做了这个决定。
    # 显式写了 IP 的（三段式）两种定位下都原样不动 —— 那是当场做的决定。
    local netmode
    netmode=$(os::state_get network mode '')
    if [[ -z ${netmode} ]]; then
        netmode='公网'
        os::info '这台机器还没设过网络定位，端口按公网处理（oneserver network 里设一次）'
    fi

    local p host_port
    local -i k
    for ((k = 0; k < ${#PC_KEYS[@]}; k++)); do
        [[ ${PC_KEYS[k]} == PublishPort=* ]] || continue
        p=${PC_KEYS[k]#*=}
        [[ -n ${p} ]] || continue

        host_port=''
        case ${p} in
            *:*:*) host_port=${p#*:} && host_port=${host_port%%:*} ;;
            *:*)
                host_port=${p%%:*}
                if [[ ${netmode} == 公网 ]]; then
                    p="127.0.0.1:${p}"
                    PC_KEYS[k]="PublishPort=${p}"
                    os::info "端口 ${host_port} 绑到 127.0.0.1（公网定位；要对外请写 -p 0.0.0.0:${host_port}:…）"
                fi
                ;;
            *) os::info "端口「${p}」只给了容器端口，宿主端口由 podman 随机分配" ;;
        esac
        [[ -n ${host_port} ]] || continue
        [[ ${host_port} =~ ^[0-9]+$ ]] || os::die 2 "端口映射「${p}」的宿主端口不是数字"
        probe::port_listening "${host_port}"
        [[ ${OS_PROBE_VALUE} == yes ]] \
            && os::die 2 "宿主端口 ${host_port} 上已经有别的东西在听，换一个"
    done

    # --- 挂载 ---
    #
    # 宿主目录不存在时会发生什么，取决于挂载写法与 podman 版本：要么容器起不来
    # （Quadlet 下表现为 start 返回 0 而服务立刻 inactive，那句
    # `statfs … no such file or directory` 要翻 journal 才看得到），要么 podman
    # 替你建一个 root:root 的空目录。**两种都不是用户要的**，所以这里自己先建。
    #
    # 但**先列出来再建**：路径打错一个字符也是「不存在」，那时建出来的是个空目录，
    # 容器照样起来、数据写进了错的地方，等发现时已经跑了几天。
    # 清单摆在眼前，打错一眼看得出。
    local -a missing=()
    local v host_path
    while IFS= read -r v; do
        [[ -n ${v} ]] || continue
        [[ ${v} == *:* ]] || os::die 2 "挂载「${v}」要写成 宿主路径:容器路径[:ro]"
        host_path=${v%%:*}
        case ${host_path} in
            /*)
                [[ -e ${host_path} ]] || missing+=("${host_path}")
                ;;
            *) os::info "挂载「${v}」的来源不是绝对路径，按命名卷处理" ;;
        esac
    done < <(keys_of Volume)

    if ((${#missing[@]} > 0)); then
        os::section '这些宿主目录还不存在'
        local m
        for m in "${missing[@]}"; do
            os::kv '将创建' "${m}"
        done
        # 用户在确认点选否 → 130，且规范要求此时**一定未变更**：
        # 这一步在任何副作用之前，退出码才对得上
        if ! os::confirm --arg create-dirs '建出来（不建的话容器多半起不来）' y; then
            os::info '已取消，什么都没有动'
            os::output 130 name="${name}" changed=no
            return 130
        fi
        for m in "${missing[@]}"; do
            os::record_change "创建了宿主目录 ${m}"
            os::run '创建挂载用的宿主目录' -- mkdir -p -- "${m}"
            # 回滚用 `rmdir` 而不是 `rm -rf`：撤销发生在中途失败时，那时容器
            # 可能已经往里写过东西了，而 `rm -rf` 会连数据一起销毁 ——
            # 回滚动作自己造成的破坏是最难被察觉的一类。空目录才删得掉，正合适
            os::defer rmdir -- "${m}"
        done
        os::info '新目录是 root:root 0755。容器里跑的若是非 root 用户（postgres、nginx-unprivileged 这类），可能还要自己调属主'
    fi

    # --- 环境变量 ---
    local e
    while IFS= read -r e; do
        [[ -n ${e} ]] || continue
        [[ ${e} == *=* ]] || os::die 2 "环境变量「${e}」要写成 KEY=VALUE"
        case ${e%%=*} in
            *PASS* | *TOKEN* | *SECRET* | *KEY* | *pass* | *token* | *secret*)
                # Quadlet 文件即使是 0640，值也会原样躺在磁盘上、并进 systemd 的
                # 环境。真正的密码该走 `podman secret`，这里只能提醒
                os::warn "「${e%%=*}」看着像凭据 —— Quadlet 文件里的值是明文，敏感值建议改用 podman secret"
                ;;
        esac
    done < <(keys_of Environment)

    # --- 翻译结果先给人看 ---
    #
    # 丢掉的与透传的都要说出来。**静默丢弃是这类翻译工具最容易犯的错**：
    # 用户以为 `--rm` 生效了，实际上它在 Quadlet 下无从表达
    if ((${#PC_DROPPED[@]} > 0)); then
        local IFS=' '
        os::info "这些参数在 Quadlet 下没有意义，已丢弃：${PC_DROPPED[*]}（容器由 systemd 托管，本来就在后台跑）"
        IFS=$'\n\t'
    fi
    if ((${#PC_PODMAN_ARGS[@]} > 0)); then
        local IFS=' '
        os::info "这些参数没有专用的 Quadlet key，原样透传给 podman：${PC_PODMAN_ARGS[*]}"
        IFS=$'\n\t'
    fi

    # --- 生成 Quadlet 文件 ---
    #
    # 走临时文件 + os::install_file 换 inode，**0640**：
    # Quadlet 文件里可能有环境变量，默认的 0644 等于摊给机器上每个用户
    local dir tmp exec_line='' args_line='' safe_cmd=''
    ((${#PC_EXEC[@]} > 0)) && quote_words exec_line ${PC_EXEC[@]+"${PC_EXEC[@]}"}
    ((${#PC_PODMAN_ARGS[@]} > 0)) && quote_words args_line ${PC_PODMAN_ARGS[@]+"${PC_PODMAN_ARGS[@]}"}
    mask_tokens
    quote_words safe_cmd ${PC_SAFE[@]+"${PC_SAFE[@]}"}
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    tmp="${dir}/${name}.container"
    {
        printf '# 由 oneserver podman run 生成。改完执行 systemctl daemon-reload。\n'
        printf '# 原始命令（凭据值已掩码，重跑前补回）：%s\n' "${safe_cmd}"
        printf '[Unit]\n'
        printf 'Description=%s（oneserver 托管）\n' "${name}"
        printf '\n[Container]\n'
        printf 'ContainerName=%s\n' "${name}"
        printf 'Image=%s\n' "${image}"
        local one
        for one in ${PC_KEYS[@]+"${PC_KEYS[@]}"}; do
            printf '%s\n' "${one}"
        done
        [[ -n ${exec_line} ]] && printf 'Exec=%s\n' "${exec_line}"
        [[ -n ${args_line} ]] && printf 'PodmanArgs=%s\n' "${args_line}"
        # 自动更新是**标签驱动**的：podman-auto-update.timer 只动带这个标签的容器
        [[ ${autoupdate} -eq 1 ]] && printf 'AutoUpdate=registry\n'
        printf '\n[Service]\n'
        printf 'Restart=%s\n' "${policy}"
        printf '\n[Install]\n'
        printf 'WantedBy=multi-user.target default.target\n'
    } >"${tmp}"

    os::record_change "创建了 Quadlet 容器 ${name}"
    os::install_file --mode 0640 "${tmp}" "${qfile}" || os::die 1 "写入 ${qfile} 失败"
    # 失败要能回到「没有这个容器」的状态（规范第一类：本次创建，撤销安全）
    os::defer rm -f -- "${qfile}"

    os::systemd_daemon_reload

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（Quadlet 文件没有真的写下去，服务也就生成不出来）'
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    # Quadlet 是**生成器**：daemon-reload 之后 <名>.service 才存在
    probe::unit_exists "${unit}"
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::err "systemd 没有生成 ${unit} —— Quadlet 文件多半有语法问题"
        os::query --timeout 10 -- \
            /usr/lib/systemd/system-generators/podman-system-generator --dryrun
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 'Quadlet 文件没能生成服务，已撤销'
    fi

    # **不能 `systemctl enable`**：Quadlet 生成的 unit 没有真实文件，
    # enable 会以「Unit file does not exist」失败 —— 开机自启由 `.container`
    # 里的 `[Install] WantedBy=` 在生成时处理，这里只管把它起来
    os::systemd_start "${unit}"

    # **起来了不等于跑着，跑着也不等于站住了。**
    #
    # 镜像拉不动、端口被占、入口命令直接退出，三种都表现为「systemctl start
    # 返回 0，容器却不在」——查一次就够。但还有一类更难缠：入口脚本先起来、
    # 几秒后才失败（连不上数据库、配置项写错，最常见的两类）。那一刻服务确实
    # 是 active，报完「已在运行」用户就走了；随后 Restart= 把它反复拉起，直到
    # systemd 判 start-limit-hit，而 Quadlet 到那时已经把容器对象删掉，
    # 用户手上只剩一个 failed 的服务。
    #
    # 所以下结论前给一个稳定期，等完再判。**判据是重启次数，不是采样状态**：
    # Restart= 的默认 RestartSec 是 100 毫秒，容器退出到重新起来的非 active 窗口
    # 只有一两百毫秒，秒级采样几乎必然错过（实测：一个「起来 3 秒后退出」的容器
    # 连采五次全是 active）。NRestarts 是 systemd 累加的计数，错不过去。
    # 代价是成功路径上多等几秒；这是建容器，不是热路径。
    local -i s=0
    while ((s < SETTLE_SECONDS)); do
        os::query --timeout 3 -- sleep 1 || true
        s+=1
    done

    probe::service_active "${unit}"
    local state=${OS_PROBE_VALUE}
    probe::unit_restarts "${unit}"
    local restarts=${OS_PROBE_VALUE:-0}

    if [[ ${state} != active || ${restarts} != 0 ]]; then
        if [[ ${state} != active ]]; then
            os::err "${unit} 没有稳定运行（当前 ${state}）"
        else
            os::err "${unit} 起来之后已经重启过 ${restarts} 次 —— 容器在反复退出"
        fi
        os::query --timeout 20 -- journalctl -u "${unit}" --no-pager -n 30
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 "容器 ${name} 没能跑起来，已撤销"
    fi

    # --- 自动更新的执行者 ---
    #
    # 标签只是「这个容器愿意被更新」，真正去拉镜像重启容器的是那个定时器。
    # 用户在上面选了 y，就把执行者也备齐 —— 只打标签不开定时器，等于让他
    # 以为开好了而实际什么都不会发生。定时器是全机一份、`ext:` 的
    if [[ ${autoupdate} -eq 1 ]]; then
        probe::unit_exists "${AUTOUPDATE_TIMER}"
        if [[ ${OS_PROBE_VALUE} != yes ]]; then
            os::warn "这个 podman 版本没有 ${AUTOUPDATE_TIMER}，标签打上了但没有东西会去执行更新"
        else
            probe::service_active "${AUTOUPDATE_TIMER}"
            if [[ ${OS_PROBE_VALUE} == active ]]; then
                os::info '自动更新服务已经在跑，这个容器下一轮就会被检查'
            else
                os::systemd_enable --now "${AUTOUPDATE_TIMER}" ext
                os::ok '顺带开启了自动更新服务（全机一份，只动打了标记的容器）'
            fi
        fi
    fi

    # --- state：容器是一个组件实例 ---
    os::state_set "container:${name}" image="${image}" method=quadlet
    # `.container` 文件是本工具创建的 → file 资源，卸载时删
    os::state_resource_add "container:${name}" file "${qfile}"
    # 服务是 **Quadlet 生成的**，文件不在我们手里 → ext:，只停止禁用
    os::state_unit_add "container:${name}" "ext:${unit}"

    os::ok "容器 ${name} 已在运行"
    os::kv '镜像' "${image}" \
        '服务' "${unit}" \
        '配置' "${qfile}" \
        '重启策略' "${policy}" \
        '自动更新' "$([[ ${autoupdate} -eq 1 ]] && printf '开' || printf '关')"
    os::info "看日志与管理：oneserver podman logs --name=${name}"
    os::output 0 name="${name}" image="${image}" unit="${unit}" changed=yes
    return 0
}

main "$@"
