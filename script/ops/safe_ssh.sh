#!/bin/bash
#
# SSH 加固：端口 · 公钥 · 关密码登录 · root 登录策略
#
# @command      safe ssh
# @name         SSH 加固
# @group        security
# @order        20
# @privilege    root
# @requires_lib >= 4.0
# @provides_unit ext:ssh.service
# @provides_unit ext:ssh.socket
# @args         [--add-pubkey=<y|n>] [--user=<用户名>] [--pubkey=<公钥内容>] [--pubkey-file=<路径>] [--port=<端口>] [--password-auth=<keep|no|yes>] [--permit-root-login=<keep|prohibit-password|no|yes>]
# @description  改端口、装公钥、关密码登录、限制 root 登录
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ## 为什么整份配置写 sshd_config.d/00-oneserver.conf
#
# 只写自己的一个片段文件，删掉它即回到发行版默认；不去遍历别人的
# sshd_config.d/*.conf 改 `PasswordAuthentication` —— 那是别的包
# （cloud-init、systemd-userdb）或用户自己的文件，改它就是「工具悄悄替你改了
# 你不知道的配置」，而且下次那个包升级就还原了。
#
# **文件名以 00- 开头是有意的**（模板里也写了理由）：sshd 的取值规则是「第一次
# 出现的值生效」，片段按文件名字典序读入 —— Ubuntu 云镜像自带的
# 50-cloud-init.conf 里写着 `PasswordAuthentication yes`，用 99- 命名的加固片段
# 会被它整个盖掉，而表现是「工具说已关闭密码登录，实际还开着」。
#
# ## 为什么改完必须问 `sshd -T`，而不是相信自己写了什么
#
# 同上：真正生效的值取决于哪个文件先被读到。写完文件就宣布成功，等于把「我打算
# 做什么」当成「系统现在是什么」。所以每次改完都：
#
#   sshd -t     语法过不过（不过就整个回滚，服务一步都不动）
#   sshd -T     有效值是不是我要的（不是就报出哪个文件在抢，并回滚）
#   probe::port_listening   端口真的在听吗（不在就回滚 + 恢复原样重启）
#
# ## socket 激活：Ubuntu 上改 Port 是不生效的
#
# 在两台真机上实测：
#   Ubuntu 24.04   ssh.socket enabled  · ssh.service disabled
#   Debian 13      ssh.socket disabled · ssh.service enabled
#
# socket 激活时监听由 systemd 完成，端口写在 ssh.socket 的 ListenStream，
# sshd 拿到的是一个已经连上的 fd —— sshd_config 里的 `Port` 完全不起作用。
# 把 ssh.socket 停掉禁用换回 ssh.service 是把发行版的默认形态改掉，用户下次
# apt 升级 openssh 时两边打架。这里**顺着发行版**：socket 激活的机器写一个
# ssh.socket 的 drop-in 覆盖 ListenStream，非 socket 的机器就只改 sshd_config。
# 两条路都验证监听。
#
# ## 卸载时**不**还原 SSH 配置（所以不登记 file 资源）
#
# 规范要求安装类把创建的文件登记进 state 供 uninstall 反向执行。这里有意不登记
# 00-oneserver.conf 与 ssh.socket 的 drop-in：卸载一个管理工具就把 SSH 端口还原
# 成 22、把密码登录打开，是**在卸载动作里降低安全性**，而且很可能直接把人锁在
# 门外（防火墙只放行了新端口）。规范的「永不自动删除」一栏里，用户配置本来就在
# 其中。`oneserver safe status` 会打出这两个文件在哪，要还原的人删掉它们即可。
#
# ## 碰 UFW 的那一处不是防火墙管理
#
# 改配置前确认当前 SSH 端口在放行清单里 —— 这条命令跑完往往紧接着就是断开重连，
# 到那一刻才发现被自己的防火墙挡住就晚了。装卸启停与规则全归 `oneserver firewall`。
#

readonly SSHD_CONFIG='/etc/ssh/sshd_config'
readonly SSHD_DROPIN_DIR='/etc/ssh/sshd_config.d'
readonly SSHD_DROPIN='/etc/ssh/sshd_config.d/00-oneserver.conf'
readonly SOCKET_DROPIN_DIR='/etc/systemd/system/ssh.socket.d'
readonly SOCKET_DROPIN='/etc/systemd/system/ssh.socket.d/00-oneserver-port.conf'
# ufw 的输出在不同 locale 下措辞不同，而「这条规则是本次新增的还是本来就有」
# 只能靠输出文本判定（退出码两种情况都是 0）。所有 ufw 调用统一注入它
readonly UFW_ENV='LC_ALL=C'

# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

# ssh 服务的 unit 名。Debian/Ubuntu 是 ssh.service，别的发行版叫 sshd.service，
# 而两边都装了 sshd.service 作为别名 —— 认得出哪个是真的才敢去 restart 它。
#
# **用变量返回，不 printf + $( )**（D135）：子 shell 会把 probe 的
# OS_PROBE_SOURCE / OS_PROBE_AGE 一起吞掉。
safe_ssh_unit() {
    local __safe_out=${1}
    probe::unit_exists 'ssh.service'
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        printf -v "${__safe_out}" '%s' 'ssh.service'
        return 0
    fi
    printf -v "${__safe_out}" '%s' 'sshd.service'
    return 0
}

# 这台机器是不是 socket 激活的 SSH。与 safe_status.sh 里那份是同一段，
# **两处相似不提取**（那边的注释里写了取舍）。
safe_socket_activated() {
    probe::unit_exists 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == yes ]] || return 1
    probe::service_enabled 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == enabled ]] && return 0
    probe::service_active 'ssh.socket'
    [[ ${OS_PROBE_VALUE} == active ]] && return 0
    return 1
}

# `PermitRootLogin` 的取值归一。
#
# **Debian 13 的 `sshd -T` 打的是 `without-password`**（容器实测），
# 那是 `prohibit-password` 在 openssh 6.x 时代的旧名字，两者语义完全相同。
# 不归一的话有两个后果：① 把当前有效值原样当成「用户想要的值」再写回配置时，
# 会被自己的取值校验拦下；② 写 `prohibit-password` 之后读回 `without-password`，
# 「有效值核对」会判成没生效，然后**回滚一次本来完全正确的加固**。
safe_norm_rootlogin() {
    local __safe_out=${1} __safe_val=${2}
    [[ ${__safe_val} == without-password ]] && __safe_val='prohibit-password'
    printf -v "${__safe_out}" '%s' "${__safe_val}"
    return 0
}

safe_require_sshd() {
    probe::package_installed openssh-server
    if [[ ${OS_PROBE_VALUE} != yes ]]; then
        os::die 3 '没有检测到 openssh-server。装 SSH 服务端不是本工具的职责：apt-get install openssh-server'
    fi
    os::require_cmd sshd ssh-keygen systemctl

    # sshd 的特权分离目录。**没有它 `sshd -t` 会直接拒绝校验**：
    #   Missing privilege separation directory: /run/sshd
    # 而 /run/sshd 是 ssh.service 的 RuntimeDirectory —— **systemd 在服务停止时
    # 把它删掉**。也就是说，SSH 当前没在跑的机器（刚被中断打断、或用户先停了
    # 服务再来改配置），我们连自己写的配置能不能用都校验不了，
    # 于是每一次都以「sshd 拒绝了新配置」收场并回滚，而真正的原因在别处。
    #
    # 它在 tmpfs 上、重启即消失、systemd 自己也会重建，因此不进变更清单、
    # 不进资源清单 —— 这不是一处需要撤销的副作用。
    if [[ ! -d /run/sshd ]]; then
        os::run '创建 sshd 特权分离目录' -- mkdir -p -m 0755 /run/sshd
    fi
    return 0
}

# 谁在抢这个配置项。改完发现有效值不是我们写的值时，用它把话说具体：
# 「PasswordAuthentication 没生效」帮不上忙，「50-cloud-init.conf 第 1 行
# 写着 PasswordAuthentication yes，它排在 00-oneserver.conf 前面」才是答案。
safe_who_wins() {
    local key=${1}
    os::query --timeout 5 -- \
        grep -rniE "^[[:space:]]*${key}[[:space:]]" "${SSHD_CONFIG}" "${SSHD_DROPIN_DIR}/" || true
    return 0
}

# 把一把公钥装进 <user>/.ssh/authorized_keys。
#
# 三件事按顺序：**先校验格式**（sshd 对认不出来的行是静默忽略，用户以为配好了，
# 关掉密码登录之后才发现登不上）· 已存在就不重复追加· 落地经
# os::install_file 换 inode（authorized_keys 正被 sshd 读，且 dry-run 必须零变更）。
safe_install_pubkey() {
    local user=${1} home=${2} key=${3}
    local ssh_dir="${home}/.ssh"
    local ak="${ssh_dir}/authorized_keys"

    local dir tmp
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    tmp="${dir}/pubkey"
    printf '%s\n' "${key}" >"${tmp}"

    if ! os::query --timeout 10 -- ssh-keygen -l -f "${tmp}"; then
        os::die 2 '这不是一把 ssh-keygen 认得的公钥（复制时被换行截断是最常见的原因）'
    fi
    os::info "公钥指纹：${OS_RUN_OUTPUT%%$'\n'*}"

    if [[ -f ${ak} ]] && os::query --timeout 5 -- grep -qxF -- "${key}" "${ak}"; then
        os::ok "这把公钥已经在 ${ak} 里，未重复添加"
        return 0
    fi

    os::run '创建 .ssh 目录' -- mkdir -p "${ssh_dir}"
    os::run '设置 .ssh 目录权限' -- chmod 0700 "${ssh_dir}"

    local newak="${dir}/authorized_keys"
    if [[ -f ${ak} ]]; then
        os::run '取出现有的 authorized_keys' -- cp -- "${ak}" "${newak}"
    else
        : >"${newak}"
    fi
    # dry-run 下上面的 cp 被跳过，newak 是空的 —— 那样落地会「删掉」现有的钥匙。
    # 预演不真写文件，所以不会出事，但也不能让它打出「将写入 1 把公钥」这种
    # 与真实执行不符的话。到这一步就够了，直接声明预演到此为止
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info "[dry-run] 将把公钥追加到 ${ak}"
        return 0
    fi
    printf '%s\n' "${key}" >>"${newak}"

    # 覆盖一个可能已有内容的文件 —— 先备份（规范第三类）。
    # os::backup_file 同时注册了「还原副本」的回滚动作
    os::backup_file "${ak}" || os::die 1 "备份 ${ak} 失败"
    os::install_file --mode 0600 "${newak}" "${ak}" || os::die 1 "写入 ${ak} 失败"
    os::run '设置 authorized_keys 属主' -- chown -R "${user}:" "${ssh_dir}"
    os::ok "公钥已加入 ${ak}"
    return 0
}

# 公钥问答的产物。SAFE_KEY_USER 永远有值（末尾那句 `ssh -p … <user>@` 要用它），
# SAFE_KEY 为空表示这次不装公钥。
SAFE_KEY_USER='root'
SAFE_KEY_HOME=''
SAFE_KEY=''

# 决定这次要不要问公钥、问谁，以及已经有公钥时还要不要再加一把。
#
# **必须排在登录方式定下来之后**：`--password-auth=no` 与
# `--permit-root-login=no|prohibit-password` 是「从此只能拿钥匙进门」，公钥是
# 它们的前提；而登录方式一个字没改时，公钥只是顺手做的一件事，不该拦住只想改
# 端口的人 —— 不分辨这两种情形，就是不管选什么都先过一遍三道公钥问题，其中
# 「给哪个用户」还会因为一个这次根本用不到的用户名不存在而以退出码 2 停下。
#
# 已有公钥的用户不再被盲问一句「要授权的公钥内容」：先把指纹列出来，再问要不要
# **再加一把**。用户看得见自己配过什么，才谈得上决定要不要更新。
safe_ask_pubkey() {
    local want_pw=${1} want_root=${2}

    # 这次改动要不要求「有钥匙才进得来」，以及是哪个选择要求的
    local -i need_key=0
    local why=''
    if [[ ${want_pw} == no ]]; then
        need_key=1
        why='关闭密码登录'
    fi
    if [[ ${want_root} == prohibit-password ]]; then
        need_key=1
        why="${why:+${why}、}root 仅允许密钥登录"
    elif [[ ${want_root} == no ]]; then
        need_key=1
        why="${why:+${why}、}禁止 root 登录"
    fi

    # 命令行直接把钥匙给了就不再问要不要 —— 否则 --non-interactive 下确认点
    # 取默认值 n，用户明明传了 --pubkey 却被静默丢掉
    local -i given=0
    if os::flag --arg pubkey || os::flag --arg pubkey-file; then
        given=1
    fi

    if [[ ${given} -eq 0 && ${need_key} -eq 0 ]]; then
        os::confirm --arg add-pubkey '顺便给某个用户装一把 SSH 公钥？' n || return 0
    fi

    # 禁用 root 登录时**不给默认值**：将来由谁负责登录必须由人指明，
    # 猜一个 root 出来，正好是这次要禁掉的那个
    if [[ ${want_root} == no ]]; then
        os::ask --arg user '禁用 root 之后由哪个用户负责登录' SAFE_KEY_USER
    else
        os::ask --arg user 'SSH 公钥要授权给哪个用户' SAFE_KEY_USER 'root'
    fi
    [[ ${SAFE_KEY_USER} =~ ^[a-z_][a-z0-9_-]*$ ]] \
        || os::die 2 "用户名「${SAFE_KEY_USER}」不合法"
    probe::user_home "${SAFE_KEY_USER}"
    SAFE_KEY_HOME=${OS_PROBE_VALUE}
    [[ -n ${SAFE_KEY_HOME} && -d ${SAFE_KEY_HOME} ]] \
        || os::die 2 "用户 ${SAFE_KEY_USER} 不存在，或它的 home 目录不在"

    # 现有的钥匙：数字之外还要指纹。「已有 2 把」回答不了用户真正想问的
    # 「里面有没有我手上这台机器的那把」，而那才是他决定要不要再加时依据的东西
    probe::ssh_authkeys "${SAFE_KEY_USER}"
    local -i have=${OS_PROBE_VALUE}
    if ((have > 0)); then
        os::info "用户 ${SAFE_KEY_USER} 的 authorized_keys 里已有 ${have} 把公钥："
        if os::query --timeout 5 -- ssh-keygen -lf "${SAFE_KEY_HOME}/.ssh/authorized_keys"; then
            local line
            while IFS= read -r line; do
                [[ -n ${line} ]] && os::info "    ${line}"
            done <<<"${OS_RUN_OUTPUT}"
        fi
    fi

    if [[ ${given} -eq 0 ]]; then
        if ((have > 0)); then
            # 已经有钥匙，这次改动的前提就已经满足 —— 默认不动它
            os::confirm --arg add-pubkey '再加一把公钥？（选否就沿用上面这些）' n || return 0
        elif [[ ${need_key} -eq 1 ]]; then
            # 一把都没有，而这次改动正是「从此只能拿钥匙进门」。这里不用
            # 「回车跳过」的措辞：跳过的真实结果是下面的锁门检查以退出码 2 停下
            os::warn "用户 ${SAFE_KEY_USER} 一把公钥都没有，而你选了「${why}」—— 现在必须装一把，否则这次改动会把你锁在门外"
        fi
    fi

    # 两条来源二选一。命令行同时给两个是矛盾指令，当场拒绝；
    # 交互下填了内容就不再问文件路径，少问一遍
    if os::flag --arg pubkey && os::flag --arg pubkey-file; then
        os::die 2 '--pubkey 与 --pubkey-file 只能给一个'
    fi
    os::ask --arg pubkey '要授权的公钥内容（ssh-ed25519 / ssh-rsa 开头的一整行，回车改从文件读）' SAFE_KEY ''
    if [[ -z ${SAFE_KEY} ]]; then
        local pubkey_file=''
        os::ask --arg pubkey-file '公钥文件路径（.pub 文件，回车跳过）' pubkey_file ''
        if [[ -n ${pubkey_file} ]]; then
            [[ -f ${pubkey_file} ]] || os::die 2 "公钥文件不存在：${pubkey_file}"
            IFS= read -r SAFE_KEY <"${pubkey_file}" || true
            [[ -n ${SAFE_KEY} ]] || os::die 2 "公钥文件是空的：${pubkey_file}"
        fi
    fi
    return 0
}

# 写 sshd 配置。返回后读 SAFE_SSHD_CHANGED 知道有没有真的改动。
SAFE_SSHD_CHANGED=0

safe_apply_sshd() {
    local port=${1} pw=${2} rootlogin=${3}
    SAFE_SSHD_CHANGED=0

    # 主配置有没有 Include 片段目录（两台真机实测都在第 12 行）。
    # 没有的话说明用户自己重写过 sshd_config，我们不去替他重排文件结构，
    # 退回到逐行改主配置
    if os::query --timeout 5 -- \
        grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "${SSHD_CONFIG}"; then

        local -i existed=0
        [[ -f ${SSHD_DROPIN} ]] && existed=1

        os::run '创建 sshd 配置片段目录' -- mkdir -p "${SSHD_DROPIN_DIR}"
        os::install_template --backup --mode 0600 \
            "${OS_TEMPLATE_DIR}/sshd-oneserver.conf" "${SSHD_DROPIN}" \
            PORT="${port}" \
            PUBKEY_AUTH='yes' \
            PASSWORD_AUTH="${pw}" \
            KBD_INTERACTIVE="${pw}" \
            PERMIT_ROOT_LOGIN="${rootlogin}" \
            || os::die 1 "写入 ${SSHD_DROPIN} 失败"
        SAFE_SSHD_CHANGED=${OS_TEMPLATE_CHANGED}

        # 本次新建的文件，撤销 = 删掉它（规范第一类）。
        # **只在原来不存在时注册**：文件本来就有的话，删掉等于把用户上一次的
        # 加固一起抹了 —— 那种情况由 --backup 注册的「还原副本」负责
        if [[ ${existed} -eq 0 && ${SAFE_SSHD_CHANGED} -eq 1 ]]; then
            os::defer rm -f -- "${SSHD_DROPIN}"
        fi
    else
        os::warn "${SSHD_CONFIG} 里没有 Include 片段目录，改主配置本身（已先备份）"
        local -i changed=0
        local kv key val
        # 注释掉的默认行（`#Port 22`）也要匹配，这样替换发生在**原来的位置**，
        # 而不是在文件末尾追加一行 —— 追加的那行会输给前面已经生效的值
        for kv in "Port ${port}" \
            'PubkeyAuthentication yes' \
            "PasswordAuthentication ${pw}" \
            "KbdInteractiveAuthentication ${pw}" \
            "PermitRootLogin ${rootlogin}"; do
            key=${kv%% *}
            val=${kv#* }
            os::replace_line --backup --append-if-missing "${SSHD_CONFIG}" \
                "^[#[:space:]]*${key}[[:space:]]" "${key} ${val}" \
                || os::die 1 "改写 ${SSHD_CONFIG} 的 ${key} 失败"
            [[ ${OS_REPLACE_CHANGED} -eq 1 ]] && changed=1
        done
        SAFE_SSHD_CHANGED=${changed}
    fi
    return 0
}

# ssh.socket 的端口 drop-in。**ListenStream= 那行空值不是笔误**：
# systemd 的列表型指令要先赋空值清掉 unit 自带的两条（v4 + v6），
# 不清的话新端口是**追加**的，机器会同时听在 22 和新端口上 ——
# 而用户以为 22 已经关了。
#
# **地址必须显式写 `0.0.0.0:<port>` 与 `[::]:<port>` 两条，禁止裸端口号**
# （两台真机实测踩过）：给 `ListenStream=` 一个裸端口号时，systemd 会自己拆成
# v4/v6 两个 socket 去配对——这条自动配对路径在**短时间内连续多次重配置同一个
# 运行中的 socket unit**（改端口来回试、菜单里连续操作）时会进入一种卡死状态：
# 新端口只绑上 IPv6，IPv4 静默拿不到监听，`ss`/`systemctl status` 都显示
# 「在监听」不报任何错，而且**已经卡死后，restart、甚至恢复成上一份能用的
# drop-in 再 restart 都救不回来**——唯一能救回来的是删掉 drop-in 整个回到
# 原厂配置。原厂 unit 自己就是显式写死两条地址（非裸端口），从未观测到同样问题；
# 让本工具写的 drop-in 与原厂格式一致，从根上不再依赖那条会卡死的自动配对路径。
safe_apply_socket_port() {
    local port=${1}
    local -i existed=0
    [[ -f ${SOCKET_DROPIN} ]] && existed=1

    local dir tmp
    os::tmpdir dir || os::die 1 '无法创建临时目录'
    tmp="${dir}/00-oneserver-port.conf"
    {
        printf '# 由 oneserver safe ssh 生成。删掉本文件即回到 ssh.socket 自带的端口。\n'
        printf '[Socket]\n'
        printf 'ListenStream=\n'
        printf 'ListenStream=0.0.0.0:%s\n' "${port}"
        printf 'ListenStream=[::]:%s\n' "${port}"
    } >"${tmp}"

    # `--backup` 不能省，且理由比别处更硬：**第二次改端口时**（existed=1）
    # 这里覆盖的是上一版 drop-in，而下面那条 `os::defer os::systemd_restart
    # ssh.socket` 会在失败回滚时重启 socket —— 没有副本可还原的话，重启用的
    # 是**已经换成新端口、且回滚没能改回去**的配置：工具报「已回滚」，
    # ssh.socket 实际听在新端口上。新端口没在安全组放行就是一次锁死，
    # 而当前会话还连着，要到断开重连才发现。sshd 那条等价路径（上面
    # safe_apply_sshd）一直是 --backup，这里跟它对齐。
    os::run '创建 ssh.socket 的 drop-in 目录' -- mkdir -p "${SOCKET_DROPIN_DIR}"
    os::install_file --backup --mode 0644 "${tmp}" "${SOCKET_DROPIN}" \
        || os::die 1 "写入 ${SOCKET_DROPIN} 失败"
    if [[ ${existed} -eq 0 && ${OS_TEMPLATE_CHANGED} -eq 1 ]]; then
        os::defer rm -f -- "${SOCKET_DROPIN}"
    fi
    os::systemd_daemon_reload
    return 0
}

# 上一次 safe_ufw_allow 是否真的新增了一条规则。
#
# **不能只看退出码**：ufw 对一条已存在的规则同样返回 0，只在输出里多打一句
# 「Skipping」。分不出「本次新增」与「用户早就有的」，注册的回滚就会去删掉
# 用户自己的规则。判据与 ufw_manager.sh 的 ufw_apply 一致。
SAFE_UFW_CHANGED=0

safe_ufw_allow() {
    local port=${1}
    SAFE_UFW_CHANGED=0

    # 有副作用且要读 stdout —— os::run_out 正是它的格子（D9），
    # 不能为了拿输出改用只读的 os::query 绕开 dry-run
    os::run_out --allow-fail --env "${UFW_ENV}" '放行 UFW 端口' -- \
        ufw allow "${port}/tcp" || true

    # dry-run 下命令没跑，输出必然是空的 —— 拿它去判定会打出「✓ 已放行」，
    # 让预演看起来像已经做完了（D15）。按「会改变」保守处理
    if [[ ${OS_RUN_SKIPPED} -eq 1 ]]; then
        SAFE_UFW_CHANGED=1
        return 0
    fi
    if [[ ${OS_RUN_STATUS} -ne 0 ]]; then
        os::err "放行 ${port}/tcp 失败"
        os::debug "ufw 输出：${OS_RUN_OUTPUT}"
        return 1
    fi
    case ${OS_RUN_OUTPUT} in
        *Skipping*) os::info "${port}/tcp 已在放行清单里，未重复添加" ;;
        *)
            SAFE_UFW_CHANGED=1
            os::ok "UFW 已放行 ${port}/tcp"
            ;;
    esac
    return 0
}

# ------------------------------------------------------------------

main() {
    safe_require_sshd

    probe::ssh_port
    local cur_port=${OS_PROBE_VALUE}
    probe::port_families "${cur_port}"
    local want_families=${OS_PROBE_VALUE}

    # 先问「要做什么」（登录方式）并把目标值定下来，再据此决定公钥要不要问、
    # 问谁 —— 关密码登录、限制 root 登录都要求先有公钥，公钥问题（含「给哪个
    # 用户」）整体排在选择之后，用户才看得出这几步是有因果关系的
    local port_in='' password_auth='' permit_root=''
    os::select --arg password-auth '密码登录' password_auth \
        'keep=保持现状' 'no=关闭密码登录' 'yes=开启密码登录'
    os::select --arg permit-root-login 'root 登录方式' permit_root \
        'keep=保持现状' 'prohibit-password=仅允许密钥' 'no=禁止 root 登录' 'yes=允许密码登录'

    # --- 目标值：keep 就沿用**当前有效值**，不是沿用配置文件里写了什么 ---
    #
    # 解析排在公钥问答之前：`keep` 落到哪一档决定了这次要不要公钥，
    # 而那是下面每一个公钥问题的前提
    probe::sshd_effective passwordauthentication
    local want_pw=${OS_PROBE_VALUE:-yes}
    probe::sshd_effective permitrootlogin
    local want_root=${OS_PROBE_VALUE:-prohibit-password}
    [[ ${password_auth} != keep ]] && want_pw=${password_auth}
    [[ ${permit_root} != keep ]] && want_root=${permit_root}
    safe_norm_rootlogin want_root "${want_root}"

    case ${want_pw} in
        yes | no) ;;
        *) os::die 2 "--password-auth 只认 keep/no/yes，当前有效值是「${want_pw}」" ;;
    esac
    case ${want_root} in
        yes | no | prohibit-password | forced-commands-only) ;;
        *) os::die 2 "--permit-root-login 的值「${want_root}」不是 sshd 认得的" ;;
    esac
    if [[ ${permit_root} == keep ]]; then
        os::debug "沿用当前有效的 root 登录策略：${want_root}"
    fi

    safe_ask_pubkey "${want_pw}" "${want_root}"

    os::ask --arg port "SSH 端口（当前 ${cur_port}，回车不改）" port_in ''
    local new_port=${cur_port}
    if [[ -n ${port_in} ]]; then
        [[ ${port_in} =~ ^[0-9]+$ ]] || os::die 2 "端口要是数字，收到「${port_in}」"
        ((port_in >= 1 && port_in <= 65535)) || os::die 2 "端口 ${port_in} 超出 1-65535"
        new_port=${port_in}
    fi
    if [[ ${new_port} != "${cur_port}" ]]; then
        probe::port_listening "${new_port}"
        [[ ${OS_PROBE_VALUE} == yes ]] \
            && os::die 2 "端口 ${new_port} 上已经有别的服务在听，换一个"
    fi

    # --- 先装公钥，再谈关密码登录。顺序反了就是「先拆梯子再上楼」 ---
    if [[ -n ${SAFE_KEY} ]]; then
        safe_install_pubkey "${SAFE_KEY_USER}" "${SAFE_KEY_HOME}" "${SAFE_KEY}"
    fi

    # --- 锁门检查：会把所有路一起断掉的两条不给确认选项，直接拒绝 ---
    #
    # 「危险但你确认就放行」在这里不成立：被锁在门外是**不可恢复**的
    # （云控制台的 VNC 不是每家都有，有的也不是人人会用），
    # 而代价只是先跑一条装公钥的命令
    if [[ ${want_pw} == no ]]; then
        probe::ssh_authkeys "${SAFE_KEY_USER}"
        local nkeys=${OS_PROBE_VALUE}
        ((nkeys > 0)) || os::die 2 \
            "用户 ${SAFE_KEY_USER} 一把公钥都没有，关掉密码登录就再也登不进来。先装公钥：oneserver safe ssh --user=${SAFE_KEY_USER} --pubkey=\"ssh-ed25519 AAAA...\""
        os::ok "用户 ${SAFE_KEY_USER} 有 ${nkeys} 把公钥，可以关密码登录"
    fi
    if [[ ${want_root} == no ]]; then
        [[ ${SAFE_KEY_USER} != root ]] || os::die 2 \
            '要禁用 root 登录，得先指明将来谁负责登录：oneserver safe ssh --user=<普通用户> --pubkey=... --permit-root-login=no（那个用户还要能 sudo）'
        probe::ssh_authkeys "${SAFE_KEY_USER}"
        ((OS_PROBE_VALUE > 0)) || os::die 2 \
            "禁用 root 登录之前，用户 ${SAFE_KEY_USER} 必须先有公钥 —— 否则两条路一起断了"
    fi
    # `prohibit-password` 同样是「从此只能拿钥匙进门」，只不过只约束 root。
    # 这里是告警而不是拒绝：密码登录还开着的话别的用户仍进得来，硬拒绝会拦掉
    # 「先给普通用户配钥匙、root 只留给控制台」这种完全合理的用法；两条路一起
    # 关的情形由上面 want_pw == no 那条拦下
    if [[ ${want_root} == prohibit-password ]]; then
        probe::ssh_authkeys root
        ((OS_PROBE_VALUE > 0)) \
            || os::warn 'root 一把公钥都没有 —— 改完之后 root 就只剩一个没有钥匙的钥匙孔，再也登不进来（密码登录还开着，别的用户不受影响）'
    fi

    # --- 别让防火墙把自己挡在门外：先放行，再改 ---
    #
    # **不改端口时这一步也要做。** 当前 SSH 端口未必在放行清单里 —— 端口可能是
    # 在防火墙启用之后才改的，规则也可能被人删过 —— 而这条命令跑完往往紧接着
    # 就是断开重连，到那一刻才发现被自己的防火墙挡住就晚了。
    # ufw 加一条已存在的规则是幂等的，本来就放行着的话只多打一行「未重复添加」
    probe::ufw_active
    if [[ ${OS_PROBE_VALUE} == yes ]]; then
        # SSH 端口**永不注册回滚**：防火墙此刻是启用着的，回滚删掉刚放行的规则
        # 之后，当前会话因为是已建立连接所以不断，下一次连接就进不来了
        safe_ufw_allow "${new_port}" \
            || os::die 1 "无法在 UFW 上放行 ${new_port}/tcp，SSH 配置一个字都没改"
        if [[ ${SAFE_UFW_CHANGED} -eq 1 ]]; then
            os::run --env "${UFW_ENV}" '重载 UFW 使放行生效' -- ufw reload
        fi
        if [[ ${new_port} != "${cur_port}" ]]; then
            os::info "旧端口 ${cur_port} 的规则保留着 —— 等你用新端口连上之后再删：oneserver firewall delete --ports=${cur_port} --proto=tcp --confirm-delete"
        fi
    else
        os::warn '这台机器没有启用防火墙，所有监听中的端口都对公网开着：oneserver firewall enable'
    fi
    if [[ ${new_port} != "${cur_port}" ]]; then
        os::warn "云服务器在机器外面还有一层安全组：${new_port} 要在厂商控制台放行，否则改完就连不上"
    fi

    # --- 万一后面哪一步失败，最后要把服务恢复成配置回滚后的样子 ---
    #
    # 回滚栈是**逆序**执行的，所以这一条要在动任何配置之前注册 ——
    # 它会在所有文件都还原之后才跑
    local ssh_unit=''
    safe_ssh_unit ssh_unit
    if safe_socket_activated; then
        os::defer os::systemd_restart 'ssh.socket'
    else
        os::defer os::systemd_restart "${ssh_unit}"
    fi

    safe_apply_sshd "${new_port}" "${want_pw}" "${want_root}"

    # dry-run 到此为止：文件没写、服务没重启，**再往下的每一句问的都是旧系统**——
    # `sshd -t` 校验的会是没改过的那份配置，「有效值是不是我要的」答案必然是否。
    # 拿旧系统的答案当预演结果，正是规范说的「会撒谎的 dry-run」
    if [[ ${OS_DRYRUN} -eq 1 ]]; then
        os::info '[dry-run] 后续步骤无法预演（校验、有效值核对、端口监听都要等配置真的写下去之后才问得出来）'
        os::output 0 port="${new_port}" password_auth="${want_pw}" \
            permit_root_login="${want_root}" user="${SAFE_KEY_USER}" changed=dry-run
        return 0
    fi

    # --- 语法：不过就一步都不往下走 ---
    #
    # 走 `sh -c` 是为了拿到 stderr：os::query 把 stderr 丢进 /dev/null，
    # 而 sshd -t 的报错全在 stderr 上，没有它用户只知道「校验失败」
    if ! os::query --timeout 10 -- sh -c 'sshd -t 2>&1'; then
        os::err 'sshd 拒绝了新配置，服务一步都没动'
        os::err "${OS_RUN_OUTPUT}"
        os::die 1 'sshd -t 未通过，正在回滚配置'
    fi
    os::ok 'sshd 语法校验通过'

    # --- 有效值核对：写了什么不算数，sshd 读到什么才算 ---
    local key want got
    for key in passwordauthentication permitrootlogin; do
        case ${key} in
            passwordauthentication) want=${want_pw} ;;
            *) want=${want_root} ;;
        esac
        probe::sshd_effective "${key}"
        got=${OS_PROBE_VALUE}
        # 读回来的可能是 without-password 这个旧名字，与我们写下去的
        # prohibit-password 是同一件事 —— 不归一就会回滚一次正确的加固
        [[ ${key} == permitrootlogin ]] && safe_norm_rootlogin got "${got}"
        if [[ ${got,,} != "${want,,}" ]]; then
            os::err "${key} 的有效值是「${got}」而不是「${want}」—— 有别的配置文件排在前面"
            safe_who_wins "${key}"
            os::err "${OS_RUN_OUTPUT}"
            os::die 1 "${key} 未能生效，正在回滚"
        fi
    done
    os::ok "有效配置已核对：密码登录=${want_pw}，root 登录=${want_root}"

    # --- 端口切换与验证 ---
    if [[ ${new_port} != "${cur_port}" ]] && safe_socket_activated; then
        safe_apply_socket_port "${new_port}"
        os::systemd_restart 'ssh.socket'
    elif [[ ${SAFE_SSHD_CHANGED} -eq 1 ]]; then
        if safe_socket_activated; then
            # socket 激活时 sshd 是每连接一个进程，配置改了下次连接就生效，
            # 但重启一下 socket 更干净（不影响已建立的连接）
            os::systemd_restart 'ssh.socket'
        else
            os::systemd_restart "${ssh_unit}"
        fi
    else
        os::ok 'SSH 配置已是目标状态，未重启服务'
    fi

    if [[ ${SAFE_SSHD_CHANGED} -eq 1 || ${new_port} != "${cur_port}" ]]; then
        # systemd 起监听有几十毫秒的延迟，一次就判会误判。
        # 五次一秒的轮询，比 `sleep 3` 既快又稳
        local -i attempt=0
        local listening='no'
        while ((attempt < 5)); do
            attempt+=1
            probe::port_listening "${new_port}"
            if [[ ${OS_PROBE_VALUE} == yes ]]; then
                listening='yes'
                break
            fi
            os::debug "第 ${attempt} 次没探到 ${new_port} 在监听，等 1 秒再看"
            os::query --timeout 3 -- sleep 1 || true
        done
        if [[ ${listening} != yes ]]; then
            os::err "SSH 没有在 ${new_port} 端口监听"
            os::query --timeout 10 -- journalctl -u "${ssh_unit}" --no-pager -n 20
            os::err "${OS_RUN_OUTPUT}"
            os::die 1 '端口未生效，正在回滚配置并恢复服务'
        fi

        # 「在监听」不等于「改动前能连的方式现在还能连」——只看 yes/no 接不住
        # 只掉了一半地址族的情况（比如只剩 IPv6，最常见的 IPv4 连接被直接拒绝）。
        # 按地址族比对，改动后不能比改动前少
        probe::port_families "${new_port}"
        local got_families=${OS_PROBE_VALUE} fam
        for fam in ${want_families}; do
            [[ " ${got_families} " == *" ${fam} "* ]] && continue
            os::err "新端口 ${new_port} 只监听在「${got_families:-无}」，比改动前的「${want_families}」少了 ${fam}"
            os::query --timeout 10 -- journalctl -u "${ssh_unit}" --no-pager -n 20
            os::err "${OS_RUN_OUTPUT}"
            os::die 1 '监听地址族不完整，正在回滚配置并恢复服务'
        done
        os::ok "SSH 正在监听 ${new_port}"
    fi

    # --- 最后一句永远是「别关这个窗口」---
    os::section '下一步'
    if [[ -n ${SSH_CONNECTION-} ]]; then
        os::warn '不要关闭当前这个 SSH 会话！先另开一个终端验证新配置：'
    else
        os::info '另开一个终端验证：'
    fi
    os::info "  ssh -p ${new_port} ${SAFE_KEY_USER}@<服务器 IP>"
    os::info '连上了再关掉旧窗口。连不上的话，当前窗口还在，能改回来。'

    os::output 0 port="${new_port}" password_auth="${want_pw}" \
        permit_root_login="${want_root}" user="${SAFE_KEY_USER}" \
        changed="$([[ ${SAFE_SSHD_CHANGED} -eq 1 ]] && printf yes || printf no)"
    return 0
}

main "$@"
