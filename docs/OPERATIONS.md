# OneServer 维护者应急手册

本手册用于异常现场的诊断与受控恢复。先保留证据、确认影响范围，再执行恢复；不要直接编辑凭据库、组件清单或安装目录。命令默认以 root 运行。

## 1. 先做只读诊断

```bash
oneserver doctor
oneserver doctor --bundle
oneserver state list
oneserver update status
journalctl -u 'oneserver-*' --since today --no-pager
```

`doctor --bundle` 会收集诊断信息，但不应包含凭据明文。提交诊断包前仍需人工检查内容。磁盘空间不足时先停止写操作，确认 `/`、`/var` 与备份目标的可用空间；不要在空间耗尽时反复重试安装、更新或恢复。

## 2. 组件清单损坏

组件清单位于 `/opt/oneserver/state/components.tsv`，上一版位于同目录的 `.bak` 文件。框架会逐行校验：主文件无法读出有效记录时自动使用有效的 `.bak`；已存在的空主文件表示权威的空清单，不会回退。

处理顺序：

1. 停止安装、卸载和更新操作。
2. 将主文件与 `.bak` 复制到管理员控制的只读证据目录，并记录权限、属主、大小和 SHA256。
3. 运行 `oneserver doctor`，确认状态是“正常”“已回退 .bak”还是“两份都损坏”。
4. 若两份都损坏，可运行 `oneserver state rebuild`。它只能恢复可探测的组件与版本，不能恢复原来的 file/pkg/unit/divert 等资源登记。
5. 对重建出的组件重新运行对应安装命令，使安装流程重新登记完整资源；在此之前不要依赖 `oneserver uninstall` 清理它们。

不要手工删除坏文件来让告警消失，也不要把猜测的路径写进 state；错误的所有权记录会让卸载误删用户资产。

## 3. 全局锁与异常残留

锁文件是 `/run/oneserver/oneserver.lock`。锁文件存在不代表仍被占用；文件内会记录持锁者信息，内核文件锁才是并发判据。

```bash
lslocks | grep '/run/oneserver/oneserver.lock'
ps -fp <PID>
```

若有持锁进程，先查明它正在进行的包管理、原子替换或更新阶段。不要删除锁文件，也不要在未确认临界区已结束时强制结束进程。若没有持锁者，保留该文件即可，下一次命令会正常重新取锁。

中断可能留下本次已创建但尚未登记的文件或 unit。优先重跑同一条幂等命令，让它按内容标记和系统事实收敛；不要根据文件名猜测所有权。

## 4. 更新中断或自检失败

```bash
oneserver update status
oneserver doctor --selftest
oneserver update rollback
```

更新器在 `/opt/oneserver/.old` 保留可回滚版本，并用 `/opt/oneserver/.update-in-progress` 标记切换阶段。先用 `status` 确认现场；仅在旧版本完整且当前版本确实异常时执行 `rollback`。不要手工交换 `lib/`、`script/` 或 `.old`，混合版本会让已加载的库与磁盘布局不一致。

回滚后再次运行 `doctor --selftest`，再检查原失败命令。若旧版本也失败，应保留诊断包和更新清单，不要连续来回切换。

## 5. 备份与恢复事故

恢复前先验证归档、目标和空间：

```bash
oneserver backup verify
oneserver restore --target=<类型:名字> --file=<归档文件名> --from=local
```

从本地或远端归档恢复时，`--target` 指的是**恢复哪份归档**，落点另由 `--into=<类型:名字>` 指定：归档记的是备份那一刻源机器上的库名与路径，换机器或站点改过名时它们在本机并不成立。不给 `--into` 时，只有归档自身的落点在本机完全成立（站点在 state 里、库名与目录都对得上）才会作为默认项，否则命令会停下来要求指定一个本机已有的落点。`--from=external` 目前仍沿用 `--target` 指定导入落点，不使用 `--into`。

恢复命令会列出精确变更，并要求输入**落点**的完整标识确认（同名回滚时它与 `--target` 相同）。先使用交互流程查看归档内容与恢复模式；确认数据库、文件目标、现有数据副本、可用空间和远端可达性后再确认。不要跳过校验，不要直接从对象存储流式覆盖生产路径。

落点是 WordPress 站点时，wp-config 里的数据库与缓存配置会被改写成本机该站点的当前值——归档里那份属于源机器。取不到本机凭据时命令在动手之前就停，不会留下一个配置对不上的站点。恢复数据库时可用 `--site-url=<地址>` 把库里的 `siteurl` / `home` 改成新域名；它只改这两行，正文与插件设置里的旧域名要用 `wp search-replace` 全库替换。

恢复完成后检查站点配置、数据库连接、文件属主和相关 systemd unit，再由应用层做读写验收。归档校验通过只说明传输内容一致，不等于应用可用。

## 6. 固定镜像的 digest 升级

`script/manage/docker_container.sh` 里的自动更新器镜像固定在一个多架构 index digest 上。它持有 Docker Socket，能力等价于宿主 root，所以不走可变 tag——每次 `docker pull` 拿到什么字节都无人可查。

升级是**人工步骤**，不会自动发生。要换新版本时：

```bash
podman manifest inspect docker.io/nickfedor/watchtower:latest | head -5
```

确认返回的 `mediaType` 是 `application/vnd.oci.image.index.v1+json`（多架构 index，amd64 与 arm64 都在里面），再取它的 digest：

```bash
podman pull docker.io/nickfedor/watchtower:latest
podman image inspect docker.io/nickfedor/watchtower:latest --format '{{index .RepoDigests 0}}'
```

把 `@sha256:` 后面那一段填进 `WATCHTOWER_DIGEST`。**固定的必须是 index digest，不是某一架构的 manifest digest**——后者换个架构就拉不动。

digest 提供的是**可复现性**，不是真实性：它保证所有机器装到同一份字节、且此后不会被无声换掉，但**不保证那份字节可信**——换 digest 时的信任模型和用浮动 tag 一样，区别只在频率，以及这里有一个可以插入人工审查的时机。真正的审查得你来做（看 release notes、看 commit、对比仓库公布的摘要）。

这个容器挂着 Docker Socket，能力等价于宿主 root，镜像来自个人命名空间的 fork。固定 digest 缩小不了这个爆炸半径。

## 7. 升级处理

以下情况停止自动操作并升级给维护者：主 state 与 `.bak` 均坏且没有安装记录副本；锁持有者处于不可确认的包管理或文件替换临界区；更新的当前版与 `.old` 都无法通过自检；备份哈希不一致；恢复目标仍在持续写入；诊断包疑似含凭据。

升级时附上时间线、执行过的命令、退出码、`doctor --bundle`、相关 journal、文件元数据与哈希。不要附 `secure.conf`、数据库口令、DNS 令牌或私钥。
