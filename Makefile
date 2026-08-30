# OneServer 开发任务入口
#
# 这份 Makefile 面向 Linux 与 CI，只是个入口。没装 make 的环境直接调底下的脚本：
#   bash tests/testenv.sh reset debian13
#
# 目标里一律不写实现，只转调 tests/ 下的脚本，避免同一段逻辑有两个版本。

SHELL := /bin/bash
DISTRO ?= debian13

.PHONY: help lint lint-selftest fmt test test-all manifest api testenv testenv-build testenv-shell testenv-list testenv-down

help:
	@echo "OneServer 开发任务"
	@echo
	@echo "  make lint                                   静态检查二十一项"
	@echo "  make lint-selftest                          反例自检：证明那些检查真的会红"
	@echo "  make fmt                                    按 .editorconfig 就地格式化"
	@echo "  make test [DISTRO=...]                      在容器里跑 lib 单元测试"
	@echo "  make test-all                               三个发行版都跑一遍"
	@echo "  make manifest                               生成分发清单 manifest.txt"
	@echo "  make api                                    由 lib/ 生成 docs/API.md"
	@echo "  make testenv [DISTRO=debian13|ubuntu2404|ubuntu2604] 销毁重建测试容器"
	@echo "  make testenv-build                          构建全部测试镜像"
	@echo "  make testenv-shell [DISTRO=...]             进测试容器"
	@echo "  make testenv-list                           列出镜像与容器状态"
	@echo "  make testenv-down                           销毁全部测试容器"

lint:
	@bash tests/lint.sh

# 正例证明不了检查还活着 —— 一条 `return 0` 也能让 lint 全部通过。
# 这个目标给每条检查喂一段确定违规的代码，要求它必须红。
lint-selftest:
	@bash tests/lint-selftest.sh

# 测试跑在一次性容器里：那里有 MariaDB 给 lib/sql.sh 的用例当裁判，
# 开发机与测试机上都没有。DISTRO 可切三个受支持发行版。
test:
	@bash tests/testenv.sh exec $(DISTRO) bash -c 'cd /src && bats tests/lib'

test-all:
	@bash tests/testenv.sh exec debian13   bash -c 'cd /src && bats tests/lib'
	@bash tests/testenv.sh exec ubuntu2404 bash -c 'cd /src && bats tests/lib'
	@bash tests/testenv.sh exec ubuntu2604 bash -c 'cd /src && bats tests/lib'

# 候选范围与 tests/lint.sh 的 shfmt 检查一致，少一类文件就会出现
# 「lint 说格式不对，make fmt 却不管它」。zsh 补全不在内：shfmt 读不了 zsh。
fmt:
	@git ls-files -- '*.sh' '*.bash' 'bin/*' \
		| xargs -r shfmt -w

# 发布期：由仓库内容推导分发清单。不入库，见 .gitignore
manifest:
	@bash packaging/make-manifest.sh

# 接口参考由 lib/ 的函数头签名行生成，不手写。lint 会校验它没过期
api:
	@bash packaging/make-api.sh

testenv:
	@bash tests/testenv.sh reset $(DISTRO)

testenv-build:
	@bash tests/testenv.sh build

testenv-shell:
	@bash tests/testenv.sh shell $(DISTRO)

testenv-list:
	@bash tests/testenv.sh list

testenv-down:
	@bash tests/testenv.sh down
