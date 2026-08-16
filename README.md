# OneServer

[![构建状态](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml/badge.svg)](https://github.com/qichiyuhub/OneServer/actions/workflows/lint.yml)
[![最新版本](https://img.shields.io/github/v/release/qichiyuhub/OneServer?display_name=tag&sort=semver)](https://github.com/qichiyuhub/OneServer/releases/latest)
[![许可证](https://img.shields.io/github/license/qichiyuhub/OneServer)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%204.3%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

简体中文 | [English](README.en.md)

## OneServer 是什么？

OneServer 是面向 Debian 和 Ubuntu 单机服务器的 Bash 运维工具，用于部署和维护 Web 服务、数据库、容器与基础安全配置。

- 安全优先：变更只在终端执行，Web 面板只读，密码单独存放。
- 极低占用：纯 Bash，不引入第三方运行库；不开启 Web 面板时无常驻进程。
- 不接管系统：服务仍由 systemd、APT 和原生配置文件管理。
- 变更可控：改动前可预演，重复执行结果一致；失败时可安全撤销的步骤自动回滚，其余精确列出已发生的变更。
- 卸载干净：安装过程全程记录，卸载按记录清理，业务数据默认保留。
- 两种用法：交互菜单用于日常运维，命令行支持 JSON 输出便于脚本/AI调用。
- 状态易读：只读 Web 面板显示组件、服务、端口、防火墙与日志。

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/qichiyuhub/OneServer/main/install.sh | bash
```

安装后 `os` 进入交互菜单。查看全部命令与参数：

```bash
oneserver --help
oneserver <命令> --help
```

## 环境要求

- Debian 或 Ubuntu，root 权限，systemd
- Bash 4.3 或更高版本、APT、dpkg、util-linux
- 可用的 APT 软件源与网络连接
- `curl`、`tar`、`coreutils`、`ca-certificates` 由安装器自动补齐
- `rclone` 可选，仅远程备份需要

Podman 需 4.4 或更高版本：Debian 13、Ubuntu 24.04 及更新版本可直接从系统仓库安装；更早的系统请改用 Docker，或自行准备符合版本要求的 Podman。

## 功能描述

| 类别 | 功能 |
| --- | --- |
| 网站 | 站点管理、Caddy 配置、WordPress 部署、PHP 配置更新 |
| 数据库 | MariaDB 数据库与账号管理 |
| 容器 | Docker、Podman、Compose 项目、镜像、容器、数据卷 |
| 安全 | 安全体检、UFW 防火墙、SSH 加固、系统更新与自动安全更新、网络定位、凭据库 |
| 备份 | 备份管理、恢复管理，支持 rclone 远端与外部备份导入 |
| 监控 | 只读 Web 面板、系统诊断、组件状态、操作日志 |
| 应用 | Caddy、PHP-FPM、MariaDB、Valkey、Node.js、Docker、Podman 的安装与卸载 |
| 工具箱 | 脚本更新、空间清理、主题预览 |

## 更新及卸载

更新，也可在「工具箱 › 脚本更新」操作：

```bash
oneserver update check
oneserver update run
```

卸载 OneServer 自身，无菜单入口：

```bash
bash /opt/oneserver/uninstall.sh
```

卸载器按组件、备份归档、密码与配置、工具自身四项依次确认，可逐项保留，不可逆操作须输入全名；四项全删后，本工具安装的软件包、文件与自身痕迹都会移除。**业务数据不在其中**——数据库、站点目录、证书与用户配置永不自动删除，卸载器只打印它们的位置，由你自行处置。组件须在此一并卸载——哪些软件包与文件属于哪个组件只有本工具记录，记录随工具一同消失。

不再使用时，建议先执行「工具箱 › 空间清理」再卸载。

## 注意事项

- 变更前可用 `--dry-run` 预演。
- `--yes` 对不可逆操作无效，删除仍须逐项输入全名确认。
- 不要手工编辑状态文件与凭据文件。
- 修改防火墙或 SSH 前，保留第二个 SSH 会话或服务商控制台。
- 恢复前先校验备份并确认目标。
- 状态异常时运行 `oneserver doctor`，再查阅[应急手册](docs/OPERATIONS.md)。
- Web 面板默认启用 Basic Auth 并监听所有网卡；关闭密码时监听收窄至本机或指定网段。走 HTTP 明文，公网访问须经 HTTPS 反向代理。

## 许可证

OneServer 使用 [MIT License](LICENSE)。第三方软件及素材适用各自许可证，详见[第三方声明](docs/THIRD_PARTY.md)。
