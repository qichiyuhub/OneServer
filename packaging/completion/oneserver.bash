# bash 补全 —— OneServer
#
# 装法：oneserver completion bash > /etc/bash_completion.d/oneserver
#
# 候选每次按 Tab 时向 `oneserver __complete` 现问，因此**永远等于当前注册表**：
# 装了新脚本立刻就能补出来，不需要重新生成这个文件。
#
# shellcheck shell=bash

_oneserver_complete() {
    local cur words
    cur=${COMP_WORDS[COMP_CWORD]}

    # 只把光标**之前**的词交出去，让框架回答「下一个词能是什么」
    local -a typed=()
    if ((COMP_CWORD > 1)); then
        typed=("${COMP_WORDS[@]:1:COMP_CWORD-1}")
    fi

    words=$(oneserver __complete "${typed[@]}" 2>/dev/null) || return 0

    local IFS=$'\n'
    # shellcheck disable=SC2207  # 理由：COMPREPLY 必须是数组，而 compgen 的输出以换行分隔，这是 bash 补全的标准写法
    COMPREPLY=($(compgen -W "${words}" -- "${cur}"))
    return 0
}

complete -F _oneserver_complete oneserver os
