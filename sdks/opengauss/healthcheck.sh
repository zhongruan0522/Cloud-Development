#!/usr/bin/env bash
# ==========================================
# openGauss SDK 健康探针（base/healthcheck.sh 逐 SDK 调用；退出码 0 为健康）
# ==========================================
# 判据：supervisord 程序段 opengauss 处于 RUNNING，且 omm 经 local socket 免密
# 能执行查询（openGauss 强制 TCP 一律密码认证，trust 不豁免）。SDK.sh 后台初始化
# 期间程序段为 STOPPED，由外层健康检查重试覆盖；初始化失败则本探针持续失败，
# 是失败组件的持续信号。
# -p 5433 与 supervisord 启动端口一致（避让 PostgreSQL 17 的 5432）；gaussdb 依赖
# LAPACKE 符号，gsql 仅需包内 lib（LD_LIBRARY_PATH，见 Dockerfile.base）。
# ==========================================
set -euo pipefail

status="$(supervisorctl -c /etc/supervisor/supervisord.conf status opengauss 2>&1)" || true
echo "${status}" | grep -qE '^opengauss\s+RUNNING' || { echo "opengauss not RUNNING"; exit 1; }
su -s /bin/bash omm -c 'LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql /opt/opengauss/bin/gsql -p 5433 -d postgres -Atc "SELECT 1;"' >/dev/null \
    || { echo "opengauss not accepting connections"; exit 1; }
