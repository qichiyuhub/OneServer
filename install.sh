#!/bin/bash
#
# OneServer 引导安装器
#
#   curl -fsSL https://raw.githubusercontent.com/qichiyuhub/OneServer/main/install.sh | bash
#   bash install.sh [--ref=<tag>] [--manifest=<路径|URL>] [--from=<目录|tar.gz>] [--yes]
#
# ==================================================================
# 这个文件为什么是全项目唯一的「自包含」脚本之二
# ==================================================================
#
# 它跑在**还没有 /opt/oneserver 的机器上**，所以 source 不了 lib/bootstrap.sh，
# 也就用不了 os::run / os::ask / ui::*。这与切换器是同一类例外，
# 但方向相反：切换器是「不能用旧 lib」，这里是「还没有 lib」。
#
# 因此本文件里的 echo、颜色、参数解析都是自己写的 —— **这不是可以照抄的样板**。
# `script/**` 下的任何脚本这么写都是违约。
#
# ==================================================================
# K11：`.initialized` 短路
# ==================================================================
#
# 旧版本在 /opt/oneserver/.initialized 存在时**跳过全部下载**直接进菜单。
# 一旦本地文件损坏或更新链断裂，重跑 `curl | bash` 什么都不做，
# 用户只能自己去 `rm /opt/oneserver/.initialized` —— 而没人知道要这么干。
#
# 现在没有这个标记文件。**每次运行都是「按清单把系统校正到目标状态」**：
# 已经一致的文件不动，缺的补上，坏的（哈希对不上）换掉，多余的（上一版有、
# 这一版没有）删掉。装、修、重装因此是同一条代码路径 —— 不存在「修复模式」
# 这个需要用户先意识到自己需要它的东西。
#
# ==================================================================
# 信任根（要诚实写，别写成「有校验所以安全」）
# ==================================================================
#
# 这个文件自己是 `curl | bash` 进来的，**它无法自证**。整条链的信任根是
# GitHub 账号 + TLS。manifest 的 SHA256 提供的是**完整性**（防传输截断、
# 防半截更新、防孤儿文件），不是**真实性** —— 清单与被它校验的文件来自
# 同一个仓库、同一条 TLS 连接，能投毒文件的攻击者同样能投毒清单。
# manifest 哈希只提供完整性校验；安装器不宣称额外的发布签名保证。
#
# 代码本身**不**从浮动分支取：清单里记着 commit SHA，源码 tar 包按那个 SHA 下载。
# 唯一浮动的是「取哪一份清单」（默认最新 release），而那正是将来签名要签的东西。

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 022

REPO_SLUG='qichiyuhub/OneServer'
ROOT='/opt/oneserver'
ETC_DIR='/etc/oneserver'
LOG_DIR='/var/log/oneserver'
BACKUP_DIR='/var/backups/oneserver'
BIN_LINKS='/usr/local/bin'
COMPLETION_DIR='/etc/bash_completion.d'
LOGROTATE_DIR='/etc/logrotate.d'

# manifest 覆盖的顶层条目。**孤儿清理只在这几项之内进行** ——
# state/ data/ secure.conf 也在 $ROOT 下，它们是运行时数据，
# 清理时碰它们等于把用户的组件记录和密码一起删了。
OWNED_TOP=('bin' 'lib' 'script' 'templates' 'packaging' 'VERSION')

REF=''
MANIFEST_SRC=''
FROM_SRC=''
ASSUME_YES=0

# --- 输出 ---------------------------------------------------------
#
# 颜色只在真 TTY 且没设 NO_COLOR 时开。这里手写是因为还没有 lib/ui.sh，
# 见文件头的说明。

C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_GRAY=''
if [[ -t 1 && -z ${NO_COLOR-} && ${TERM-} != 'dumb' ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_CYAN=$'\033[0;36m'
    C_GRAY=$'\033[90m'
fi

info() { printf '%s·%s %s\n' "${C_CYAN}" "${C_RESET}" "${1}"; }
ok() { printf '%s✓%s %s\n' "${C_GREEN}" "${C_RESET}" "${1}"; }
warn() { printf '%s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "${1}" >&2; }
err() { printf '%s✗%s %s\n' "${C_RED}" "${C_RESET}" "${1}" >&2; }
muted() { printf '%s  %s%s\n' "${C_GRAY}" "${1}" "${C_RESET}"; }
die() {
    err "${1}"
    exit "${2:-1}"
}

STAGING=''
cleanup() {
    [[ -n ${STAGING} && -d ${STAGING} ]] && rm -rf -- "${STAGING}"
    return 0
}
trap cleanup EXIT
# 中断时不做任何「回滚」：这个脚本的写入是逐文件原子替换，
# 中途停下留下的是「一半新一半旧」，而重跑一次就会把它校正回来 ——
# 猜着回滚反而可能把已经正确的文件换成旧的
trap 'err "被中断"; exit 131' INT TERM HUP

usage() {
    cat <<'EOF'
OneServer 安装器

  bash install.sh [选项]

  --ref=<tag>          从指定的 release tag 取清单（默认：最新 release）
  --manifest=<路径|URL> 直接指定 manifest.txt（离线安装 / 自建分发用）
  --from=<目录|tar.gz>  源码从本地取，不下载（离线安装）
  --yes                不询问，覆盖已有安装
  --help               显示本帮助

装完之后：oneserver --help  ·  直接敲 os 进菜单
EOF
}

# --- 参数 ---------------------------------------------------------

parse_args() {
    local a
    for a in "$@"; do
        case ${a} in
            --ref=*) REF=${a#*=} ;;
            --manifest=*) MANIFEST_SRC=${a#*=} ;;
            --from=*) FROM_SRC=${a#*=} ;;
            --yes | -y) ASSUME_YES=1 ;;
            --help | -h)
                usage
                exit 0
                ;;
            *) die "不认识的参数：${a}（--help 看用法）" 2 ;;
        esac
    done
    return 0
}

# --- 前置检查 -----------------------------------------------------

platform_supported() {
    case "${1-}" in
        debian | ubuntu) return 0 ;;
        *) return 1 ;;
    esac
}

preflight() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die '需要 root 权限：sudo bash install.sh' 4

    # bash 4.3+：本项目大量使用 `printf -v`、关联数组与 `${var,,}`
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
        die "需要 bash 4.3 或更高，当前是 ${BASH_VERSION}" 4
    fi

    # 严格解析，不 source（K12）：本仓库的硬规则是配置/系统文件不当代码执行，
    # /etc/os-release 虽是 root 拥有的发行版标准文件、风险低，但没有理由破例
    local id=''
    if [[ -r /etc/os-release ]]; then
        id=$(sed -nE 's/^ID="?([^"]*)"?$/\1/p' /etc/os-release)
    fi
    platform_supported "${id}" \
        || die "不支持的平台：${id:-未知}（仅支持 Debian / Ubuntu）" 4

    # 装依赖前先看有没有 —— 「已经有了就别动」是规范的精神，
    # 也免得在一台管理良好的机器上无端跑一次 apt
    local -a need=()
    command -v curl >/dev/null 2>&1 || need+=(curl)
    command -v tar >/dev/null 2>&1 || need+=(tar)
    command -v sha256sum >/dev/null 2>&1 || need+=(coreutils)
    [[ -e /etc/ssl/certs/ca-certificates.crt ]] || need+=(ca-certificates)
    if [[ ${#need[@]} -gt 0 ]]; then
        info "安装依赖：${need[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            || warn 'apt-get update 失败，继续尝试安装'
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}" \
            || die "装不上依赖：${need[*]}" 3
    fi
    return 0
}

# --- 取清单与源码 -------------------------------------------------

fetch_to() {
    local url=${1} dst=${2}
    # manifest 是整条信任链的锚点（它决定装哪个 commit、校验哪些哈希），
    # 而它自己没有任何校验——任何一跳返回 302 到 http:// 的响应（DNS 劫持、
    # 被攻破的镜像站、企业中间盒）curl 会安静地跟过去，此后按明文取回的
    # 清单里的 commit 与哈希装一整套以 root 运行的代码。
    curl -fsSL --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 300 -o "${dst}" "${url}"
}

obtain_manifest() {
    local dst="${STAGING}/manifest.txt"

    if [[ -n ${MANIFEST_SRC} ]]; then
        case ${MANIFEST_SRC} in
            http://*)
                die "清单地址是明文 http://，拒绝：${MANIFEST_SRC}（manifest 是整条信任链的锚点，它自己没有校验，必须走 HTTPS）" 2
                ;;
            https://*)
                info "下载清单：${MANIFEST_SRC}"
                fetch_to "${MANIFEST_SRC}" "${dst}" || die "清单下载失败：${MANIFEST_SRC}"
                ;;
            *)
                [[ -f ${MANIFEST_SRC} ]] || die "清单不存在：${MANIFEST_SRC}" 2
                cp -- "${MANIFEST_SRC}" "${dst}" || die "读不了清单：${MANIFEST_SRC}"
                ;;
        esac
        return 0
    fi

    local url
    if [[ -n ${REF} ]]; then
        url="https://github.com/${REPO_SLUG}/releases/download/${REF}/manifest.txt"
    else
        url="https://github.com/${REPO_SLUG}/releases/latest/download/manifest.txt"
    fi
    info "下载清单：${url}"
    fetch_to "${url}" "${dst}" || die "清单下载失败。还没有发布过 release 时，用 --manifest= 指定一份"
    return 0
}

# 解析清单。结果落在三个平行数组里 + 三个标量。
MF_SCHEMA='' MF_VERSION='' MF_COMMIT=''
declare -a MF_SUM=() MF_MODE=() MF_PATH=()

parse_manifest() {
    local file=${1}
    local key f1 f2 f3
    local -i lineno=0
    while IFS=$'\t' read -r key f1 f2 f3 || [[ -n ${key} ]]; do
        lineno+=1
        [[ -n ${key} ]] || continue
        [[ ${key} == '#'* ]] && continue
        case ${key} in
            schema) MF_SCHEMA=${f1} ;;
            version) MF_VERSION=${f1} ;;
            commit) MF_COMMIT=${f1} ;;
            generated) : ;;
            file)
                # 三个字段一个都不能少（字段数固定、禁止空字段）
                [[ -n ${f1} && -n ${f2} && -n ${f3} ]] \
                    || die "清单第 ${lineno} 行字段不全"
                [[ ${f1} =~ ^[0-9a-f]{64}$ ]] || die "清单第 ${lineno} 行的哈希不合法"
                [[ ${f2} =~ ^0[0-7]{3}$ ]] || die "清单第 ${lineno} 行的权限不合法：${f2}"
                # **路径必须自己再查一遍**：清单是从网上取来的，
                # `../../etc/shadow` 这种东西不能靠生成器把关
                case ${f3} in
                    /* | *..* | *' '*) die "清单第 ${lineno} 行的路径不合法：${f3}" ;;
                esac
                MF_SUM+=("${f1}")
                MF_MODE+=("${f2}")
                MF_PATH+=("${f3}")
                ;;
            *)
                # 未知前缀忽略并告警 —— 这就是「预留签名字段」的实质：
                # 老版本读新清单不会炸
                warn "清单第 ${lineno} 行的字段「${key}」本版本不认识，已忽略"
                ;;
        esac
    done <"${file}"

    [[ ${MF_SCHEMA} == 1 ]] || die "清单格式版本 ${MF_SCHEMA:-缺失} 本版本读不了（需要 1）"
    [[ -n ${MF_VERSION} ]] || die '清单缺 version'
    [[ ${MF_COMMIT} =~ ^[0-9a-f]{40}$ ]] || die "清单里的 commit 不合法：${MF_COMMIT:-缺失}"
    [[ ${#MF_PATH[@]} -gt 0 ]] || die '清单里一个文件都没有'
    return 0
}

# 源码落到 $STAGING/src，目录结构与仓库根一致
obtain_source() {
    local src="${STAGING}/src"
    mkdir -p "${src}"

    if [[ -n ${FROM_SRC} ]]; then
        if [[ -d ${FROM_SRC} ]]; then
            info "源码来自本地目录：${FROM_SRC}"
            cp -a -- "${FROM_SRC}/." "${src}/" || die "复制不了 ${FROM_SRC}"
            return 0
        fi
        [[ -f ${FROM_SRC} ]] || die "源码不存在：${FROM_SRC}" 2
        info "源码来自本地包：${FROM_SRC}"
        tar --no-same-owner --no-same-permissions -xzf "${FROM_SRC}" -C "${src}" --strip-components=1 \
            || die "解包失败：${FROM_SRC}"
        return 0
    fi

    # **按 commit SHA 下载，不按分支**：清单说了是哪个 commit，
    # 拉分支等于「清单校验的是 A，装上去的是 B」
    local url="https://codeload.github.com/${REPO_SLUG}/tar.gz/${MF_COMMIT}"
    local tgz="${STAGING}/src.tar.gz"
    info "下载源码：commit ${MF_COMMIT:0:12}"
    fetch_to "${url}" "${tgz}" || die "源码下载失败：${url}"
    tar --no-same-owner --no-same-permissions -xzf "${tgz}" -C "${src}" --strip-components=1 || die '源码解包失败'
    return 0
}

# --- 校验 ---------------------------------------------------------

verify_source() {
    local src="${STAGING}/src"
    local -i i n=${#MF_PATH[@]} bad=0
    local p sum got

    info "校验 ${n} 个文件的 SHA256"
    for ((i = 0; i < n; i++)); do
        p="${src}/${MF_PATH[i]}"
        if [[ ! -f ${p} ]]; then
            err "清单里有、包里没有：${MF_PATH[i]}"
            bad+=1
            continue
        fi
        got=$(sha256sum -- "${p}") || {
            err "算不出哈希：${MF_PATH[i]}"
            bad+=1
            continue
        }
        got=${got%% *}
        sum=${MF_SUM[i]}
        if [[ ${got} != "${sum}" ]]; then
            err "哈希对不上：${MF_PATH[i]}"
            bad+=1
        fi
    done

    # **一个对不上就整个拒绝，不允许「跳过坏的继续装」** ——
    # 那等于「让校验失败」成为绕过校验的手段（同 D97）
    ((bad == 0)) || die "${bad} 个文件没通过校验，什么都没有安装"
    ok '全部文件校验通过'
    return 0
}

# --- 安装 ---------------------------------------------------------

# 已装的版本（没装过则为空）
installed_version() {
    [[ -r "${ROOT}/VERSION" ]] || return 0
    tr -d ' \t\n\r' <"${ROOT}/VERSION"
}

confirm_overwrite() {
    local cur=${1}
    [[ -n ${cur} ]] || return 0
    if [[ ${cur} == "${MF_VERSION}" ]]; then
        info "已装 ${cur}，本次按清单校正（一致的文件不会动）"
        return 0
    fi
    info "已装 ${cur}，将换成 ${MF_VERSION}"
    [[ ${ASSUME_YES} -eq 1 ]] && return 0
    if [[ ! -t 0 ]]; then
        # `curl | bash` 时 stdin 是管道，问不了 —— 这种场景默认继续，
        # 因为用户敲那条命令本身就是「我要装」的意思
        warn '非交互，直接继续（要跳过确认可显式加 --yes）'
        return 0
    fi
    local reply=''
    printf '%s?%s 继续？[Y/n] ' "${C_YELLOW}" "${C_RESET}"
    IFS= read -r reply || true
    case ${reply,,} in
        '' | y | yes) return 0 ;;
        *) die '已取消' 130 ;;
    esac
}

# 逐文件原子替换（临时文件 + mv 换 inode）。
#
# **绝不能用 `install -m` 或 `cp` 直写目标**：被替换的往往正是**正在跑的**
# 那个文件 —— bash 会从旧偏移量继续读一个内容已变的文件，以 root 执行错乱
# 的字节（K13 就是这个形态）。
# 目标路径与它在 $ROOT 之下的每一级父目录都不许是符号链接。
#
# 这棵树里的每个脚本此后都会以 root 被执行，而 `mkdir -p` 与 `cp` 都会跟随
# 符号链接：某一级被换成链接，写入就落到了别人选的位置。**逐级 lstat**，
# 不是只看最后那一段 —— 中间任意一级都够用。
assert_no_symlink() {
    local rel=${1} cur=${ROOT} seg
    [[ ! -L ${ROOT} ]] || die "${ROOT} 是符号链接，拒绝安装"
    local IFS='/'
    for seg in ${rel}; do
        [[ -n ${seg} ]] || continue
        cur="${cur}/${seg}"
        [[ ! -L ${cur} ]] || die "${cur} 是符号链接，拒绝安装（程序目录里的每个文件都会以 root 执行）"
    done
    return 0
}

place_files() {
    local src="${STAGING}/src"
    local -i i n=${#MF_PATH[@]} changed=0 same=0
    local rel dst tmp links

    for ((i = 0; i < n; i++)); do
        rel=${MF_PATH[i]}
        dst="${ROOT}/${rel}"
        assert_no_symlink "${rel}"
        mkdir -p -- "${dst%/*}" || die "建不了目录 ${dst%/*}"

        # 内容一致就只校正元数据，不换 inode（规范：已是目标状态不产生变更）。
        #
        # **属主也要校正，不只是权限。** 这条分支从前只 chmod，于是一棵属主被
        # 改过的树重装之后属主仍然不对 —— 而「装、修、重装是同一条代码路径」
        # 正是这个安装器的定位，修不回来就等于修复模式失效。
        #
        # **硬链接数不为 1 时改走换 inode 那条路**：`chmod`/`chown` 作用于
        # inode，而另一条路径指向同一个 inode 时，那边的权限会跟着一起变。
        links=$(stat -c '%h' -- "${dst}" 2>/dev/null || printf '1')
        if [[ -f ${dst} && ${links} == 1 ]] && cmp -s -- "${src}/${rel}" "${dst}"; then
            chmod "${MF_MODE[i]}" -- "${dst}" 2>/dev/null || true
            chown root:root -- "${dst}" 2>/dev/null || true
            same+=1
            continue
        fi

        # 临时名走 mktemp，不拼 `$$`（同 lib/template.sh 的 template::_place）：
        # PID 可以喷洒预置，而 mktemp 走 O_EXCL|O_CREAT，路径已存在就失败
        tmp=$(mktemp "${dst}.install.XXXXXXXX") || die "建不了临时文件 ${rel}"
        cp -- "${src}/${rel}" "${tmp}" || die "复制不了 ${rel}"
        chmod "${MF_MODE[i]}" -- "${tmp}" || die "改不了权限 ${rel}"
        chown root:root -- "${tmp}" || die "改不了属主 ${rel}"
        mv -f -- "${tmp}" "${dst}" || die "换不上 ${rel}"
        changed+=1
    done

    # 目录的属主与权限也要校正，不只是顶层那几个。
    #
    # `setup_dirs` 只管 $ROOT 与几个系统目录；`mkdir -p` 在这里新建的嵌套目录
    # （script/install/、packaging/systemd/ …）此前无人过问属主。一个非 root
    # 属主、或组/其他可写的目录，等于让别人能替换里面那些以 root 执行的脚本 ——
    # 而重装本该把这种状态修回来。
    find "${ROOT}/bin" "${ROOT}/lib" "${ROOT}/script" "${ROOT}/templates" \
        "${ROOT}/packaging" -type d -exec chown root:root -- {} + 2>/dev/null || true
    find "${ROOT}/bin" "${ROOT}/lib" "${ROOT}/script" "${ROOT}/templates" \
        "${ROOT}/packaging" -type d -exec chmod go-w -- {} + 2>/dev/null || true

    ok "文件就位：${changed} 个更新 · ${same} 个已是目标状态"
    return 0
}

# 上一版有、这一版没有的文件要删掉（计划 5.5：不留孤儿脚本）。
#
# 留着的后果不是占地方：一个被删掉的旧脚本仍然带着 `@command`，
# 注册表照样把它扫出来，于是用户在菜单里看到一条**本版本已经不存在**的命令。
remove_orphans() {
    local -A keep=()
    local rel top
    for rel in "${MF_PATH[@]}"; do
        keep["${rel}"]=1
    done

    local -i removed=0
    local f
    for top in "${OWNED_TOP[@]}"; do
        [[ -e "${ROOT}/${top}" ]] || continue
        [[ -d "${ROOT}/${top}" ]] || continue
        while IFS= read -r f; do
            rel=${f#"${ROOT}/"}
            [[ -n ${keep[${rel}]-} ]] && continue
            rm -f -- "${f}" && removed+=1
        done < <(find "${ROOT}/${top}" -type f)
        # 空目录一并收掉，否则删完一批脚本会留下一串空壳目录
        find "${ROOT}/${top}" -type d -empty -delete 2>/dev/null || true
    done

    ((removed > 0)) && info "清掉 ${removed} 个不属于本版本的文件"
    return 0
}

setup_dirs() {
    # **没有 ${ROOT}/public**：probe 快照与面板数据在 /run/oneserver-public
    # （tmpfs），由采集器与框架自己建。这里再建一个同名目录，落下的是一个
    # 谁也不写、却全局可读的空壳 —— 卸载时还得记得清它
    # data/ 与 state/ 分开：前者是工具自己的运行数据（面板历史、告警去重基线），
    # 丢了只是可惜；后者是组件清单，卸载按它反向执行。**必须在这里建出来**——
    # 面板的 unit 用 ReadWritePaths 精确列了它，而挂命名空间发生在 ExecStart
    # 之前，路径不存在就是 226/NAMESPACE，进程根本起不来
    mkdir -p "${ROOT}" "${ETC_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${ROOT}/state" "${ROOT}/data"
    chown root:root "${ROOT}" "${ETC_DIR}" "${LOG_DIR}" "${BACKUP_DIR}" "${ROOT}/state" "${ROOT}/data"
    chmod 0755 "${ROOT}"
    chmod 0750 "${ETC_DIR}" "${LOG_DIR}"
    chmod 0700 "${BACKUP_DIR}"
    chmod 0750 "${ROOT}/state" "${ROOT}/data"
    # 早先的版本在这里建过 ${ROOT}/public。它不在 OWNED_TOP 里，remove_orphans
    # 扫不到，装过那些版本的机器会一直留着一个空的全局可读目录。只在它确实空着
    # 时收掉 —— 万一有人往里放过东西，那是他的文件，不归安装器处置
    rmdir "${ROOT}/public" 2>/dev/null || true

    # secure.conf 只建一个 0600 的空壳，**不覆盖已有的** ——
    # 里面是这台机器上所有自动生成的密码
    if [[ ! -e "${ROOT}/secure.conf" ]]; then
        : >"${ROOT}/secure.conf"
        chmod 0600 "${ROOT}/secure.conf"
    fi
    return 0
}

setup_entrypoints() {
    # `os` 是 `oneserver` 的符号链接，两者行为完全一致。
    ln -sfn "${ROOT}/bin/oneserver" "${BIN_LINKS}/oneserver"
    ln -sfn "${ROOT}/bin/oneserver" "${BIN_LINKS}/os"
    ok "入口就位：${BIN_LINKS}/oneserver 与 ${BIN_LINKS}/os"

    # 补全是**动态**的（D86）：这份文件每次按 Tab 回头问 oneserver __complete，
    # 所以它随分发落地一次就够，不需要在每次加命令后重新生成。
    #
    # **目录不在也要建**：最小安装的 Debian 没装 bash-completion，
    # /etc/bash_completion.d 因此不存在 —— 「有目录才装」的写法会让这些机器
    # 永远没有补全，而且没有任何提示。放进去的文件在装上 bash-completion
    # 的那一刻自动生效，装不上也只是一个惰性文件，代价为零
    if [[ -f "${ROOT}/packaging/completion/oneserver.bash" ]]; then
        mkdir -p "${COMPLETION_DIR}"
        cp -- "${ROOT}/packaging/completion/oneserver.bash" "${COMPLETION_DIR}/oneserver"
        chmod 0644 "${COMPLETION_DIR}/oneserver"
        ok "bash 补全已装（新开一个 shell 生效）"
    fi

    if [[ -d ${LOGROTATE_DIR} && -f "${ROOT}/packaging/logrotate/oneserver" ]]; then
        cp -- "${ROOT}/packaging/logrotate/oneserver" "${LOGROTATE_DIR}/oneserver"
        chmod 0644 "${LOGROTATE_DIR}/oneserver"
    fi
    return 0
}

# 装完立刻自检：**装上一个跑不起来的版本，比装不上更糟**
selfcheck() {
    if ! "${ROOT}/bin/oneserver" --help >/dev/null 2>&1; then
        err '装完之后 oneserver --help 跑不起来'
        muted "手动看一眼：${ROOT}/bin/oneserver --help"
        return 1
    fi
    ok '自检通过（oneserver --help 可执行）'
    return 0
}

# --- 主流程 -------------------------------------------------------

main() {
    parse_args "$@"
    preflight

    STAGING=$(mktemp -d /tmp/oneserver-install.XXXXXXXX) || die '建不了临时目录'
    chmod 0700 "${STAGING}"

    obtain_manifest
    parse_manifest "${STAGING}/manifest.txt"
    info "清单：版本 ${MF_VERSION} · commit ${MF_COMMIT:0:12} · ${#MF_PATH[@]} 个文件"

    obtain_source
    verify_source

    local cur
    cur=$(installed_version)
    confirm_overwrite "${cur}"

    setup_dirs
    place_files
    remove_orphans
    setup_entrypoints
    selfcheck || die '安装完成但自检失败，请按上面的提示排查'

    printf '\n'
    ok "OneServer ${MF_VERSION} 安装完成"
    muted '敲 os 进菜单，或 oneserver --help 看全部命令'
    muted '第一件该做的事：oneserver safe status'
    return 0
}

main "$@"
