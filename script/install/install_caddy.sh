#!/bin/bash
#
# 安装/升级 Caddy（可选 DNS 插件）
#
# @command      install caddy
# @name         Caddy
# @group        app
# @order        110
# @privilege    root
# @requires_lib >= 4.8
# @provides     caddy
# @provides_unit ext:caddy.service
# @args         [--plugins=<+加|-减|序号|列表|none>] [--skip-official] [--relax-apparmor] [--on-build-error=<retry|prebuilt|abort>] [--fallback-prebuilt=<y|n>] [--allow-web-ports=<y|n>]
# @description  装 Caddy，可换成带 DNS 插件的二进制
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ------------------------------------------------------------------
# 为什么是「apt 装官方框架 + 换二进制」这么绕
#
# 官方 apt 包给的是 unit、caddy 用户、/etc/caddy、/var/lib/caddy 这一整套系统
# 集成，但它的二进制**不含 Cloudflare DNS 插件** —— 而没有那个插件就签不了
# DNS-01 的通配符证书，那是本项目用 Caddy 的主要理由。
#
# 所以：apt 装框架 → dpkg-divert 把 apt 的二进制挪到 caddy.default →
# update-alternatives 让 /usr/bin/caddy 指向带插件的那份。apt 后续升级 caddy
# 包时写的是 caddy.default，alternatives 的选择不受影响，两边各自成立。
#
# **不直接覆盖 /usr/bin/caddy**：那是 dpkg 管的文件，覆盖它等于跟包管理器抢
# 同一个路径 —— apt 下次升级就把插件版冲掉了，而用户看到的现象是「通配符证书
# 突然签不了了」，中间隔着好几周，根本联想不到是 apt 干的。

readonly CADDY_KEYRING='/usr/share/keyrings/caddy-stable-archive-keyring.gpg'
readonly CADDY_LIST='/etc/apt/sources.list.d/caddy-stable.list'
readonly CADDY_DEFAULT_BIN='/usr/bin/caddy.default'
readonly CADDY_CUSTOM_BIN='/usr/bin/caddy.custom'
readonly CADDY_DROPIN='/etc/systemd/system/caddy.service.d/oneserver.conf'
readonly CADDY_LOG_DIR='/var/log/caddy'

# --- 两个来源，能力不一样，顺序由此而定（D106）---
#
#   官方按需构建   任意插件组合都能现场编译 → **第一顺序**
#                  代价：产物是当场编出来的，没有稳定哈希，也就**没有 SHA256**。
#                  只能靠 TLS + 随后的功能验证（规范的例外）
#   本项目仓库     只有「清单原样」那一个组合，但**每个资产都附 .sha256**
#                  → 官方够不着、太慢、或用户显式 --skip-official 时的兜底
#
# 所以「用户动过 +/- 」与「走仓库」是互斥的：仓库那份里没有他加的插件。
# 这种情况不硬着头皮装 —— 功能验证会拦下来，见 verify_binary。
readonly BUILD_REPO='qichiyuhub/caddy-custom-build'
readonly OFFICIAL_API='https://caddyserver.com/api/download'

# 完整的 Caddy 二进制是几十 MB（带上整份默认清单时 70 MB 上下）。5 MB 是个宽松下界，
# 只用来把错误页和截断的响应挡在外面，不是版本相关的精确判据
readonly CADDY_MIN_BIN_BYTES=5000000

# 下面三个是函数的返回通道。**不用 $( ) 取返回值**：那是子 shell，
# 里面的 os::record_change / os::defer 一条都传不出来，而这个脚本的
# 回滚清单正是靠它们攒的（同 D74 的理由）。
CADDY_ARCH=''
CADDY_TAG=''
CADDY_BIN_CHANGED=0
CADDY_DROPIN_CHANGED=0

# 归一化之后的插件组合（逗号分隔的完整模块路径，已排序去重）与「是否动过清单」
CADDY_PLUGINS=''
CADDY_CUSTOMIZED=0

# ------------------------------------------------------------------

# 本机架构 → 发布资产里的架构名。不认的架构直接退出码 4：
# 把 amd64 的二进制装到 arm64 上，报错会推迟到几步之后的「服务起不来」。
resolve_arch() {
    probe::arch
    case ${OS_PROBE_VALUE} in
        x86_64) CADDY_ARCH='amd64' ;;
        aarch64 | arm64) CADDY_ARCH='arm64' ;;
        *) os::die 4 "不支持的架构：${OS_PROBE_VALUE}（仅 amd64 / arm64）" ;;
    esac
    return 0
}

# 取构建仓库的最新 tag，写进 CADDY_TAG。
# **不用 jq**：D5 是零运行时依赖，而 jq 在最小安装里不预装。只要一个字段，
# bash 的字符串裁剪就够；拿不到就返回 1，由调用方决定降级还是失败。
resolve_latest_tag() {
    CADDY_TAG=''
    os::query --timeout 20 -- curl -fsSL --proto '=https' --proto-redir '=https' \
        "https://api.github.com/repos/${BUILD_REPO}/releases/latest" || return 1
    local tag=${OS_RUN_OUTPUT}
    tag=${tag#*\"tag_name\":}
    tag=${tag#*\"}
    tag=${tag%%\"*}
    [[ ${tag} =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    CADDY_TAG=${tag}
    return 0
}

# 主源：本项目构建仓库，带 SHA256
#
# **两种失败必须分开**（返回码 1 与 2）：
#   1 = 够不着（取不到 tag、下载失败）—— 可以降级到官网兜底
#   2 = 下到了但**校验不过** —— **禁止降级**，直接失败
#
# 这不是洁癖：校验失败自动走无校验的路，等于把校验作废 —— 中间人只要让
# 校验失败（改几个字节即可），就能把你推到那条没有校验的路上去。
# 容器验收第一次跑就是这个形态：校验因格式问题失败，脚本一声不响换了官网源，
# 最后还打了绿色的「安装成功」（D97）。
fetch_from_github() {
    local dir=${1}
    resolve_latest_tag || {
        os::warn '取不到构建仓库的最新版本'
        return 1
    }

    local ver=${CADDY_TAG#v}
    local base="https://github.com/${BUILD_REPO}/releases/download/${CADDY_TAG}"
    local name="caddy-${ver}-linux-${CADDY_ARCH}.tar.gz"
    os::info "构建仓库最新版本 ${CADDY_TAG}（${CADDY_ARCH}）"

    os::retry 3 '下载 Caddy 二进制包' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 -o "${dir}/${name}" "${base}/${name}" || return 1
    os::retry 3 '下载 SHA256 校验文件' -- \
        curl -fsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 -o "${dir}/${name}.sha256" "${base}/${name}.sha256" || return 1

    # 第三方软件必须校验官方 SHA256。
    #
    # **不用 `sha256sum -c`**：仓库发布的 .sha256 里只有裸哈希，没有文件名，
    # 而 -c 要的是「哈希 + 两个空格 + 文件名」，遇到裸哈希会报 improperly
    # formatted 并**返回非零** —— 于是每次都「校验失败」，然后悄悄降级到官网。
    # 容器验收第一次跑就是这个形态。这里自己算自己比，顺带兼容带文件名的格式。
    local want
    want=$(<"${dir}/${name}.sha256")
    want=${want%% *}
    want=${want,,}

    os::query --timeout 120 -- sha256sum "${dir}/${name}" || {
        os::err '算不出下载文件的 SHA256'
        return 2
    }
    local got_hash=''
    got_hash=${OS_RUN_OUTPUT%% *}
    got_hash=${got_hash,,}

    if [[ -z ${want} || ${want} != "${got_hash}" ]]; then
        os::err 'SHA256 校验失败，已丢弃下载的文件'
        os::debug "期望 ${want}，实际 ${got_hash}"
        return 2
    fi
    os::ok "SHA256 校验通过（${got_hash:0:16}…）"

    os::run '解压 Caddy 二进制包' -- tar -xzf "${dir}/${name}" -C "${dir}" caddy || return 1
    return 0
}

# 默认清单（`<模块路径>=<说明>`）拆成两样东西：
#   CADDY_OPTIONS      喂给 os::multiselect 的选项数组，值是**短名**
#   CADDY_DEFAULT_SET  归一化排序后的默认组合，用来判「用户动过清单没有」
#
# 选单里显示短名（剥掉 `github.com/`）：满屏全路径又长又难扫，而 `+全路径`
# 与 `+短名` 经 plugin_module_path 归一到同一个字符串，去重不会漏掉任何一种写法。
CADDY_OPTIONS=()
CADDY_DEFAULT_SET=''

caddy_load_defaults() {
    CADDY_OPTIONS=()
    local -a items=() paths=()
    local one path desc joined='' sep=''
    IFS=',' read -r -a items <<<"${OS_DEFAULT_CADDY_PLUGINS}"
    for one in ${items[@]+"${items[@]}"}; do
        [[ -n ${one} ]] || continue
        path=${one%%=*}
        desc=''
        if [[ ${one} == *=* ]]; then
            desc=${one#*=}
        fi
        CADDY_OPTIONS+=("${path#github.com/}=${desc}")
        paths+=("${path}")
        joined+="${sep}${path}"
        sep=','
    done
    caddy_normalize CADDY_DEFAULT_SET "${joined}"
    return 0
}

# caddy_normalize <输出变量名> <逗号分隔的插件名>   补全成完整模块路径后排序去重
#
# **结果就是与 state 比对的那个字符串。** 归一化漏一处的现象不是报错：
# state 里记的与这次算出来的永远对不上，于是每次执行都判成「组合变了」→
# 重下几十 MB 换二进制，而屏幕上一切正常（同 D108）。
caddy_normalize() {
    local __cd_out=${1} __cd_list=${2}
    local -a __cd_items=() __cd_full=() __cd_sorted=()
    local __cd_one __cd_res='' __cd_sep=''
    IFS=',' read -r -a __cd_items <<<"${__cd_list}"
    for __cd_one in ${__cd_items[@]+"${__cd_items[@]}"}; do
        [[ -n ${__cd_one} ]] || continue
        __cd_full+=("$(plugin_module_path "${__cd_one}")")
    done
    mapfile -t __cd_sorted < <(printf '%s\n' ${__cd_full[@]+"${__cd_full[@]}"} | sort -u)
    for __cd_one in ${__cd_sorted[@]+"${__cd_sorted[@]}"}; do
        [[ -n ${__cd_one} ]] || continue
        __cd_res+="${__cd_sep}${__cd_one}"
        __cd_sep=','
    done
    printf -v "${__cd_out}" '%s' "${__cd_res}"
    return 0
}

# 插件名 → Go 模块路径。
#
# 官网 API 要的是**完整模块路径**（`github.com/caddy-dns/duckdns`），而人写的
# 是 `caddy-dns/duckdns`。判据是第一段里有没有点：有点就是主机名，当完整路径用
# （`git.example.com/me/plugin` 照样能装）；没有就默认 GitHub。
#
# 少了这一步官网直接回 400，curl 以 22 退出，屏幕上只有一句「下载失败」——
# 而真正的原因是参数少了一截。容器验收里 duckdns 就是这么失败的。
plugin_module_path() {
    local p=${1}
    local first=${p%%/*}
    if [[ ${first} == *.* ]]; then
        printf '%s\n' "${p}"
    else
        printf 'github.com/%s\n' "${p}"
    fi
    return 0
}

# 官网按需构建的下载 + 当场验形。**这两件事必须在同一个可重试单元里**。
#
# 按需构建的响应是边编译边流式返回的：服务端编译到一半失败时，流会**干净地
# 结束**，curl 看到的是正常 EOF，退出码 0 —— 于是「下载成功」的是一个截断的
# 文件。校验和这条路走不通（按需构建没有官方 SHA256），所以只能验形：ELF 魔数
# 加最小体积。带插件的 Caddy 是几十 MB，几百 KB 的「成功」响应必然是错误页或
# 半截文件。
#
# 放在 retry 之外的话，这类失败要等到 verify_binary 才发现，而那时已经不重试了，
# 用户看到的就是「第 2 次尝试成功」紧接着「下载的二进制跑不起来」。
caddy_fetch_official_once() {
    local url=${1} out=${2}
    local -i rc=0

    # --max-time 走 OS_DEFAULT_CADDY_BUILD_TIMEOUT，不写死：那个配置项的原意就是
    # 「超过这个秒数就当官方够不着，回落预构建」，写死等于让用户改了 conf 也不生效。
    # 而只给 --connect-timeout 的话，连上之后服务端卡住就是无限等 ——
    # 按需构建本来就要几十秒，人分不清是在编译还是已经挂了
    curl -fsSL --proto '=https' --proto-redir '=https' \
        --connect-timeout 30 --max-time "${OS_DEFAULT_CADDY_BUILD_TIMEOUT}" \
        -o "${out}" "${url}" || rc=$?

    # **curl 的退出码原样带出去。** 22（HTTP 4xx）说明官方拒绝了这个插件组合 ——
    # 多半是名字写错，该让人改；28（超时）说明够不着，该回落预构建。
    # 两者的下一步动作完全相反，压成同一个 1 就再也分不出来了
    if ((rc != 0)); then
        return "${rc}"
    fi

    local -i size=0
    size=$(stat -c %s -- "${out}" 2>/dev/null || printf '0')
    if ((size < CADDY_MIN_BIN_BYTES)); then
        printf '下载的文件只有 %d 字节，不是完整的 Caddy 二进制\n' "${size}" >&2
        printf '开头 200 字节：\n' >&2
        head -c 200 -- "${out}" >&2
        printf '\n' >&2
        # 90 不是 curl 的码：服务端编译到一半失败时流会**干净地**结束，curl 看到
        # 正常 EOF 退 0。这属瞬时故障，值得重试，所以它不在 --stop-on 里
        return 90
    fi

    local magic
    magic=$(od -An -N4 -tx1 -- "${out}" 2>/dev/null | tr -d ' \n')
    if [[ ${magic} != '7f454c46' ]]; then
        printf '下载的文件不是 ELF 可执行文件（魔数 %s，大小 %d 字节）\n' \
            "${magic:-空}" "${size}" >&2
        return 90
    fi
    return 0
}

# 官网按需构建：**任意插件组合都能装，代价是没有校验和**。
#
# URL 里每个插件一个 `&p=`，模块路径中的 `/` 要转成 %2F。纯 bash 转，不引依赖。
fetch_from_official() {
    local dir=${1}
    local url="${OFFICIAL_API}?os=linux&arch=${CADDY_ARCH}"
    # CADDY_PLUGINS 里已经是归一化过的完整模块路径，这里只做 URL 编码
    local one enc
    local IFS=','
    for one in ${CADDY_PLUGINS}; do
        [[ -n ${one} ]] || continue
        enc=${one//'/'/%2F}
        url+="&p=${enc}"
    done

    # 三个码重试也不会变，命中即刻返回，把决定权交回 main：
    #   22  HTTP 4xx —— 官方拒绝了这个组合，多半是插件名写错，该让人改
    #    6  DNS 解析不了 —— 网络根本不通
    #   28  超时 —— OS_DEFAULT_CADDY_BUILD_TIMEOUT 的原意就是「当它够不着」，
    #       再试一遍就是再等一个完整的超时（三次 = 半小时白等）
    # 剩下的（连接被拒 7、空响应 52、传输中断 56、验形不过 90）才值得重试，
    # 而它们都是瞬间失败，重试几乎不花时间
    local -i rc=0
    os::retry --stop-on 6,22,28 2 '从官网下载 Caddy 二进制' -- \
        caddy_fetch_official_once "${url}" "${dir}/caddy" || rc=$?
    return "${rc}"
}

# 用预构建之前一律确认，并把「和你要的组合差在哪」指名道姓摊开。
#
# 同意之后**目标组合退回默认清单**。这一步是整个兜底路径里最容易漏的：
# 不退回的话 state 里记的是用户要的 11 个、实际装的是预构建那 10 个，
# 下次执行一比对「组合变了」→ 每次都重下几十 MB 换二进制，
# 而屏幕上一切正常（幂等静默失效）。
confirm_prebuilt() {
    local reason=${1}
    os::warn "${reason}"
    os::info '本项目仓库的预构建只有清单原样的那一组插件，不能增删；它带 SHA256 校验'

    if [[ ${CADDY_CUSTOMIZED} -eq 1 ]]; then
        local -a lost=() extra=()
        local one
        local IFS=','
        for one in ${CADDY_PLUGINS}; do
            [[ -n ${one} ]] || continue
            [[ ",${CADDY_DEFAULT_SET}," == *",${one},"* ]] || lost+=("${one}")
        done
        for one in ${CADDY_DEFAULT_SET}; do
            [[ -n ${one} ]] || continue
            [[ ",${CADDY_PLUGINS}," == *",${one},"* ]] || extra+=("${one}")
        done
        IFS=' '
        if [[ ${#lost[@]} -gt 0 ]]; then
            os::warn "你要的这些不在预构建里：${lost[*]}"
        fi
        if [[ ${#extra[@]} -gt 0 ]]; then
            os::warn "预构建里多出这些（你排除过）：${extra[*]}"
        fi
    fi

    os::confirm --arg fallback-prebuilt '改用本项目仓库的预构建？' n \
        || os::die 1 '已取消，Caddy 二进制未更换。apt 版 Caddy 可能已装上并在跑，但它不含任何插件 —— 改好插件名或换个时间再执行一次即可'

    if [[ ${CADDY_CUSTOMIZED} -eq 1 ]]; then
        CADDY_PLUGINS=${CADDY_DEFAULT_SET}
        CADDY_CUSTOMIZED=0
        os::info '插件组合已退回清单原样'
    fi
    return 0
}

# 功能验证：跑得起来，且**要的插件真的在里面**。
#
# 两个来源都要过这一关 —— 校验和证明「文件没被改」，证明不了「文件是对的」。
# 官网按需构建尤其需要：插件名拼错时它照样返回一个能跑的 Caddy，只是没有那个
# 插件，而用户要等到签证书失败那天才发现。
#
# `caddy-dns/cloudflare` 对应模块 `dns.providers.cloudflare` —— 这是 caddy-dns
# 系列的命名约定，只对这一系列成立，其余插件只能粗查「模块名里有没有它」。
verify_binary() {
    local bin=${1}
    os::run '给二进制加执行权限' -- chmod 0755 "${bin}" || return 1

    os::query --timeout 20 -- "${bin}" version || {
        # 光说「跑不起来」没法排查：文件在临时目录里，命令一结束就被清掉，
        # 用户手上什么证据都不剩。体积与魔数是这里唯一还能留下的线索
        local -i size=0
        local magic=''
        size=$(stat -c %s -- "${bin}" 2>/dev/null || printf '0')
        magic=$(od -An -N4 -tx1 -- "${bin}" 2>/dev/null | tr -d ' \n')
        os::err "下载的二进制跑不起来（${size} 字节，文件头 ${magic:-空}，ELF 应为 7f454c46）"
        return 1
    }
    local ver=${OS_RUN_OUTPUT%%$'\n'*}

    # 用 `build-info` 而不是 `list-modules`，理由见 probe::caddy_plugins。
    # **这里不能改调那个探测**：它问的是已经装在机器上的那个 caddy，而此刻要验的
    # 是刚下载、还没换上去的这个临时二进制 —— 同一种事实，两个不同的对象。
    os::query --timeout 30 -- "${bin}" build-info || {
        os::err '读不到 Caddy 构建信息'
        return 1
    }
    local info=${OS_RUN_OUTPUT}

    local one
    local IFS=','
    for one in ${CADDY_PLUGINS}; do
        [[ -n ${one} ]] || continue
        if [[ ${info} != *"${one}"* ]]; then
            os::err "二进制里没有编进 ${one}，拒绝安装"
            return 1
        fi
    done
    os::ok "二进制验证通过：${ver}"
    return 0
}

# ------------------------------------------------------------------

# 密钥环与源定义是不是**本次从无到有建**的。用户按 Caddy 官方文档手工配过
# 同样这两个路径是常见情况，那种情况下它们不是「本项目创建的」，按 §12
# 登记成 file 会让 `uninstall caddy` 把用户自己配的 apt 源删掉。
# 判断只能在写之前做，所以用全局变量带出来（函数之间不用 $( )：子 shell，D135）。
CADDY_KEYRING_CREATED=0
CADDY_LIST_CREATED=0

setup_apt_repo() {
    local dir=${1}

    [[ -f ${CADDY_KEYRING} ]] || CADDY_KEYRING_CREATED=1
    [[ -f ${CADDY_LIST} ]] || CADDY_LIST_CREATED=1

    # 密钥先落到临时目录，再经 os::install_file 换 inode 放到位，
    # 不用 `curl | tee 目标` 那种就地截断的写法。
    #
    # **不是 `-1`（--tlsv1，只设最低版本为 1.0，不设上限，还会覆盖发行版
    # 可能配置的更高下限）**。这条取的正是 apt 仓库的签名密钥，它决定
    # 此后 apt 信任谁，理应用能拿到的最高版本。
    os::retry 3 '下载 Caddy 仓库签名密钥' -- \
        curl -fsSL --tlsv1.2 --proto '=https' --proto-redir '=https' --connect-timeout 15 \
        -o "${dir}/caddy.key" \
        'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' || return 1

    # dry-run 下上面那条根本没跑，临时目录里是空的 —— 再往下就是拿不存在的
    # 文件去落地。诚实地停在这里，由 main 打分叉声明。
    [[ ${OS_DRYRUN} -eq 1 ]] && return 0

    os::run '转换签名密钥格式' -- \
        gpg --batch --yes --dearmor -o "${dir}/caddy.gpg" "${dir}/caddy.key" || return 1
    # `--backup`：理由同 install_docker —— 覆盖的可能是用户按官方文档
    # 手工配过的同名文件（§10 第三类「先备份再改」）
    os::install_file --backup --mode 0644 "${dir}/caddy.gpg" "${CADDY_KEYRING}" || return 1
    local -i changed=${OS_TEMPLATE_CHANGED}

    # 源定义随分发落地，不联网取（§11）：它决定此后 apt 信任哪个仓库、
    # 用哪个 keyring，这个决定必须随分发落地、可被 manifest 的 SHA256 覆盖，
    # 而不是每次安装时向网络要一次 —— 一份被换掉的响应就能让 apt 以 root
    # 装任意包，且这种替换落不进本项目任何一层校验。
    os::install_template --backup --mode 0644 "${OS_TEMPLATE_DIR}/caddy.list" "${CADDY_LIST}" \
        "KEYRING=${CADDY_KEYRING}" || return 1
    [[ ${OS_TEMPLATE_CHANGED} -eq 1 ]] && changed=1

    # 只有源真的变了才刷索引：第二次执行要零变更，而 apt-get update
    # 每次都跑既是几秒钟，也是一条无谓的审计记录
    if [[ ${changed} -eq 1 ]]; then
        os::pkg_refresh
    fi
    return 0
}

# 结果写进 CADDY_BIN_CHANGED
switch_binary() {
    local staged=${1}

    os::query -- dpkg-divert --list /usr/bin/caddy
    if [[ ${OS_RUN_OUTPUT} != *"${CADDY_DEFAULT_BIN}"* ]]; then
        # divert 与随后的重装都属「禁止自动回滚」类：撤销 divert 会动到
        # dpkg 的账本，猜着还原比不还原更危险
        os::record_change "把 apt 的 /usr/bin/caddy 分流到 caddy.default"
        os::critical_begin '设置 dpkg-divert'
        os::run '分流 apt 的 Caddy 二进制' -- \
            dpkg-divert --divert "${CADDY_DEFAULT_BIN}" --rename /usr/bin/caddy
        os::critical_end

        # --rename 把文件挪走了，apt 得重装一份回来占住 /usr/bin/caddy。
        # 变更登记与临界区都在 os::pkg_reinstall 里
        os::pkg_reinstall caddy
    fi

    # 覆盖已有二进制前先备份：验证不过时框架逆序还原（「先备份再改」）
    os::install_file --backup --mode 0755 "${staged}" "${CADDY_CUSTOM_BIN}" || return 1
    CADDY_BIN_CHANGED=${OS_TEMPLATE_CHANGED}

    # 二进制没换、且 /usr/bin/caddy 已经指向它，就什么都不用做了。
    # update-alternatives 与 setcap 本身幂等，但每次都跑会留下四条审计记录，
    # 让「第二次执行到底动没动系统」这个问题没法一眼回答。
    if [[ ${CADDY_BIN_CHANGED} -eq 0 ]]; then
        os::query -- readlink -f /usr/bin/caddy
        if [[ ${OS_RUN_OUTPUT} == "${CADDY_CUSTOM_BIN}" ]]; then
            os::query -- getcap "${CADDY_CUSTOM_BIN}"
            if [[ ${OS_RUN_OUTPUT} == *cap_net_bind_service* ]]; then
                return 0
            fi
        fi
    fi

    if [[ -x ${CADDY_DEFAULT_BIN} ]]; then
        os::run '注册官方二进制为候选' -- \
            update-alternatives --install /usr/bin/caddy caddy "${CADDY_DEFAULT_BIN}" 10
    fi
    os::run '注册自定义二进制为候选' -- \
        update-alternatives --install /usr/bin/caddy caddy "${CADDY_CUSTOM_BIN}" 50
    os::run '选用自定义二进制' -- \
        update-alternatives --set caddy "${CADDY_CUSTOM_BIN}"

    # setcap 跟着 inode 走，每换一次二进制都要重设 —— 这是 install_file 换
    # inode 的直接代价，也正是它「不动正在运行的那个 inode」的直接收益。
    os::run '授予绑定特权端口的能力' -- \
        setcap cap_net_bind_service=+ep "${CADDY_CUSTOM_BIN}"
    return 0
}

# OneServer 对 caddy.service 的全部覆盖，一个 drop-in 装完。
#
# ## LogsDirectory —— 日志目录交给 systemd 建，**不自己 mkdir + chown**
#
# Caddyfile 里 `output file /var/log/caddy/...` 要 caddy 用户能写，而 apt 包只
# 建 /etc/caddy 与 /var/lib/caddy。缺了这一步，配好日志后的第一次重载就是
# `open /var/log/caddy/...: permission denied` —— 而 Caddy 把这句写进 journal
# 之后照常服务，站点全是好的，人要等到去翻日志文件时才发现它压根没生成。
#
# mkdir + chown 只对当下有效：/var/log 被清理、或目录被手工删掉就又没了。
# LogsDirectory= 是每次启动前按 unit 的 User=/Group= 建好，重装与手工误删自愈。
#
# **它只管目录本身，不管目录里的文件。** systemd 只有在目录属主与配置不符时
# 才递归修正；目录已经是 caddy:caddy 时，里面一个 root 属主的文件它看都不看
# —— 而 Caddy 打不开那个文件就直接启动失败。所以还需要 fix_log_owner。
#
# 0750 而不是 systemd 默认的 0755：访问日志里有访客 IP、UA 与请求路径，
# 0755 等于把它摊给机器上每一个用户（§15）。
#
# ## ExecStart —— 去掉官方 unit 的 --environ
#
# 官方 unit 是 `caddy run --environ --config ...`，而 `--environ` 把**整个进程
# 环境**打到 stdout，stdout 进 journal。DNS 令牌恰恰是经 EnvironmentFile 注入
# 环境的（caddy-manager 的 token 动作）—— 于是那个 0600 文件里小心存着的令牌，
# 明文躺在 `journalctl -u caddy` 里：systemd-journal 组的任何人都读得到，
# 而且会跟着任何一份为排查而导出的日志一起流出去。
#
# 代价是把官方那行 ExecStart **固化在这里**，官方将来给它加参数这台机器不会
# 跟着变。没有别的关法：--environ 写死在 unit 里，不受任何配置项控制。
# 令牌不进日志更重要。**先空一行 `ExecStart=` 清空**，否则 Type=notify 的
# unit 有两条 ExecStart 会直接拒绝启动。
install_dropin() {
    local dir=${1}
    local tmp="${dir}/oneserver.conf"
    {
        printf '[Service]\n'
        printf 'LogsDirectory=caddy\n'
        printf 'LogsDirectoryMode=0750\n'
        printf 'ExecStart=\n'
        printf 'ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile\n'
    } >"${tmp}"

    # 目录已在就不跑 mkdir：它本身幂等，但每次执行都留一条审计记录，
    # 会让「第二次执行到底动没动系统」没法一眼回答（同 switch_binary）
    if [[ ! -d ${CADDY_DROPIN%/*} ]]; then
        os::run '创建 systemd drop-in 目录' -- mkdir -p "${CADDY_DROPIN%/*}" || return 1
    fi
    os::install_file --mode 0644 "${tmp}" "${CADDY_DROPIN}" || return 1
    CADDY_DROPIN_CHANGED=${OS_TEMPLATE_CHANGED}
    return 0
}

# 起服务前把日志目录里的东西交还给 caddy。
#
# root 属主的日志文件太容易出现了：`caddy validate` 会 provision 模块、**真把
# 配置里写的日志文件建出来**，而校验要读 0600 的环境文件，只能以 root 跑。
# 人手工敲一次 validate 也一样。
#
# 留下一个 root:root 0600 的文件之后，caddy 进程打不开它 —— **启动直接失败**，
# 不是降级也不是告警。而 LogsDirectory= 兜不住这种情况（见上）。
#
# 先探再改：目录本来就对时不留审计记录，第二次执行才是真的零变更。
fix_log_owner() {
    [[ -d ${CADDY_LOG_DIR} ]] || return 0
    os::query -- find "${CADDY_LOG_DIR}" ! -user caddy -print -quit || return 0
    [[ -n ${OS_RUN_OUTPUT} ]] || return 0
    os::record_change "把 ${CADDY_LOG_DIR} 的属主改回 caddy"
    os::run '把日志目录交还给 caddy 用户' -- chown -R caddy:caddy "${CADDY_LOG_DIR}"
}

# Ubuntu 的 caddy 包带一份 AppArmor profile，按 apt 那份二进制写死。
# 换成自定义二进制后策略对不上，enforce 模式下服务会被拒绝启动。
relax_apparmor() {
    # aa-complain 由 apparmor-utils 提供；系统事实只出自 probe::（§3），
    # 不绕开它自己判 command -v
    probe::package_installed apparmor-utils
    [[ ${OS_PROBE_VALUE} == yes ]] || return 0
    [[ -f /etc/apparmor.d/usr.bin.caddy ]] || return 0
    probe::service_active apparmor.service
    [[ ${OS_PROBE_VALUE} == active ]] || return 0

    # 这是降低安全性的选项，默认必须为 n，且要同步说清补偿控制
    if ! os::confirm --arg relax-apparmor \
        'AppArmor 正在保护 Caddy，而自定义二进制会对不上策略。是否改为 complain 模式？' n; then
        os::warn 'AppArmor 保持 enforce —— 若 Caddy 起不来，先看它是不是被拦了'
        return 0
    fi
    os::record_change '把 Caddy 的 AppArmor 策略改为 complain'
    os::run '调整 AppArmor 策略' -- aa-complain /usr/bin/caddy
    os::warn 'AppArmor 已降为 complain（只告警不拦截）。补偿控制：Caddy 仍以专用 caddy 用户运行，且只持有 cap_net_bind_service'
    return 0
}

# Caddy 要对外提供服务就得有这三条。443 的 udp 是 HTTP/3 —— 少了它不会有
# 任何报错，只是浏览器悄悄退回 TCP，而那正是「配了 HTTP/3 却一直没生效」
# 这类问题最难查的形态。
readonly -a CADDY_FW_RULES=(80/tcp 443/tcp 443/udp)

# 这三条里还差哪些，结果写进 CADDY_FW_MISSING。
#
# 判定经 os::ufw_allowed（§11）。**从前是 `${rules} == *'443'*` 这样的子串判**，
# 那会被 `18443`、`4430` 或规则里的任何一处「443」蒙混过去，于是明明没放行
# 却一声不吭。
CADDY_FW_MISSING=()

collect_missing_rules() {
    probe::ufw_rules
    local rules=${OS_PROBE_VALUE} one
    CADDY_FW_MISSING=()
    for one in "${CADDY_FW_RULES[@]}"; do
        os::ufw_allowed "${rules}" "${one%/*}" "${one#*/}" && continue
        CADDY_FW_MISSING+=("${one}")
    done
    return 0
}

# 安装收尾：UFW 开着但 80/443 没放行时问一句。
#
# **默认否**（§15：放宽访问来源默认必须为否），而且只在 UFW 确实启用时才问 ——
# 没有防火墙时这几个端口本来就通着，问了是噪声。
#
# 问一句而不是只丢一行提示：装 Caddy 的目的就是对外提供服务，而「装完了但外面
# 访问不到」这件事从 Caddy 自己的日志里看不出来（它照常监听、照常启动），
# 用户只会看到浏览器转圈。但放不放行仍然是用户的决定 —— 内网反代、云厂商
# 安全组已经挡在前面、只做本机 TLS 终结，都是不该自动开口的形态。
offer_firewall_allow() {
    probe::ufw_active
    [[ ${OS_PROBE_VALUE} == yes ]] || return 0
    collect_missing_rules
    [[ ${#CADDY_FW_MISSING[@]} -gt 0 ]] || return 0

    # **在子 shell 里改 IFS**。`local IFS=' '` 是动态作用域，它会一路盖到本函数
    # 往下调用的每一个函数里，而脚本头把 IFS 设成 $'\n\t' 是有人依赖的。
    local missing
    missing=$(
        IFS=' '
        printf '%s' "${CADDY_FW_MISSING[*]}"
    )
    os::confirm --arg allow-web-ports \
        "UFW 已启用，但没放行 ${missing} —— 外面访问不到这台机器上的站点。放行？" n || {
        os::info '留着了。自己放行：oneserver firewall allow --ports=80,443'
        return 0
    }

    # **放行失败不让安装失败**。走到这里 Caddy 已经装好、起来、也 enable 了 ——
    # 以非零中止会让人以为 Caddy 没装上，而实际缺的只是一条防火墙规则，
    # 用户自己一条命令就能补。这也是这个函数与 web.sh 里同名函数的分界：
    # 那边放行是 `web enable` 这条命令的一部分，做不到就是没做完。
    local one
    for one in "${CADDY_FW_MISSING[@]}"; do
        os::ufw_allow "${one%/*}" "${one#*/}" || {
            os::warn "放行 ${one} 失败。Caddy 已经装好了，自己补：oneserver firewall allow --ports=80,443"
            return 0
        }
    done
    os::ufw_reload || {
        os::warn '规则已加上但 ufw reload 失败，可能还没生效：oneserver firewall reload'
        return 0
    }
    os::ok "已放行 ${missing}（所有来源）"
    return 0
}

# ------------------------------------------------------------------

main() {
    resolve_arch

    # 1) 插件组合。**默认零输入**：回车就是清单原样。
    #    清单在 OS_DEFAULT_CADDY_PLUGINS，用户改 /etc/oneserver/oneserver.conf，
    #    脚本一个字都不用动。序号、增删与拒绝规则全在 os::multiselect 里。
    caddy_load_defaults
    local picked=''
    os::multiselect --arg plugins 'Caddy 插件清单' picked "${CADDY_OPTIONS[@]}"
    caddy_normalize CADDY_PLUGINS "${picked}"

    # 「动过清单」看的是**最终组合**，不是用户敲了什么形态：把清单原样敲一遍
    # 也是没动过，而按输入形态判会把它误判成动过，于是和 --skip-official
    # 撞出一个并不存在的冲突。
    CADDY_CUSTOMIZED=0
    if [[ ${CADDY_PLUGINS} != "${CADDY_DEFAULT_SET}" ]]; then
        CADDY_CUSTOMIZED=1
    fi

    local skip_official=0
    os::flag --arg skip-official && skip_official=1

    # 2) 依赖。setcap 在 libcap2-bin 里，最小安装的机器上没有，
    #    而它是切二进制那一步的硬前提
    os::pkg_install ca-certificates curl gnupg tar libcap2-bin apt-transport-https
    # od / stat 用于验形（按需构建那条路没有 SHA256，只能验 ELF 魔数与体积）
    os::require_cmd curl gpg tar sha256sum od stat dpkg-divert update-alternatives

    probe::component_version caddy
    local current=${OS_PROBE_VALUE%%$'
'*}
    [[ -n ${current} ]] && os::info "当前已安装：${current}"

    local dir
    os::tmpdir dir

    setup_apt_repo "${dir}" || os::die 1 '配置 Caddy apt 源失败'
    os::pkg_install caddy

    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（二进制尚未下载，验证与切换都要真实文件）'
        os::output 0 arch="${CADDY_ARCH}" plugins="${CADDY_PLUGINS:-none}" changed=dry-run
        return 0
    fi

    install_dropin "${dir}" || os::die 1 '写入 Caddy 的 systemd drop-in 失败'

    # 3) 已经是目标状态就别下载了。
    #
    # 判据三条**缺一不可**：state 记的插件组合与这次算出来的一样 · 已装版本
    # 就是仓库最新版 · /usr/bin/caddy 确实指向自定义二进制。少一条都会误判 ——
    # 比如只比版本号，apt 原版与插件版的 `caddy version` 输出一模一样，
    # 「装了插件版」和「根本没装插件」就分不出来了。
    #
    # 省下的是每次执行都重下十几 MB，以及官方那次现场编译的等待。
    local -i want_switch=1
    [[ -z ${CADDY_PLUGINS} ]] && want_switch=0

    if [[ ${want_switch} -eq 1 && -n ${current} ]]; then
        local recorded
        recorded=$(os::state_get caddy plugins)
        os::query -- readlink -f /usr/bin/caddy
        if [[ ${recorded} == "${CADDY_PLUGINS}" && ${OS_RUN_OUTPUT} == "${CADDY_CUSTOM_BIN}" ]] \
            && resolve_latest_tag && [[ ${current%% *} == "${CADDY_TAG}" ]]; then
            os::ok "已是最新版 ${CADDY_TAG}，插件组合未变，跳过下载"
            want_switch=0
        fi
    fi

    # 4) 取二进制。**官方第一顺序**（任意组合都能编），仓库兜底（有 SHA256）。
    #
    #    顺序是这么定的（D106）：官方能满足任意插件清单，永远最新；仓库那份
    #    只覆盖清单原样的组合。把只覆盖一种组合的源放在第一位，等于让「加一个
    #    插件」这件事默认走不通。代价是默认路径没有校验和 ——规范为
    #    「按需构建」留的例外，靠 TLS + 功能验证兜。
    if [[ ${want_switch} -eq 1 ]]; then
        # 二进制单独要一个**可执行**的临时目录：上面那个 dir 在 /run 下，而
        # systemd 给 /run 挂 noexec —— 下载完 chmod 0755 也跑不起来，
        # verify_binary 必然失败，且报错指向文件而不是挂载选项
        local bindir
        os::tmpdir bindir --exec || os::die 1 '无法创建可执行的临时目录'

        local -i ok=0 rc=0 round=0
        local choice='' repick=''

        # 官方这条路最多走三轮：每轮失败后**按失败原因分岔**。
        # HTTP 4xx 是唯一「用户改一下就能成」的失败，所以只有它会回头问人；
        # 其余（超时、DNS、反复传输失败）不是用户能改的，直接进兜底。
        while [[ ${ok} -eq 0 && ${skip_official} -eq 0 ]]; do
            round=$((round + 1))
            os::info '官方按需构建：现场编译，没有可校验的 SHA256，靠 TLS 与随后的功能验证'
            rc=0
            fetch_from_official "${bindir}" || rc=$?
            if [[ ${rc} -eq 0 ]]; then
                ok=1
                break
            fi
            if [[ ${rc} -ne 22 ]]; then
                break
            fi

            os::err '官方按需构建拒绝了这个插件组合（HTTP 4xx）'
            os::info '多半是插件名写错，或那个插件没有被 Caddy 的插件注册表收录'
            os::kv '当前组合' "${CADDY_PLUGINS}"
            if [[ ${round} -ge 3 ]]; then
                os::die 2 '连续三次都被官方拒绝，请核对插件名后重新执行'
            fi
            # `--keep-screen`：上面那三行（被拒绝、多半是什么原因、当前组合）
            # 是选「重试还是换预构建」的全部依据，清屏就等于什么都没说
            os::select --keep-screen --arg on-build-error '接下来怎么办' choice \
                'retry=改插件名，再试一次官方' 'prebuilt=改用仓库预构建' 'abort=放弃'
            case ${choice} in
                retry)
                    # --reask 是必须的：不加的话这里读到的还是命令行上那个被
                    # 官方顶回来的值，三轮问的是同一件事，等于挂起
                    repick=''
                    os::multiselect --reask --arg plugins 'Caddy 插件清单' repick "${CADDY_OPTIONS[@]}"
                    caddy_normalize CADDY_PLUGINS "${repick}"
                    CADDY_CUSTOMIZED=0
                    if [[ ${CADDY_PLUGINS} != "${CADDY_DEFAULT_SET}" ]]; then
                        CADDY_CUSTOMIZED=1
                    fi
                    ;;
                prebuilt) break ;;
                *) os::die 2 '已放弃，没有做任何替换' ;;
            esac
        done

        if [[ ${ok} -eq 0 ]]; then
            # **用预构建之前一律确认。** 唯一免问的是 --skip-official 且组合没被
            # 增删过：那时用户已经显式点名要这个来源，而且什么都不会丢
            if [[ ${skip_official} -eq 0 ]]; then
                confirm_prebuilt '官方按需构建这次用不了'
            elif [[ ${CADDY_CUSTOMIZED} -eq 1 ]]; then
                confirm_prebuilt '按 --skip-official 使用本项目仓库的预构建'
            fi

            rc=0
            fetch_from_github "${bindir}" && ok=1 || rc=$?
            # 2 = 校验不过。**这条路不许降级**：改用无校验的源等于让
            # 「让校验失败」成为绕过校验的手段（D97）
            if [[ ${rc} -eq 2 ]]; then
                os::die 1 'Caddy 二进制未通过 SHA256 校验，拒绝安装（不会自动改用无校验的来源）'
            fi
        fi
        [[ ${ok} -eq 1 ]] || os::die 1 '两个来源都拿不到可用的 Caddy 二进制'

        verify_binary "${bindir}/caddy" || os::die 1 'Caddy 二进制验证未通过，没有做任何替换'
        switch_binary "${bindir}/caddy" || os::die 1 '替换 Caddy 二进制失败'
        relax_apparmor
    fi

    # 5) 起服务。**二进制与 drop-in 都没换就不重启** —— 重启一个正在服务的
    #    Caddy 是实打实的变更（连接被掐、证书重新加载），而规范要求第二次执行
    #    零变更。服务本来就没跑的话仍然要拉起来，那不是变更，是达到目标状态。
    #
    #    drop-in 变了必须 **restart 而不是 reload**：LogsDirectory 是 systemd
    #    起进程前才处理的，reload 只让 Caddy 重读配置，日志目录一样不会出现。
    fix_log_owner
    probe::service_active caddy.service
    if [[ ${CADDY_BIN_CHANGED} -eq 1 || ${CADDY_DROPIN_CHANGED} -eq 1 || ${OS_PROBE_VALUE} != active ]]; then
        os::systemd_daemon_reload
        os::systemd_restart caddy.service
    fi

    probe::service_active caddy.service
    if [[ ${OS_PROBE_VALUE} != active ]]; then
        os::query --timeout 10 -- journalctl -u caddy.service --no-pager -n 20
        os::debug "journalctl 尾部：${OS_RUN_OUTPUT}"
        os::die 1 'Caddy 服务启动失败，日志里有 journalctl 的尾部输出'
    fi
    os::systemd_enable caddy.service

    # 6) 状态与**资源清单**。
    #    没有这一段，F6 的 uninstall 就只能靠猜 —— 而猜错的代价是把 dpkg 管的
    #    文件删掉，或者把用户本来就装着的包 purge 掉。
    probe::component_version caddy
    local ver=${OS_PROBE_VALUE%%$'\n'*}
    local method='apt+custom-bin'
    [[ -z ${CADDY_PLUGINS} ]] && method='apt'
    os::state_set caddy version="${ver}" method="${method}" plugins="${CADDY_PLUGINS:-none}"

    # 只登记**本组件自己的**包，而且只在本次真装上时登记。
    #
    # 两层过滤缺一不可：
    #   * 本来就有的不记 —— 否则卸载会 purge 掉用户自己装的东西
    #   * `ca-certificates` / `curl` / `gnupg` / `apt-transport-https` 这些通用
    #     依赖不记 —— 它们不属于 Caddy，卸载 Caddy 把 curl 一起 purge 掉，
    #     后果比留下一个包严重得多。**验收时就是在 state 里看见 apt-transport-https
    #     才发现这一点的。**
    local pkg
    while IFS= read -r pkg; do
        [[ ${pkg} == caddy ]] || continue
        os::state_resource_add caddy pkg "${pkg}"
    done < <(os::pkg_installed_names)

    # 本项目放下的文件。/etc/caddy/Caddyfile 与 /var/lib/caddy **不登记**：
    # 前者是用户配置、后者是 ACME 账户与证书私钥，卸载时删掉它们
    # 意味着要重新签发，还可能撞上 CA 的速率限制
    # 只登记本次真正建出来的那份（理由见 CADDY_KEYRING_CREATED 的声明处）
    ((CADDY_KEYRING_CREATED == 1)) && os::state_resource_add caddy file "${CADDY_KEYRING}"
    ((CADDY_LIST_CREATED == 1)) && os::state_resource_add caddy file "${CADDY_LIST}"
    # drop-in 登记，/var/log/caddy **不登记** —— 目录是 systemd 建的，
    # 里面是日志（数据），卸载只打印位置不删（§12）
    os::state_resource_add caddy file "${CADDY_DROPIN}"
    if [[ -n ${CADDY_PLUGINS} ]]; then
        os::state_resource_add caddy file "${CADDY_CUSTOM_BIN}"
        os::state_resource_add caddy divert /usr/bin/caddy
        os::state_resource_add caddy alt "caddy:${CADDY_CUSTOM_BIN}"
        [[ -x ${CADDY_DEFAULT_BIN} ]] && os::state_resource_add caddy alt "caddy:${CADDY_DEFAULT_BIN}"
    fi

    local shown_bin=${CADDY_CUSTOM_BIN}
    [[ -z ${CADDY_PLUGINS} ]] && shown_bin='/usr/bin/caddy'
    os::kv '版本' "${ver}" \
        '插件' "${CADDY_PLUGINS:-none（apt 原版）}" \
        '二进制' "${shown_bin}" \
        '配置文件' /etc/caddy/Caddyfile \
        '证书目录' /var/lib/caddy \
        '日志目录' '/var/log/caddy（0750 caddy:caddy，由 systemd 维护）'

    local changed_text='no'
    if [[ ${CADDY_BIN_CHANGED} -eq 1 ]]; then
        changed_text='yes'
        os::ok "Caddy 已安装/升级：${ver}"
    else
        os::ok "Caddy ${ver} 已是目标状态"
    fi

    # **排在资源清单之后**：这一步会停下来问一句，而在它前面中断就意味着
    # Caddy 装好了、起来了，state 里却什么都没有 —— uninstall 从此找不到它。
    # 放行本身与 Caddy 装没装是两件事，问晚一点不损失什么。
    offer_firewall_allow

    os::output 0 version="${ver}" arch="${CADDY_ARCH}" \
        plugins="${CADDY_PLUGINS:-none}" changed="${changed_text}"
    return 0
}

main "$@"
