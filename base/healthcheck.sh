#!/bin/bash
# Docker 健康检查：通过 supervisorctl 确认所有关键进程均处于 RUNNING 状态。
# 任何一个进程非 RUNNING 则返回失败。
# SSH Server（sshd）和 xrdp 不在 supervisord 管理下，单独检查进程是否存在。
set -e

# supervisorctl status 遵循 LSB 语义：只要存在任一非 RUNNING 的程序就返回 3
# （supervisord 不可达时返回 4）。dockerd 设计上 autostart=false（见 base/supervisord.conf），
# 默认部署下恒为 STOPPED，导致退出码恒为 3——退出码无法区分"有意不自启的 dockerd"与
# "关键服务挂了"，因此不能作为健康判据。此处捕获输出并吞掉退出码（|| true）是安全的：
# 若 supervisord 本身挂掉，STATUS 为空或仅含连接错误信息，下方 grep 断言必然失败 exit 1，
# 不会误报健康（健康语义完全由显式断言决定，而非退出码）。
STATUS=$(supervisorctl -c /etc/supervisor/supervisord.conf status 2>&1) || true

# supervisord 不可达或全部进程都不是 RUNNING 时，输出不含任何 RUNNING 行：立即失败并暴露原因
echo "$STATUS" | grep -q 'RUNNING' || { echo "supervisord not reachable or no process RUNNING: $STATUS"; exit 1; }

# 检查 openchamber、serena 是否都处于 RUNNING 状态
# （opencode serve 由 openchamber 托管拉起，不在 supervisord 直接管辖内）
echo "$STATUS" | grep -qE '^openchamber\s+RUNNING' || { echo "openchamber not RUNNING"; exit 1; }
echo "$STATUS" | grep -qE '^serena\s+RUNNING' || { echo "serena not RUNNING"; exit 1; }

# dockerd 默认 autostart=false、按需手动拉起（节省内存），STOPPED 属预期行为，不参与健康判定；
# 但若显式设置 ENABLE_DOCKERD=1（承诺开机自启），dockerd 就必须 RUNNING，否则判不健康。
if [ "${ENABLE_DOCKERD:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^dockerd\s+RUNNING' || { echo "dockerd not RUNNING"; exit 1; }
fi

# PostgreSQL / MySQL 同 dockerd 模式：默认 autostart=false 不参与健康判定；
# ENABLE_*=1（承诺开机自启）时必须 RUNNING 且能接受连接（进程 RUNNING 不代表
# 已就绪接受连接；瞬时抖动由 Docker 外层重试容忍）。
if [ "${ENABLE_PG:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^postgresql\s+RUNNING' || { echo "postgresql not RUNNING"; exit 1; }
    /usr/lib/postgresql/17/bin/pg_isready -h 127.0.0.1 -p 5432 -q \
        || { echo "postgresql not accepting connections"; exit 1; }
fi
if [ "${ENABLE_MYSQL:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^mysql\s+RUNNING' || { echo "mysql not RUNNING"; exit 1; }
    mysqladmin --silent ping -u root 2>/dev/null \
        || { echo "mysql not accepting connections"; exit 1; }
fi

# 检查 sshd（SSH 现已无条件启动：公钥来自挂载文件，密码认证来自 SSH_PASSWORD）
pgrep -x sshd >/dev/null || { echo "sshd not running"; exit 1; }

# 检查 xrdp（默认启用，ENABLE_DESKTOP=0 时跳过；slim 变体无桌面组件，同样跳过）
if [ "${ENABLE_DESKTOP:-1}" = "1" ] && [ -x /usr/local/bin/init-desktop.sh ]; then
    pgrep -x xrdp >/dev/null || { echo "xrdp not running"; exit 1; }
fi

echo "All services healthy"
exit 0
