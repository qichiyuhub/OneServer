#!/bin/bash
#
# 安装 Node.js（官方发布 + SHA256 校验）
#
# @command      install nodejs
# @name         Node.js
# @group        app
# @order        150
# @privilege    root
# @requires_lib >= 4.0
# @provides     nodejs:<major>
# @args         [--version=<lts|latest|大版本号>]
# @description  从官网装 Node.js，校验 SHA256，多版本共存
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 为什么不用 fnm、不用发行版源、不加 NodeSource
#
# **fnm（旧脚本的方案）是 K10 的第二处**：`curl -fsSL https://fnm.vercel.app/install
# | bash` —— 把 root 权限直接交给第三方脚本，无任何校验。这是本项目仅有的两处
# 「以 root 管道执行第三方脚本」之一，规范明令禁止。
#
# 发行版源太旧：Debian 13 是 20.x、Ubuntu 24.04 是 18.x（18 已 EOL）。
# NodeSource 要往系统里加第三方 apt 源，而 D99 定过「只有 Caddy 一家加第三方源」，
# 这会是第二家 —— 为一个能直接下官方发布的东西加一整套源，不划算。
#
# 官方发布这条路满足规范的全部要求：
#   * nodejs.org 官方域名 + TLS
#   * **每个版本都有 SHASUMS256.txt，而且是标准格式**（`哈希␣␣文件名`），
#     `sha256sum -c` 直接认 —— 与 Caddy 那份裸哈希不同（D98 踩过的坑）
#   * 校验失败硬失败，不降级（D97 不放宽）
#
# ## 多版本靠 update-alternatives，不靠符号链接
#
# 组件标识是 `nodejs:<大版本>`（D35），两个大版本可以并存，各自解到自己的目录。
# 那么 /usr/local/bin/node 该指向谁？**用 update-alternatives**：
#
#   * 优先级 = 大版本号，所以默认新版本胜出
#   * 卸掉 v24 之后，alternatives **自动回落到 v22**，链接不会断
#
# 换成「装的时候 ln -sf 覆盖一下」的话，两个实例都会把这三个链接登记成自己的
# `file` 资源，卸载其中一个就把指向另一个的链接删掉了 ——规范里
# `alt` 这个资源类型存在的理由正是这个。

readonly NODE_DIST='https://nodejs.org/dist'
readonly NODE_PREFIX='/usr/local/lib/nodejs'

# 函数之间的返回通道。不用 $( ) 取返回值：那是子 shell，
# os::record_change / os::defer 一条都传不出来（D74）。
NODE_ARCH=''
NODE_VERSION=''
NODE_MAJOR=''
NODE_TARBALL=''
NODE_TARGET=''
NODE_CHANGED=0

# ------------------------------------------------------------------

resolve_arch() {
    probe::arch
    case ${OS_PROBE_VALUE} in
        x86_64) NODE_ARCH='x64' ;;
        aarch64 | arm64) NODE_ARCH='arm64' ;;
        *) os::die 4 "不支持的架构：${OS_PROBE_VALUE}（仅 x64 / arm64）" ;;
    esac
    return 0
}

# 解析 `--version` 的三种写法，结果写进 NODE_VERSION / NODE_MAJOR。
#
# **数据源是 index.tab 不是 index.json**：同样的内容，一个是制表符分隔的表，
# 一个要解 JSON。D5 是零运行时依赖，而 jq 在最小安装里没有 —— 手搓 JSON 解析
# 是给自己找 bug，而 index.tab 一行 `read -r` 就拆开了。
#
#   第 1 列  版本（v24.18.1）
#   第 10 列 LTS 代号（不是 LTS 的写 `-`）
#
# 表本身按版本从新到旧排，所以「第一条匹配的」就是最新的那条。
resolve_version() {
    local spec=${1}

    os::query --timeout 30 -- curl -fsSL --proto '=https' --proto-redir '=https' \
        "${NODE_DIST}/index.tab" \
        || os::die 1 '取不到 Node.js 发布列表（nodejs.org/dist/index.tab）'
    local table=${OS_RUN_OUTPUT}
    [[ -n ${table} ]] || os::die 1 'Node.js 发布列表是空的'

    local line ver lts
    local IFS=$'\n'
    for line in ${table}; do
        [[ ${line} == version* ]] && continue
        IFS=$'\t' read -r ver _ _ _ _ _ _ _ _ lts _ <<<"${line}"
        [[ ${ver} == v[0-9]* ]] || continue

        case ${spec} in
            latest)
                NODE_VERSION=${ver}
                break
                ;;
            lts)
                [[ -n ${lts} && ${lts} != '-' ]] || continue
                NODE_VERSION=${ver}
                break
                ;;
            *)
                # 大版本号：v24.18.1 的大版本是 24
                local m=${ver#v}
                m=${m%%.*}
                [[ ${m} == "${spec}" ]] || continue
                NODE_VERSION=${ver}
                break
                ;;
        esac
    done

    if [[ -z ${NODE_VERSION} ]]; then
        os::die 2 "在官方发布列表里找不到「${spec}」对应的版本（可写 lts / latest / 大版本号）"
    fi
    NODE_MAJOR=${NODE_VERSION#v}
    NODE_MAJOR=${NODE_MAJOR%%.*}
    return 0
}

# 下载并校验。**校验失败硬失败，不换源、不跳过**（D97）——
# 自动降级到无校验的路，等于让「让校验失败」成为绕过校验的手段。
#
# `sha256sum -c` 这次能直接用：官方那份是标准的「哈希␣␣文件名」格式。
# 加 --ignore-missing 是因为 SHASUMS256.txt 里列着十几个平台的产物，
# 本地只下了一个 —— 不加的话其余每一行都报「No such file」并返回非零。
fetch_node() {
    local dir=${1}
    local name="node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
    local base="${NODE_DIST}/${NODE_VERSION}"

    os::info "下载 ${NODE_VERSION}（linux-${NODE_ARCH}）"
    os::run_out '下载 Node.js 发布包' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
        -o "${dir}/${name}" "${base}/${name}" \
        || os::die 1 "下载失败：${base}/${name}"

    os::run_out '下载 SHA256 校验清单' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 \
        -o "${dir}/SHASUMS256.txt" "${base}/SHASUMS256.txt" \
        || os::die 1 '下载 SHASUMS256.txt 失败'

    # 从清单里取出**这个文件那一行**的哈希再比，不 `cd`、不起内层 shell
    # （同 backup.sh 的 action_verify）。原来的 `cd '${dir}' && sha256sum -c`
    # 要一层 shell，于是目录得拼进脚本文本 —— 这里的 dir 来自 os::tmpdir、
    # 恰好不含元字符，但「值恰好安全」是会在重构中静默失效的保证。
    #
    # 顺带去掉 `--ignore-missing`：它原本是为了跳过清单里其余几十个平台的
    # 产物，而只取自己那一行就不需要它。这也堵上了它的副作用 —— 清单里
    # **根本没有**我们这个文件时，`-c --ignore-missing` 不算失败。
    local want='' line lhash lname
    while IFS= read -r line || [[ -n ${line} ]]; do
        lhash=${line%% *}
        lname=${line##* }
        [[ ${lname} == "${name}" ]] || continue
        want=${lhash}
        break
    done <"${dir}/SHASUMS256.txt"
    [[ ${want} =~ ^[0-9a-f]{64}$ ]] \
        || os::die 1 "SHASUMS256.txt 里没有 ${name} 的哈希，拒绝安装"

    os::query --timeout 60 -- sha256sum -- "${dir}/${name}" \
        || os::die 1 "计算 ${name} 的 SHA256 失败"
    [[ ${OS_RUN_OUTPUT%% *} == "${want}" ]] \
        || os::die 1 "${name} 未通过 SHA256 校验，拒绝安装（不会自动改用无校验的来源）"
    os::ok 'SHA256 校验通过'

    NODE_TARBALL="${dir}/${name}"
    return 0
}

# 解包到 /usr/local/lib/nodejs/node-vX.Y.Z-linux-<arch>/，路径写进 NODE_TARGET。
#
# **结果走模块级变量，不用 `printf` + `$( )` 取** —— 第一版就是那么写的，
# 而 `os::info` / `os::ok` 默认打到 stdout（D57：只有 warn/error 走 stderr），
# 于是「✓ SHA256 校验通过」被一起捕获进了变量，`tar -xJf` 收到的文件名前面
# 挂着两行提示语。报错是「解包失败」，而真正的原因在三行之外（同 D74）。
#
# 解到带版本号的目录而不是一个固定的 `nodejs/`：两个大版本要能并存，
# 而且升级补丁版时新旧两份可以同时在盘上，切换只是改 alternatives 的一行。
install_tarball() {
    local tarball=${1}
    local target="${NODE_PREFIX}/node-${NODE_VERSION}-linux-${NODE_ARCH}"

    NODE_TARGET=${target}
    if [[ -x "${target}/bin/node" ]]; then
        os::info "${target} 已存在，跳过解包"
        return 0
    fi

    os::run '创建 Node.js 安装目录' -- mkdir -p "${NODE_PREFIX}"
    # 解到临时目录再 mv：直接解到目标路径的话，解到一半被打断会留下
    # 一个「看起来装好了」的半截目录，下次执行的 -x 判断会认它
    local staging="${NODE_PREFIX}/.staging.$$"
    os::critical_begin '解包 Node.js'
    local -i rc=0
    os::run '解包 Node.js' -- mkdir -p "${staging}" || rc=$?
    [[ ${rc} -eq 0 ]] && { os::run '展开发布包' -- tar -xJf "${tarball}" -C "${staging}" --strip-components=1 || rc=$?; }
    [[ ${rc} -eq 0 ]] && { os::run '就位 Node.js 目录' -- mv -T "${staging}" "${target}" || rc=$?; }
    # 「必须回滚」类：${target} 是本次创建、当前无人使用，撤销完全安全——
    # 不像 NODE_PREFIX 本身（可能是既有目录），这一条不该只记变更清单了事，
    # 后面校验步骤（libatomic.so.1 缺失等）失败时应该真的把半成品收掉
    [[ ${rc} -eq 0 ]] && os::defer os::run --allow-fail '回滚：删除本次解包的 Node.js 目录' -- rm -rf -- "${target}"
    os::critical_end
    if [[ ${rc} -ne 0 ]]; then
        os::run --allow-fail '清理未完成的解包目录' -- rm -rf "${staging}"
        os::die 1 '解包 Node.js 失败'
    fi

    NODE_CHANGED=1
    return 0
}

# **先验证解出来的这个 node 真能跑，再去动 alternatives。**
#
# 顺序反过来的代价是实打实的：容器验收里装 Node 26 时，官方二进制依赖
# `libatomic.so.1` 而最小系统没有 —— 先注册的话，26 凭优先级立刻成为默认的
# `node`，**整台机器的 node 当场坏掉**，而且是在「安装成功」的绿字之后。
# 已经装好的 24 还在盘上，却被一个跑不起来的候选顶掉了。
#
# 这和 install_caddy 的 verify_binary → switch_binary 是同一条：
# 切换之前先证明新东西可用，别拿正在用的东西赌。
verify_node_binary() {
    local target=${1}
    os::query --timeout 20 -- "${target}/bin/node" --version && return 0
    os::err "解包出来的 node 跑不起来，没有改动 ${OS_LOCAL_BIN_DIR}/node"
    os::info "常见原因是缺系统库。诊断：${target}/bin/node --version"
    return 1
}

# 注册到 update-alternatives。优先级 = 大版本号，所以新版本默认胜出，
# 而卸掉它之后自动回落到还装着的旧版本。
register_alternatives() {
    local target=${1}
    os::record_change "把 node/npm/npx 注册进 update-alternatives（优先级 ${NODE_MAJOR}）"
    # 注册进去之后若后续步骤失败，要把它摘掉再退出 —— 否则留下的是
    # 「state 里没这个实例，alternatives 里却有它」，下次执行谁也对不上
    os::defer update-alternatives --remove node "${target}/bin/node"
    os::run '注册 Node.js 到 alternatives' -- \
        update-alternatives --install "${OS_LOCAL_BIN_DIR}/node" node "${target}/bin/node" "${NODE_MAJOR}" \
        --slave "${OS_LOCAL_BIN_DIR}/npm" npm "${target}/bin/npm" \
        --slave "${OS_LOCAL_BIN_DIR}/npx" npx "${target}/bin/npx"
    return 0
}

# ------------------------------------------------------------------

main() {
    resolve_arch

    local spec=''
    os::ask --arg version '要装哪个版本？lts / latest / 大版本号（如 24）' spec 'lts'
    [[ -n ${spec} ]] || spec='lts'

    # tar 的 xz 支持在 Debian 最小安装里要单独装 xz-utils，
    # 少了它 `tar -xJf` 报的是「不认识的压缩格式」，跟 Node 一点关系没有。
    #
    # libatomic1 是官方二进制的运行时依赖，最小系统里没有 —— 容器验收里
    # Node 26 就是这么倒在 `libatomic.so.1: cannot open shared object file` 上的。
    # 它是系统共享库不是 Node 的组成部分，按 D103 **不登记进资源清单**。
    os::pkg_install ca-certificates curl xz-utils tar libatomic1
    os::require_cmd curl tar sha256sum update-alternatives

    resolve_version "${spec}"
    local id="nodejs:${NODE_MAJOR}"
    os::info "目标版本 ${NODE_VERSION}（组件标识 ${id}）"

    # 已是目标状态就别下了。判据两条：state 记的版本与这次算出来的一样，
    # 且那个目录**确实还在**（有人手动删过目录的话，state 说装了也不算数）。
    local recorded target
    recorded=$(os::state_get "${id}" version)
    target="${NODE_PREFIX}/node-${NODE_VERSION}-linux-${NODE_ARCH}"
    local -i want_install=1
    if [[ ${recorded} == "${NODE_VERSION}" && -x "${target}/bin/node" ]]; then
        os::ok "${NODE_VERSION} 已安装且是该通道的最新版，跳过下载"
        want_install=0
    fi

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        if [[ ${want_install} -eq 1 ]]; then
            os::info "[dry-run] 将下载并校验 ${NODE_VERSION}，解包到 ${target}"
            os::info "[dry-run] 将把 node/npm/npx 注册进 update-alternatives（优先级 ${NODE_MAJOR}）"
        fi
        os::info '[dry-run] 后续步骤无法预演（发布包尚未下载，校验与解包都要真实文件）'
        os::output 0 version="${NODE_VERSION}" major="${NODE_MAJOR}" \
            arch="${NODE_ARCH}" changed=dry-run
        return 0
    fi

    if [[ ${want_install} -eq 1 ]]; then
        local dir
        os::tmpdir dir || os::die 1 '无法创建临时目录'
        fetch_node "${dir}"
        install_tarball "${NODE_TARBALL}"
        target=${NODE_TARGET}
        verify_node_binary "${target}" || os::die 1 "Node.js ${NODE_VERSION} 验证未通过，未改动系统的 node"
        register_alternatives "${target}"
    fi

    # 验证走真实路径 —— 直接跑 /usr/local/bin/node，而不是跑解包目录里那个。
    # 要证明的是「用户敲 node 能用」，不是「文件解出来了」。
    probe::component_version nodejs
    if [[ ${OS_PROBE_STATUS} != ok || -z ${OS_PROBE_VALUE} ]]; then
        os::die 1 "装好了但 ${OS_LOCAL_BIN_DIR}/node 跑不起来"
    fi
    local running=${OS_PROBE_VALUE}
    # npm 是个包装脚本，要在 PATH 里找得到 node 才跑得起来。而脚本的 PATH 按
    # 规范固定成四个系统目录，**不含 /usr/local/bin** —— 不定点补上的话，
    # 这里永远打「npm 未知」，而用户在自己的 shell 里敲 npm 明明是好的。
    os::query --timeout 30 --env "PATH=${target}/bin:${PATH}" \
        -- "${OS_LOCAL_BIN_DIR}/npm" --version || true
    local npm_ver=${OS_RUN_OUTPUT:-未知}

    # alternatives 当前选中的是谁 —— 装了多个大版本时这一条最容易被误解：
    # 刚装的不一定是生效的（优先级由大版本号定，装 v22 不会顶掉已装的 v24）
    os::query --timeout 10 -- readlink -f "${OS_LOCAL_BIN_DIR}/node"
    local active_path=${OS_RUN_OUTPUT}
    if [[ ${running} != "${NODE_VERSION}" ]]; then
        os::warn "当前生效的是 ${running}，不是刚装的 ${NODE_VERSION} —— alternatives 按大版本号定优先级。要手动切换：update-alternatives --config node"
    fi

    # 状态与资源清单
    os::state_set "${id}" version="${NODE_VERSION}" major="${NODE_MAJOR}" \
        arch="${NODE_ARCH}" prefix="${target}"
    os::state_resource_add "${id}" file "${target}"
    os::state_resource_add "${id}" alt "node:${target}/bin/node"

    os::kv '目标版本' "${NODE_VERSION}" \
        '组件标识' "${id}" \
        '安装目录' "${target}" \
        '当前生效' "${running}（${active_path}）" \
        'npm' "${npm_ver}"

    local changed_text='no'
    if [[ ${NODE_CHANGED} -eq 1 ]]; then
        changed_text='yes'
        os::ok "Node.js ${NODE_VERSION} 已安装（${id}）"
    else
        os::ok "Node.js ${NODE_VERSION} 已是目标状态（${id}）"
    fi
    os::output 0 version="${NODE_VERSION}" major="${NODE_MAJOR}" \
        arch="${NODE_ARCH}" active="${running}" changed="${changed_text}"
    return 0
}

main "$@"
