#!/bin/bash
#
# 更新 OneServer 自身
#
# @command      update
# @name         脚本更新
# @group        toolbox
# @order        10
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<status|run|check|rollback>] [--ref=<tag>] [--manifest=<路径|URL>] [--from=<目录|tar.gz>] [--force] [--confirm-rollback=<y|n>]
# @description  按清单更新到新版本，原子切换，自检不过回滚
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 这个脚本只干阶段 1 与阶段 2
# ==================================================================
#
#   阶段 1  下载到 .staging → 校验 → 取锁      ← 这里
#   阶段 2  把切换器复制到 /run → exec 它      ← 这里
#   阶段 3  切换器：原子换目录 → 跑自检        ← packaging/updater.sh
#   阶段 4  切换器：自检不过就地回滚           ← packaging/updater.sh
#
# **它自己绝不动 `lib/`**。原因写在切换器的文件头上：本进程启动时已经把旧版本
# 的 lib 读进内存，替换之后它执行的是旧函数、操作的是新布局，行为未定义。
# 所以这里做完校验就 `exec` 出去，把替换交给一个站在两个版本之外的进程。
#
# 锁：bootstrap 已按规范取了全局锁，fd 经 `exec` 继承给切换器 ——
# 整个更新期间不可能有第二个 oneserver 进程在跑。
#
# --- 与 install.sh 的重复 ---
#
# 「取清单 → 解析 → 校验哈希」这段两边各有一份。**这是第二次，按「两处相似
# 不提取，第三次才提取」不动它**，而且这两份的处境本来就不同：install.sh
# 跑在还没有 lib 的机器上，只能自己写；这里能用 os::run / os::query，
# 写法与它并不一样。硬凑成一份的代价是 install.sh 要去 source 它更新出来的
# 那个 lib —— 那正是本文件开头说的未定义行为。

# 与 install.sh 的 OWNED_TOP、packaging/updater.sh 的 TOP_ORDER 必须一致：
# 清单覆盖哪些，校验与切换就该管哪些。
#
# 清单还覆盖三个根级文件（VERSION / install.sh / uninstall.sh），它们由切换器
# 的 TOP_FILES 换。这里不需要列它们：remove_staging_orphans 的 keep 集合来自
# MF_PATH，本来就含它们；要清的只是「目录里有、清单里没有」的那些。
readonly -a UPDATE_TOP=('lib' 'templates' 'packaging' 'script' 'bin')

readonly STAGING="${OS_ROOT}/.staging"
readonly UPDATER_SRC="${OS_ROOT}/packaging/updater.sh"

# 切换器的落脚点。**必须是能执行的文件系统，因此不能是 /run。**
#
# 规范 §13 原本写「复制到 /run 再 exec 它」，而 §4.2 同一份文件里就写着
# 「/run 挂 noexec，要现场执行的临时文件放 /var/tmp/oneserver」——两节自相
# 矛盾，而实现照 §13 写了。实测 Debian 13 与 Ubuntu 24.04 的 /run 都是
# `rw,nosuid,nodev,noexec`，于是 `oneserver update run` **在两个受支持的
# 发行版上都跑不完**：切换器复制过去、执行位给了，exec 仍然
# `Permission denied`。更新通道是所有安全修复的投递路径，它断了等于修复发不
# 出去。规范已按 §4.2 那一节校正。
#
# 用 os::tmpdir --exec 而不是自己拼路径：它替我们做了三件必须做的事——
# 校验 /var/tmp/oneserver 属主是 root（那目录全局可写且带 sticky，本地用户
# 能抢先建）、当场验一次真的能执行、目录建成 0700。
OS_UPDATER_RUN=''
readonly IN_PROGRESS="${OS_ROOT}/.update-in-progress"

# check 与 run 问的是同一个字段，说明只写一份：各写一句的结果是同一个东西
# 在两处有两种解释。「清单」是本项目内部的词，用户屏幕上必须有人解释它
readonly MANIFEST_HINT='清单＝版本号与文件校验码；平时不填，离线更新填本地路径 /tmp/manifest.txt'

MF_SCHEMA='' MF_VERSION='' MF_COMMIT=''
declare -a MF_SUM=() MF_MODE=() MF_PATH=()

# ------------------------------------------------------------------

# 读某棵树的 VERSION，结果写进调用方给的变量（D135）。
# 收一个路径参数是为了同时问「现在跑的是哪版」与「回滚会退回哪版」——
# 后者是用户在按下确认之前唯一想知道的事，而它就在 .old/VERSION 里
version_of() {
    local __up_out=${1} __up_file=${2}
    local __up_v=''
    [[ -r ${__up_file} ]] && __up_v=$(tr -d ' \t\n\r' <"${__up_file}")
    printf -v "${__up_out}" '%s' "${__up_v}"
    return 0
}

# 解析清单。校验规则与 install.sh 那份一致 ——
# **路径必须自己再查一遍**：清单是从网上取来的，`../../etc/shadow` 这种东西
# 不能靠生成器把关。
parse_manifest() {
    local file=${1}
    MF_SCHEMA='' MF_VERSION='' MF_COMMIT=''
    MF_SUM=() MF_MODE=() MF_PATH=()

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
                [[ -n ${f1} && -n ${f2} && -n ${f3} ]] || os::die 1 "清单第 ${lineno} 行字段不全"
                [[ ${f1} =~ ^[0-9a-f]{64}$ ]] || os::die 1 "清单第 ${lineno} 行的哈希不合法"
                [[ ${f2} =~ ^0[0-7]{3}$ ]] || os::die 1 "清单第 ${lineno} 行的权限不合法"
                case ${f3} in
                    /* | *..* | *' '*) os::die 1 "清单第 ${lineno} 行的路径不合法：${f3}" ;;
                esac
                MF_SUM+=("${f1}")
                MF_MODE+=("${f2}")
                MF_PATH+=("${f3}")
                ;;
            *) os::warn "清单第 ${lineno} 行的字段「${key}」本版本不认识，已忽略" ;;
        esac
    done <"${file}"

    [[ ${MF_SCHEMA} == 1 ]] || os::die 1 "清单格式版本 ${MF_SCHEMA:-缺失} 本版本读不了（需要 1）"
    [[ -n ${MF_VERSION} ]] || os::die 1 '清单缺 version'
    [[ ${MF_COMMIT} =~ ^[0-9a-f]{40}$ ]] || os::die 1 "清单里的 commit 不合法：${MF_COMMIT:-缺失}"
    [[ ${#MF_PATH[@]} -gt 0 ]] || os::die 1 '清单里一个文件都没有'
    return 0
}

# 取清单，**结果写进调用方给的变量名**（D135：脚本自己的辅助函数也一律用
# 变量返回，禁止 `printf` + `$( )` —— 子 shell 会把 OS_RUN_SKIPPED 一起吞掉，
# 而 dry-run 判断正靠它）。取不到时把变量置空。
#
# 本地路径直接读（离线更新与 dry-run 都靠它），网络来源才走下载 ——
# 下载是副作用，dry-run 下会被跳过，那时诚实声明预演到此为止。
obtain_manifest() {
    local __up_out=${1} __up_dst=${2} __up_ref=${3} __up_src=${4}
    printf -v "${__up_out}" '%s' ''

    # manifest 是整条信任链的锚点，它自己没有任何校验——明文 http:// 允许
    # 任意一跳的中间人把它换成攻击者的版本，此后按里面的 commit 与哈希装
    # 一整套以 root 运行的代码。拒绝在这里比拒绝在 curl 层面更早、更明确。
    if [[ ${__up_src} == http://* ]]; then
        os::die 2 "清单地址是明文 http://，拒绝：${__up_src}（manifest 没有自身校验，必须走 HTTPS）"
    fi
    if [[ -n ${__up_src} && ${__up_src} != https://* ]]; then
        [[ -f ${__up_src} ]] || os::die 2 "清单不存在：${__up_src}"
        os::run '取本地清单' -- cp -- "${__up_src}" "${__up_dst}"
        # dry-run 下 cp 被跳过，但本地清单本来就读得到，直接读原文件即可完整预演
        [[ -f ${__up_dst} ]] || __up_dst=${__up_src}
        printf -v "${__up_out}" '%s' "${__up_dst}"
        return 0
    fi

    local __up_url=${__up_src}
    if [[ -z ${__up_url} ]]; then
        if [[ -n ${__up_ref} ]]; then
            __up_url="https://github.com/${OS_DEFAULT_UPDATE_REPO}/releases/download/${__up_ref}/manifest.txt"
        else
            __up_url="https://github.com/${OS_DEFAULT_UPDATE_REPO}/releases/latest/download/manifest.txt"
        fi
    fi
    os::info "清单来源：${__up_url}"
    os::run_out '下载分发清单' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 120 -o "${__up_dst}" "${__up_url}" \
        || os::die 1 "清单下载失败：${__up_url}"
    [[ ${OS_RUN_SKIPPED} -eq 1 ]] && return 0
    printf -v "${__up_out}" '%s' "${__up_dst}"
    return 0
}

# 源码落到 $STAGING。**staging 必须在 $OS_ROOT 之内**：
# 切换靠 `mv -T`，而跨文件系统的 mv 是「复制 + 删除」，不是原子替换。
obtain_source() {
    local from=${1}

    os::run '清理上一次的暂存区' -- rm -rf -- "${STAGING}"
    os::run '建立暂存区' -- mkdir -p "${STAGING}"

    if [[ -n ${from} ]]; then
        if [[ -d ${from} ]]; then
            os::info "源码来自本地目录：${from}"
            os::run '复制本地源码' -- cp -a -- "${from}/." "${STAGING}/"
            return 0
        fi
        [[ -f ${from} ]] || os::die 2 "源码不存在：${from}"
        os::info "源码来自本地包：${from}"
        os::run '解开本地源码包' -- tar --no-same-owner --no-same-permissions -xzf "${from}" -C "${STAGING}" --strip-components=1
        return 0
    fi

    local url="https://codeload.github.com/${OS_DEFAULT_UPDATE_REPO}/tar.gz/${MF_COMMIT}"
    local tgz="${STAGING}/.src.tar.gz"
    os::info "下载源码：commit ${MF_COMMIT:0:12}"
    os::run_out '下载源码包' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 600 -o "${tgz}" "${url}" \
        || os::die 1 "源码下载失败：${url}"
    os::run '解开源码包' -- tar --no-same-owner --no-same-permissions -xzf "${tgz}" -C "${STAGING}" --strip-components=1
    os::run '删掉源码包' -- rm -f -- "${tgz}"
    return 0
}

# 逐个比哈希。**一个对不上就整个拒绝**，不允许「跳过坏的继续」——
# 那等于让「校验失败」成为绕过校验的手段（同 D97）。
verify_staging() {
    local -i i n=${#MF_PATH[@]} bad=0
    local p got

    os::info "校验 ${n} 个文件"
    for ((i = 0; i < n; i++)); do
        p="${STAGING}/${MF_PATH[i]}"
        if [[ ! -f ${p} ]]; then
            os::err "清单里有、包里没有：${MF_PATH[i]}"
            bad+=1
            continue
        fi
        os::query --timeout 20 -- sha256sum -- "${p}" || {
            os::err "算不出哈希：${MF_PATH[i]}"
            bad+=1
            continue
        }
        got=${OS_RUN_OUTPUT%% *}
        if [[ ${got} != "${MF_SUM[i]}" ]]; then
            os::err "哈希对不上：${MF_PATH[i]}"
            bad+=1
        fi
    done
    ((bad == 0)) || os::die 1 "${bad} 个文件没通过校验，一个字节都没有替换"

    # 权限也要按清单校正：tar 里的模式受 umask 与打包方式影响，
    # 而丢了执行位的表现是「更新完之后这条命令莫名其妙不存在」。
    #
    # **按模式分组一次性 chmod**，不是一个文件一条命令：后者是 57 次 os::run，
    # 57 条审计记录、57 行日志，而它们说的是同一件事
    local -a mode755=() mode644=()
    for ((i = 0; i < n; i++)); do
        if [[ ${MF_MODE[i]} == 0755 ]]; then
            mode755+=("${STAGING}/${MF_PATH[i]}")
        else
            mode644+=("${STAGING}/${MF_PATH[i]}")
        fi
    done
    [[ ${#mode755[@]} -gt 0 ]] && os::run '校正可执行文件的权限' -- chmod 0755 -- "${mode755[@]}"
    [[ ${#mode644[@]} -gt 0 ]] && os::run '校正普通文件的权限' -- chmod 0644 -- "${mode644[@]}"

    # **属主也要校正，不只是权限。** 走 codeload 那条路时 tar 带
    # `--no-same-owner`，解出来就是 root；但 `--from=<目录>` 是 `cp -a`，属主
    # 原样继承自源目录。一次成功的切换会把整棵**以 root 执行**的程序树装成非
    # root 属主（实测同步自 Windows 的源码目录解出来是 UNKNOWN:UNKNOWN），
    # 而注册表随后照常扫描并以 root 派发其中每一个脚本。
    # 整棵 staging 一次 chown，不逐个：清单外的文件在下一步才被清掉，
    # 而它们此刻同样不该属于别人。
    os::run '校正暂存区属主' -- chown -R root:root -- "${STAGING}"
    os::ok '全部文件校验通过'
    return 0
}

# 清单之外的文件删掉，不随整目录 swap 落地。
#
# **verify_staging 只遍历 MF_PATH——只校验清单里列出的条目**，随后切换器
# 把 lib/ templates/ packaging/ script/ bin/ 五个顶层目录整目录 mv 换上。
# staging 里有、清单里没有的文件此前一个字节都没校验就上线了——这不是
# 理论问题：packaging/make-manifest.sh 生成清单时显式排除了自己（发布期
# 工具，不随分发落地），但它本身在 git 里、因而在 codeload 源码包里、
# 因而落进 staging，若不清理，每次 update run 都会把它整目录 mv 进
# /opt/oneserver/packaging/。风险面在 script/：注册表扫描 script/** 的
# 每个文件，任何带 @command 元数据的文件都会成为一条可被 CLI 与菜单
# 派发的 root 命令。与 install.sh 的 remove_orphans 对称，只是作用对象是
# staging（还没上线）而不是 ROOT（已经在跑）。
remove_staging_orphans() {
    local -A keep=()
    local rel
    for rel in "${MF_PATH[@]}"; do
        keep["${rel}"]=1
    done

    local -a extra=()
    local top f
    for top in "${UPDATE_TOP[@]}"; do
        [[ -d "${STAGING}/${top}" ]] || continue
        while IFS= read -r f; do
            rel=${f#"${STAGING}/"}
            [[ -n ${keep[${rel}]-} ]] && continue
            extra+=("${f}")
        done < <(find "${STAGING}/${top}" -type f)
    done

    if [[ ${#extra[@]} -gt 0 ]]; then
        os::warn "清单之外发现 ${#extra[@]} 个未校验的文件，拒绝随更新落地，已清除"
        os::run '清除清单之外的文件' -- rm -f -- "${extra[@]}"
        for top in "${UPDATE_TOP[@]}"; do
            [[ -d "${STAGING}/${top}" ]] || continue
            os::run --allow-fail '清理清空后的空目录' -- \
                find "${STAGING}/${top}" -type d -empty -delete
        done
    fi
    return 0
}

# 把切换器放到一个能执行的临时目录，路径写进 OS_UPDATER_RUN。
#
# **清理在前不在后**：本进程随后就 exec 走了，退出钩子不会跑，os::tmpdir 登记
# 的清理项没人回放。所以每次先把上一轮留下的目录收掉，落地数量因此恒为一个，
# 而不是每更新一次多一个。不在切换器里自删：bash 是按需分块读脚本的，
# 删掉正在跑的那个文件正是 K13 的形态。
stage_updater() {
    os::run --allow-fail '清理上一轮的切换器目录' -- \
        find "${OS_TMP_ROOT}" -maxdepth 1 -name 'os.*' -type d -exec rm -rf -- {} + || true

    local dir=''
    os::tmpdir dir --exec || return 1
    OS_UPDATER_RUN="${dir}/updater.sh"
    os::run '把切换器复制到可执行目录' -- cp -- "${UPDATER_SRC}" "${OS_UPDATER_RUN}" || return 1
    os::run '给切换器执行位' -- chmod 0700 "${OS_UPDATER_RUN}" || return 1
    return 0
}

# 上一次切换没走完的话，标记还在。**这不是可以忽略的告警**：
# 此时机器上是「新 lib + 旧 script」这类半截状态。
warn_if_interrupted() {
    [[ -e ${IN_PROGRESS} ]] || return 0
    os::warn '检测到上一次更新没有走完（.update-in-progress 还在）'
    if [[ -d "${OS_ROOT}/.old" ]]; then
        os::warn "上一版还在 ${OS_ROOT}/.old，可以退回去：oneserver update rollback"
    fi
    return 0
}

# ------------------------------------------------------------------

action_status() {
    local cur='' old='' rollback='没有可回滚的上一版'
    version_of cur "${OS_VERSION_FILE}"
    if [[ -d "${OS_ROOT}/.old" ]]; then
        version_of old "${OS_ROOT}/.old/VERSION"
        rollback="可回滚到 ${old:-上一版}"
    fi

    os::section 'OneServer 更新'
    os::kv '当前版本' "${cur:-未知}" \
        '回滚状态' "${rollback}"
    if [[ -e ${IN_PROGRESS} ]]; then
        os::warn '检测到上一次更新没有走完；先检查或回滚，不要直接再次更新'
    fi
    # check 与 run 都要去 GitHub 取清单，run 还要再取一份源码；只有 rollback
    # 全程在本机。把联网范围说窄了，用户会以为选「更新」不动网络
    os::info '「检查」与「更新」会联网访问 GitHub，「回滚」只用本机留下的上一版'
    return 0
}

action_check() {
    local ref='' manifest_src='' cur=''
    os::ask --hint '想看某个旧版本就填版本号，例：v0.1.1' \
        --arg ref '检查哪个版本？回车＝最新版' ref ''
    os::ask --hint "${MANIFEST_HINT}" \
        --arg manifest '版本清单从哪来？回车＝自动取' manifest_src ''

    warn_if_interrupted
    version_of cur "${OS_VERSION_FILE}"

    local mf=''
    obtain_manifest mf "${OS_RUN_DIR}/manifest.txt" "${ref}" "${manifest_src}"
    if [[ -z ${mf} ]]; then
        os::info '[dry-run] 后续步骤无法预演（清单没有真的下载）'
        os::output 0 current="${cur}" checked=no
        return 0
    fi
    parse_manifest "${mf}"

    os::section '版本'
    os::kv '当前' "${cur:-未知}" \
        '可用' "${MF_VERSION}" \
        'commit' "${MF_COMMIT:0:12}" \
        '文件数' "${#MF_PATH[@]}"

    if [[ ${cur} == "${MF_VERSION}" ]]; then
        os::ok "当前已是 ${MF_VERSION}，没有新版本"
        os::output 0 current="${cur}" available="${MF_VERSION}" update=no
        return 0
    fi
    os::info "有新版 ${MF_VERSION} 可装 —— 回操作列表选「更新到新版本」，或敲 oneserver update run${ref:+ --ref=${ref}}"
    os::output 0 current="${cur}" available="${MF_VERSION}" update=yes
    return 0
}

action_run() {
    local ref='' manifest_src='' from='' cur=''
    os::ask --hint '想装某个指定版本就填版本号，例：v0.1.1' \
        --arg ref '更新到哪个版本？回车＝最新版' ref ''
    os::ask --hint "${MANIFEST_HINT}" \
        --arg manifest '版本清单从哪来？回车＝自动取' manifest_src ''
    os::ask --hint '断网或本地测试时填已有的源码目录或安装包，例：/root/OneServer' \
        --arg from '程序文件从哪来？回车＝自动下载' from ''
    local force=0
    os::flag --arg force && force=1

    warn_if_interrupted
    version_of cur "${OS_VERSION_FILE}"

    local mf=''
    obtain_manifest mf "${OS_RUN_DIR}/manifest.txt" "${ref}" "${manifest_src}"
    if [[ -z ${mf} ]]; then
        os::info '[dry-run] 后续步骤无法预演（清单没有真的下载）'
        os::output 0 current="${cur}" changed=dry-run
        return 0
    fi
    parse_manifest "${mf}"

    os::section '更新'
    os::kv '当前版本' "${cur:-未知}" \
        '目标版本' "${MF_VERSION}" \
        'commit' "${MF_COMMIT:0:12}" \
        '文件数' "${#MF_PATH[@]}"

    if [[ ${cur} == "${MF_VERSION}" && ${force} -eq 0 ]]; then
        # 菜单里没有「强制」这一项，只能给出完整命令行 —— 说「加 --force」
        # 的话，用户在这一屏找不到任何地方可以加
        os::ok "当前已是 ${MF_VERSION}，无需更新（想按同一版本重装一遍：oneserver update run --force）"
        os::output 0 current="${cur}" changed=no
        return 0
    fi

    [[ -x ${UPDATER_SRC} ]] || os::die 3 "切换器不在或不可执行：${UPDATER_SRC}"

    obtain_source "${from}"
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（源码没有真的落到暂存区，校验与切换都无从谈起）'
        os::info "[dry-run] 真实执行时会：校验 ${#MF_PATH[@]} 个文件 → 原子切换 → 跑 doctor --selftest → 不过就回滚"
        os::output 0 current="${cur}" target="${MF_VERSION}" changed=dry-run
        return 0
    fi
    verify_staging
    remove_staging_orphans

    # --- 阶段 2：把切换器搬到 $OS_ROOT 之外，然后 exec 它 ---
    #
    # 搬出去是硬要求：它要替换的正是自己所在的那棵树。
    stage_updater || os::die 1 '无法准备切换器'

    os::record_change "把 ${OS_ROOT} 从 ${cur:-未知} 切换到 ${MF_VERSION}"
    os::info '交给切换器（本进程到此为止，锁经 exec 继承过去）'

    # `exec` 而不是 fork：本进程的内存里是**旧版本的 lib**，替换之后它执行的
    # 是旧函数、操作的是新布局。让它彻底消失是唯一安全的做法（D14）
    exec "${OS_UPDATER_RUN}" switch \
        --root="${OS_ROOT}" \
        --staging="${STAGING}" \
        --version="${MF_VERSION}"
}

action_rollback() {
    if [[ ! -d "${OS_ROOT}/.old" ]]; then
        os::die 2 "没有可回滚的上一版（${OS_ROOT}/.old 不在）—— 上一次更新要么成功并清理了，要么根本没跑到切换那一步"
    fi
    [[ -x ${UPDATER_SRC} ]] || os::die 3 "切换器不在或不可执行：${UPDATER_SRC}"

    # 退回哪一版必须在确认之前说出来：只说「上一版」的话，用户按 y 时
    # 并不知道自己要落到哪个版本号上
    local cur='' old=''
    version_of cur "${OS_VERSION_FILE}"
    version_of old "${OS_ROOT}/.old/VERSION"
    os::warn "将把 OneServer 从 ${cur:-未知} 退回 ${old:-上一版}（只换程序文件，凭据、组件登记与探测快照不动）"
    # **不复用 --force。** 它在 run 那边的意思是「同一版本也强制重装」，在这里
    # 却成了「跳过确认」—— 同一条命令下一个开关两个意思，而这两个动作的危险
    # 程度完全不同：一个是重装当前版本，一个是把整棵程序目录换回上一版
    os::confirm --arg confirm-rollback '确认回滚？' n || os::die 130 '已取消'

    stage_updater || os::die 1 '无法准备切换器'

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 真实执行时会 exec 切换器把上一版换回来'
        os::output 0 changed=dry-run
        return 0
    fi

    os::record_change "把 ${OS_ROOT} 回滚到上一版"
    exec "${OS_UPDATER_RUN}" rollback --root="${OS_ROOT}"
}

# ------------------------------------------------------------------

main() {
    os::require_cmd curl tar sha256sum

    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_status --arg action '操作' dispatch \
        'check=检查有没有新版本' 'run=更新到新版本' 'rollback=回滚到上一版'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        check) action_check ;;
        run) action_run ;;
        rollback) action_rollback ;;
        *) os::die 2 "未知操作「${1}」，可用：status check run rollback" ;;
    esac
}

main "$@"
