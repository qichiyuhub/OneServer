#!/usr/bin/env bats
#
# uninstall.sh（仓库根的自卸载器）
#
# 这个文件只回答一个问题：**卸完之后还剩什么**。
#
# 它测的不是「删除命令有没有被调用」，而是那份落点清单全不全 —— 少一行的
# 后果不是报错，是机器上悄悄留下一份垃圾，而写代码的人永远不会知道。
# 所以两条路一起走：
#
#   1. 把全部落点在真实文件系统上造出来 → 跑卸载 → 逐个断言它没了，
#      再全盘扫一遍 `*oneserver*`
#   2. 静态比对：lib/paths.sh 里那些落在程序目录**之外**的路径常量，
#      必须逐个出现在卸载器里 —— 这条挡的是「以后新增一个落点忘了登记」
#
# **安全阀**：自己装一份并留下 `.bats-owned` 记号，只卸带记号的那份。
# 那里已经有一份不带记号的（真机上的安装）就整条跳过，绝不去动它。

setup_file() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
}

setup() {
    load "${BATS_TEST_DIRNAME}/../helper/load.sh"
    os_load_lib ui log
}

# 卸载器要写的每一处。**与 uninstall.sh 的 self_lines 是同一份清单**，
# 两边分叉的话下面第一条用例就红
os_footprint() {
    cat <<'EOF'
/opt/oneserver
/etc/oneserver
/var/log/oneserver
/var/backups/oneserver
/run/oneserver
/run/oneserver-public
/usr/local/bin/oneserver
/usr/local/bin/os
/etc/logrotate.d/oneserver
/etc/bash_completion.d/oneserver
EOF
}

# 自己装一份，**不蹭 cli.bats 那份**：它的 teardown_file 跑完就把 /opt/oneserver
# 删了，蹭它的结果是这里两条用例永远 skip —— 而 skip 在汇总里长得跟 ok 一样，
# 最该跑的两条静静地没跑，没人会发现。
os_fresh_install() {
    [ "$(id -u)" -eq 0 ] || return 1
    [ -d /src ] || return 1
    # 安全阀：那里有一份不是 bats 装的东西，就什么都不做 —— 这两条用例会把它卸掉
    if [ -e /opt/oneserver ] && [ ! -e /opt/oneserver/.bats-owned ]; then
        return 1
    fi
    rm -rf /opt/oneserver
    mkdir -p /opt/oneserver
    cp -a /src/. /opt/oneserver/
    : >/opt/oneserver/.bats-owned
    chmod +x /opt/oneserver/bin/oneserver /opt/oneserver/bin/oneserver-menu
    ln -sf /opt/oneserver/bin/oneserver /usr/local/bin/oneserver
    ln -sf /opt/oneserver/bin/oneserver /usr/local/bin/os
    return 0
}

# --- 静态：落点清单不能漏 -----------------------------------------

@test "落点清单：paths.sh 里程序目录之外的路径常量，卸载器逐个都要处理" {
    local un="${OS_TEST_REPO_ROOT}/uninstall.sh"
    local v
    # OS_ROOT 之外的落点。少一个就是卸完留一份垃圾，而现场没有任何报错。
    # OS_TMP_ROOT 不在这张表里：D244 之后它在 OS_ROOT 底下，随程序目录一起收走
    for v in OS_ETC_DIR OS_LOG_DIR OS_BACKUP_DIR OS_RUN_DIR OS_PUBLIC_DIR \
        OS_SECURE_CONF OS_ROOT; do
        grep -q "\${${v}}" "${un}" || {
            printf 'uninstall.sh 没有处理 %s\n' "${v}" >&2
            return 1
        }
    done
}

@test "落点清单：卸载器不留下 systemd unit" {
    grep -q 'oneserver-\*\.timer' "${OS_TEST_REPO_ROOT}/uninstall.sh"
    grep -q 'oneserver-\*\.service' "${OS_TEST_REPO_ROOT}/uninstall.sh"
}

@test "自卸载不在菜单里：registry 只扫 script/，仓库根的文件扫不到" {
    # 放进 script/ 就一定进菜单（没有隐藏开关），这条钉住它待在外面
    [ ! -e "${OS_TEST_REPO_ROOT}/script/ops/self_uninstall.sh" ]
    grep -q 'OS_SCRIPT_DIR' "${OS_TEST_REPO_ROOT}/lib/registry.sh"
    # 而它必须随分发落地，否则 curl 装进来的人手上没有这个文件
    grep -q "'uninstall.sh'" "${OS_TEST_REPO_ROOT}/packaging/make-manifest.sh"
}

@test "卸组件的命令里不再有自卸载那条路" {
    local f="${OS_TEST_REPO_ROOT}/script/ops/uninstall.sh"
    # `--all` 与 `--confirm-uninstall=oneserver` 这个魔法值都搬走了
    run grep -n 'self_uninstall' "${f}"
    [ "${status}" -ne 0 ]
    run grep -n -- '--arg all' "${f}"
    [ "${status}" -ne 0 ]
}

# --- 真机：造出全部落点，卸完一个不剩 -----------------------------

@test "卸载后不留残留：全部落点消失，全盘搜不到 oneserver" {
    os_fresh_install || skip '需要 root、/src 挂载，且 /opt/oneserver 未被别人占用'

    # 造出全部落点。程序目录由 os_fresh_install 装好，其余按清单铺开
    mkdir -p /etc/oneserver /var/log/oneserver /var/backups/oneserver/archives \
        /run/oneserver /run/oneserver-public \
        /etc/logrotate.d /etc/bash_completion.d
    printf 'db.password=s3cret\n' >/opt/oneserver/secure.conf
    printf 'x\n' >/etc/oneserver/oneserver.conf
    printf 'x\n' >/var/log/oneserver/oneserver.log
    printf 'x\n' >/var/backups/oneserver/archives/keep.tar.gz
    printf 'x\n' >/run/oneserver-public/probe.tsv
    printf 'x\n' >/etc/logrotate.d/oneserver
    printf 'x\n' >/etc/bash_completion.d/oneserver
    ln -sf /opt/oneserver/bin/oneserver /usr/local/bin/oneserver
    ln -sf /opt/oneserver/bin/oneserver /usr/local/bin/os

    # 四样全选：组件（state 是空的，这一问会自己跳过）· 归档 · 凭据与配置 · 自身
    run bash /opt/oneserver/uninstall.sh \
        --non-interactive --force-destroy --remove-archives=y --purge=y
    [ "${status}" -eq 0 ]

    local p
    while IFS= read -r p; do
        [[ -n ${p} ]] || continue
        [ ! -e "${p}" ] || {
            printf '卸载后仍然存在：%s\n' "${p}" >&2
            return 1
        }
    done < <(os_footprint)

    # 全盘扫一遍。排除 /src（仓库挂载）与 /tmp（bats 自己的工作区）——
    # 那两处不是安装产物
    run bash -c "find / -xdev \\( -path /src -o -path /tmp -o -path /proc -o -path /sys \\) -prune -o -name '*oneserver*' -print 2>/dev/null"
    [ -z "${output}" ] || {
        printf '全盘仍能搜到：\n%s\n' "${output}" >&2
        return 1
    }

    # /run 是 tmpfs，与 / 不在同一个设备上，上面那条 -xdev 根本到不了它 ——
    # 而锁、面板数据、凭据临时文件全在那儿，必须单独再扫一遍
    run bash -c "find /run -name '*oneserver*' -print 2>/dev/null"
    [ -z "${output}" ] || {
        printf '/run 里仍能搜到：\n%s\n' "${output}" >&2
        return 1
    }
}

@test "非交互下不点名就不卸组件：multiselect 的「全选」默认不能用在这里" {
    # os::multiselect 在 --non-interactive 时取「全选」（等价于回车）。放任它的
    # 话，一条 --non-interactive --force-destroy 会把十几个应用连包带库一起
    # purge 掉，而没有任何人打过它们的名字
    grep -q 'os::flag --arg components' "${OS_TEST_REPO_ROOT}/uninstall.sh"
    grep -q 'OS_NON_INTERACTIVE' "${OS_TEST_REPO_ROOT}/uninstall.sh"
}

@test "全局开关传给子进程：漏掉 --dry-run 的预演会真的把组件卸掉" {
    local un="${OS_TEST_REPO_ROOT}/uninstall.sh"
    # 子进程是独立进程，读的是自己的命令行，读不到父进程的 OS_DRYRUN
    grep -q 'child+=(--dry-run)' "${un}"
    grep -q 'child+=(--non-interactive)' "${un}"
    # 交互模式下不许把 --force-destroy 传下去 —— 那里每个组件各自打全名
    grep -q 'OS_NON_INTERACTIVE' "${un}"
    grep -qF 'uninstall --id="${one}" ${child[@]+"${child[@]}"}' "${un}"
}

@test "组件清单按逗号拆：multiselect 交回的是一行，不是一行一个" {
    # 按行读的话整串会被当成一个组件标识传下去，现场表现是 --id=a,b,c 找不到组件
    grep -q "IFS=',' read -r -a picks" "${OS_TEST_REPO_ROOT}/uninstall.sh"
}

@test "保守卸载：不选归档与凭据时，它们留在原地" {
    os_fresh_install || skip '需要 root、/src 挂载，且 /opt/oneserver 未被别人占用'

    mkdir -p /var/backups/oneserver/archives /etc/oneserver
    printf 'x\n' >/var/backups/oneserver/archives/keep.tar.gz
    printf 'db.password=s3cret\n' >/opt/oneserver/secure.conf

    # 两问都答否 —— 默认就是否，这里显式给上，免得默认值一改测试就跟着变
    run bash /opt/oneserver/uninstall.sh \
        --non-interactive --force-destroy --remove-archives=n --purge=n
    [ "${status}" -eq 0 ]

    # 归档是「机器没了之后还能恢复」的东西，凭据库里是站点此刻还在用的密码
    [ -f /var/backups/oneserver/archives/keep.tar.gz ]
    [ -f /opt/oneserver/secure.conf ]
    [ "$(cat /opt/oneserver/secure.conf)" = 'db.password=s3cret' ]
    [ -d /etc/oneserver ]
    # 程序本体仍然要走干净
    [ ! -e /opt/oneserver/bin ]
    [ ! -e /opt/oneserver/lib ]
    [ ! -e /usr/local/bin/oneserver ]
}

teardown_file() {
    # 兜底：某条用例中途失败时 /opt/oneserver 可能还留着半份。
    # 只删自己装的那份，标记文件是唯一凭据（同 cli.bats）
    if [ -f /opt/oneserver/.bats-owned ]; then
        rm -rf /opt/oneserver
    fi
}
