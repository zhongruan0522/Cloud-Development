# syntax=docker/dockerfile:1

# ==========================================
# 动态层：仅包含自动检测更新的组件
#
# CI（docker-build.yml）用同一份 Dockerfile 在同一工作流内并行构建两个变体，
# 各自显式传入 BASE_IMAGE：
#   - slim（默认）：FROM Base 镜像（:base），产出无后缀 tag vX.Y.Z（NoDesktop-Base）
#   - desktop   ：FROM 桌面镜像（:desktop），产出 vX.Y.Z-desktop（Desktop-Base）
# 下方 ARG 默认值仅作本地构建兜底（默认 slim）；每次自动更新触发时只重建本文件，
# Base/桌面层完全复用缓存。
# ==========================================

# ---
# 层排序策略（重要！修改顺序前请务必阅读）
# ---
# Docker 缓存 key = 父层 digest + 当前层命令字符串（含 ARG 替换值）。
# 任意一层重建都会让其下游所有层失效——即使下游命令完全没变，
# 由于父层 digest 变了，下游也必须重新执行，并产生新的层 digest。
# 因此层顺序必须严格按「更新频率从低到高」排列：
#   最稳定（最重、最低频）→ 最易变（最轻、最高频）
# 这样高频包升级时，低频/重型层才能命中缓存不重建。
#
# 当前顺序（自上而下，父→子）：
#   1. serena-agent  ← uv tool install，中低频
#   2. Codex         ← npm，中频
#   3. Claude Code   ← npm，中高频
#   3.5 CC 补丁       ← agent/ccpatch/*.sh，中低频（紧跟 CC 层，CC 升级时自动对最新 cli.js 重跑）
#   4. codex-security ← npm，高频（0.x 早期阶段，迭代极快）
#   5. Antigravity    ← 官方清单最新版二进制直装，高频（1.x 早期阶段）
#   6. opencode       ← npm，最高频（用户感知最强的小版本迭代）
#   7. openchamber    ← pnpm，最高频（与 opencode 同频发布，且运行时托管 opencode 进程）
#
# 拆分 npm 层后，单个 npm 包升级只重建自己一层，不影响其他 npm 包缓存。

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:base
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG SERENA_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_SECURITY_VERSION=latest
ARG ANTIGRAVITY_VERSION=latest
ARG OPENCHAMBER_VERSION=latest

# === 1. serena-agent（uv tool install，中低频）===
# UV_CACHE_DIR 指到 /tmp 且与安装同层删除：默认缓存落在 /root/.cache/uv
# 会被烧进镜像层（曾累积 ~110M）。
RUN if ! command -v uv >/dev/null 2>&1; then \
      curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME=/tmp/uv-cargo UV_INSTALL_DIR=/usr/local/bin sh \
      && rm -rf /tmp/uv-cargo; \
    fi \
    && UV_CACHE_DIR=/tmp/uv-cache UV_TOOL_BIN_DIR=/usr/local/bin uv tool install -p 3.13 "serena-agent@${SERENA_VERSION}" --prerelease=allow \
    && rm -rf /tmp/uv-cache \
    && serena init

# === 2. Codex（npm，中频）===
# 拆分独立层：单个 npm 包升级不再连带重建其他 npm 包。
# npm cache clean 必须与安装同一 RUN：动态层继承 Base 层 ENV HOME=/root，
# npm 缓存落在 /root/.npm，跨层删除不缩小镜像（曾累积 862M）。
RUN npm install -g @openai/codex@${CODEX_VERSION} \
    && npm cache clean --force

# === 3. Claude Code（npm，中高频）===
# 安装官方 npm 包 @anthropic-ai/claude-code。
# 版本由 CLAUDE_CODE_VERSION 驱动（check-update.yml 检测 npm registry）。
# @cometix/ccline 是配套工具，随 CC 一起重建，不单独接入自动更新。
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm install -g @cometix/ccline \
    && npm cache clean --force

# === 3.5 Claude Code 补丁（agent/ccpatch/，中低频）===
# 装完 Claude Code 后自动执行 agent/ccpatch/ 下全部 *.sh 补丁脚本。
# - 官方 npm 包现为原生二进制分发、未提供 cli.js 时，runner 会明确说明并跳过 JS 补丁。
# - 兼容性：runner 用 glob 遍历，未来新增 .sh 无需改 Dockerfile 自动生效。
# - 容错：任一脚本失败仅告警不中断（runner 内部容错 + 外层 || true 双保险），构建不受影响。
# - 层排序：紧跟 CC 层之后——采用 cli.js 的 CC 升级时，父层 digest 变化会令此层自动重跑补丁。
COPY agent/run-ccpatch.sh /usr/local/bin/run-ccpatch.sh
COPY agent/ccpatch/ /opt/ccpatch/
RUN chmod +x /usr/local/bin/run-ccpatch.sh \
    && /usr/local/bin/run-ccpatch.sh || true

# === 4. codex-security（npm，高频）===
# OpenAI Codex Security CLI，仅 npm 分发：https://www.npmjs.com/package/@openai/codex-security
RUN npm install -g @openai/codex-security@${CODEX_SECURITY_VERSION} \
    && npm cache clean --force

# === 5. Antigravity CLI（agy，官方清单直装，高频）===
# 安装流程等价官方 bootstrapper（curl -fsSL https://antigravity.google/cli/install.sh | bash）：
# 清单 → 下载 → SHA512 校验 → 落盘 /usr/local/bin/agy。三点与 npm 组件不同：
# - 无历史版本可锁：manifests/linux_amd64.json 永远只返回最新版（version/url/sha512），
#   因此 ARG 仅作缓存 key（CI 每次构建前实时查清单传入），使 agy 自身升级能失效本层；
#   构建期若清单已比 ARG 新，说明上游在构建间隙发了新版——告警后照装最新版
#   （清单装不了旧版，严格报错会拖垮所有底层级联重建；元数据漂移由下轮 check-update 自愈）。
# - GCS 下载链路实测存在 403/200 交替抖动（与 UA 无关），必须 --retry-all-errors 才能稳定下载。
# - 包内是单个二进制 antigravity（解压后约 197MB），安装+清理必须同一 RUN 完成以回收空间。
RUN set -eux \
    && AGY_ARCH="$(dpkg --print-architecture)" \
    && case "${AGY_ARCH}" in amd64|arm64) ;; *) echo "Unsupported Antigravity CLI architecture: ${AGY_ARCH}" >&2; exit 1 ;; esac \
    && curl -fsSL --retry 10 --retry-all-errors --retry-delay 2 -o /tmp/agy-manifest.json \
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_${AGY_ARCH}.json" \
    && AGY_LATEST="$(jq -r '.version' /tmp/agy-manifest.json)" \
    && AGY_URL="$(jq -r '.url' /tmp/agy-manifest.json)" \
    && AGY_SHA512="$(jq -r '.sha512' /tmp/agy-manifest.json)" \
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

# === 6. opencode v2（最高频，必须排最后）===
# v2 起官方 npm 包由 opencode-ai 更名为 @opencode/cli（仅含 2.x，v1 停在 opencode-ai@1.18.x）。
# postinstall 会把命中平台的二进制硬链进包内 bin/，因此装完裁掉其余平台包不影响运行。
# rm -rf 必须与 install 在同一 RUN 内：Docker 层叠加，
# 在新层里删除上一层添加的文件不会回收空间，必须安装+删除在同一层完成。
RUN npm install -g @opencode/cli@${OPENCODE_VERSION} \
    && npm cache clean --force \
    && rm -rf /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-baseline \
              /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-musl

# === 7. openchamber（pnpm，最高频）===
# OpenChamber Web UI（@openchamber/web），运行时托管 opencode serve，对外提供 4096 端口。
# - 必须补装 python3-dev：node-pty 的 prebuild 二进制仅在 Node ABI 匹配时可用，
#   ABI 失配回退 node-gyp 本地编译时需要 Python.h 才能成功。
# - DEBIAN_FRONTEND=noninteractive 保证 apt 非交互安装不卡构建；CI=true 让 pnpm
#   跳过全局目录变更时的交互确认（构建容器内无 TTY）。
# - HOME=/root：pnpm 全局 bin 落在 /root/.local/share/pnpm/bin，
#   与运行时 PATH（entrypoint 写入的 profile.d）保持一致；
#   若以默认 root 家目录安装，服务降权后找不到 openchamber 可执行文件。
# - PATH 必须显式包含 PNPM_HOME/bin：Base 层 ENV 的 PATH 只带 PNPM_HOME 本身，
#   而 pnpm 要求"配置的全局 bin 目录必须在 PATH 中"，缺失会直接拒绝全局安装
#   （[ERROR] ... is not in PATH → Run "pnpm setup"）。这是 CI 首次构建失败根因。
# - symlink 到 /usr/local/bin：supervisord 不加载 profile.d 的 PATH，
#   用绝对路径且 node 一定能找到的方式拉起服务。
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-dev \
    && rm -rf /var/lib/apt/lists/* \
    && env HOME=/root PNPM_HOME=/root/.local/share/pnpm CI=true \
       PATH="/root/.local/share/pnpm/bin:/root/.local/share/pnpm:${PATH}" \
       pnpm add -g "@openchamber/web@${OPENCHAMBER_VERSION}" \
    && rm -rf /root/.cache/pnpm \
    && ln -sf /root/.local/share/pnpm/bin/openchamber /usr/local/bin/openchamber \
    && chown -R root:root /root/.local/share/pnpm \
    && openchamber --version

# 动态层覆盖启动配置。
COPY base/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY base/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY base/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
