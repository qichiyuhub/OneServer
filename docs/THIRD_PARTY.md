# 第三方来源与许可说明

OneServer 自身代码与原创模板按仓库根目录的 MIT 许可证分发。本仓库不内置第三方二进制或运行时依赖；安装时取得的软件由各自发行者和系统包管理器提供，并继续适用其各自许可证。

## 仓库内模板

- `templates/wp-config.php` 是 OneServer 原创的最小互操作配置模板，按 MIT 分发。它只使用 WordPress 公开记录的配置常量和加载入口，不复制 `wp-config-sample.php` 的注释或表达。接口依据为 WordPress 官方的 [wp-config.php 文档](https://developer.wordpress.org/apis/wp-config-php/)；WordPress 软件本身按官方说明的 [GPLv2-or-later](https://wordpress.org/about/license/) 分发，但不随本模板捆绑。
- `templates/docker.list`、`templates/caddy.list` 是由 OneServer 生成参数填充的 APT source stanza，只记录仓库 URL、发行版代号和组件名，不包含供应商程序代码。安装得到的 Docker/Caddy 软件及仓库签名材料适用各供应商许可证。
- 其余 `templates/`、`packaging/systemd/` 与 `packaging/logrotate/` 文件均为本项目原创的配置、unit、页面或轮转规则，按 MIT 分发。

## 运行时取得的软件

Debian、Ubuntu、Docker、Caddy、MariaDB、PHP、Podman、Valkey、Node.js、WordPress、rclone 及其他由命令安装的组件不是 OneServer 的组成部分。OneServer 只调用系统包管理器或经校验的官方发布渠道；管理员仍需按部署场景核对相应软件许可证和再分发义务。

加入从外部项目复制或改编的文件时，必须同时记录来源 URL、取得版本、修改说明、SPDX 标识和所需许可证文本；不能仅依赖仓库根目录的 MIT 声明。
