#!/usr/bin/env bash
# ==========================================
# KingbaseES SDK 健康探针（base/healthcheck.sh 逐 SDK 调用；退出码 0 为健康）
# ==========================================
# 判据：supervisord 程序段 kingbase 处于 RUNNING，且 system 经 local socket 免密
# 能执行查询（SDK.sh initdb --auth-local=trust）。SDK.sh 后台初始化期间程序段为
# STOPPED，由外层健康检查重试覆盖；初始化失败则本探针持续失败，是失败组件的
# 持续信号。ksql 二进制 rpath 自足（无需 LD_LIBRARY_PATH），-d test 为金仓默认库。
# ==========================================
set -euo pipefail

status="$(supervisorctl -c /etc/supervisor/supervisord.conf status kingbase 2>&1)" || true
echo "${status}" | grep -qE '^kingbase\s+RUNNING' || { echo "kingbase not RUNNING"; exit 1; }
# -p 54321 与 supervisord 启动端口一致（官方默认端口）
su -s /bin/bash kingbase -c '/opt/Kingbase/ES/Server/bin/ksql -p 54321 -U system -d test -Atc "SELECT 1;"' >/dev/null \
    || { echo "kingbase not accepting connections"; exit 1; }
