# ==========================================
# Magpie 多 Agent 统一模型网关 + Web UI（默认关闭，ENABLE_MAGPIE=1 开启）
# 第三波组件：supervisord.conf autostart 恒为 false，ENABLE_MAGPIE=1 时后台
# 任务校验参数、确保数据与缓存目录就绪并经 supervisorctl 运行期拉起（非重资源
# 数据库，走 run_bg 不占数据库并发闸门）。
# 认证：Web UI 无独立用户名，由 MAGPIE_WEB_KEY 保护（须 >=16 位且仅含
# [A-Za-z0-9._~-]；留空则每次启动随机生成并输出带 key 的登录链接至容器日志）。
# 持久化：配置/密钥/路由/用量落 /root/.config/magpie，插件 Bun 与模型目录缓存
# 落 /root/.cache/magpie（与容器内 Agent 共享 HOME=/root，CLI 零配置对齐）。
# 运行中随时可手动拉起：supervisorctl start magpie
# ==========================================
init_and_start_magpie() {
    if [ ! -x /usr/local/bin/magpie ]; then
        log_fatal "未找到 /usr/local/bin/magpie（仅动态层镜像内置 Magpie）"
        return 1
    fi

    if [ -n "${MAGPIE_WEB_KEY:-}" ]; then
        if [ "${#MAGPIE_WEB_KEY}" -lt 16 ]; then
            log_fatal "MAGPIE_WEB_KEY 长度不足 16 位（当前 ${#MAGPIE_WEB_KEY} 位），可用 openssl rand -hex 16 生成"
            return 1
        fi
        case "${MAGPIE_WEB_KEY}" in
            *[!A-Za-z0-9._~-]*)
                log_fatal "MAGPIE_WEB_KEY 仅允许字母、数字及 - . _ ~（可用 openssl rand -hex 16 生成）"
                return 1
                ;;
        esac
    fi

    mkdir -p /root/.config/magpie /root/.cache/magpie
    if [ "${RUN_USER}" != "root" ]; then
        local run_group
        run_group="$(id -gn "${RUN_USER}")"
        if ! mountpoint -q /root/.config/magpie; then
            chown -R "${RUN_USER}:${run_group}" /root/.config/magpie
        fi
        if ! mountpoint -q /root/.cache/magpie; then
            chown -R "${RUN_USER}:${run_group}" /root/.cache/magpie
        fi
    fi

    supervisorctl_start magpie || { log_fatal "Magpie 拉起失败（详见容器日志）"; return 1; }
    if [ -n "${MAGPIE_WEB_KEY:-}" ]; then
        echo "==> Magpie 就绪：Web UI ${MAGPIE_WEB_ADDR}（固定 MAGPIE_WEB_KEY）/ 网关 ${MAGPIE_ADDR}"
    else
        echo "==> Magpie 就绪：Web UI ${MAGPIE_WEB_ADDR}（本次随机密钥见容器日志）/ 网关 ${MAGPIE_ADDR}"
    fi
}
if [ "${ENABLE_MAGPIE:-0}" = "1" ]; then
    run_bg 第三波 "Magpie" magpie-init init_and_start_magpie
fi
