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
# 注意：三库/DockerD 由 entrypoint 第三波后台任务初始化并运行期拉起（supervisord
# 恒 autostart=false），容器刚启动的初始化窗口内 STOPPED 属预期——健康检查语义
# 保持诚实（此刻确实不可用），由外层健康检查重试机制覆盖该窗口。
# 初始化失败时 entrypoint 不再终止容器（log_fatal 暴露 + 本脚本持续变红），
# healthcheck 是失败组件的唯一持续信号，请勿弱化。
if [ "${ENABLE_PG:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^postgresql\s+RUNNING' || { echo "postgresql not RUNNING"; exit 1; }
    # pg_isready 无需认证，仅探测 postmaster 应答
    /usr/lib/postgresql/17/bin/pg_isready -h 127.0.0.1 -p 5432 -q \
        || { echo "postgresql not accepting connections"; exit 1; }
fi
if [ "${ENABLE_MYSQL:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^mysql\s+RUNNING' || { echo "mysql not RUNNING"; exit 1; }
    # 官方文档（dev.mysql.com/doc/refman/8.4/en/mysqladmin.html）：mysqladmin ping
    # 只要服务器在运行即返回 0——即使 Access denied 也算存活，故无需带密码
    mysqladmin --silent ping -u root 2>/dev/null \
        || { echo "mysql not accepting connections"; exit 1; }
fi
if [ "${ENABLE_OPENGAUSS:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^opengauss\s+RUNNING' || { echo "opengauss not RUNNING"; exit 1; }
    # openGauss 强制 TCP 一律密码认证（trust 不豁免），探活走 omm + local socket 免密；
    # -p 5433 与 supervisord 启动端口一致（避让 PostgreSQL 17 的 5432）；
    # gaussdb 依赖 LAPACKE 符号，gsql 仅需包内 lib（LD_LIBRARY_PATH，见 Dockerfile.base）
    su -s /bin/bash omm -c 'LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql /opt/opengauss/bin/gsql -p 5433 -d postgres -Atc "SELECT 1;"' >/dev/null \
        || { echo "opengauss not accepting connections"; exit 1; }
fi
if [ "${ENABLE_KINGBASE:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^kingbase\s+RUNNING' || { echo "kingbase not RUNNING"; exit 1; }
    # 探活走 system + local socket 免密（entrypoint initdb --auth-local=trust）；
    # -p 54321 与 supervisord 启动端口一致（官方默认端口，避让 PG 5432 / openGauss 5433）；
    # ksql 二进制 rpath 自足（对比 openGauss 无需 LD_LIBRARY_PATH），-d test 为金仓默认库
    su -s /bin/bash kingbase -c '/opt/Kingbase/ES/Server/bin/ksql -p 54321 -U system -d test -Atc "SELECT 1;"' >/dev/null \
        || { echo "kingbase not accepting connections"; exit 1; }
fi

# 检查 sshd（SSH 现已无条件启动：公钥来自挂载文件，密码认证来自 SSH_PASSWORD）
pgrep -x sshd >/dev/null || { echo "sshd not running"; exit 1; }

# 检查 xrdp（默认启用，ENABLE_DESKTOP=0 时跳过；slim 变体无桌面组件，同样跳过）
if [ "${ENABLE_DESKTOP:-1}" = "1" ] && [ -x /usr/local/bin/init-desktop.sh ]; then
    pgrep -x xrdp >/dev/null || { echo "xrdp not running"; exit 1; }
fi

echo "All services healthy"
exit 0
