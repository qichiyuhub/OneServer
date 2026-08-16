#!/bin/bash
#
# 本工具自己的操作日志
#
# @command      logs
# @name         操作日志
# @group        monitor
# @order        30
# @privilege    root
# @requires_lib >= 1.26
# @args         [--action=<status|recent|audit|errors>]
# @description  查看本工具做过什么：操作记录、副作用审计与错误
#

set -Eeuo pipefail
IFS=$'\n\t'
PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

source /opt/oneserver/lib/bootstrap.sh

# ==================================================================
# 它只管本工具自己的日志
# ==================================================================
#
# **不做「各来源日志聚合」。** 容器日志在「容器 › 查看日志」、Caddy 日志在
# 「Caddy 管理 › 查看日志」、备份日志在「备份 › 查看备份日志」—— 那些都已经
# 有入口，再汇总一次就是同一件事的第二个入口，两处措辞和行为迟早分叉。
#
# 真正没有入口的只有 /var/log/oneserver 下这三份，而它们回答的问题别处答不了：
# **这个工具在这台机器上都做过什么。** `doctor --bundle` 里有一份 100 行的
# 摘录，但那是打包贴 issue 用的，混在整份诊断里，不适合日常翻。
#
# --- 不实现分页、搜索、跟踪 ---
#
# 那是 less 与 journalctl 的活，在 Bash 里重写一遍只会更难用。这里给的是
# 「最近 N 条 + 按级别筛」，要更细的就直奔文件 —— 所以每一屏都把路径打出来。

# 行数固定，不做成参数：这一屏是「扫一眼最近发生了什么」，要精确翻页、
# 搜索、跟踪的场合，直奔文件用 less/grep 比在这里堆参数强
readonly LOG_LINES=50

# 主日志一行的形状：`<时间> LEVEL [命令] 消息`，级别是 `%-5s` 的大写词
readonly LEVEL_RE='^[^[:space:]]+[[:space:]]+(WARN|ERROR)[[:space:]]'

# dump <标题> <文件> <过滤器>   把一份日志的尾部打出来
#
# 过滤器为空就是纯 tail。**先 grep 再 tail**：反过来是「最后 N 行里恰好有
# 几条错误」，而用户要的是「最近 N 条错误」——一台跑了很久的机器上，
# 这两个结果差着几个月
dump() {
    local title=${1} file=${2} filter=${3-}
    if [[ ! -r ${file} ]]; then
        os::info "${title}：还没有 ${file}"
        return 0
    fi

    if [[ -n ${filter} ]]; then
        # 过滤串由用户在界面上输入，**尤其**不能拼进内层 shell 的脚本文本
        # （规范 §10）：三个值全部经位置参数传入
        os::query --timeout 20 -- sh -c \
            "grep -E \"\$1\" \"\$2\" | tail -n \"\$3\"" \
            sh "${filter}" "${file}" "${LOG_LINES}" || true
    else
        os::query --timeout 20 -- tail -n "${LOG_LINES}" "${file}" || true
    fi

    os::section "${title}"
    if [[ -z ${OS_RUN_OUTPUT} ]]; then
        os::info '没有匹配的记录'
        return 0
    fi
    # JSON 模式下一个字都不许直接往 stdout 打，否则信封就不是合法 JSON 了
    if [[ ${OS_OUTPUT} == json ]]; then
        local line
        local IFS=$'\n'
        for line in ${OS_RUN_OUTPUT}; do
            [[ -n ${line} ]] && os::output_item text="${line}"
        done
        return 0
    fi
    printf '%s\n' "${OS_RUN_OUTPUT}"
    return 0
}

# 总览：三份日志各有多大、最后写于何时。**先答「有没有东西可看」** ——
# 日志目录写不进去时（权限、磁盘满）三份都会是空的，那本身就是要先解决的问题
action_status() {
    local f label
    local -a rows=()
    local size mtime
    for f in "${OS_LOG_MAIN}:操作记录" "${OS_AUDIT_LOG}:副作用审计" "${OS_LOG_JSONL}:结构化日志"; do
        label=${f#*:}
        f=${f%%:*}
        if [[ ! -r ${f} ]]; then
            rows+=("${label}" "还没有 ${f}")
            continue
        fi
        # 这两条不需要内层 shell：du 的第一列在 bash 里切，stderr 由 os::query
        # 默认丢弃 —— 少一层 shell，路径也就不用拼进任何脚本文本（规范 §10）
        os::query --timeout 10 -- du -h -- "${f}" || true
        size=${OS_RUN_OUTPUT%%[[:space:]]*}
        size=${size:-?}
        os::query --timeout 10 -- date -r "${f}" '+%Y-%m-%d %H:%M:%S' || true
        mtime=${OS_RUN_OUTPUT:-未知}
        rows+=("${label}" "${size} · 最后写于 ${mtime}")
    done

    # 目录也进同一次 os::kv：分两次调用时各算各的列宽，最后一行就对不齐了
    rows+=('目录' "${OS_LOG_DIR}")

    os::section '日志'
    os::kv "${rows[@]}"
    os::output 0 dir="${OS_LOG_DIR}"
    return 0
}

action_recent() {
    dump "最近 ${LOG_LINES} 条操作记录" "${OS_LOG_MAIN}" ''
    os::output 0 file="${OS_LOG_MAIN}" lines="${LOG_LINES}"
    return 0
}

# 审计与操作记录是两份东西：前者只记**改变了系统的那些步骤**，带退出码和
# 真正执行的命令行。排查「上周谁把防火墙关了」看的是这一份
action_audit() {
    dump "最近 ${LOG_LINES} 条副作用" "${OS_AUDIT_LOG}" ''
    os::output 0 file="${OS_AUDIT_LOG}" lines="${LOG_LINES}"
    return 0
}

action_errors() {
    dump "最近 ${LOG_LINES} 条告警与错误" "${OS_LOG_MAIN}" "${LEVEL_RE}"
    os::output 0 file="${OS_LOG_MAIN}" lines="${LOG_LINES}"
    return 0
}

# ------------------------------------------------------------------

main() {
    local action=${1-}
    if [[ -n ${action} ]]; then
        dispatch "${action}"
        return 0
    fi

    os::action_menu --overview action_status --arg action '操作' dispatch \
        'errors=只看告警与错误' 'recent=最近的操作记录' 'audit=副作用审计'
}

dispatch() {
    case ${1} in
        status) action_status ;;
        recent) action_recent ;;
        audit) action_audit ;;
        errors) action_errors ;;
        *) os::die 2 "未知操作「${1}」，可用：status recent audit errors" ;;
    esac
}

main "$@"
