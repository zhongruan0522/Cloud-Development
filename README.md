# Cloud-Development

基于Docker环境构建的一个隔离开发虚拟环境

## 本项目的缘由

我需要一个可以快速拉起、撤销环境修改的容器，且具备隔离的Agent开发，以便我可以直接开完全访问模式

## SDK 可扩展挂载

镜像本体不含 Flutter / Android SDK / Gradle / Rust / apk-tools。这些组件走 **挂载式可扩展模式**：compose 将 `./sdks` 挂到容器 `/opt/sdks`，entrypoint **第三波** 启动时后台执行各 `SDK.sh`——首启自动下载部署（不阻塞 SSH/主服务），SDK 本体与缓存落在挂载目录内跨重建持久，一次性产物自动清理，版本更新/拆卸不触发镜像重建。

内置数据库（PostgreSQL / MySQL / openGauss / KingbaseES / DM8）与 Redis 走同一机制：二进制在 Base 层，部署脚本在 `sdks/` 下，目录在即启用、首启自动初始化，数据默认落容器可写层（容器重建即清空，`docker restart` 保留）。

apt 安装清单（`sdks/apt-list/`）只需维护一个 `packages.txt`：一行一个包名，容器启动时自动装上尚未安装的包。

- 官方模板（`sdks/flutter|android|gradle|rust|apk-tools/SDK.sh`、六个数据库目录与 apt 安装清单）随仓库自带，clone 即用；
- 只需要其中几个 → compose `environment:` 设 `ENABLE_<目录名大写>=0`；版本覆盖（`FLUTTER_VERSION` 等）同样加进 `environment:`；
- 全部 SDK 同时在途最多 3 个，完成一个补位一个；
- 自定义组件按 `sdks/README.md` 中的 SDK.sh 契约编写，放入 `sdks/<组件名>/SDK.sh` 即被自动扫描部署。

## 日志

`docker logs` 只包含启动状态行：三波时间线与各组件的成功/失败状态行，账号、SSH 等同步段的提示行，以及 OpenChamber、Magpie 的 Web UI 入口地址。过程细节在容器内的文件里：后台部署任务的输出在 `/var/log/init/`，各常驻服务（OpenChamber、Magpie、DockerD 与各数据库）的输出在 `/var/log/supervisor/<程序名>.log`（stdout 与 stderr 合并，跨启动追加、按大小轮转，每次启动以一行带时间戳的 `===== <日期 时间> 启动 <程序名> =====` 分隔），程序段的运行期状态迁移（退出、自动拉起、放弃重试）在 `/tmp/supervisord.log`。位置与查看方法见 `sdks/README.md` 的“日志位置”一节。

## 宿主机显示转发

容器内的图形程序可以显示到宿主机屏幕，分两步启用，都在宿主机操作：

1. 放行容器主账号。桌面会话的 X 服务器带 cookie 启动，不认无 cookie 的本机连接，容器账号要由宿主机加入访问控制表，写它的数值 uid（主账号 `opencode` 默认 1000，设了 `LOCAL_UID` 时用对应的值）：

   ```bash
   xhost +si:localuser:#1000
   ```

   需要以 root 身份运行图形程序时再放行 root：`xhost +si:localuser:root`。

2. 在桌面会话的终端里启动，compose 把当前 shell 的 `DISPLAY` 传进容器并挂载 `/tmp/.X11-unix`；长期启用在 `.env` 里写 `DISPLAY=:0`（按桌面会话的实际显示号）。

   ```bash
   docker compose up -d
   ```

启动后在 `docker logs` 里看 `[X11]` 这一行：已连通即可用；未连通时该行带着原因与修复命令，容器不因此退出，启用了 healthcheck 时健康检查同时为不健康，宿主机重新放行后自动恢复。容器内执行 `xdpyinfo | head -3` 可以随时复验。

宿主机会话提供 X 设置时（GNOME 等桌面默认如此），字体、主题与缩放随 X 连接取自宿主机会话，不需要挂载宿主机的配置目录。放行只在当前桌面会话有效，宿主机重新登录后需要再执行一次第 1 步。

## 账号与权限

容器引导、supervisord、sshd、dockerd 与各数据库由 root 负责；日常使用镜像预建的主账号 `opencode`（uid/gid 1000）。

- **免密 sudo**：`sudo <命令>` 直接提权，`sudo -i` 进 root 的登录 shell。
- **进入主账号**：`ssh opencode@<主机>`，或在宿主机 `docker exec -it Development su - opencode`。
- **SSH**：挂载的 `./app-config/ssh/authorized_keys` 同时放行 `opencode` 与 root，已有的 `ssh root@` 用法不用改。设置 `SSH_PASSWORD` 即启用密码认证，口令属于 `opencode`。公钥在容器启动时复制，更新后需重启容器。
- **Agent 与配置归主账号**：compose 把 `.claude`、`.codex`、opencode 配置、`.vscode-server` 等挂到 `/home/opencode` 下，OpenChamber 与 Magpie 也以 `opencode` 运行；git 的身份与凭据（`.gitconfig`、`.git-credentials`、gh 配置）root 与 `opencode` 各挂同一份。
- **家目录与工作区自动对齐**：每次启动把 `/home/opencode` 与 `/workspace` 整棵树（含挂载进来的目录）的属主交给 `opencode`，并给各目录加上主账号组可读写的默认 ACL。之后 root 在里面新建的文件与目录 `opencode` 能直接改写，反过来亦然；只读挂载保持原样。对齐在后台任务里完成，结果看 `docker logs` 里 `[第一波][目录权限]` 这一行。

这两个目录带默认 ACL，`umask` 在其中不生效：靠 `umask 077` 收权限的办法不起作用，需要对别的账号保密的文件用显式权限（`chmod 600`、`install -m 600`，或自带显式权限的工具）；主账号有免密 sudo，权限位对它不起防护作用。主账号的 `~/.ssh` 不带默认 ACL，`ssh-keygen` 生成的私钥照常是 600。

`LOCAL_UID` / `LOCAL_GID`：宿主机登录用户不是 uid 1000 时，在 `.env` 里设成登录用户的 uid 与 gid，主账号随之改号，挂载目录里的文件在宿主机上就归该用户所有；留空或为 0 即保持 1000，撞上镜像里别的账号时容器启动即报错退出。从旧版本升级后首次启动，原有数据的属主在这次对齐里改为主账号，数据量大时需要一些时间。

## 镜像标签

发行标签为北京日期 Calver（`vYYYY.MM.DD`），同日多次构建覆盖同一个标签；镜像分 Base 层与动态层两层构建，成品 `FROM :base`。

> 关于开发思路：
>
> 由于Agent是更新比较频繁的，但是开发依赖却是更新频率较低的。
>
> 所以本项目拆分成两层docker，一层为base，用于存放更新频率低的开发依赖、基础环境，一层为动态层，用于存放更新较为频繁的agent等用途
>
> 如果你需要定制一个适用你的，可以直接从base入手，将开发依赖进行适配即可，动态层已经覆盖安装了主流的开发Agent（例如CC、OpenCode）
