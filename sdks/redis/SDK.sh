#!/usr/bin/env bash
# ==========================================
# Redis 7 本地缓存/数据库挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：二进制由 Base 层安装（Debian 仓库 redis-server 包，
# 见 Dockerfile.base），本脚本每次启动写入密码并经 supervisorctl 拉起；运行形态
# （前台运行、监听 0.0.0.0、日志进容器 stdout/stderr）由 base/supervisord.conf 的
# [program:redis] 命令行覆盖包配置决定。
# 数据目录 /var/lib/redis 在挂载目录之外，默认落容器可写层——容器重建即全新、
# docker restart 保留（SIGTERM 关停时按默认 save 点落 RDB 快照，同一容器内数据
# 仍在）；需要跨重建保留时在 compose 为该路径挂卷。
# 认证：密码即统一变量 DB_PASSWORD。requirepass 对应 Redis 官方默认 ACL 用户
# default（只带密码的客户端均以它连接）；另建同名 ACL 用户 redis（同密码、
# 全权限），需要用户名的客户端用 redis://redis:<DB_PASSWORD>@host:6379/0。
# 进程系统账号亦为 redis（包预建）。
# 配置每次启动按当前 DB_PASSWORD 重写密码行（非仅首启），密码始终与该变量一致。
# 密码写入用 Redis 7 配置文件引号串（仅 " 与 \ 需转义），空格、单引号、#、中文等
# 原样生效；经 printf 追加而非 sed 替换串（& 与 \ 会被 sed 解释）。
# 运行中随时可手动拉起：supervisorctl start redis
# ==========================================
set -euo pipefail

SDK_NAME="redis"
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 入口模块库（镜像内）：supervisorctl_start 等待 supervisord 控制通道就绪后拉起程序段
[ -f /usr/local/share/entrypoint.d/lib.sh ] \
    || fatal "未找到 /usr/local/share/entrypoint.d/lib.sh（镜像入口模块库）"
source /usr/local/share/entrypoint.d/lib.sh

[ -x /usr/bin/redis-server ] || fatal "未找到 /usr/bin/redis-server（仅 Base 层镜像内置 Redis）"
REDIS_CONF=/etc/redis/redis.conf
[ -f "${REDIS_CONF}" ] || fatal "未找到 Redis 包配置 ${REDIS_CONF}"
[ -n "${DB_PASSWORD:-}" ] || fatal "DB_PASSWORD 未设置（统一数据库密码，Redis 用户 redis）"

# Redis 7 配置文件引号串：仅双引号与反斜杠需要转义
redis_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "${s}"
}

# 幂等：先清掉上次写入的密码行，再按当前 DB_PASSWORD 追加
sed -i -e '/^[[:space:]]*requirepass /d' -e '/^[[:space:]]*user /d' "${REDIS_CONF}"
REDIS_PW_ESC="$(redis_quote "${DB_PASSWORD}")"
printf 'requirepass %s\n' "${REDIS_PW_ESC}" >> "${REDIS_CONF}"
printf 'user redis on >%s ~* &* +@all\n' "${REDIS_PW_ESC}" >> "${REDIS_CONF}"
# pidfile 目录（包配置 pidfile /run/redis/redis-server.pid，镜像内无 tmpfiles.d）
mkdir -p /run/redis && chown redis:redis /run/redis

supervisorctl_start redis || fatal "Redis 拉起失败（详见容器日志）"

# 认证自检：密码经配置文件引号串往返后必须可认证。redis-cli 对 NOAUTH/WRONGPASS
# 应答的退出码为 0，判据只能是应答内容（PONG）。
[ "$(REDISCLI_AUTH="${DB_PASSWORD}" redis-cli -h 127.0.0.1 -p 6379 ping 2>/dev/null)" = PONG ] \
    || fatal "Redis 认证探活失败（DB_PASSWORD 写入配置后应答非 PONG，详见容器日志）"
[ "$(REDISCLI_AUTH="${DB_PASSWORD}" redis-cli --user redis -h 127.0.0.1 -p 6379 ping 2>/dev/null)" = PONG ] \
    || fatal "Redis ACL 用户 redis 认证探活失败"
log "Redis 就绪：TCP 0.0.0.0:6379（用户 redis / default + DB_PASSWORD）/ 容器内 REDISCLI_AUTH=\"\$DB_PASSWORD\" redis-cli"
