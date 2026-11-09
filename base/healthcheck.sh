#!/bin/bash
# Docker 健康检查：通过 supervisorctl 确认所有关键进程均处于 RUNNING 状态。
# 任何一个进程非 RUNNING 则返回失败。
# SSH Server（sshd）和 xrdp 不在 supervisord 管理下，单独检查进程是否存在。
set -e

# supervisorctl status 遵循 LSB 语义：存在任一非 RUNNING 程序即返回 3（supervisord
# 不可达时返回 4）；dockerd autostart=false（见 base/supervisord.conf），默认部署下
# 恒为 STOPPED，退出码无法区分有意不自启与关键服务故障。健康语义完全由下方显式断言
# 决定：捕获输出并吞掉退出码，supervisord 本身挂掉时 STATUS 为空或仅含连接错误，
# grep 断言必然失败。
STATUS=$(supervisorctl -c /etc/supervisor/supervisord.conf status 2>&1) || true

# supervisord 不可达或全部进程都不是 RUNNING 时，输出不含任何 RUNNING 行：立即失败并暴露原因
echo "$STATUS" | grep -q 'RUNNING' || { echo "supervisord not reachable or no process RUNNING: $STATUS"; exit 1; }

# 检查 openchamber 是否处于 RUNNING 状态
# （opencode serve 由 openchamber 托管拉起，不在 supervisord 直接管辖内）
echo "$STATUS" | grep -qE '^openchamber\s+RUNNING' || { echo "openchamber not RUNNING"; exit 1; }

# dockerd 默认 autostart=false、按需手动拉起（节省内存），STOPPED 属预期行为，不参与健康判定；
# 但若显式设置 ENABLE_DOCKERD=1（承诺开机自启），dockerd 就必须 RUNNING，否则判不健康。
if [ "${ENABLE_DOCKERD:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^dockerd\s+RUNNING' || { echo "dockerd not RUNNING"; exit 1; }
fi

# PostgreSQL / MySQL 同 dockerd 模式：默认 autostart=false 不参与健康判定；
# ENABLE_*=1（承诺开机自启）时必须 RUNNING 且能接受连接（瞬时抖动由外层重试容忍）。
# 五库/DockerD 由 entrypoint 第三波后台任务初始化并运行期拉起，容器刚启动的
# 初始化窗口内 STOPPED 属预期，由外层健康检查重试覆盖。
# 初始化失败时 healthcheck 持续变红，是失败组件的唯一持续信号。
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
    # ksql 二进制 rpath 自足（无需 LD_LIBRARY_PATH），-d test 为金仓默认库
    su -s /bin/bash kingbase -c '/opt/Kingbase/ES/Server/bin/ksql -p 54321 -U system -d test -Atc "SELECT 1;"' >/dev/null \
        || { echo "kingbase not accepting connections"; exit 1; }
fi
if [ "${ENABLE_DM:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^dm\s+RUNNING' || { echo "dm not RUNNING"; exit 1; }
    # 达梦无 local socket 免密通道（TCP 一律密码认证），探活走 SYSDBA + 统一
    # DB_PASSWORD；连接串中密码须整体双引号括起（disql 语义，密码含 @ 等
    # 字符必需，正确返回 0 / 错误返回 2）；-p 5236 与 supervisord 启动端口一致
    # （官方默认端口，避让 PG 5432 / openGauss 5433 / KingbaseES 54321）
    DM_HC_PWD="${DB_PASSWORD:-Opencode@123}"
    runuser -u dmdba -- /opt/dmdbms/bin/disql "SYSDBA/\"${DM_HC_PWD}\"@127.0.0.1:5236" -e "SELECT 1;" >/dev/null \
        || { echo "dm not accepting connections"; exit 1; }
fi

# 检查 sshd（SSH 现已无条件启动：公钥来自挂载文件，密码认证来自 SSH_PASSWORD）
pgrep -x sshd >/dev/null || { echo "sshd not running"; exit 1; }

# 检查 xrdp（默认启用，ENABLE_DESKTOP=0 时跳过；slim 变体无桌面组件，同样跳过）
if [ "${ENABLE_DESKTOP:-1}" = "1" ] && [ -x /usr/local/bin/init-desktop.sh ]; then
    pgrep -x xrdp >/dev/null || { echo "xrdp not running"; exit 1; }
    pgrep -x xrdp-sesman >/dev/null || { echo "xrdp-sesman not running"; exit 1; }
fi

echo "All services healthy"
exit 0
