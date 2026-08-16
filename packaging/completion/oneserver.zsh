#compdef oneserver os
#
# zsh 补全 —— OneServer
#
# 装法：oneserver completion zsh > "${fpath[1]}/_oneserver"
#
# 与 bash 那份同源：候选每次都向 `oneserver __complete` 现问，
# 因此永远等于当前注册表，装了新脚本不必重新生成本文件。

_oneserver_complete() {
    local -a typed cands

    # words[1] 是命令自己，光标位置是 CURRENT；只交出光标之前的词
    if (( CURRENT > 2 )); then
        typed=( "${words[@]:1:CURRENT-2}" )
    fi

    cands=( ${(f)"$(oneserver __complete "${typed[@]}" 2>/dev/null)"} )
    (( ${#cands} )) || return 1

    compadd -- "${cands[@]}"
}

_oneserver_complete "$@"
