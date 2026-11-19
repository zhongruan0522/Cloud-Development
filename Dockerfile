# syntax=docker/dockerfile:1

# ==========================================
# 动态层：自动检测更新的 Agent 组件 + 末尾直装组件（magpie）
#
# CI（docker-build.yml）用同一份 Dockerfile 在同一工作流内并行构建两个变体，
# 各自显式传入 BASE_IMAGE：
#   - slim（默认）：FROM Base 镜像（:base），产出无后缀 tag vX.Y.Z（NoDesktop-Base）
#   - desktop   ：FROM 桌面镜像（:desktop），产出 vX.Y.Z-desktop（Desktop-Base）
# 下方 ARG 默认值仅作本地构建兜底（默认 slim）；每次自动更新触发时只重建本文件，
# Base/桌面层完全复用缓存。
# ==========================================

# ---
# 层排序策略（修改顺序前请阅读）
# ---
# Docker 缓存 key = 父层 digest + 当前层命令字符串（含 ARG 替换值）。
# 任意一层重建都会让其下游所有层失效——即使下游命令完全没变，
# 由于父层 digest 变了，下游也必须重新执行，并产生新的层 digest。
# 因此层顺序必须严格按「更新频率从低到高」排列：
#   最稳定（最重、最低频）→ 最易变（最轻、最高频）
# 这样高频包升级时，低频/重型层才能命中缓存不重建。
#
# 当前顺序（自上而下，父→子）：
#   1. Codex          ← npm，中频
#   2. Claude Code    ← npm，中高频
#   3. codex-security ← npm，高频（0.x 早期阶段，迭代极快）
#   4. Antigravity    ← 官方清单最新版二进制直装，高频（1.x 早期阶段）
#   5. opencode       ← npm，最高频（用户感知最强的小版本迭代）
#   6. openchamber    ← pnpm，最高频（与 opencode 同频发布，且运行时托管 opencode 进程）
#   7. magpie         ← 官方静态 CLI/Web 二进制直装，不参与自动更新与通知（排最底，不影响上层缓存）
#
# 各 npm 包独立成层：单个包升级只重建自己一层，不影响其他包缓存。

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:base
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_SECURITY_VERSION=latest
ARG ANTIGRAVITY_VERSION=latest
ARG OPENCHAMBER_VERSION=latest

# === 1. Codex（npm，中频）===
# 独立层：单个 npm 包升级只重建本层。
# npm cache clean 必须与安装同一 RUN：动态层继承 Base 层 ENV HOME=/root，
# npm 缓存落在 /root/.npm，跨层删除不缩小镜像。
RUN npm install -g @openai/codex@${CODEX_VERSION} \
    && npm cache clean --force

# === 2. Claude Code（npm，中高频）===
# 官方 npm 包 @anthropic-ai/claude-code，版本由 CLAUDE_CODE_VERSION 驱动
# （check-update.yml 检测 npm registry）；@cometix/ccline 为配套工具，同层安装。
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm install -g @cometix/ccline \
    && npm cache clean --force

# === 3. codex-security（npm，高频）===
# OpenAI Codex Security CLI，仅 npm 分发：https://www.npmjs.com/package/@openai/codex-security
RUN npm install -g @openai/codex-security@${CODEX_SECURITY_VERSION} \
    && npm cache clean --force

# === 4. Antigravity CLI（agy，官方清单直装，高频）===
# 安装流程等价官方 bootstrapper（curl -fsSL https://antigravity.google/cli/install.sh | bash）：
# 清单 → 下载 → SHA512 校验 → 落盘 /usr/local/bin/agy。
# - 无历史版本可锁：manifests/linux_<arch>.json 永远只返回最新版（version/url/sha512），
#   ARG 仅作缓存 key（CI 每次构建前实时查清单传入），使 agy 自身升级能失效本层；
#   构建期清单比 ARG 新时告警后照装最新版（元数据由下轮 check-update 对齐）。
# - GCS 下载链路存在 403/200 交替抖动，必须 --retry-all-errors 才能稳定下载。
# - 包内是单个二进制 antigravity，安装+清理必须同一 RUN 完成以回收空间。
RUN set -eux \
    && AGY_ARCH="$(dpkg --print-architecture)" \
    && case "${AGY_ARCH}" in amd64|arm64) ;; *) echo "Unsupported Antigravity CLI architecture: ${AGY_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSL --retry 10 --retry-all-errors --retry-delay 2 -o /tmp/agy-manifest.json \
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_${AGY_ARCH}.json" \
    && AGY_LATEST="$(jq -r '.version // empty' /tmp/agy-manifest.json)" \
    && AGY_URL="$(jq -r '.url // empty' /tmp/agy-manifest.json)" \
    && AGY_SHA512="$(jq -r '.sha512 // empty' /tmp/agy-manifest.json)" \
    && if [ -z "${AGY_LATEST}" ] || [ -z "${AGY_URL}" ] || [ -z "${AGY_SHA512}" ]; then \
        echo "Malformed Antigravity CLI manifest" >&2; exit 1; fi \
    && if [ "${ANTIGRAVITY_VERSION}" != "latest" ] && [ "${ANTIGRAVITY_VERSION}" != "${AGY_LATEST}" ]; then \
        echo "WARNING: requested Antigravity CLI ${ANTIGRAVITY_VERSION}, but upstream manifest serves ${AGY_LATEST}; installing ${AGY_LATEST}" >&2; fi \
    && curl -fsSL --retry 10 --retry-all-errors --retry-delay 2 -o /tmp/agy.tar.gz "${AGY_URL}" \
    && echo "${AGY_SHA512}  /tmp/agy.tar.gz" | sha512sum -c - \
    && tar -xzf /tmp/agy.tar.gz -C /tmp \
    && install -m 0755 /tmp/antigravity /usr/local/bin/agy \
    && /usr/local/bin/agy --version \
    && rm -rf /tmp/agy-manifest.json /tmp/agy.tar.gz /tmp/antigravity

# === 5. opencode（最高频，必须排最后）===
# 官方 npm 包 @opencode/cli（2.x）。postinstall 会把命中平台的二进制硬链进包内
# bin/，因此装完裁掉其余平台包不影响运行。
# rm -rf 必须与 install 在同一 RUN 内：Docker 层叠加，
# 在新层里删除上一层添加的文件不会回收空间，必须安装+删除在同一层完成。
RUN npm install -g @opencode/cli@${OPENCODE_VERSION} \
    && npm cache clean --force \
    && rm -rf /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-baseline \
              /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-musl

# === 6. openchamber（pnpm，最高频）===
# OpenChamber Web UI（@openchamber/web），运行时托管 opencode serve，对外提供 4096 端口。
# node-pty ABI 失配回退 node-gyp 编译所需的 python3-dev 由 Base 层提供。
# - CI=true 让 pnpm 跳过全局目录变更时的交互确认（构建容器内无 TTY）。
# - PNPM_HOME=/opt/pnpm：全局 bin/包树/store 落系统路径；/root 为 0700，普通用户
#   不可穿透，入口经 /usr/local/bin 软链对全部用户可用。
# - PATH 必须显式包含全局 bin 目录：pnpm 要求"配置的全局 bin 目录必须在 PATH 中"，
#   缺失会直接拒绝全局安装（[ERROR] ... is not in PATH → Run "pnpm setup"）。
# - rm store（与安装同 RUN）：store 与全局 node_modules 硬链共享文件内容，
#   删除仅减引用计数、不影响运行；容器内 root 再跑 pnpm add -g 时 store 自动重建。
# - symlink 到 /usr/local/bin：supervisord 不加载 profile.d 的 PATH，
#   用绝对路径且 node 一定能找到的方式拉起服务。
RUN env HOME=/root PNPM_HOME=/opt/pnpm CI=true \
       PATH="/opt/pnpm/bin:${PATH}" \
       pnpm add -g "@openchamber/web@${OPENCHAMBER_VERSION}" \
    && rm -rf /root/.cache/pnpm /opt/pnpm/store \
    && ln -sf /opt/pnpm/bin/openchamber /usr/local/bin/openchamber \
    && chown -R root:root /opt/pnpm \
    && openchamber --version

# === 7. magpie（静态 CLI/Web 二进制直装，排最底；不参与自动更新与通知）===
# 从官方发布清单（usemagpie.ai/api/latest）拉取静态无 GUI 构建（magpie-cli-linux-<arch>，
# 内嵌完整 Web UI + 统一模型网关 + CLI，零 GTK/WebKitGTK 依赖），优先 R2 下载、失败回退
# GitHub Release，严格校验 SHA-256 后落盘 /usr/local/bin/magpie。
# 不设版本 ARG、不接入 check-update/notify，置于所有组件最底以复用上层全部缓存。
RUN set -eux \
    && MAGPIE_ARCH="$(dpkg --print-architecture)" \
    && case "${MAGPIE_ARCH}" in amd64|arm64) ;; *) echo "Unsupported magpie architecture: ${MAGPIE_ARCH}" >&2; exit 1 ;; esac \
    && MAGPIE_ASSET="magpie-cli-linux-${MAGPIE_ARCH}" \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/magpie-latest.json \
        "https://usemagpie.ai/api/latest" \
    && MAGPIE_URL="$(jq -r --arg a "${MAGPIE_ASSET}" '.assets[$a].url // empty' /tmp/magpie-latest.json)" \
    && MAGPIE_GITHUB="$(jq -r --arg a "${MAGPIE_ASSET}" '.assets[$a].github // empty' /tmp/magpie-latest.json)" \
    && MAGPIE_SHA256="$(jq -r --arg a "${MAGPIE_ASSET}" '.assets[$a].sha256 // empty' /tmp/magpie-latest.json)" \
    && if [ -z "${MAGPIE_URL}" ] || [ -z "${MAGPIE_SHA256}" ]; then \
        echo "Malformed magpie release feed for ${MAGPIE_ASSET}" >&2; exit 1; fi \
    && (curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/magpie "${MAGPIE_URL}" \
        || { [ -n "${MAGPIE_GITHUB}" ] && [ "${MAGPIE_GITHUB}" != "${MAGPIE_URL}" ] \
             && curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/magpie "${MAGPIE_GITHUB}"; }) \
    && echo "${MAGPIE_SHA256}  /tmp/magpie" | sha256sum -c - \
    && install -m 0755 /tmp/magpie /usr/local/bin/magpie \
    && /usr/local/bin/magpie --version \
    && rm -rf /tmp/magpie-latest.json /tmp/magpie

# 动态层覆盖启动配置；入口与其 source 模块库整体同步。
COPY base/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY base/entrypoint.d/ /usr/local/share/entrypoint.d/
COPY base/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY base/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
