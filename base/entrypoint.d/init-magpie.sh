# ==========================================
# Magpie 多 Agent 统一模型网关 + Web UI（默认关闭，ENABLE_MAGPIE=1 开启）
# 第三波组件：supervisord.conf autostart 恒为 false，ENABLE_MAGPIE=1 时后台
# 任务校验参数、确保数据与缓存目录就绪并经 supervisorctl 运行期拉起（非重资源
# 数据库，走 run_bg 不占数据库并发闸门）。
# 认证：Web UI 无独立用户名，由 MAGPIE_WEB_KEY 保护（须 >=16 位且仅含
# [A-Za-z0-9._~-]；留空则由 entrypoint.sh 每次启动随机生成，登录链接以状态行进容器日志）。
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

    supervisorctl_start magpie || { log_fatal "Magpie 拉起失败"; return 1; }
    # Web 登录链接状态行：链接取 Magpie 本次启动打印的横幅——程序日志里最后一个启动
    # 分隔行之后带登录链接的行（"magpie web on <链接>" 与各 "on the network <链接>"）。
    # 链接的规则（对外地址 MAGPIE_PUBLIC_URL、TLS、本机各地址的枚举）以 Magpie 为准，
    # 这里不另拼。链接含登录密钥，只写容器 stdout（log_link），不落任务日志；密钥未
    # 设置时每次启动随机生成，这几行是容器日志里取得登录链接的地方。
    local log="${PROGRAM_LOG_DIR}/magpie.log" start line
    local -a links=()
    for _ in $(seq 1 30); do
        start="$(grep -n '^===== [0-9-]\{10\} [0-9:]\{8\} 启动 magpie =====$' "${log}" | tail -n 1 | cut -d: -f1)"
        if [ -z "${start}" ]; then
            log_fatal "程序日志 ${log} 里没有本次启动的分隔行"
            return 1
        fi
        links=()
        while IFS= read -r line; do
            case "${line}" in
                *'/?k='*)
                    [[ "${line}" =~ (https?://[^[:space:]]+) ]] && links+=("${BASH_REMATCH[1]}")
                    ;;
            esac
        done < <(tail -n +"$((start + 1))" "${log}" | head -n 60)
        [ "${#links[@]}" -gt 0 ] && break
        sleep 0.5
    done
    if [ "${#links[@]}" -eq 0 ]; then
        log_fatal "Magpie 启动后 15 秒内未在程序日志里打印登录链接（横幅格式可能已变，见 ${log}）"
        return 1
    fi
    for line in "${links[@]}"; do
        log_link "[第三波][Magpie] - Web UI ${line}"
    done
    echo "==> Magpie 就绪：Web UI ${MAGPIE_WEB_ADDR}（登录链接见容器日志状态行）/ 网关 ${MAGPIE_ADDR}"
}
if [ "${ENABLE_MAGPIE:-0}" = "1" ]; then
    run_bg 第三波 "Magpie" magpie-init init_and_start_magpie
fi
