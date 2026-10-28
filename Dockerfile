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
#   2. Claude Code   ← npm，中高频
#   3. Droid         ← npm，高频（0.x 早期阶段）
#   4. opencode       ← npm，最高频（用户感知最强的小版本迭代）
#   5. openchamber    ← pnpm，最高频（与 opencode 同频发布，且运行时托管 opencode 进程）
#
# 拆分 npm 层后，单个 npm 包升级只重建自己一层，不影响其他 npm 包缓存。

ARG BASE_IMAGE=ghcr.io/zhongruan0522/opencode-docker:base
FROM ${BASE_IMAGE}

ARG OPENCODE_VERSION=latest
ARG SERENA_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG DROID_VERSION=latest
ARG OPENCHAMBER_VERSION=latest

# === 1. serena-agent（uv tool install，中低频）===
# 仅安装模式：不常驻拉起 MCP HTTP 服务（客户端按需以 stdio 自行启动），
# 版本仍由 check-update.yml 驱动自动更新。
# UV_CACHE_DIR 指到 /tmp 且与安装同层删除：默认缓存落在 /root/.cache/uv
# 会被烧进镜像层（曾累积 ~110M）。
# UV_TOOL_DIR / UV_PYTHON_INSTALL_DIR 迁 /opt（本机 uv 0.13 实测布局）：uv 默认
# 把工具 venv 与下载的 CPython 3.13 落 ~/.local/share/uv/（构建期即 /root 下），
# /root 为 0700 私有目录，desktop 用户（uid 10002）不可穿透，/usr/local/bin/serena
# 入口软链对其成死链。两处必须一起迁：venv 的 bin/python 是指向解释器的软链
# （实测 tools/<t>/bin/python -> python/cpython-3.13.*/bin/python3.13），只迁
# venv 不迁解释器仍会穿回 /root。对齐 Playwright（/opt/ms-playwright）/
# CodeGraph（/opt/codegraph）的系统级共享先例。
RUN if ! command -v uv >/dev/null 2>&1; then \
      curl -fsSL https://astral.sh/uv/install.sh | env CARGO_HOME=/tmp/uv-cargo UV_INSTALL_DIR=/usr/local/bin sh \
      && rm -rf /tmp/uv-cargo; \
    fi \
    && UV_CACHE_DIR=/tmp/uv-cache UV_TOOL_DIR=/opt/uv-tools UV_PYTHON_INSTALL_DIR=/opt/uv-python UV_TOOL_BIN_DIR=/usr/local/bin uv tool install -p 3.13 "serena-agent@${SERENA_VERSION}" --prerelease=allow \
    && rm -rf /tmp/uv-cache \
    && serena init

# === 2. Claude Code（npm，中高频）===
# 安装官方 npm 包 @anthropic-ai/claude-code。
# 版本由 CLAUDE_CODE_VERSION 驱动（check-update.yml 检测 npm registry）。
# @cometix/ccline 是配套工具，随 CC 一起重建，不单独接入自动更新。
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm install -g @cometix/ccline \
    && npm cache clean --force

# === 3. Droid CLI（npm，高频）===
# Factory Droid CLI（npm 包名 droid，https://docs.factory.com/）。
# - npm 分发版在构建期即禁用内置自动更新（官方文档明示），版本升级完全由
#   check-update.yml 驱动，与本项目"版本类组件"模式契合。
# - 主包仅是 JS shim（~26KB），平台二进制经 @factory/cli-* 可选依赖分发：
#   linux/amd64 下会同时装下 x64 与 x64-baseline 两个 ~269M 变体，shim 按
#   AVX2 探测选择——与 opencode 层同策略裁掉 baseline（CI amd64 runner 支持 AVX2）。
# - 运行时数据（会话/凭据/设置，实测无 ~/.factory 之外的散落目录）由
#   docker-compose 挂载 /root/.factory 持久化。
# - rm 必须与 install 同一 RUN：跨层删除不回收空间。
RUN npm install -g droid@${DROID_VERSION} \
    && npm cache clean --force \
    && rm -rf /usr/local/lib/node_modules/droid/node_modules/@factory/cli-linux-x64-baseline

# === 4. opencode v2（最高频，必须排最后）===
# v2 起官方 npm 包由 opencode-ai 更名为 @opencode/cli（仅含 2.x，v1 停在 opencode-ai@1.18.x）。
# postinstall 会把命中平台的二进制硬链进包内 bin/，因此装完裁掉其余平台包不影响运行。
# rm -rf 必须与 install 在同一 RUN 内：Docker 层叠加，
# 在新层里删除上一层添加的文件不会回收空间，必须安装+删除在同一层完成。
RUN npm install -g @opencode/cli@${OPENCODE_VERSION} \
    && npm cache clean --force \
    && rm -rf /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-baseline \
              /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-baseline-musl \
              /usr/local/lib/node_modules/@opencode/cli/node_modules/@opencode/cli-linux-x64-musl

# === 5. openchamber（pnpm，最高频）===
# OpenChamber Web UI（@openchamber/web），运行时托管 opencode serve，对外提供 4096 端口。
# （node-pty ABI 失配回退 node-gyp 编译所需的 python3-dev 已由 Base 层统一提供。）
# - DEBIAN_FRONTEND=noninteractive 保证 apt 非交互安装不卡构建；CI=true 让 pnpm
#   跳过全局目录变更时的交互确认（构建容器内无 TTY）。
# - PNPM_HOME=/opt/pnpm：全局 bin/包树/store 整体落系统路径（本机 pnpm 12.11.2
#   实测三者均跟随 PNPM_HOME），Base 层 ENV 已同步。此前落 /root/.local/share/pnpm
#   时 /root 为 0700，desktop 用户（uid 10002）不可穿透，软链救不活；迁 /opt 后
#   /usr/local/bin/openchamber 对全部用户可用，对齐 Playwright/CodeGraph 先例。
# - PATH 必须显式包含全局 bin 目录：pnpm 要求"配置的全局 bin 目录必须在 PATH 中"，
#   缺失会直接拒绝全局安装（[ERROR] ... is not in PATH → Run "pnpm setup"）。
#   这是 CI 首次构建失败根因。
# - rm store（与安装同 RUN）：store 与全局 node_modules 硬链共享文件内容
#   （实测 links=2），删除仅减引用计数、不影响运行，留着则 index.db 与目录
#   条目白白烧进镜像层；容器内 root 再跑 pnpm add -g 时 store 自动重建。
# - symlink 到 /usr/local/bin：supervisord 不加载 profile.d 的 PATH，
#   用绝对路径且 node 一定能找到的方式拉起服务。
RUN env HOME=/root PNPM_HOME=/opt/pnpm CI=true \
       PATH="/opt/pnpm/bin:${PATH}" \
       pnpm add -g "@openchamber/web@${OPENCHAMBER_VERSION}" \
    && rm -rf /root/.cache/pnpm /opt/pnpm/store \
    && ln -sf /opt/pnpm/bin/openchamber /usr/local/bin/openchamber \
    && chown -R root:root /opt/pnpm \
    && openchamber --version

# 动态层覆盖启动配置。
COPY base/entrypoint.sh /usr/local/bin/entrypoint.sh
# 入口的 source 模块库随覆盖机制整体同步（漏 COPY 任意模块 = 新入口配旧库）。
COPY base/entrypoint.d/ /usr/local/share/entrypoint.d/
COPY base/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY base/supervisord.conf /etc/supervisor/supervisord.conf
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh
