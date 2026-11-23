# SDK 可扩展挂载目录

镜像本体不含 Flutter / Android SDK / Gradle / Rust / apk-tools。这些组件以 **挂载式 SDK** 形态提供：compose 把本目录挂进容器 `/opt/sdks`，entrypoint **第三波【可选组件】** 后台执行各 `SDK.sh`，自动部署并注入环境变量。

内置数据库与 Redis 走同一机制：二进制由 Base 层安装，这里只放部署脚本，目录在即启用、首启自动初始化，数据默认随容器重建清空（见[数据库 SDK](#数据库-sdk)）。

## 目录结构

```
sdks/                          ← compose 挂载 → /opt/sdks
├── flutter/                   ← 工具链 SDK
│   ├── SDK.sh                 ← 部署入口（随仓库自带，官方模板）
│   ├── sdk/                   ← SDK 本体（首启下载解压，持久，运行期生成）
│   ├── cache/                 ← 持久性缓存（pub-cache 等，跨重建保留，运行期生成）
│   └── tmp/                   ← 一次性产物（下载包），部署完成即清理，平时不存在
├── android/                   ← 同上；sdk/ 即 ANDROID_SDK_ROOT（含增量包）
├── gradle/                    ← 同上；cache/gradle-home 即 GRADLE_USER_HOME
├── rust/                      ← 同上；sdk/rustup + sdk/cargo 即 RUSTUP/CARGO_HOME
├── apk-tools/                 ← 同上；bin/ 为统一 wrapper 目录
├── pg/                        ← 数据库 SDK：SDK.sh + healthcheck.sh 两个脚本
├── mysql/                     ← 同上
├── opengauss/                 ← 同上
├── kingbase/                  ← 同上
├── dm/                        ← 同上
└── redis/                     ← 同上
```

工具链 SDK 的 `sdk/` 与 `cache/` 均在挂载卷上：**容器重建不丢，换版本 = 删掉 `sdk/`（或改版本 env）下次启动自动重拉**。已加入 `.gitignore`，clone 仓库不会拖带 GB 级二进制。数据库 SDK 目录里只有脚本，数据不落在这里。

## SDK.sh 契约（自定义 SDK 按此编写）

1. **入口唯一**：目录内放一个可执行入口 `SDK.sh`，entrypoint 只认 `<目录名>/SDK.sh`；目录名即组件名（task tag / 日志名 / 停用开关变量名）。
2. **运行时机**：entrypoint 第三波以 root 后台执行，`bash SDK.sh` 调用（无需 +x）；环境变量注入：
   - `SDK_DIR`：本组件目录（手动重跑可省略，脚本自动取自身所在目录）；
   - `SDK_OWNER`：主账号名（非 root 时部署完成后需 `chown -R` 给它）；
   - 容器已导出的环境变量原样继承（如数据库统一密码 `DB_PASSWORD`）。
3. **并发闸门**：全部 SDK 共用一个闸门，**同时在途最多 3 个，完成一个补位一个**；下发顺序为目录名字典序。排队中的任务在 `docker logs` 里是"排队"状态行，获得槽位后变"部署中"。
4. **幂等**：每次容器启动（含 docker restart）都会重跑。已部署时只做 env 注入与软链修复，秒过；版本变更走增量或整目录重部署。
5. **一次性产物及时清理**：下载包、临时解压目录一律落在 `tmp/`，部署完成立即 `rm -rf`；需要跨重建保留的（依赖缓存等）放 `cache/`。
6. **env 注入**：写 `/etc/profile.d/zz-sdk-<组件名>.sh`（登录/SSH/桌面/agent 会话生效；文件名字典序保证在 `opencode-env.sh` 之后追加 PATH）。同时把主命令软链到 `/usr/local/bin`，保证 `docker exec` 等非登录 shell 也可用。
7. **失败语义**：尽早失败（依赖自检前置）、`==> [组件名] FATAL: ...` 暴露并非零退出；不终止容器，`docker logs` 出一行"失败"状态行并附日志路径。完整日志落 `/var/log/init/sdk-<组件名>.log`（成功后归档为 `第三波-sdk-<组件名>.log`）；`docker logs` 对任务只输出状态行。
8. **健康检查（可选）**：目录内放 `healthcheck.sh` 即参与容器健康判定——`base/healthcheck.sh` 每次以 `bash` 逐个执行，退出码 0 为健康，非 0 则容器判不健康。常驻服务类 SDK（如数据库）应提供。
9. **停用开关**：compose `environment:` 设 `ENABLE_<目录名大写>=0` 即跳过——不下发部署、不参与健康检查，`docker logs` 打一行"跳过"。目录名转变量名：字母转大写，其余字符逐个转下划线（`apk-tools` → `ENABLE_APK_TOOLS`）。

模板骨架（复制到 `sdks/<你的组件>/SDK.sh` 改造即可）：

```bash
#!/usr/bin/env bash
set -euo pipefail
SDK_NAME="my-sdk"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SDK_OWNER="${SDK_OWNER:-}"
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

TARGET="${SDK_DIR}/sdk/my-sdk"
if [ ! -x "${TARGET}/bin/my-sdk" ]; then
    log "部署 my-sdk → ${TARGET}"
    mkdir -p "${SDK_DIR}/tmp" "${SDK_DIR}/sdk"
    curl -fL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_DIR}/tmp/my-sdk.tar.gz" "https://example.com/my-sdk.tar.gz"
    tar --no-same-owner -xzf "${SDK_DIR}/tmp/my-sdk.tar.gz" -C "${SDK_DIR}/sdk"
    rm -rf "${SDK_DIR}/tmp"            # 一次性产物即时清理
else
    log "已部署，跳过下载"
fi

mkdir -p /etc/profile.d && cat > /etc/profile.d/zz-sdk-my-sdk.sh <<EOF
export PATH="\${PATH}:${TARGET}/bin"
EOF
if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi
log "my-sdk 就绪"
```

## 数据库 SDK

| 目录 | 组件 | 端口 | 账号 | 容器内连接 |
|---|---|---|---|---|
| `pg` | PostgreSQL 17 | 5432 | postgres | `psql -U postgres`（socket 免密） |
| `mysql` | MySQL 8.4 | 3306 | root | `mysql -u root -p"$DB_PASSWORD"` |
| `opengauss` | openGauss 7.0.0（Oracle 兼容模式） | 5433 | omm | `LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql /opt/opengauss/bin/gsql -h 127.0.0.1 -p 5433 -U omm -W "$DB_PASSWORD" -d postgres` |
| `kingbase` | KingbaseES V9R2（oracle 模式） | 54321 | system | `/opt/Kingbase/ES/Server/bin/ksql -p 54321 -U system -d test`（socket 免密） |
| `dm` | 达梦 DM8 | 5236 | SYSDBA | `/opt/dmdbms/bin/disql 'SYSDBA/"$DB_PASSWORD"@localhost:5236'` |
| `redis` | Redis 7 | 6379 | redis（另保留官方默认用户 default） | `REDISCLI_AUTH="$DB_PASSWORD" redis-cli` |

- **密码**：统一取 `DB_PASSWORD`。五个关系库仅首启初始化时写入，已有数据不追溯（改密进容器 `ALTER USER`）；Redis 每次启动按当前值重写配置，密码始终与该变量一致。openGauss 初始用户密码的字符仅限数字、字母与官方文档列出的特殊字符（`~!@#$%^&*()-_=+\|[{}]:;,.<>/?`），不能含空格与引号；openGauss / DM8 有强制复杂度（见 compose 注释）。
- **连接**：上表命令以主账号身份直接执行；`gsql`、`ksql`、`disql` 不在镜像 `PATH` 上，须写全路径（`gsql` 另需 `LD_LIBRARY_PATH` 指向包内库）。socket 免密的范围：PostgreSQL 与 KingbaseES 对任意系统账号开放；openGauss 仅初始用户 omm 以系统账号 omm 身份可免密；MySQL、达梦、Redis 一律密码。达梦密码本身含双引号时连接串无法表达，改用 `/opt/dmdbms/bin/disql SYSDBA@localhost:5236` 按提示输入密码。
- **监听**：各库统一 `0.0.0.0`，对外暴露由 compose 端口映射控制（默认不发布端口）。
- **数据位置与生命周期**：数据目录在挂载目录之外（`/var/lib/postgresql`、`/var/lib/mysql`、`/var/lib/opengauss`、`/var/lib/kingbase`、`/var/lib/dm8`、`/var/lib/redis`），默认落容器可写层——**容器重建即全新**（换镜像、`docker compose down` 后再 `up`）；`docker restart`、宿主重启、异常自动拉起仍是同一个容器，数据保留。需要跨重建保留某个库的数据时，在 compose 为对应路径挂卷即可，`SDK.sh` 对"镜像留空数据目录 / 挂空卷 / 挂已有数据卷"三种场景统一幂等。
- **首启耗时**：各库初始化 5-30s，后台进行，不阻塞 SSH / 主服务就绪；初始化期间容器被停止，下次启动由各脚本的 `.initializing` 标记识别并清理重建。
- **拉起方式**：`SDK.sh` 只做初始化并经 `supervisorctl` 拉起 `base/supervisord.conf` 中对应的程序段（`autostart=false`）。手动重跑：`sudo bash /opt/sdks/<目录>/SDK.sh`；已初始化时直接 `supervisorctl start <程序名>`。
- **DM8 的 CPU 要求**：当前构建要求 AVX-512 指令集，不支持的 CPU 上 SDK 部署失败（FATAL 提示）、容器照常运行；此类机器设 `ENABLE_DM=0` 跳过。

## 官方组件与版本覆盖

| 组件 | 默认版本 | 覆盖 env | 备注 |
|---|---|---|---|
| flutter | 3.44.4 | `FLUTTER_VERSION` | 依赖同挂载的 android 组件 + JDK 21；首启自动预热 Dart 缓存 |
| android | cmdline-tools 11076708 | `ANDROID_CMDLINE_TOOLS_BUILD`、`ANDROID_SDK_PACKAGES` | 包清单变更走 sdkmanager 增量安装 |
| gradle | 9.6.0 | `GRADLE_VERSION` | 多版本共存（按版本分目录）；依赖缓存随挂载持久 |
| rust | 1.95.0 | `RUST_VERSION`、`RUST_MIRROR` | rustup 机制，换版本增量装、旧工具链保留；镜像默认国内 rsproxy.cn（rustup-init/dist/crates 全链路），安装失败自动退化官方源重试一次，`RUST_MIRROR=official` 强制官方，显式设 `RUSTUP_DIST_SERVER`/`RUSTUP_UPDATE_ROOT` 则完全尊重外部值 |
| apk-tools | 3.0.2 / 1.5.5 / 2.4.35 / 1.3.0 | `APKTOOL_VERSION` 等 4 个同名 env | 任一版本变更整目录重部署 |

覆盖方式：`docker-compose.yml` 的 `environment:` 加一行（如 `- FLUTTER_VERSION=3.45.0`），或直接修改对应 `SDK.sh` 的默认值（挂载卷上的文件，立即生效，无需重建镜像）。数据库版本随 Base 层镜像滚动，升级走 `Dockerfile.base`。

## 注意事项

- **首启下载量**：官方五个工具链合计约 6-7GB（flutter ~1G tarball + dart 缓存 ~1G、android ~2G、rust ~1G、gradle ~140M、apk-tools ~100M）。第三波与主服务并行，不阻塞 SSH/OpenChamber 就绪；只要其中几个 → compose `environment:` 设 `ENABLE_<目录名大写>=0`。
- **首次启动的部署顺序**：目录名字典序、闸门 3 个在途。android / flutter / rust 这类大体积下载会长时间占用槽位，排在后面的数据库要等前面的任务完成才开始初始化；SDK 已部署后各任务秒过，数据库随即 3 个一批初始化。
- **手动重跑**：容器内 `sudo bash /opt/sdks/<组件>/SDK.sh`（写 `/etc/profile.d` 需要 root）。
- **docker exec 非登录 shell**：不 source profile.d，SDK env 不在——用 `bash -l` 或直接用 `/usr/local/bin` 下的软链命令。
- **非 root 主账号**：部署产物已按 `SDK_OWNER` chown；Flutter 的 dubious ownership 由 SDK.sh 写系统级 `git safe.directory` 处理。
- **本目录不触发 CI 构建**：`sdks/**` 在各 workflow paths 白名单之外（纯运行期内容），改 SDK.sh 无需重建镜像。
