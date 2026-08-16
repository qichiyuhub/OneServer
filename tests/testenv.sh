#!/usr/bin/env bash
#
# OneServer 可重置测试环境（F0.3）
#
# 在 podman 宿主上起一个带 systemd 的一次性容器。镜像构建完成后，
# `reset` 拿到一个干净系统只需数秒。
#
# 两种运行模式，自动判断：
#   本地  宿主上有 podman            —— 直接跑
#   远程  没有 podman（如 Windows）  —— 把工作区同步到 ${TESTENV_HOST} 后经 ssh 执行
#
# 环境变量：
#   TESTENV_HOST        远程宿主（默认 myrule-validator）
#   TESTENV_REMOTE_SRC  远程工作区路径（默认 /root/oneserver-src）
#   TESTENV_LOCAL=1     强制本地模式，不做远程转发
#
# 本脚本是开发工具；功能脚本约束见 docs/TECHNICAL_SPEC.md。
# 但同样遵守：无 ANSI 序列、错误进 stderr、shellcheck 零告警。

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly IMAGE_PREFIX="oneserver-testenv"
readonly CTR_PREFIX="oneserver-test"
# 数组而非空格分隔字符串：上面把 IFS 设成了 $'\n\t'，字符串在 for 里不按空格分词
declare -ra DISTROS=(debian13 ubuntu2404 ubuntu2604)

TESTENV_HOST="${TESTENV_HOST:-myrule-validator}"
TESTENV_REMOTE_SRC="${TESTENV_REMOTE_SRC:-/root/oneserver-src}"

# --- 输出 ---

die() {
    printf 'testenv: 错误: %s\n' "$*" >&2
    exit 1
}

note() {
    printf 'testenv: %s\n' "$*" >&2
}

# --- 发行版表 ---

distro_base() {
    case "${1}" in
        debian13) printf '%s\n' "docker.io/library/debian:13" ;;
        ubuntu2404) printf '%s\n' "docker.io/library/ubuntu:24.04" ;;
        ubuntu2604) printf '%s\n' "docker.io/library/ubuntu:26.04" ;;
        *) die "未知发行版 '${1}'，可用：${DISTROS[*]}" ;;
    esac
}

image_of() { printf '%s\n' "${IMAGE_PREFIX}:${1}"; }
ctr_of() { printf '%s\n' "${CTR_PREFIX}-${1}"; }

# --- 远程转发 ---
#
# 没有 podman 就把整个工作区打包送到 TESTENV_HOST，再在那边用同一份脚本执行。
# 用 tar 而不是 rsync：Git Bash 自带 tar，不带 rsync。

sync_src() {
    local dst
    dst="$(printf '%q' "${TESTENV_REMOTE_SRC}")"
    note "同步工作区 → ${TESTENV_HOST}:${TESTENV_REMOTE_SRC}"
    tar -cf - -C "${REPO_ROOT}" \
        --exclude=.git \
        --exclude=tests/.tmp \
        . \
        | {
            # shellcheck disable=SC2029  # 理由：dst 就是要在本地展开后送到远端，已用 %q 转义
            ssh "${TESTENV_HOST}" "mkdir -p ${dst} && tar -xf - -C ${dst}"
        }
}

remote_exec() {
    # 逐个拼接而不是 "${arr[*]}"：脚本开头把 IFS 设成了 $'\n\t'，
    # 数组的 * 展开会用 IFS 首字符（换行）连接，拼出来的命令行会散成多行。
    local cmd="TESTENV_LOCAL=1 bash ${TESTENV_REMOTE_SRC}/tests/testenv.sh"
    local arg
    for arg in "$@"; do
        cmd+=" $(printf '%q' "${arg}")"
    done

    sync_src
    note "在 ${TESTENV_HOST} 上执行 testenv.sh ${1}"
    # -t 让 `shell` 子命令拿得到交互式终端
    ssh -t "${TESTENV_HOST}" "${cmd}"
}

# --- podman 前置 ---

require_podman() {
    command -v podman >/dev/null 2>&1 \
        || die "宿主上没有 podman。Debian/Ubuntu 装法：apt-get install -y podman"
    command -v timeout >/dev/null 2>&1 \
        || die "宿主上没有 timeout。Debian/Ubuntu 装法：apt-get install -y coreutils"
}

ctr_exists() {
    podman container exists "$(ctr_of "${1}")"
}

ctr_running() {
    [[ "$(timeout 5s podman inspect -f '{{.State.Running}}' "$(ctr_of "${1}")" 2>/dev/null || true)" == "true" ]]
}

# --- 子命令 ---

cmd_build() {
    require_podman
    local -a pull_flag=()
    if [[ "${1:-}" == "--pull" ]]; then
        pull_flag=(--pull=always)
        shift
    fi

    local -a targets=("$@")
    [[ ${#targets[@]} -gt 0 ]] || targets=("${DISTROS[@]}")
    local d
    for d in "${targets[@]}"; do
        local base image
        base="$(distro_base "${d}")"
        image="$(image_of "${d}")"
        note "构建 ${image}（基于 ${base}）"
        # 构建阶段沿用宿主网络：不少测试宿主的 DNS 由 VPN/虚拟网卡提供，
        # Podman 默认 build 网络拿不到同一解析路径，会在 apt-get update 处假失败。
        # 这里只下载公开测试依赖，不承载生产凭据或不可信构建参数。
        podman build --network=host "${pull_flag[@]}" \
            --build-arg "BASE=${base}" \
            -t "${image}" \
            -f "${REPO_ROOT}/tests/containers/Containerfile" \
            "${REPO_ROOT}/tests/containers"
    done
}

# 就绪判定交给容器里的 systemd 自己：`is-system-running --wait` 阻塞到启动
# 队列排空，一次 exec 就够，不用轮询。
#
# 不用 podman 原生 healthcheck：它靠宿主上的临时 systemd timer 驱动，
# 而 GitHub Actions 的 runner 上这个 timer 不触发 —— 容器早已 multi-user.target
# 就绪，State.Health 却一直停在 starting、Log 为 null（一次都没执行过）。
wait_systemd_ready() {
    local ctr="${1}"
    local state="" deadline=$((SECONDS + 120))

    note "等待容器内 systemd 启动完成…"
    while ((SECONDS < deadline)); do
        # systemd 刚起来时私有套接字还没建好，systemctl 会立刻失败退出，
        # 所以 --wait 外面还要套一层重试。
        state="$(timeout 60s podman exec "${ctr}" systemctl is-system-running --wait 2>/dev/null || true)"
        case "${state}" in
            running) return 0 ;;
            degraded)
                note "systemd 状态：degraded（有 unit 未起来，容器里属正常）"
                timeout 5s podman exec "${ctr}" systemctl list-units --failed --no-legend --no-pager >&2 || true
                return 0
                ;;
        esac
        sleep 1
    done
    note "${ctr} systemd 未就绪，最后状态：${state:-无响应}"
    return 1
}

systemd_diagnostics() {
    local ctr="${1}"
    note "${ctr} 启动诊断："
    timeout 5s podman logs --tail 200 "${ctr}" >&2 || true
    timeout 5s podman exec "${ctr}" systemctl list-jobs --no-pager >&2 || true
    timeout 5s podman exec "${ctr}" systemctl list-units --failed --no-legend --no-pager >&2 || true
    timeout 5s podman exec "${ctr}" journalctl -b -n 200 --no-pager >&2 || true
}

cmd_up() {
    require_podman
    local d="${1:?用法: testenv.sh up <distro>}"
    local image ctr
    local -i retry="${2:-1}"
    image="$(image_of "${d}")"
    ctr="$(ctr_of "${d}")"

    podman image exists "${image}" || cmd_build "${d}"

    if ctr_exists "${d}"; then
        if ctr_running "${d}"; then
            note "${ctr} 已在运行（要干净系统请用 reset）"
        else
            podman start "${ctr}" >/dev/null
        fi
    else
        # --privileged：OneServer 要动 systemd unit、ufw/nftables、sysctl。
        # 逐个 cap 放行等于把「工具在真 VPS 上能干什么」重新定义一遍，
        # 测出来的行为就不是生产行为了。容器是一次性的，这里选真实性。
        podman run -d \
            --name "${ctr}" \
            --hostname "${d}" \
            --systemd=always \
            --privileged \
            --volume "${REPO_ROOT}:/src:ro" \
            "${image}" >/dev/null
    fi

    if ! wait_systemd_ready "${ctr}"; then
        systemd_diagnostics "${ctr}"
        if ((retry)); then
            note "${ctr} 首次启动失败，重建后再试一次"
            cmd_rm "${d}"
            cmd_up "${d}" 0
            return 0
        fi
        die "${ctr} 重建后 systemd 仍未就绪"
    fi

    note "${ctr} 就绪，源码挂在 /src（只读）"
}

cmd_reset() {
    require_podman
    local d="${1:?用法: testenv.sh reset <distro>}"
    cmd_rm "${d}"
    cmd_up "${d}"
}

cmd_rm() {
    require_podman
    local d="${1:?用法: testenv.sh rm <distro>}"
    if ctr_exists "${d}"; then
        note "销毁 $(ctr_of "${d}")"
        podman rm -f -t 3 "$(ctr_of "${d}")" >/dev/null
    fi
}

cmd_down() {
    require_podman
    local d
    for d in "${DISTROS[@]}"; do cmd_rm "${d}"; done
}

cmd_shell() {
    require_podman
    local d="${1:?用法: testenv.sh shell <distro>}"
    ctr_running "${d}" || cmd_up "${d}"
    exec podman exec -it "$(ctr_of "${d}")" bash -l
}

cmd_exec() {
    require_podman
    local d="${1:?用法: testenv.sh exec <distro> <命令...>}"
    shift
    [[ $# -gt 0 ]] || die "exec 需要一个命令"
    ctr_running "${d}" || cmd_up "${d}"
    exec podman exec "$(ctr_of "${d}")" "$@"
}

cmd_list() {
    require_podman
    local d
    for d in "${DISTROS[@]}"; do
        local img_state="无" ctr_state="无"
        podman image exists "$(image_of "${d}")" && img_state="有"
        if ctr_exists "${d}"; then
            ctr_state="停止"
            ctr_running "${d}" && ctr_state="运行中"
        fi
        # 只对 ASCII 的发行版名用宽度符：printf 按字节补齐，中文字段一补必歪
        printf '%-12s 镜像 %s · 容器 %s\n' "${d}" "${img_state}" "${ctr_state}"
    done
}

cmd_doctor() {
    printf '宿主        : %s\n' "$(uname -srm)"
    if command -v podman >/dev/null 2>&1; then
        printf 'podman      : %s\n' "$(podman --version)"
    else
        printf 'podman      : 未安装\n'
    fi
    printf '工作区      : %s\n' "${REPO_ROOT}"
    printf '远程宿主    : %s\n' "${TESTENV_HOST}"
    printf '可用发行版  : %s\n' "${DISTROS[*]}"
}

usage() {
    cat <<'EOF'
用法: tests/testenv.sh <子命令> [参数]

  build [--pull] [distro...]   构建镜像（缺省构建全部）
  up <distro>                  起容器（不存在则建）
  reset <distro>               销毁重建 —— 拿到干净系统
  shell <distro>               进容器的 root shell
  exec <distro> <命令...>      在容器里执行命令
  rm <distro>                  销毁单个容器
  down                         销毁全部容器
  list                         列出镜像与容器状态
  sync                         只同步工作区到远程宿主
  doctor                       打印环境信息

发行版: debian13 ubuntu2404 ubuntu2604

例:
  bash tests/testenv.sh build
  bash tests/testenv.sh reset debian13
  bash tests/testenv.sh exec debian13 bash /src/install.sh
EOF
}

main() {
    local sub="${1:-}"
    [[ -n "${sub}" ]] || {
        usage
        exit 2
    }
    shift

    case "${sub}" in
        -h | --help | help)
            usage
            return 0
            ;;
        doctor)
            cmd_doctor
            return 0
            ;;
    esac

    # 没有 podman 且没强制本地 —— 转发到远程宿主
    if [[ "${TESTENV_LOCAL:-}" != "1" ]] && ! command -v podman >/dev/null 2>&1; then
        [[ "${sub}" == "sync" ]] && {
            sync_src
            return 0
        }
        remote_exec "${sub}" "$@"
        return
    fi

    case "${sub}" in
        build) cmd_build "$@" ;;
        up) cmd_up "$@" ;;
        reset) cmd_reset "$@" ;;
        rm) cmd_rm "$@" ;;
        down) cmd_down ;;
        shell) cmd_shell "$@" ;;
        exec) cmd_exec "$@" ;;
        list) cmd_list ;;
        sync) note "本地模式，无需同步" ;;
        *) die "未知子命令 '${sub}'，用 --help 查看用法" ;;
    esac
}

main "$@"
