# tests/helper/load.sh —— 单元测试的装配入口
#
# 按 lib 的依赖层顺序 source，顺序与 bootstrap.sh 一致。
# lib 模块之间**不互相 source**：装配只有一处，顺序才是显式的、可检查的。
# 因此测试也必须走同一条装配路径，否则测的是一个现实中不存在的加载顺序。
#
# 用法（bats）：
#   load "${BATS_TEST_DIRNAME}/../helper/load"
#   os_load_lib ui

OS_TEST_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export OS_TEST_REPO_ROOT

# os_load_lib [最高层模块...]   总是先装 L0，再按给定顺序装后面的
os_load_lib() {
    local lib="${OS_TEST_REPO_ROOT}/lib"
    # L0 —— 三个常量文件，零依赖
    # shellcheck source=/dev/null
    source "${lib}/paths.sh"
    # shellcheck source=/dev/null
    source "${lib}/defaults.sh"
    # shellcheck source=/dev/null
    source "${lib}/theme.sh"

    local m
    for m in "$@"; do
        # shellcheck source=/dev/null
        source "${lib}/${m}.sh"
    done
}

# os_test_no_tty   把 UI 探测结果强制成「非 TTY、无色、UTF-8」
# 断言渲染结果时必须先调它：否则同一个用例在本地终端与 CI 里输出不同。
#
# shellcheck disable=SC2034  # 理由：这里赋的是 lib/ui.sh 的全局变量，本文件内不消费
os_test_no_tty() {
    OS_UI_STDOUT_TTY=0
    OS_UI_STDERR_TTY=0
    OS_UI_COLOR_CAPABLE=0
    OS_UI_UTF8=1
    OS_UI_WIDTH=80
    ui::_load_symbols
    ui::_load_tree_symbols
}
