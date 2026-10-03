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

# 检查 sshd（仅在 authorized_keys 存在时）
if [ -f /home/app/.ssh/authorized_keys ] && [ -s /home/app/.ssh/authorized_keys ]; then
    pgrep -x sshd >/dev/null || { echo "sshd not running"; exit 1; }
fi

# 检查 xrdp（默认启用，ENABLE_DESKTOP=0 时跳过；slim 变体无桌面组件，同样跳过）
if [ "${ENABLE_DESKTOP:-1}" = "1" ] && [ -x /usr/local/bin/init-desktop.sh ]; then
    pgrep -x xrdp >/dev/null || { echo "xrdp not running"; exit 1; }
fi

echo "All services healthy"
exit 0
