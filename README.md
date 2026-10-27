# Cloud-Development

基于Docker环境构建的一个隔离开发虚拟环境

## 本项目的缘由

我需要一个可以快速拉起、撤销环境修改的容器，且具备隔离的Agent开发，以便我可以直接开完全访问模式

## 镜像变体

| Tag                   | 说明                                                                            |
| --------------------- | ------------------------------------------------------------------------------- |
| `vxxxxxxxx`（无后缀） | slim 版（NoDesktop-Base）：不含远程桌面，体积更小，`FROM :base`                 |
| `vxxxxxxxx-desktop`   | 完整版（Desktop-Base，默认）：XFCE4/xrdp 远程桌面（端口 3390），`FROM :desktop` |

> 桌面版的 RDP 与 SSH 使用同一个 `SSH_USER` 和 `SSH_PASSWORD`，不再创建独立的桌面账号。设置 `SSH_PASSWORD` 后，SSH 密码和挂载的 `authorized_keys` 公钥仍可并用；公钥在容器启动时从挂载文件复制，更新公钥后需重启容器。使用 Compose 前需创建 `./app-config/authorized_keys` 文件（可以为空），避免文件缺失时挂载失败。非 root 主账号不会自动修改挂载目录的属主，工作区和配置卷应提前授予其 `LOCAL_UID`/`LOCAL_GID` 访问权限。未设置密码时只能通过 SSH 公钥登录，RDP 无法使用空密码登录。旧的 `DESKTOP_USER`、`DESKTOP_PASSWORD`、`DESKTOP_USER_PASSWORD` 和 `ALLOW_APP_DESKTOP` 不再生效，请迁移到 SSH 配置。默认 root 桌面拥有完整权限，建议仅在可信网络或 SSH 隧道中使用强密码访问 RDP。

> 关于开发思路：
>
> 由于Agent是更新比较频繁的，但是开发依赖却是更新频率较低的。
>
> 所以本项目拆分成两层docker，一层为base，用于存放更新频率低的开发依赖、基础环境，一层为动态层，用于存放更新较为频繁的agent等用途
>
> 如果你需要定制一个适用你的，可以直接从base入手，将开发依赖进行适配即可，动态层已经覆盖安装了主流的开发Agent（例如CC、OpenCode）
