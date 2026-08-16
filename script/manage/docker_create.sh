#!/bin/bash
#
# 创建容器
#
# @command      docker run
# @name         创建容器
# @group        container
# @order        70
# @requires     docker
# @privilege    root
# @requires_lib >= 1.20
# @args         --run-cmd=<整条 run 命令> [--name=<名字>] [--restart-policy=<always|unless-stopped|on-failure|no>] [--auto-update=<y|n>]
# @description  粘贴 docker run 命令，补齐参数后直接建容器
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 一个容器 = dockerd 管的一条记录，没有第二份配置
# ==================================================================
#
# **与 `oneserver podman run` 是两套东西，不要照着它读。** podman 那边把
# `docker run` 翻译成 Quadlet 文件再交给 systemd，是因为裸 podman 容器
# 重启机器就没了、也没人盯着它。Docker 这些全由 dockerd 自己做：
# `--restart` 是引擎的能力，docker.service 开机自启，容器跟着回来。
#
# 于是这里**不翻译**，只补齐三样非有不可的东西，其余原样交给 docker：
#
#   `-d`        没有它命令会一直挂在前台，而这是个管理工具不是终端
#   `--name`    没有名字 docker 会随机取一个，此后 start/stop/logs 全找不着它
#   `--restart` docker 的默认是「不重启」—— 崩一次就再也不起来，且没有任何提示
#
# **认不出的 flag 一律透传**，这是与 podman 那边最大的区别，也是安全的：
# 那边认错一个 flag 会把它翻进错误的 Quadlet 段，容器行为跟着变；这边最坏
# 也只是 docker 自己报一句参数错误，语义不会被我们改写。
#
# **端口绑哪个地址不在这里管。** 它由 `/etc/docker/daemon.json` 的 `"ip"`
# 决定，`oneserver install docker` 与 `oneserver network` 设好 ——
# 一处设定，此后每一条 `docker run` 都算数，包括用户自己在终端里敲的、
# 以及 docker compose 起的。逐条命令去改写端口反而只能管住走这个入口的那些。
#
# **自动更新是名单驱动的**：名字进本工具在 state 里存的那份名单，更新器启动时
# 拿着名单只盯这几个容器。这里问一句是因为**这是最省事的时机**，不是唯一时机 ——
# 建完之后随时可以在 `oneserver docker` 里切换，容器不用重建（那正是名单模式
# 相对标签模式换来的东西，见 docker_container.sh 文件头）。
#
# **这里不部署更新器**：名单里多一个名字与「机器上要不要跑一个定时更新器」
# 是两个决定，建一个容器不该顺带做后一个。更新器没跑就提醒一句，由用户去
# 「开启自动更新服务」。
#
# ==================================================================
# 原始命令要留一份，凭据不能留
# ==================================================================
#
# docker 容器没有 Quadlet 那样可读可 diff 的配置文件，事后想改参数只能凭
# `docker inspect` 反推，而它推不全（自定义网络、复杂 mount）。所以把用户
# 粘进来的这条命令**打成容器自己的一个标签**存下来：跟着容器走，容器删了
# 记录也跟着没，生命周期是对的，也不用在本工具这边另立一份账。
#
# **存之前先掩码**：run 命令里带 `-e DB_PASSWORD=…` 是常态，而这份记录是给人
# 翻阅的，明文密码不能进。掩码的代价是存下来的命令不能原样重跑，改的时候要
# 自己把密码补回去 —— 另一个选择是把密码写进一个随时会被 `docker inspect`
# 打出来的地方，那不能接受。
#
# 同一次扫描顺便把凭据值交给执行封装登记脱敏（`--secret-val`）。**在这之前
# 它们是明文进日志的** —— 整条命令原样交给 docker 执行，而日志记的就是那条
# 命令。podman 侧不中招是因为它翻译成文件、不把命令交给引擎。

readonly NAME_RE='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$'
readonly WATCHTOWER_NAME='oneserver-watchtower'
readonly RUNCMD_LABEL='io.oneserver.run-cmd'
readonly DOCKER_ID='docker'

# ------------------------------------------------------------------

require_docker() {
    probe::component_version docker
    [[ -n ${OS_PROBE_VALUE} ]] || os::die 3 '没有检测到 Docker。先 oneserver install docker'
    os::require_cmd docker

    # daemon 停着的话下面每一条命令都会以「Cannot connect to the Docker
    # daemon」失败 —— 那句话不会告诉人服务是停着的，只会让人去查网络与权限
    probe::service_active docker.service
    [[ ${OS_PROBE_VALUE} == active ]] \
        || os::die 3 "dockerd 没在跑（当前 ${OS_PROBE_VALUE:-未知}）—— Docker 的每条命令都要连它：systemctl start docker.service"
    return 0
}

validate_name() {
    local name=${1}
    [[ ${name} =~ ${NAME_RE} ]] \
        || os::die 2 "容器名「${name}」不合法：以字母或数字开头，此后只收字母、数字、下划线、点与短横线"
    return 0
}

container_exists() {
    local name=${1} line
    os::query --timeout 20 -- docker ps -a --format '{{.Names}}'
    while IFS= read -r line; do
        [[ ${line} == "${name}" ]] && return 0
    done <<<"${OS_RUN_OUTPUT}"
    return 1
}

watchtower_running() {
    os::query --timeout 10 -- docker inspect -f '{{.State.Status}}' "${WATCHTOWER_NAME}" || return 1
    [[ ${OS_RUN_OUTPUT} == running ]]
}

# 把名字加进自动更新名单。名单是空格分隔的一个值，与 `oneserver docker` 那边
# 读写的是同一份（state 的 docker 组件下）。
#
# 全局 IFS 是 `\n\t`，空格不在里面 —— 拆名单必须自己把 IFS 设成空格，
# 否则整份名单会当成一个词，「已经在里面了吗」永远判否，名单里于是出现重复名
au_add() {
    local name=${1} list one acc=''
    list=$(os::state_get "${DOCKER_ID}" autoupdate '')
    local IFS=' '
    for one in ${list}; do
        [[ ${one} == "${name}" ]] && return 0
        acc+="${acc:+ }${one}"
    done
    IFS=$'\n\t'
    acc+="${acc:+ }${name}"
    os::state_set "${DOCKER_ID}" "autoupdate=${acc}" || os::die 1 '写入自动更新名单失败'
    return 0
}

# 环境变量名看着像不像凭据。先转小写再比，否则 `Password`、`apiKey` 这类
# 大小写混写的名字两边模式都不命中，而它们恰恰是最常见的写法
cred_key() {
    local k=${1,,}
    case ${k} in
        *pass* | *token* | *secret* | *key*) return 0 ;;
    esac
    return 1
}

# 扫一遍参数，产出两样东西：掩码后的参数（DC_SAFE，用来存进标签）与需要登记
# 脱敏的凭据值（DC_SECRETS，交给执行封装）。
#
# 三种写法都要认：`-e KEY=V`（值在下一个词）、`--env=KEY=V`、`-eKEY=V`。
# 掩码后**保持原来的形态**（两个词的仍是两个词），存下来的命令才跟用户粘进来的
# 那条对得上，改的时候不用先在脑子里翻译一遍
DC_SAFE=()
DC_SECRETS=()
scan_env_secrets() {
    local -i k
    local t prefix kv key val
    DC_SAFE=()
    DC_SECRETS=()
    for ((k = 0; k < ${#args[@]}; k++)); do
        t=${args[k]}
        prefix=''
        case ${t} in
            -e | --env)
                DC_SAFE+=("${t}")
                k=$((k + 1))
                [[ ${k} -lt ${#args[@]} ]] || break
                kv=${args[k]}
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
                DC_SAFE+=("${t}")
                continue
                ;;
        esac
        key=${kv%%=*}
        val=${kv#*=}
        if [[ ${kv} == *=* ]] && cred_key "${key}"; then
            DC_SAFE+=("${prefix}${key}=***")
            if [[ ${#val} -ge 6 ]]; then
                DC_SECRETS+=("${val}")
            elif [[ -n ${val} ]]; then
                # 执行封装拒绝登记短于 6 个字符的值：短值全局替换会把整行命令
                # 打成马赛克，看着脱敏了实际是把证据毁了。所以这里如实说它进了日志
                os::warn "「${key}」的值不足 6 个字符，无法在日志里脱敏，它会明文留在日志里 —— 换一个更长的值"
            fi
        else
            DC_SAFE+=("${prefix}${kv}")
        fi
    done
    return 0
}

# 把掩码后的参数拼回一条可读的命令。含空白或引号的词补上引号，
# 不然存下来的命令再粘出去就散架了
safe_cmdline() {
    local __dc_out=${1} __dc_one __dc_acc='docker run'
    for __dc_one in ${DC_SAFE[@]+"${DC_SAFE[@]}"}; do
        case ${__dc_one} in
            *[[:space:]]* | *\"*) __dc_acc+=" \"${__dc_one//\"/\\\"}\"" ;;
            *) __dc_acc+=" ${__dc_one}" ;;
        esac
    done
    printf -v "${__dc_out}" '%s' "${__dc_acc}"
    return 0
}

# ------------------------------------------------------------------
# 切词
# ------------------------------------------------------------------

# 把一条命令行切成词，结果写进 DC_TOKENS。引号没闭合时返回 1。
#
# 认单引号（内部一律字面）、双引号（内部只有 `\"` `\\` 是转义）与反斜杠，
# 与 shell 一致。**不做变量展开、不做 glob**：粘进来的 `$HOME` 就是字面的
# `$HOME` —— 展开它等于替用户改写他的命令，而他多半是从一份文档里复制的。
#
# **不能把整条字符串交给 `sh -c`**，那是 eval 的另一种写法，全项目禁止（§10）。
# 也不用 `xargs`：它的引号规则与 shell 有出入，用它会让「粘进来的命令」
# 与「在终端里敲的同一条命令」有两种含义。
#
# 与 podman_create.sh 里那份是同一套规则的第二份实现。**出现第三个消费者
# 就该进 lib** —— 到那时「同一条命令在不同引擎下切出不同的词」才真正开始难查。
DC_TOKENS=()
tokenize() {
    local s=${1}
    local -i i n=${#s} started=0
    local cur='' ch quote=''
    DC_TOKENS=()
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
            # 换行与回车也算分隔：`--run-cmd=` 传进来的值可能带换行，
            # 从 Windows 终端粘来的还会带 `\r` —— 不当空白的话它会粘在词尾
            # 变成 `nginx:alpine\r`，然后镜像拉不到
            ' ' | $'\t' | $'\n' | $'\r')
                if ((started == 1)); then
                    DC_TOKENS+=("${cur}")
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
    ((started == 1)) && DC_TOKENS+=("${cur}")
    return 0
}

# 首词指名了别的引擎时怎么拒。
#
# 不能像从前那样把 `podman` 一起吃掉：按 D210 剩下的 flag 是**原样透传**给
# docker 的，而 podman 独有的 `--userns=keep-id`、`--pod`、挂载的 `:Z`/`:z`
# docker 不认 —— 最好的结果是 docker 报一句参数错误，最坏是被它按别的语义收下。
# **拒绝必须给出下一步**，理由同 podman 侧：不然用户删掉首词再粘就绕过去了。
reject_foreign_engine() {
    local named=${1}
    probe::component_version podman
    if [[ ${named} == podman && -n ${OS_PROBE_VALUE} ]]; then
        os::die 2 '这是一条 podman 命令，而你正在用 Docker 建容器 —— 照粘会建成 docker 容器，而 podman ps 看不见它。要建 Podman 容器请走「Podman 容器 › 创建容器」（oneserver podman run）；确实要建 docker 容器就把开头的 podman 改成 docker'
    fi
    os::die 2 "这是一条 ${named} 命令，不是 docker run。要用 Docker 建这个容器，把开头的 ${named} 改成 docker 再粘一次，其余参数原样保留"
}

validate_run_cmd() {
    local v=${1}
    [[ -n ${v} ]] || return 1
    # 续行由 `os::ask --multiline` 接完，走到这里还挂着反斜杠只有一种可能：
    # 粘到一半断了。半条命令照样能跑出一个「像那么回事」的容器，所以要拒绝
    [[ ${v} != *\\ ]] || return 1
    return 0
}

# ------------------------------------------------------------------

# 建容器：粘命令 → 切词 → 补齐必需的几样 → 校验挂载 → 跑 → 确认真的在跑
main() {
    require_docker

    local cmdline=''
    os::ask --arg run-cmd --multiline --validate validate_run_cmd \
        '粘贴完整的 run 命令（带 \ 换行的多行命令直接整段粘）' cmdline ''

    tokenize "${cmdline}" || os::die 2 '命令里的引号没有闭合'
    [[ ${#DC_TOKENS[@]} -gt 0 ]] || os::die 2 '没有收到命令'

    # `sudo docker run …` 是从文档里复制时最常见的形态。本命令已经是 root，
    # 把 sudo 原样传下去只会多一层进程，还会让 --env 之类的行为变得不一样
    local -i start=0
    [[ ${DC_TOKENS[start]} == sudo ]] && start=$((start + 1))
    case ${DC_TOKENS[start]-} in
        docker) start=$((start + 1)) ;;
        podman | nerdctl) reject_foreign_engine "${DC_TOKENS[start]}" ;;
        *) os::die 2 "命令要以 docker run 开头，收到「${DC_TOKENS[start]-}」" ;;
    esac
    [[ ${DC_TOKENS[start]-} == run ]] \
        || os::die 2 "只收 run 命令，收到「${DC_TOKENS[start]-}」—— 别的操作请用本命令的其他动作或直接敲 docker"
    start=$((start + 1))

    local -a args=("${DC_TOKENS[@]:start}")
    [[ ${#args[@]} -gt 0 ]] || os::die 2 'run 后面什么都没有，至少要给出镜像'

    # --- 扫一遍，看这三样在不在 ---
    #
    # **只扫不改**：这里判断的是 flag 在不在，不解析它的值，所以不需要一张
    # 「哪个 flag 吃下一个词」的表。代价是理论上有个词恰好是 `--name` 的
    # **值**时会误判 —— 那时我们不会再补一个 --name，docker 自己会报重复参数，
    # 而不是安静地做错事。为这个概率去维护一张 flag 表不划算。
    local -i has_detach=0 has_name=0 has_restart=0
    local name='' policy='' t
    local -i k
    for ((k = 0; k < ${#args[@]}; k++)); do
        t=${args[k]}
        case ${t} in
            -d | --detach) has_detach=1 ;;
            --name)
                has_name=1
                name=${args[k + 1]-}
                ;;
            --name=*)
                has_name=1
                name=${t#--name=}
                ;;
            --restart)
                has_restart=1
                policy=${args[k + 1]-}
                ;;
            --restart=*)
                has_restart=1
                policy=${t#--restart=}
                ;;
        esac
    done

    if ((has_name == 1)); then
        [[ -n ${name} ]] || os::die 2 '--name 后面没有值'
    else
        os::ask --arg name '这条命令没写 --name，容器叫什么' name ''
        [[ -n ${name} ]] || os::die 2 '要给出容器名字：--name=web'
    fi
    validate_name "${name}"
    container_exists "${name}" \
        && os::die 2 "已经有一个叫 ${name} 的容器。改配置就先删了重建：oneserver docker rm --name=${name}"

    if ((has_restart == 0)); then
        # 默认必须问：docker 不写 --restart 就是 `no`，容器崩一次就永远
        # 停在那儿，而 `docker ps` 的默认视图连它都不列
        os::select --arg restart-policy '这条命令没写 --restart，失败后怎么办' policy \
            'always=总是重启（开机也拉起）' 'unless-stopped=除非手动停过，否则重启' \
            'on-failure=仅异常退出时重启' 'no=不自动重启'
    fi

    # --- 自动更新：名单驱动 ---
    #
    # **默认 y**：容器不跟着上游镜像走，跑的就是一个再也不打补丁的东西。
    # 名单本身不会让任何事情发生（要更新器跑起来才算数），所以这一问默认为是
    # 并不构成「替用户放宽了什么」。
    #
    # 但**代价必须在这里说**，不能等到用户去点「开启自动更新服务」才第一次听见：
    # 这一问答「是」的人，下一步就会被引导去启用更新器，而那个更新器要挂
    # Docker Socket —— 能对它说话就等于宿主 root。在他不知道这一点的时候
    # 拿一个默认 y 把他推过去，等于替他做了那个决定。
    os::info '说明：自动更新由一个更新器容器执行，它要挂载 /var/run/docker.sock —— 那等价于宿主 root 权限'
    os::info '现在选「是」只是把这个容器记进名单，不会启动任何东西；真正生效要你之后手动「开启自动更新服务」'
    local -i autoupdate=0
    os::confirm --arg auto-update '开启自动更新（镜像有新版本时自动拉取并重建这个容器）' y \
        && autoupdate=1

    # --- 端口：只提醒，不改写 ---
    #
    # 不写宿主 IP 的映射绑到哪儿由 daemon.json 的 "ip" 决定（安装时按网络定位
    # 设好）。显式写了 IP 的**原样不动** —— 那是当场做的决定。
    # 但公网定位下写死 0.0.0.0 意味着直接暴露在公网，而 **ufw 拦不住它**，
    # 所以这一句必须说出来。
    local netmode
    netmode=$(os::state_get network mode '')
    [[ -n ${netmode} ]] || netmode='公网'

    local pval
    for ((k = 0; k < ${#args[@]}; k++)); do
        pval=''
        case ${args[k]} in
            -p | --publish) pval=${args[k + 1]-} ;;
            --publish=*) pval=${args[k]#--publish=} ;;
        esac
        [[ -n ${pval} ]] || continue
        case ${pval} in
            0.0.0.0:* | '[::]:'*)
                [[ ${netmode} == 公网 ]] \
                    && os::warn "端口映射 ${pval} 写死了对全网监听，而这台机器是公网定位 —— Docker 发布的端口绕过 ufw，防火墙拦不住它"
                ;;
            # 三段式写死了宿主 IP，那是当场做的决定，原样不动
            *:*:*) ;;
            *:*) os::info "端口映射 ${pval} 没写宿主 IP，按 dockerd 的默认绑定地址走（oneserver install docker 里显示的那个）" ;;
            *) os::info "端口映射 ${pval} 只给了容器端口，宿主端口由 docker 随机分配" ;;
        esac
    done

    # --- 跑 ---
    #
    # 补的 flag 一律落进 cmd、排在 args 之前，**不能塞进 `args`**：`args` 是
    # 用户原样给的词，镜像名混在里面，而镜像名之后的一切 docker 都当成容器
    # 自己的命令 —— 加在 args 末尾等于把 flag 传给了容器里的入口脚本
    # （撞过一次：nginx 的 entrypoint 报 `illegal option --`）
    local safe_cmd=''
    scan_env_secrets
    safe_cmdline safe_cmd

    local -a cmd=(run)
    ((has_detach == 1)) || cmd+=(-d)
    ((has_name == 1)) || cmd+=(--name "${name}")
    ((has_restart == 1)) || cmd+=(--restart "${policy}")
    cmd+=(--label "${RUNCMD_LABEL}=${safe_cmd}")
    cmd+=("${args[@]}")

    # 凭据值按**值**匹配脱敏，不按位置（位置索引在任何人往命令中间插一个参数时
    # 立即错位，而错位不报错，唯一表现是密码开始明文进日志）
    local -a secret_args=()
    local s
    for s in ${DC_SECRETS[@]+"${DC_SECRETS[@]}"}; do
        secret_args+=(--secret-val "${s}")
    done

    # 容器是本次创建的、撤销干净且安全 —— 属「必须回滚」类，注册回滚。
    # 后面那道「它真的在跑吗」的校验不通过时，不该留一个半死的容器在那儿
    os::record_change "创建了容器 ${name}"
    # 选项写在 desc 之后：执行封装的解析是循环到 `--` 为止，顺序无关，
    # 而 desc 排在最前面才看得出它是个固定字符串（规范要求，也是 lint 的判据）
    os::run '创建并启动容器' ${secret_args[@]+"${secret_args[@]}"} -- docker "${cmd[@]}" \
        || os::die 1 "docker run 失败，容器 ${name} 没有建起来（详情看日志）"
    os::defer docker rm -f -- "${name}"

    # --- 确认它真的在跑 ---
    #
    # `docker run -d` 返回 0 只说明容器**建起来了**，不说明它还活着：
    # 配置错、镜像的 entrypoint 立刻退出、挂载进去的文件不对 —— 这些都让它
    # 在一秒内变成 Exited(1)，而命令本身是成功的。不查这一下，本工具就会
    # 报告「容器已就绪」，而实际上什么都没跑起来
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 容器没有真的创建，后续状态无从确认'
        os::output 0 name="${name}" changed=dry-run
        return 0
    fi

    os::query --timeout 20 -- docker inspect -f '{{.State.Status}}' "${name}"
    local status=${OS_RUN_OUTPUT}
    if [[ ${status} != running ]]; then
        os::err "容器 ${name} 建起来了，但现在的状态是 ${status:-未知}，下面是它最后几行日志："
        # 容器日志绝大多数走 stderr（nginx、postgres 都是），而 os::query
        # 默认丢弃 stderr —— 不合流的话这里会打出一片空白，正好在最需要它的
        # 时候。合流用框架现成的 `--want-stderr`，值经 argv 传入，不起内层 shell
        os::query --timeout 20 --want-stderr -- docker logs --tail 20 "${name}"
        [[ -n ${OS_RUN_OUTPUT} ]] && os::info "${OS_RUN_OUTPUT}"
        # 退出码 1 会让框架回放回滚栈，撤掉这次刚创建的容器
        os::die 1 '容器没能跑起来，已自动撤销。照日志改完命令再来一次'
    fi

    # --- 名单 ---
    #
    # 放在「它真的在跑吗」之后：容器没起来就被撤销了，名单里留个名字是假事实
    if ((autoupdate == 1)); then
        au_add "${name}"
        # 两种情形都要用户再走一步「开启自动更新服务」：没开的要开，开着的要
        # 重建才能带上新名单（名单是更新器的启动参数）。**这里不替他做** ——
        # 部署更新器是一个全机决定，不该由「建了一个容器」顺带触发
        if watchtower_running; then
            os::info '名字已加入自动更新名单。到 oneserver docker 里再走一次「开启自动更新服务」，更新器才会带上它'
        else
            os::info '名字已加入自动更新名单。自动更新服务还没开，到 oneserver docker 里「开启自动更新服务」才会真正开始更新'
        fi
    fi

    os::section '容器已就绪'
    os::kv '名字' "${name}" \
        '重启策略' "${policy:-（命令里自带）}" \
        '状态' "${status}" \
        '自动更新' "$([[ ${autoupdate} -eq 1 ]] && printf '已加入名单' || printf '关')"
    os::info "看日志与管理：oneserver docker logs --name=${name}"
    os::output 0 name="${name}" status="${status}" auto_update="${autoupdate}" changed=yes
    return 0
}

main "$@"
