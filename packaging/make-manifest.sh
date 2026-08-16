#!/bin/bash
#
# 生成分发清单 manifest.txt
#
#   bash packaging/make-manifest.sh [输出路径]        默认写到 ./manifest.txt
#
# **这是发布期工具，不是命令脚本**：它跑在开发机 / CI 上，不随分发落到用户机器，
# 因此没有元数据头、不 source lib/bootstrap.sh（那需要 /opt/oneserver 存在）。
# 规范管的是 `script/**`，规范管的是 `lib/**`，这里两者都不属于。
# 但 shellcheck 与 shfmt 照样管得到它（tests/lint.sh 收全部 *.sh）。
#
# --- 为什么清单是**生成**的，不是手写的 ---
#
# 旧 `script/script_list.txt` 是手写的，于是它天然会漂：删掉一个脚本没人记得
# 改它，新增一个脚本忘了加就永远发不出去。清单必须由「仓库里实际有什么」推导，
# 这样它不可能与事实不符。
#
# --- 为什么权限取自 git 索引而不是文件系统 ---
#
# 开发机是 Windows，工作区的执行位是假的（全 0755 或全 0644 取决于挂载方式）。
# git 索引里的 100755 / 100644 才是真相 —— `tests/lint.sh` 的「可执行位」检查
# 也是认索引不认工作区，两处必须一致。

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# **这里不写死 PATH**（规范的文件头是给 `script/**` 定的）：
# 这个工具要在开发机上跑，而开发机是 Windows + Git Bash —— git 在
# /mingw64/bin，写死 `/usr/sbin:/usr/bin:/sbin:/bin` 的后果是它当场
# 报「不在 git 仓库里」，而真因是找不到 git（第一次跑就撞上了）。
# 服务器脚本写死 PATH 是为了防 PATH 劫持提权；这个工具不以 root 跑、
# 不落到用户机器上，那条威胁不成立。

MANIFEST_SCHEMA=1

die() {
    printf 'make-manifest: %s\n' "${1}" >&2
    exit 1
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die '不在 git 仓库里 —— 清单必须由仓库内容推导，不接受手工目录'
cd "${repo_root}" || die "进不去 ${repo_root}"

out=${1:-${repo_root}/manifest.txt}

[[ -f VERSION ]] || die '缺少 VERSION 文件'
version=$(tr -d ' \t\n\r' <VERSION)
[[ -n ${version} ]] || die 'VERSION 是空的'

commit=$(git rev-parse HEAD 2>/dev/null) || die '取不到 HEAD 的 commit'
[[ ${commit} =~ ^[0-9a-f]{40}$ ]] || die "commit 不是 40 位十六进制：${commit}"

# 工作区脏的时候照样生成，但要说出来：清单里的 commit 指的是 HEAD，
# 而文件的哈希取自工作区 —— 两者不一致的清单发出去，用户按 commit 下载的
# tar 包会对不上哈希，而现场表现是「校验失败」，查起来毫无头绪。
# 工作区脏就**拒绝**，不是警告。
#
# 清单里的 commit 记的是 HEAD，而文件哈希取自工作区——两者不一致的清单发出去，
# 用户按 commit 从 GitHub 下回来的 tar 包必然对不上哈希，现场表现是「校验失败」
# 且毫无头绪。这正是清单要提供的完整性保证本身失效。
#
# 从前这里只打一行警告然后照常生成。发布是不可逆的（Release 一旦建好，
# 用户端 install/update 立刻开始用它），而一行警告在 CI 日志里滚过去没人看见。
# 供应链的门槛不该由「记得看警告」来守。
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    printf 'make-manifest: 工作区有未提交的改动，拒绝生成清单\n' >&2
    printf '  清单里的 commit 是 %s，而哈希取自工作区，两者对不上。\n' "${commit:0:12}" >&2
    printf '  用户按 commit 下载的源码包会校验失败，且看不出原因。\n' >&2
    printf '  先提交（或 git stash），再生成清单。\n' >&2
    exit 1
fi

# 覆盖范围：分发物 = 用户机器上真正会用到的东西。
# docs/ 与 tests/ 不进 —— 它们不影响运行，而每多一个文件就多一处哈希要对。
declare -a patterns=(
    'VERSION'
    'install.sh'
    # 卸载器必须随分发落地：装机的人多半是 curl 一条命令进来的，手上没有仓库。
    # 它故意不在 script/ 下（那里的东西一律进菜单），入口是 README 里的一行
    'uninstall.sh'
    'bin/*'
    'lib/*'
    'script/*'
    'templates/*'
    'packaging/*'
)

# `git ls-files` 会把子目录也展开（script/install/xxx.sh），不需要自己递归。
# -s 一并给出索引模式，省掉第二次调用。
declare -a rows=()
while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    # 格式：<模式> <对象> <暂存号>\t<路径>
    mode=${line%% *}
    path=${line#*$'\t'}

    case ${path} in
        packaging/make-manifest.sh) continue ;; # 发布期工具，不随分发落地
        *' '*) die "路径含空白，清单格式不支持：${path}" ;;
        *..*) die "路径含 ..：${path}" ;;
    esac
    [[ -f ${path} ]] || die "git 里有但工作区没有：${path}"

    case ${mode} in
        100755) perm='0755' ;;
        100644) perm='0644' ;;
        120000) die "清单不收符号链接：${path}（分发物里出现链接会让原子切换的语义变模糊）" ;;
        *) die "不认识的索引模式 ${mode}：${path}" ;;
    esac

    sum=$(sha256sum -- "${path}") || die "算不出哈希：${path}"
    sum=${sum%% *}
    rows+=("$(printf 'file\t%s\t%s\t%s' "${sum}" "${perm}" "${path}")")
done < <(git ls-files -s -- "${patterns[@]}")

[[ ${#rows[@]} -gt 0 ]] || die '一个文件都没收到，清单不该是空的'

now=$(date -u +%s)

# 写临时文件再 mv 换 inode：清单可能正被另一个进程读
tmp="${out}.tmp.$$"
{
    printf 'schema\t%s\n' "${MANIFEST_SCHEMA}"
    printf 'version\t%s\n' "${version}"
    printf 'commit\t%s\n' "${commit}"
    printf 'generated\t%s\n' "${now}"
    printf '%s\n' "${rows[@]}"
} >"${tmp}" || die "写不了 ${tmp}"
chmod 0644 "${tmp}" 2>/dev/null || true
mv -f -- "${tmp}" "${out}" || die "换不上 ${out}"

printf 'manifest: %s\n' "${out}"
printf '  版本   %s\n' "${version}"
printf '  commit %s\n' "${commit}"
printf '  文件   %d 个\n' "${#rows[@]}"
