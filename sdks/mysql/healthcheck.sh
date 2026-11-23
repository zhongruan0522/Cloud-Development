#!/usr/bin/env bash
# ==========================================
# MySQL SDK 健康探针（base/healthcheck.sh 逐 SDK 调用；退出码 0 为健康）
# ==========================================
# 判据：supervisord 程序段 mysql 处于 RUNNING，且 mysqld 应答。SDK.sh 后台初始化
# 期间程序段为 STOPPED，由外层健康检查重试覆盖；初始化失败则本探针持续失败，
# 是失败组件的持续信号。
# ==========================================
set -euo pipefail

status="$(supervisorctl -c /etc/supervisor/supervisord.conf status mysql 2>&1)" || true
echo "${status}" | grep -qE '^mysql\s+RUNNING' || { echo "mysql not RUNNING"; exit 1; }
# 官方文档（dev.mysql.com/doc/refman/8.4/en/mysqladmin.html）：mysqladmin ping
# 只要服务器在运行即返回 0——即使 Access denied 也算存活，故无需带密码
mysqladmin --silent ping -u root 2>/dev/null \
    || { echo "mysql not accepting connections"; exit 1; }
