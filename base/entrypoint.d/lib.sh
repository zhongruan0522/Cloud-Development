# ==========================================
# 后台任务基础设施（四波统一契约）
# ==========================================
# 失败出口：任务失败以一行状态行暴露（[阶段][服务] - [状态：失败] - 日志路径），
# 不终止容器——杀容器会让已就绪的 SSH/主服务陪葬，且 restart 重试对
# 初始化类失败（如密码复杂度不足）毫无帮助；失败组件保持未运行，
# healthcheck 诚实变红，由编排侧/用户决策（重试幂等，见 .initializing 标记）。

# 任务日志目录与阶段计数目录（entrypoint 主流程每次启动重建 STAGE_ROOT）
LOG_DIR=/var/log/init
STAGE_ROOT=/run/init-stage

# 任务内致命错误出口：只写任务日志（stderr 全量落盘），容器 stdout 不再有
# 任务过程行——失败原因由 run_bg 的"失败"状态行附日志路径指路。
log_fatal() {
    echo "[FATAL] ${1}" >&2
}

# 等待 supervisord 控制通道就绪后拉起服务（exec 后 socket 需片刻出现）。
# supervisorctl start 返回 0 表示进程已通过 startsecs 存活判定。
# 输出全量落任务日志：成功与否由 run_bg 状态行统一呈现。
supervisorctl_start() {
    local prog="$1" i err=""
    for i in $(seq 1 60); do
        if err="$(supervisorctl -c /etc/supervisor/supervisord.conf start "${prog}" 2>&1)"; then
            echo "[${prog}] 已由后台初始化任务拉起"
            return 0
        fi
        sleep 1
    done
    echo "[${prog}] supervisorctl start 失败：${err}" >&2
    return 1
}

# ==========================================
# 阶段记账：每波任务的成败计数与阶段汇总行
# ==========================================
# 计数目录 <STAGE_ROOT>/<阶段>/：pending（在途任务数）、success / fail（完成
# 计数）、dispatched（主进程"本波已全部下发"标记）、lock（flock 文件）。
# 汇总行（"[阶段] - [状态：成功数/失败数]"）由"本波最后一个完成者"在锁内
# 打印——主进程在第二波末尾即 exec supervisord 消失，无法由主进程收口；每波
# 在全部下发完后由主进程写 dispatched 标记（stage_dispatch_done），完成者归零
# 后见标记才打，保证每波恰好一行汇总。/run 在 docker restart（同容器
# stop+start）间不清零，计数目录由主流程在下发前 rm -rf 重建，残留不跨启动。
stage_register() {
    local stage="$1" fd n
    # dir 须独立声明：同一 local 语句内引用刚声明的变量（stage）时展开发生在
    # local 执行前、取到空值（bash 参数展开先于内建执行），不能合并一行。
    local dir="${STAGE_ROOT}/${stage}"
    mkdir -p "${dir}"
    exec {fd}>"${dir}/lock"
    flock "${fd}"
    n="$(cat "${dir}/pending" 2>/dev/null || echo 0)"
    echo $((n + 1)) > "${dir}/pending"
    flock -u "${fd}"
    exec {fd}>&-
}

stage_settle() {
    local stage="$1" result="$2" fd s f n
    local dir="${STAGE_ROOT}/${stage}"
    exec {fd}>"${dir}/lock"
    flock "${fd}"
    s="$(cat "${dir}/success" 2>/dev/null || echo 0)"
    f="$(cat "${dir}/fail" 2>/dev/null || echo 0)"
    n="$(cat "${dir}/pending" 2>/dev/null || echo 0)"
    if [ "${result}" = "ok" ]; then
        echo $((s + 1)) > "${dir}/success"
    else
        echo $((f + 1)) > "${dir}/fail"
    fi
    echo $((n - 1)) > "${dir}/pending"
    if [ -f "${dir}/dispatched" ] && [ "$((n - 1))" = "0" ]; then
        if [ "${result}" = "ok" ]; then
            echo "[${stage}] - [状态：$((s + 1))/${f}]"
        else
            echo "[${stage}] - [状态：${s}/$((f + 1))]"
        fi
    fi
    flock -u "${fd}"
    exec {fd}>&-
}

# 主流程在某波全部下发后调用：写 dispatched 标记；无任务的波次没有完成者，
# 由本调用在锁内兜底打 0/0（有任务时 pending>0 不打，留给最后完成者）。
stage_dispatch_done() {
    local stage="$1" fd
    local dir="${STAGE_ROOT}/${stage}"
    mkdir -p "${dir}"
    exec {fd}>"${dir}/lock"
    flock "${fd}"
    touch "${dir}/dispatched"
    if [ "$(cat "${dir}/pending" 2>/dev/null || echo 0)" = "0" ]; then
        echo "[${stage}] - [状态：$(cat "${dir}/success" 2>/dev/null || echo 0)/$(cat "${dir}/fail" 2>/dev/null || echo 0)]"
    fi
    flock -u "${fd}"
    exec {fd}>&-
}

# 任务内状态行出口（唯一允许写容器 stdout 的任务内通道）：log_status 双写——
# 当前 stdout（任务内即日志文件）+ fd 3（run_bg 开的容器 stdout 通道）。
# 仅限并发限流这类"容器日志必要节点"，任务过程细节禁用（stdout 保持纯状态行）；
# 在 run_bg 上下文之外调用时 fd 3 未开，穿透行静默省略（不报错）。
log_status() {
    echo "${1}"
    { echo "${1}" >&3; } 2>/dev/null || true
}

# 后台任务统一入口：状态行 + 全量落盘 + 阶段记账。
# - 状态行（容器 stdout 对任务仅此三行）：下发时"部署中"、结束时"成功/失败"，
#   各附任务日志路径——docker logs 不再出现任何任务过程行。
# - 日志分层：任务 stdout/stderr 全量落 ${LOG_DIR}/<tag>.log（每次启动截断
#   重写），任务内部的 ==> 阶段行只存在于日志文件中（旧版 awk 透传机制移除：
#   五库并行时 initdb/gs_initdb 过程行交错刷屏、进度行被劈断，排障极易误判）。
#   成功后改名 "<阶段>-<tag>.log" 归档，失败保持 <tag>.log 原名——日志目录里
#   无阶段前缀的文件即失败任务，一眼定位。
# - 阶段记账：注册/收口见上方 stage_* 注释；失败不再向 stdout 附 tail 摘要
#   （失败原因查任务日志，状态行已指路）。
# - 进程收尾：后台子 shell 退出后被 supervisord 收养收割（"reaped unknown
#   pid" 噪音同源，不新增类型）。
# 用法：run_bg <阶段> <服务名> <tag> <func> [args...]；任务函数成功 return 0 / 失败 return 1。
run_bg() {
    local stage="$1" svc="$2" tag="$3"
    shift 3
    local log="${LOG_DIR}/${tag}.log"
    stage_register "${stage}"
    echo "[${stage}][${svc}] - [状态：部署中] - [日志位于${log}]"
    (
        mkdir -p "${LOG_DIR}"
        : > "${log}"
        RC=0
        # fd 3 = 容器 stdout 通道（见 log_status），任务函数继承；任务结束即关。
        exec 3>&1
        "$@" >> "${log}" 2>&1 || RC=$?
        exec 3>&-
        if [ "${RC}" = "0" ]; then
            mv -f "${log}" "${LOG_DIR}/${stage}-${tag}.log"
            echo "[${stage}][${svc}] - [状态：成功] - [日志位于${LOG_DIR}/${stage}-${tag}.log]"
            stage_settle "${stage}" ok
        else
            echo "[${stage}][${svc}] - [状态：失败] - [日志位于${log}]"
            stage_settle "${stage}" fail
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
# 排队等待发生时打一行限流行到容器 stdout + 任务日志（log_status 双写，
# 每任务只打一次，不刷屏）。
db_gated_run() {
    local stage="$1" tag="$2" rc=0 waited=0
    shift 2
    while ! db_gate_try "${tag}"; do
        if [ "${waited}" = "0" ]; then
            log_status "[${stage}] - 当前并发已大于${DB_GATE_MAX}，不再下发"
            waited=1
        fi
        sleep 2
    done
    "$@" || rc=$?
    db_gate_release "${tag}"
    return "${rc}"
}
# 用法：run_db <阶段> <服务名> <tag> <func> [args...]——run_bg 的限流变体，
# 供第三波数据库任务使用（限流行带波次前缀）。
run_db() {
    local stage="$1" svc="$2" tag="$3"
    shift 3
    run_bg "${stage}" "${svc}" "${tag}" db_gated_run "${stage}" "${tag}" "$@"
}
