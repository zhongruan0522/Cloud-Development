# AGENTS.md

## Docker 镜像分层策略

本项目使用两层 Docker 镜像构建（自底向上）：

1. **Base 层**（`Dockerfile.base` → `:base`）：仅存放稳定、低频变动的组件（工具链、运行时库、全局 npm/Python 包、Playwright 浏览器等），月级变动。
2. **动态层**（`Dockerfile` → release tag `vX.Y.Z`）：仅包含绑定了自动更新检测（`check-update.yml`）的版本类组件，天级变动，`FROM :base`；镜像推送成功后才写 release 版本锁。

在新加入依赖的时候，如果用户没说放入哪层，则默认放入 Base 层。

### 层数预算

成品镜像的层数有硬上限：CNB 制品库按清单引用数计（config 加 layers），合计到 64 个即被拒收（[官方文档](https://docs.cnb.cool/zh/artifact/docker.html#xian-zhi)写“镜像最大 64 层”，报错为 `Manifest references (config and layers) exceed the limitation(64) of registry`），新增任何一层都要先算预算。可执行位等文件属性用 `COPY --chmod` 在复制时直接设定，不另起 `RUN chmod` 层；确需新增内容时优先并入相邻层。

### 触发归属原则

- **Base 层**：`Dockerfile.base`、`base/**`（含 entrypoint.sh / healthcheck.sh / supervisord.conf 等启动文件）改动触发 `build-base.yml`；Base 构建完成后通过 `trigger-dynamic` job 级联重建动态层（以 Base 镜像的 digest 精确引用构建，版本号取上次 release 锁定值）。
- **`Dockerfile`（动态层）只触发 `docker-build.yml`**：CI 显式传入 `BASE_IMAGE` 构建，并额外 COPY 了 `base/` 下的入口脚本、`entrypoint.d/` 模块库、healthcheck 与 supervisord.conf 用于覆盖下层同名文件——这些是稳定文件，其更新靠下层级联保证；动态层本身只新增版本类组件（opencode/claude-code 等），单独改 `Dockerfile` 不应带动下层。
- **黑名单（不触发任何构建）**：README.md、docker-compose.yml、docker-compose.x11.yml、AGENTS.md、`.github/**`、`sdks/**`（纯运行期挂载内容与文档）、`参考项目/**` 等纯文档/部署配置。`paths:` 白名单本身就是黑名单——只有列出的路径才会触发构建。

## 文件布局架构

项目按职责划分为顶层模块：

| 目录       | 职责       | 说明                                                                                                                                                                                                                  |
| ---------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base/`    | Base 层    | 存放底层工具、依赖库组件、构建期一次性脚本（如 Go 模块预热）及容器启动文件（entrypoint/supervisord/healthcheck），归属 Base 层                                                                                        |
| `sdks/`    | 挂载式 SDK | 可扩展 SDK 组件（flutter/android/gradle/rust/apk-tools 工具链 + pg/mysql/opengauss/kingbase/dm/redis 六个数据库的官方 SDK.sh 模板 + 契约 README），不烧进任何镜像层；entrypoint 第三波扫描 `/opt/sdks/*/SDK.sh` 后台部署，并发闸门同时最多 3 个在途（init-sdks.sh 注入 SDK_DIR/SDK_OWNER；`ENABLE_<目录名大写>=0` 跳过；目录内 healthcheck.sh 参与容器健康判定）。数据库二进制在 Base 层，数据默认落容器可写层 |

## 日志分层

容器 stdout（`docker logs`）只有状态行：后台任务与波次的 `[阶段][组件] - [状态：…]` 行，OpenChamber 与 Magpie 的 Web UI 入口地址行，以及入口脚本同步段的 `[组件] - …` 提示行（账号、SSH、OpenChamber 密码、GitHub 私钥、X11 显示）。程序输出不得写入容器 stdout：`[program:x]` 段的日志不得指向 `/dev/fd/1` 或 `/dev/fd/2`，`[supervisord]` 段的 `silent=true` 须保留，后台任务不得往 stdout 打过程行。含登录密钥的链接行用 `lib.sh` 的 `log_link`（只进容器 stdout，不落任务日志）。

- 任务日志：`base/entrypoint.d/lib.sh` 的 `run_bg` / `run_sdk` 全量落 `/var/log/init/<tag>.log`。
- 程序日志：`base/supervisord.conf` 各 `[program:x]` 段把 stdout 与 stderr 合并落 `/var/log/supervisor/<程序段名>.log`，按大小轮转，每次拉起前写一行带时间戳的启动分隔行（`lib.sh` 的 `log_program_start`）；新增 `[program:x]` 段沿用这四行（`stdout_logfile`、`stdout_logfile_maxbytes`、`stdout_logfile_backups`、`redirect_stderr`）。
- 程序日志目录与 `lib.sh` 的 `PROGRAM_LOG_DIR` 是同一约定，改动须同步。

## 关于任务结束后的处理方式

若用户未说明不需要提交/推送，则默认完成需求后就提交并推送上云

## 行为反模式警示：拒绝纠错残留

严厉禁止以下“纠偏后残留历史痕迹与自我辩解”的行为模式：

> 用户让做一盘“番茄炒蛋”，Agent 擅自加了“东坡肉”；被指出后虽然去掉了，但提交/PR 时写着「番茄炒蛋（无东坡肉）」，并在注释中大篇幅解释为什么本道菜不需要加东坡肉。

**交付要求**：任何代码、注释、文档、提交信息及回复，都必须直接呈现对齐后的**干净终态设计**（Clean final-state design），严禁包含任何前序错误、自我辩解或“在此删掉某逻辑”的纠错痕迹。
