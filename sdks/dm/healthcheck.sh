#!/usr/bin/env bash
# ==========================================
# 达梦 DM8 SDK 健康探针（base/healthcheck.sh 逐 SDK 调用；退出码 0 为健康）
# ==========================================
# 判据：supervisord 程序段 dm 处于 RUNNING，且 5236 端口接受 TCP 连接。
# 探针不依赖密码：DB_PASSWORD 仅在首启初始化时写入达梦，此后与实例实际密码
# 不保证一致（见 sdks/README.md"密码"）。达梦无 local socket 免密通道，也
# 没有免认证的协议层探活命令，故以端口应答为准。SDK.sh 后台初始化期间程序
# 段为 STOPPED，由外层健康检查重试覆盖；初始化失败则本探针持续失败，是失败
# 组件的持续信号。
# ==========================================
set -euo pipefail

status="$(supervisorctl -c /etc/supervisor/supervisord.conf status dm 2>&1)" || true
echo "${status}" | grep -qE '^dm\s+RUNNING' || { echo "dm not RUNNING"; exit 1; }
# bash 内建 /dev/tcp：连接建立即返回 0，拒绝或超时返回非 0
timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/5236' 2>/dev/null \
    || { echo "dm not accepting connections"; exit 1; }
