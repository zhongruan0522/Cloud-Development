#!/bin/bash
# Docker 健康检查：通过 supervisorctl 确认所有关键进程均处于 RUNNING 状态，
# 并逐个执行挂载式 SDK 目录内的 healthcheck.sh（若有）；任一判定不过即返回失败。
# SSH Server（sshd）不在 supervisord 管理下，单独检查进程是否存在。
# 宿主机显示转发启用时（DISPLAY 已设置）另以主账号连一次 X 服务器。
set -e

# 后台任务共享库：挂载式 SDK 的启用规则（sdk_is_enabled）与 init-sdks.sh 共用。
source /usr/local/share/entrypoint.d/lib.sh

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

# Magpie 同 dockerd 模式：默认 autostart=false 不参与健康判定；
# ENABLE_MAGPIE=1（承诺开机自启）时必须 RUNNING 且网关能应答（magpie healthcheck
# 为纯只读 HTTP 探测，不写配置目录）。
if [ "${ENABLE_MAGPIE:-0}" = "1" ]; then
    echo "$STATUS" | grep -qE '^magpie\s+RUNNING' || { echo "magpie not RUNNING"; exit 1; }
    /usr/local/bin/magpie healthcheck >/dev/null \
        || { echo "magpie gateway not accepting connections"; exit 1; }
fi

# 挂载式 SDK（entrypoint 第三波 init-sdks.sh 部署）：目录内提供 healthcheck.sh 的
# 组件（随仓库自带的数据库 pg / mysql / opengauss / kingbase / dm / redis）参与
# 健康判定——程序段须 RUNNING 且能接受连接（瞬时抖动由外层重试容忍）。SDK.sh 在
# 后台初始化并运行期拉起，容器刚启动的初始化窗口内 STOPPED 属预期，由外层健康
# 检查重试覆盖；初始化失败时 healthcheck 持续变红，是失败组件的唯一持续信号。
# 目录存在即启用，ENABLE_<目录名大写>=0 时停用（不下发、不参与健康判定）。
for sdk_hook in "${SDKS_ROOT:-/opt/sdks}"/*/healthcheck.sh; do
    [ -f "${sdk_hook}" ] || continue
    sdk_name="$(basename "$(dirname "${sdk_hook}")")"
    sdk_is_enabled "${sdk_name}" || continue
    bash "${sdk_hook}" || { echo "sdk '${sdk_name}' unhealthy"; exit 1; }
done

# 检查 sshd（SSH 现已无条件启动：公钥来自挂载文件，密码认证来自 SSH_PASSWORD）
pgrep -x sshd >/dev/null || { echo "sshd not running"; exit 1; }

# 宿主机显示转发（DISPLAY 由 compose 传入）须保持连通：宿主机 X 服务器
# 重启或访问控制被撤销后连不通即不健康，宿主机重新放行后自动恢复。
if [ -n "${DISPLAY:-}" ]; then
    X11_REASON="$(x11_probe opencode)" \
        || { echo "x11 display ${DISPLAY} not connected: ${X11_REASON}"; exit 1; }
fi

echo "All services healthy"
exit 0
