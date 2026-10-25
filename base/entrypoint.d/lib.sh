# ==========================================
# 后台任务基础设施
# ==========================================
# 后台任务失败出口：FATAL 阶段行经任务日志管道透传容器 stdout（醒目暴露），
# 不再终止容器——杀容器会让已就绪的 SSH/主服务陪葬，且 restart 重试对
# 初始化类失败（如密码复杂度不足）毫无帮助；失败组件保持未运行，
# healthcheck 诚实变红，由编排侧/用户决策（重试幂等，见 .initializing 标记）。
log_fatal() {
    echo "==> [FATAL] ${1}"
}

# 等待 supervisord 控制通道就绪后拉起服务（exec 后 socket 需片刻出现）。
# supervisorctl start 返回 0 表示进程已通过 startsecs 存活判定。
supervisorctl_start() {
    local prog="$1" i err=""
    for i in $(seq 1 60); do
        if err="$(supervisorctl -c /etc/supervisor/supervisord.conf start "${prog}" 2>&1)"; then
            echo "==> [${prog}] 已由后台初始化任务拉起"
            return 0
        fi
        sleep 1
    done
    echo "==> [${prog}] supervisorctl start 失败：${err}" >&2
    return 1
}

# 后台任务统一入口：日志分层 + 结束摘要一行。
# - 输出分层：任务 stdout/stderr 全量落 /var/log/init/<tag>.log（每次启动
#   截断重写），仅 ==> 开头的阶段行透传容器 stdout（带 [tag] 前缀）——
#   docker logs 只见关键节点，initdb/mysqld 的过程细节不再三库交错刷屏
#   （并行化初版 PG 中文与 openGauss 英文输出逐段穿插、进度行被劈断，
#   排障时极易误判初始化错乱）。
# - 结束摘要：任务收尾必打一行最终状态；失败时附带任务日志尾部，
#   docker logs 即见失败原因无需翻文件。
# - 进程收尾：内层子 shell 退出后 awk 读到 EOF 随之退出，均被
#   supervisord 收养收割（"reaped unknown pid" 噪音同源，不新增类型）。
# 用法：run_bg <tag> <func> [args...]；任务函数成功 return 0 / 失败 return 1。
run_bg() {
    local tag="$1"
    shift
    (
        LOG="/var/log/init/${tag}.log"
        mkdir -p /var/log/init
        : > "${LOG}"
        T0=$(date +%s)
        RC=0
        (
            # awk 变量名用 logfile：log 是 awk 内置函数名，-v log= 会被 mawk 拒绝
            exec > >(awk -v tag="${tag}" -v logfile="${LOG}" \
                '{ print >> logfile; if ($0 ~ /^==> /) printf "[%s] %s\n", tag, $0; fflush() }') 2>&1
            "$@"
        ) || RC=$?
        T1=$(date +%s)
        if [ "${RC}" = "0" ]; then
            echo "[${tag}] ✓ 完成（$((T1 - T0))s），完整日志 ${LOG}"
        else
            echo "[${tag}] ✗ 失败（$((T1 - T0))s），最近输出（完整日志 ${LOG}）："
            tail -n 15 "${LOG}" 2>/dev/null | sed 's/^/    /' || true
        fi
    ) &
}

# 第三波单批并行闸门：数据库初始化+拉起是重资源动作（openGauss 共享内存
# ~3.5G、DM8 首启初始化数据 ~0.8G、MySQL ~500M……），库数增多后无上限并行
# 会把内存/IO 打爆——单批最多 DB_GATE_MAX 个数据库并行，超出的在各自后台
# 任务内排队，槽位释放后串行补位。"计数+占位"全程持 flock 锁原子完成，
# 多任务同时抢槽不超发；槽位以 tag 命名的空文件计数，闸门目录在第三波
# 发起前重建（docker restart 后残留的槽位文件不跨启动计数，防泄漏死锁）。
# 仅数据库任务入闸：dockerd 无初始化步骤、非重资源组件，保持原 run_bg。
DB_GATE_MAX=3
DB_GATE_DIR=/run/db-init-gate
# 尝试为 tag 占一个槽位：占位成功返回 0，已满返回 1（不阻塞）。
db_gate_try() {
    local tag="$1" fd rc=1
    exec {fd}>"${DB_GATE_DIR}.lock" || return 1
    flock "${fd}" || { exec {fd}>&-; return 1; }
    if [ "$(ls -1 "${DB_GATE_DIR}" 2>/dev/null | wc -l)" -lt "${DB_GATE_MAX}" ]; then
        : > "${DB_GATE_DIR}/${tag}"
        rc=0
    fi
    flock -u "${fd}"
    exec {fd}>&-
    return "${rc}"
}
db_gate_release() {
    rm -f "${DB_GATE_DIR}/${1}"
}
# 数据库任务统一包裹器（经 run_db 发起）：占槽→执行→无论成败释放。
# 排队等待发生时打一行 ==> 阶段行透传 docker logs（只打一次，不刷屏）。
db_gated_run() {
    local tag="$1" rc=0 waited=0
    shift
    while ! db_gate_try "${tag}"; do
        if [ "${waited}" = "0" ]; then
            echo "==> [并行限流] 数据库单批并行已达上限 ${DB_GATE_MAX}，排队等待槽位..."
            waited=1
        fi
        sleep 2
    done
    "$@" || rc=$?
    db_gate_release "${tag}"
    return "${rc}"
}
# 用法同 run_bg：run_db <tag> <func> [args...]——run_bg 的限流变体，
# 供第三波数据库任务使用。
run_db() {
    local tag="$1"
    shift
    run_bg "${tag}" db_gated_run "${tag}" "$@"
}
