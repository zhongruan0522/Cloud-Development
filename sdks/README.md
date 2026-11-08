# SDK 可扩展挂载目录

镜像本体不含 Flutter / Android SDK / Gradle / Rust / apk-tools（Base 层已拆出，瘦身约 5-7GB）。这些组件以 **挂载式 SDK** 形态提供：compose 把本目录挂进容器 `/opt/sdks`，entrypoint **第四波【SDK 组件】** 后台并行执行各 `SDK.sh`，自动下载部署并注入环境变量。

## 目录结构

```
sdks/                          ← compose 挂载 → /opt/sdks
├── flutter/
│   ├── SDK.sh                 ← 部署入口（随仓库自带，本目录官方模板）
│   ├── sdk/                   ← SDK 本体（首启下载解压，持久，运行期生成）
│   ├── cache/                 ← 持久性缓存（pub-cache 等，跨重建保留，运行期生成）
│   └── tmp/                   ← 一次性产物（下载包），部署完成即清理，平时不存在
├── android/                   ← 同上；sdk/ 即 ANDROID_SDK_ROOT（含增量包）
├── gradle/                    ← 同上；cache/gradle-home 即 GRADLE_USER_HOME
├── rust/                      ← 同上；sdk/rustup + sdk/cargo 即 RUSTUP/CARGO_HOME
└── apk-tools/                 ← 同上；bin/ 为统一 wrapper 目录
```

`sdk/` 与 `cache/` 均在挂载卷上：**容器重建不丢，换版本 = 删掉 `sdk/`（或改版本 env）下次启动自动重拉**。已加入 `.gitignore`，clone 仓库不会拖带 GB 级二进制。

## SDK.sh 契约（自定义 SDK 按此编写）

1. **入口唯一**：目录内放一个可执行入口 `SDK.sh`，entrypoint 只认 `<目录名>/SDK.sh`；目录名即组件名（task tag / 日志名）。
2. **运行时机**：entrypoint 第四波以 root 后台并行执行，`bash SDK.sh` 调用（无需 +x）；环境变量注入：
   - `SDK_DIR`：本组件目录（手动重跑可省略，脚本自动取自身所在目录）；
   - `SDK_OWNER`：主账号名（非 root 时部署完成后需 `chown -R` 给它）。
3. **幂等**：每次容器启动（含 docker restart）都会重跑。已部署时只做 env 注入与软链修复，秒过；版本变更走增量或整目录重部署。
4. **一次性产物及时清理**：下载包、临时解压目录一律落在 `tmp/`，部署完成立即 `rm -rf`；需要跨重建保留的（依赖缓存等）放 `cache/`。
5. **env 注入**：写 `/etc/profile.d/zz-sdk-<组件名>.sh`（登录/SSH/桌面/agent 会话生效；文件名字典序保证在 `opencode-env.sh` 之后追加 PATH）。同时把主命令软链到 `/usr/local/bin`，保证 `docker exec` 等非登录 shell 也可用。
6. **失败语义**：尽早失败（依赖自检前置）、`==> [组件名] FATAL: ...` 暴露并非零退出；不终止容器、不参与 healthcheck（SDK 是可选增强组件）。完整日志落 `/var/log/init/sdk-<组件名>.log`，`docker logs` 只透传 `==> ` 开头的阶段行。

模板骨架（复制到 `sdks/<你的组件>/SDK.sh` 改造即可；`. ` 开头的隐藏目录不会被扫描，可用来停用某个官方组件）：

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

## 官方组件与版本覆盖

| 组件 | 默认版本 | 覆盖 env | 备注 |
|---|---|---|---|
| flutter | 3.44.4 | `FLUTTER_VERSION` | 依赖同挂载的 android 组件 + JDK 21；首启自动预热 Dart 缓存 |
| android | cmdline-tools 11076708 | `ANDROID_CMDLINE_TOOLS_BUILD`、`ANDROID_SDK_PACKAGES` | 包清单变更走 sdkmanager 增量安装 |
| gradle | 9.0 | `GRADLE_VERSION` | 多版本共存（按版本分目录）；依赖缓存随挂载持久 |
| rust | 1.95.0 | `RUST_VERSION` | rustup 机制，换版本增量装、旧工具链保留 |
| apk-tools | 3.0.2 / 1.5.5 / 2.4.35 / 1.3.0 | `APKTOOL_VERSION` 等 4 个同名 env | 任一版本变更整目录重部署 |

覆盖方式：`docker-compose.yml` 的 `environment:` 加一行（如 `- FLUTTER_VERSION=3.45.0`），或直接修改对应 `SDK.sh` 的默认值（挂载卷上的文件，立即生效，无需重建镜像）。

## 注意事项

- **首启下载量**：官方五个组件合计约 6-7GB（flutter ~1G tarball + dart 缓存 ~1G、android ~2G、rust ~1G、gradle ~140M、apk-tools ~100M）。第四波与主服务并行，不阻塞 SSH/OpenChamber 就绪；只要其中几个 → 删掉对应目录即可。
- **手动重跑**：容器内 `sudo bash /opt/sdks/<组件>/SDK.sh`（写 `/etc/profile.d` 需要 root）。
- **docker exec 非登录 shell**：不 source profile.d，SDK env 不在——用 `bash -l` 或直接用 `/usr/local/bin` 下的软链命令。
- **非 root 主账号**：部署产物已按 `SDK_OWNER` chown；Flutter 的 dubious ownership 由 SDK.sh 写系统级 `git safe.directory` 处理。
- **本目录不触发 CI 构建**：`sdks/**` 在各 workflow paths 白名单之外（纯运行期内容），改 SDK.sh 无需构建镜像。
