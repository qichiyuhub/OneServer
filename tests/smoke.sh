#!/usr/bin/env bash
# 安装后命令发现 smoke：逐条验证注册表里的命令能走到自己的帮助页。

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ONESERVER_BIN='/opt/oneserver/bin/oneserver'

[[ -x ${ONESERVER_BIN} ]] || {
    printf 'smoke: 找不到已安装入口 %s\n' "${ONESERVER_BIN}" >&2
    exit 1
}

declare -a commands=()
while IFS= read -r command; do
    [[ -n ${command} ]] && commands+=("${command}")
done < <(sed -nE 's/^#[[:space:]]*@command[[:space:]]+(.+[^[:space:]])[[:space:]]*$/\1/p' \
    "${REPO_ROOT}"/script/*/*.sh | sort -u)

[[ ${#commands[@]} -gt 0 ]] || {
    printf 'smoke: 源码里没有发现任何 @command\n' >&2
    exit 1
}

# 先报名字再跑：挂住时日志最后一行就是罪魁。走 stderr，stdout 留给末尾总结。
for command in "${commands[@]}"; do
    IFS=' ' read -r -a words <<<"${command}"
    printf 'smoke: %s\n' "${command}" >&2
    "${ONESERVER_BIN}" "${words[@]}" --help >/dev/null

    # 第二条路径走真实 bootstrap、平台检查、依赖检查和非交互参数契约，但用
    # dry-run 保证不会安装/启停/覆盖。不同命令在空系统上的合理结果可以是
    # 成功、参数错、缺依赖或环境不满足；关键是不能崩溃或泄漏外部退出码。
    rc=0
    "${ONESERVER_BIN}" "${words[@]}" --dry-run --non-interactive \
        >/dev/null 2>&1 || rc=$?
    case ${rc} in
        0 | 1 | 2 | 3 | 4 | 5 | 130 | 131) ;;
        *)
            printf 'smoke: %s 泄漏了未定义退出码 %d\n' "${command}" "${rc}" >&2
            exit 1
            ;;
    esac
done

# 校验安装后的真实权限与路径；Windows/WSL 的只读源码挂载可能把源文件呈现为
# 0777，logrotate 会在解析内容前先拒绝它，测不到分发真正落地的 0644 文件。
logrotate --debug /etc/logrotate.d/oneserver >/dev/null

printf 'smoke: %d 条命令的安装、发现、帮助、dry-run 与退出码契约均可达\n' "${#commands[@]}"
