#!/usr/bin/env bash
# ==========================================
# Redis SDK 健康探针（base/healthcheck.sh 逐 SDK 调用；退出码 0 为健康）
# ==========================================
# 判据：supervisord 程序段 redis 处于 RUNNING，且以统一密码 DB_PASSWORD 能完成
# 认证（ACL 用户 redis）。redis-cli 对 NOAUTH/WRONGPASS 应答的退出码为 0，判据
# 必须是应答内容（PONG）；密码经 REDISCLI_AUTH 传入，不走命令行参数。
# SDK.sh 后台部署期间程序段为 STOPPED，由外层健康检查重试覆盖；部署失败则本探针
# 持续失败，是失败组件的持续信号。
# ==========================================
set -euo pipefail

status="$(supervisorctl -c /etc/supervisor/supervisord.conf status redis 2>&1)" || true
echo "${status}" | grep -qE '^redis\s+RUNNING' || { echo "redis not RUNNING"; exit 1; }
# 密码取容器环境变量 DB_PASSWORD；容器环境未设置该变量时取与 entrypoint.sh 相同的
# 默认值（SDK.sh 在 entrypoint 导出的环境里运行，写进配置的即该值）。
REDIS_HC_PWD="${DB_PASSWORD:-Opencode@123}"
[ "$(REDISCLI_AUTH="${REDIS_HC_PWD}" redis-cli -h 127.0.0.1 -p 6379 --user redis ping 2>/dev/null)" = PONG ] \
    || { echo "redis not accepting authenticated connections"; exit 1; }
