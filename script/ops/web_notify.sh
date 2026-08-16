#!/bin/bash
#
# 面板 Telegram 通知器
#
# 只由 oneserver-web-fast.service 在采集后调用，不是用户命令。把它注册进菜单
# 会诱导用户手动运行一个只会等锁、也没有可交互操作的内部步骤。
#
# @privilege    root-trylock
# @requires_lib >= 4.1
#
# **它有副作用（发通知、写去重基线），所以不能是 `root-nolock`；但它每 30 秒
# 跑一次，而这一轮做不做都行 —— 告警晚半分钟没有代价。** 从前它是默认的
# `root`：用户在菜单里停留时，被派发的那条命令一直持锁，于是这里每轮等满 30
# 秒、超时、以 5 退出，往 JSONL 写数条错误。而 JSONL 正是面板要发布的产物，
# 一变就得整份重写它的副本 —— 实测「用户正在用工具」因此被放大成每天几百 MB
# 的磁盘写入和满屏红字。锁被占是预期内的正常情形，不是故障（规范 §6）。
set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

readonly ALERT_FILE="${OS_PUBLIC_DIR}/alerts.tsv"
# 去重基线**不放 public/**：那个目录是 tmpfs、里面只放「此刻的快照」（规范
# §4.2）。这份基线是记录 —— 丢了的话每次重启都会把当前所有告警重发一遍；
# 它也是通知器的内部账本，本来就不该对本机所有用户公开。
#
# 落在 data/ 而不是 state/：state 是组件清单，卸载按它反向执行，
# 与组件无关的账本混进去是拿卸载语义冒险。
readonly BASELINE="${OS_WEB_ALERT_BASELINE}"

readonly TOKEN_KEY='web.telegram_token'
readonly CHAT_KEY='web.telegram_chat_id'

# 把当前告警存成下一轮的比对基线。0640：它是内部账本，不对外
#
# `--quiet`：这个脚本跟快档走，30 秒一轮。默认的 info 级会往 JSONL 里堆出
# 一天 2880 条例行记录（内容没变时的「已是目标状态」同样每轮一条），
# 把真实事件挤出面板日志页 —— 而那份日志正是面板自己要发布的产物。
save_baseline() {
    os::install_file --quiet --mode 0640 "${ALERT_FILE}" "${BASELINE}" || true
    return 0
}

has_key() {
    local file=${1} want=${2} key _rest
    while IFS=$'\t' read -r key _rest || [[ -n ${key} ]]; do
        [[ ${key} == "${want}" ]] && return 0
    done <"${file}"
    return 1
}

main() {
    local token='' chat=''
    os::secure_load "${TOKEN_KEY}" token || return 0
    # 与写入侧对称：chat ID 不是秘密，不登记脱敏也不因为它短而告警
    os::secure_load --not-secret "${CHAT_KEY}" chat || return 0
    [[ -r ${ALERT_FILE} ]] || return 0

    local old=${BASELINE} msg='' key _level text
    if [[ ! -r ${old} ]]; then
        save_baseline
        return 0
    fi
    while IFS=$'\t' read -r key _level text || [[ -n ${key} ]]; do
        [[ -n ${key} ]] || continue
        if ! has_key "${old}" "${key}"; then
            msg+="⚠ ${text}"$'\n'
        fi
    done <"${ALERT_FILE}"
    while IFS=$'\t' read -r key _level text || [[ -n ${key} ]]; do
        [[ -n ${key} ]] || continue
        if ! has_key "${ALERT_FILE}" "${key}"; then
            msg+="✅ 已恢复：${text}"$'\n'
        fi
    done <"${old}"
    [[ -n ${msg} ]] || {
        save_baseline
        return 0
    }
    # os::run_out 没有 --timeout 选项（超时早由 curl 自己的 --max-time 保证，
    # 认不出的长选项现在会硬失败退出 2 而不是被当成 desc 悄悄吞掉）。
    #
    # token 用 `-K -` 从 stdin 读 curl 配置，不拼进 URL 再进 argv：这个脚本
    # 由 oneserver-web-fast.timer 每 30 秒跑一次，同机任何用户 `ps -ef` /
    # `cat /proc/*/cmdline` 都能在这个窗口里偷到 token。--stdin-secret 把整串
    # 配置登记进脱敏表，token 因此既不进 argv 也不进日志。
    #
    # chat_id 不加 --secret-val：它不是凭据，只是数字群组/用户 ID，
    # 而 --secret-val 对短于 6 字符的值会拒绝执行整条命令 —— chat_id
    # 一旦短于这个长度，告警会每 30 秒静默失败一次，得不偿失。
    os::run_out --stdin-secret "url = \"https://api.telegram.org/bot${token}/sendMessage\"" \
        '发送 Telegram 面板告警' -- \
        curl -fsS --max-time 10 --data-urlencode "chat_id=${chat}" --data-urlencode "text=${msg}" -K - \
        || return 1
    save_baseline
}

main "$@"
