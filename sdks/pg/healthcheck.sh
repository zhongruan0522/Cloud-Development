#!/usr/bin/env bash
# ==========================================
# PostgreSQL SDK 健康探针（base/healthcheck.sh 逐 SDK 调用；退出码 0 为健康）
# ==========================================
# 判据：supervisord 程序段 postgresql 处于 RUNNING，且 postmaster 应答
# （pg_isready 无需认证）。SDK.sh 后台初始化期间程序段为 STOPPED，由外层健康
# 检查重试覆盖；初始化失败则本探针持续失败，是失败组件的持续信号。
# 版本升级（如 17→18）需同步修改本文件中硬编码的 17 版本路径。
# ==========================================
set -euo pipefail

status="$(supervisorctl -c /etc/supervisor/supervisord.conf status postgresql 2>&1)" || true
echo "${status}" | grep -qE '^postgresql\s+RUNNING' || { echo "postgresql not RUNNING"; exit 1; }
# pg_isready 无需认证，仅探测 postmaster 应答
/usr/lib/postgresql/17/bin/pg_isready -h 127.0.0.1 -p 5432 -q \
    || { echo "postgresql not accepting connections"; exit 1; }
