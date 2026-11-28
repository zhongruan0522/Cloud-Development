# ==========================================
# 后台任务基础设施（三波统一契约）
# ==========================================
# 失败出口：任务失败以一行状态行暴露（[阶段][服务] - [状态：失败] - 日志路径），
# 不终止容器——杀容器会让已就绪的 SSH/主服务陪葬，且 restart 重试对
# 初始化类失败（如密码复杂度不足）毫无帮助；失败组件保持未运行，
# healthcheck 诚实变红，由编排侧/用户决策（重试幂等，见 .initializing 标记）。

# 任务日志目录与阶段计数目录（entrypoint 主流程每次启动重建 STAGE_ROOT）
LOG_DIR=/var/log/init
STAGE_ROOT=/run/init-stage

# 托管程序的日志目录：base/supervisord.conf 各 [program:x] 段把 stdout/stderr 合并落
# <PROGRAM_LOG_DIR>/<程序段名>.log（按大小轮转），容器 stdout 不出现程序输出；
# 二者是同一约定，改动须同步。
PROGRAM_LOG_DIR=/var/log/supervisor
# supervisord 自身日志（程序段的状态迁移、拉起被拒的原因），与 base/supervisord.conf
# 的 logfile 是同一约定，改动须同步。
SUPERVISORD_LOG=/tmp/supervisord.log

# 任务内致命错误出口：只写任务日志（stderr 全量落盘），容器 stdout 不输出
# 任务过程行——失败原因由任务的"失败"状态行附日志路径指路。
log_fatal() {
    echo "[FATAL] ${1}" >&2
}

# 程序段状态：supervisorctl status 的状态列（RUNNING / STARTING / BACKOFF / FATAL /
# EXITED / STOPPED / UNKNOWN）。控制通道不可达或配置中无此程序段时输出为空；始终返回 0
# （调用方多为 set -e 环境）。
supervisorctl_state() {
    local name state
    read -r name state <<<"$(supervisorctl -c /etc/supervisor/supervisord.conf status "$1" 2>&1)" || true
    if [ "${name}" = "$1" ]; then
        printf '%s\n' "${state%%[[:space:]]*}"
    fi
    return 0
}

# 程序日志的启动分隔行：程序输出多不带时间戳，程序日志又跨启动追加，每次拉起前在
# 程序日志末尾写一行带时间戳的分隔行，界定本次启动的批次；批内的时刻对照 supervisord
# 自身日志（SUPERVISORD_LOG）里 spawned / exited 的时间戳。supervisord 以追加模式打开
# 程序日志，外部追加不影响它的轮转判定。经 supervisorctl_start 拉起的程序段由该函数
# 写入；autostart 的 openchamber 由入口主流程在 exec supervisord 前写入。
log_program_start() {
    echo "===== $(date '+%F %T') 启动 ${1} =====" >> "${PROGRAM_LOG_DIR:?}/${1:?}.log"
}

# 等待 supervisord 控制通道就绪后拉起服务，成功判据是程序段进入 RUNNING。
# supervisorctl start 的返回码不能作判据：进程启动即退时 supervisord 自行重试
# （startretries），重试间隙里再 start 以 "already started" 返回 0。故每轮读程序段
# 状态再定动作：未在运行则下发一次拉起；STARTING / BACKOFF 是 supervisord 仍在
# startsecs 窗口内或自行重试，等它的结果；RUNNING 即成功；下发之后进入 FATAL /
# EXITED / STOPPED 即失败并带出状态行。控制通道未就绪（supervisorctl status 返回 4，
# exec 后 socket 需片刻出现）时每秒再看，最多 60 轮。
# 输出全量落任务日志：成功与否由任务状态行统一呈现。成功行与失败行都附下一步要看的
# 文件——程序运行期日志（PROGRAM_LOG_DIR）或 supervisord 自身日志（SUPERVISORD_LOG，
# 程序段状态迁移与拉起被拒的原因记在那里），任务日志由此指到原因所在。
# 下发拉起前先向程序日志写启动分隔行（log_program_start）。
# 数据库 SDK 的 SDK.sh 是独立进程，运行期 source 本文件复用本函数；autostart 的
# openchamber 同样经本函数等到 RUNNING（主流程第二波任务）。
supervisorctl_start() {
    local prog="$1" i issued=0 state out rc
    for i in $(seq 1 60); do
        rc=0
        supervisorctl -c /etc/supervisor/supervisord.conf status >/dev/null 2>&1 || rc=$?
        if [ "${rc}" = 4 ]; then
            state="控制通道未就绪"
            sleep 1
            continue
        fi
        state="$(supervisorctl_state "${prog}")"
        case "${state}" in
            RUNNING)
                echo "[${prog}] 程序段已在运行（程序日志 ${PROGRAM_LOG_DIR}/${prog}.log）"
                return 0
                ;;
            STARTING|BACKOFF)
                ;;
            "")
                echo "[${prog}] supervisorctl 报错：$(supervisorctl -c /etc/supervisor/supervisord.conf status "${prog}" 2>&1)（程序段状态迁移见 ${SUPERVISORD_LOG}）" >&2
                return 1
                ;;
            *)
                if [ "${issued}" = 1 ]; then
                    echo "[${prog}] 拉起后进程未在运行：$(supervisorctl -c /etc/supervisor/supervisord.conf status "${prog}" 2>&1)（启动即退的原因见程序日志 ${PROGRAM_LOG_DIR}/${prog}.log）" >&2
                    return 1
                fi
                issued=1
                log_program_start "${prog}"
                rc=0
                out="$(supervisorctl -c /etc/supervisor/supervisord.conf start "${prog}" 2>&1)" || rc=$?
                # 拉起被拒（命令文件不存在、不可执行等）时程序段仍为 STOPPED
                if [ "${rc}" != 0 ] && [ "$(supervisorctl_state "${prog}")" = STOPPED ]; then
                    echo "[${prog}] supervisorctl start 失败：${out}（拉起被拒的原因见 ${SUPERVISORD_LOG}）" >&2
                    return 1
                fi
                ;;
        esac
        sleep 1
    done
    echo "[${prog}] 拉起失败：60 轮内未进入 RUNNING（${state}；程序日志 ${PROGRAM_LOG_DIR}/${prog}.log，程序段状态迁移见 ${SUPERVISORD_LOG}）" >&2
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
    # dir 单独声明：bash 参数展开先于 local 内建执行，同一 local 语句内引用
    # 刚声明的变量会取到空值。
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
# 仅限并发限流、访问入口地址这类"容器日志必要节点"，任务过程细节禁用（stdout 保持纯状态行）；
# 在 run_bg 上下文之外调用时 fd 3 未开，穿透行静默省略（不报错）。
log_status() {
    echo "${1}"
    { echo "${1}" >&3; } 2>/dev/null || true
}

# 任务内入口链接出口：只写容器 stdout（fd 3），不落任务日志——供含登录密钥的链接行
# 使用，密钥不在任务日志里多留一份；其余任务内状态行仍用 log_status。
# 在 run_bg 上下文之外调用时 fd 3 未开，静默省略（不报错）。
log_link() {
    { echo "${1}" >&3; } 2>/dev/null || true
}

# 后台任务统一入口：状态行 + 全量落盘 + 阶段记账。
# - 状态行（容器 stdout 对任务仅这几行）：下发时"部署中"（限流变体 run_sdk 为
#   "排队"，获得并发槽位时再打"部署中"），结束时"成功/失败"，均附任务日志
#   路径——docker logs 不出现任务过程行。
# - 日志分层：任务 stdout/stderr 全量落 ${LOG_DIR}/<tag>.log（每次启动截断重写），
#   任务内部的 ==> 阶段行只存在于日志文件中；成功后改名 "<阶段>-<tag>.log" 归档，
#   失败保持 <tag>.log 原名——日志目录里无阶段前缀的文件即失败任务。
# - 阶段记账：注册/收口见上方 stage_* 注释；失败原因查任务日志（状态行已指路）。
# - 进程收尾：后台子 shell 退出后由 supervisord 收养收割。
# 用法：run_bg <阶段> <服务名> <tag> <func> [args...]；任务函数成功 return 0 / 失败 return 1。
run_bg() {
    local stage="$1" svc="$2" tag="$3"
    shift 3
    _run_task "${stage}" "${svc}" "${tag}" "部署中" "$@"
}

# 用法：run_sdk <阶段> <服务名> <tag> <func> [args...]——run_bg 的限流变体，供
# SDK 任务使用：下发即计入阶段并在闸门外排队（状态行"排队"），获得并发槽位后
# 才开始执行（状态行"部署中"）。
run_sdk() {
    local stage="$1" svc="$2" tag="$3"
    shift 3
    _run_task "${stage}" "${svc}" "${tag}" "排队" sdk_gated_run "${stage}" "${svc}" "${tag}" "$@"
}

# 任务下发实现（run_bg / run_sdk 共用）：登记阶段计数，打首发状态行，fork 后台
# 子 shell 执行任务并按退出码收口。日志文件在子 shell 起步即建立（排队期间已
# 存在、内容为空），首发状态行即可附其路径。
_run_task() {
    local stage="$1" svc="$2" tag="$3" state="$4"
    shift 4
    local log="${LOG_DIR}/${tag}.log"
    stage_register "${stage}"
    echo "[${stage}][${svc}] - [状态：${state}] - [日志位于${log}]"
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

# ==========================================
# SDK 部署并发闸门
# ==========================================
# SDK 任务（工具链下载解压、数据库首启初始化）都是重资源动作（openGauss 共享
# 内存 ~3.5G、DM8 首启初始化数据 ~0.8G、MySQL ~500M、Android/Flutter 下载解压数
# GB……），同时在途最多 SDK_GATE_MAX 个，完成一个补位一个：排队的任务在各自后台
# 任务内轮询，槽位释放后即接管，始终保持上限个在途直到全部下发完。"计数+占位"
# 全程持 flock 锁原子完成，多任务同时抢槽不超发；槽位以 tag 命名的空文件计数，
# 闸门目录在第三波发起前重建（docker restart 后残留的槽位文件不跨启动计数）。
# 仅 SDK 任务入闸（经 run_sdk 发起）；DockerD / Magpie 无初始化步骤、非重资源
# 组件，走 run_bg。
SDK_GATE_MAX=3
SDK_GATE_DIR=/run/sdk-deploy-gate
# 尝试为 tag 占一个槽位：占位成功返回 0，已满返回 1（不阻塞）。
sdk_gate_try() {
    local tag="$1" fd rc=1
    exec {fd}>"${SDK_GATE_DIR}.lock" || return 1
    flock "${fd}" || { exec {fd}>&-; return 1; }
    if [ "$(ls -1 "${SDK_GATE_DIR}" 2>/dev/null | wc -l)" -lt "${SDK_GATE_MAX}" ]; then
        : > "${SDK_GATE_DIR:?}/${tag:?}"
        rc=0
    fi
    flock -u "${fd}"
    exec {fd}>&-
    return "${rc}"
}
# 释放 tag 的槽位（tag 或闸门目录为空即报错退出，不静默）。
sdk_gate_release() {
    rm -f "${SDK_GATE_DIR:?}/${1:?}"
}
# SDK 任务统一包裹器（经 run_sdk 发起）：排队占槽 → 打"部署中"状态行 → 执行 →
# 无论成败释放槽位（释放后即由排队任务补位）。
sdk_gated_run() {
    local stage="$1" svc="$2" tag="$3" rc=0
    shift 3
    while ! sdk_gate_try "${tag}"; do
        sleep 2
    done
    log_status "[${stage}][${svc}] - [状态：部署中] - [日志位于${LOG_DIR}/${tag}.log]"
    "$@" || rc=$?
    sdk_gate_release "${tag}"
    return "${rc}"
}

# ==========================================
# SDK 启用规则（init-sdks.sh 下发与 healthcheck.sh 健康判定共用）
# ==========================================
# 挂载目录下的 SDK 目录存在即启用；环境变量 ENABLE_<目录名大写>=0 时停用——
# 不下发部署、不参与健康检查（目录保持原样，随时可恢复）。目录名转变量名：
# 字母转大写，其余字符逐个转下划线（apk-tools → ENABLE_APK_TOOLS）。
sdk_enable_var() {
    printf 'ENABLE_%s' "$(printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9' '_')"
}
# 目录名已启用返回 0，已停用返回 1。
sdk_is_enabled() {
    local var
    var="$(sdk_enable_var "$1")"
    [ "${!var-}" != "0" ]
}

# ==========================================
# 宿主机 X11 显示（DISPLAY 由 compose 传入即启用）
# ==========================================
# DISPLAY 与宿主机的 /tmp/.X11-unix 由 compose 传入，容器内的图形程序经文件系统
# 套接字连宿主机的 X 服务器。桌面会话启动的 X 服务器与 Xwayland 都带 cookie 启动，
# 容器账号不持有那份 cookie，要由宿主机把它的 uid 加入访问控制表才连得通
# （xhost +si:localuser:#<uid>，主账号默认即 #1000）。
# 入口脚本启动时与 healthcheck 每次都以主账号实际连一次，原因与修复提示走同一行。
# 只接受 :N 与 unix:N 两种形式：套接字路径由显示号决定，带主机名的形式走 TCP，
# 宿主机的 X 服务器默认不监听。
# x11_display_socket <DISPLAY>：输出套接字路径；形式不受支持时输出为空并返回 1。
x11_display_socket() {
    local disp="$1" num
    case "${disp}" in
        :*) ;;
        unix:*) disp=":${disp#unix:}" ;;
        *) return 1 ;;
    esac
    num="${disp#:}"
    num="${num%%.*}"
    case "${num}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '/tmp/.X11-unix/X%s\n' "${num}"
}

# 以主账号身份执行命令。
# 用法：x11_as <主账号> <命令> [参数...]
x11_as() {
    runuser -u "$1" -- "${@:2}"
}

# x11_probe <主账号>：DISPLAY 未设置即未启用，返回 0 且无输出；否则以主账号连接
# 一次，连通返回 0；连不通返回 1，把原因与修复提示写到标准输出，由调用方原样
# 并入状态行。限时 5 秒，X 服务器无应答时不卡住入口脚本与 healthcheck。
x11_probe() {
    local user="$1" sock err rc
    if [ -z "${DISPLAY:-}" ]; then
        return 0
    fi
    if ! sock="$(x11_display_socket "${DISPLAY}")"; then
        echo "DISPLAY=${DISPLAY} 形式不受支持（只接受 :N 或 unix:N）"
        return 1
    fi
    if [ ! -S "${sock}" ]; then
        echo "宿主机 X 套接字 ${sock} 不存在（compose 未挂载 /tmp/.X11-unix，或宿主机没有桌面会话）"
        return 1
    fi
    rc=0
    err="$(x11_as "${user}" timeout 5 xdpyinfo 2>&1 >/dev/null)" || rc=$?
    if [ "${rc}" = 0 ]; then
        return 0
    fi
    err="${err%%$'\n'*}"
    case "${rc}:${err}" in
        124:*) echo "X 服务器 5 秒内无应答" ;;
        *:"Authorization required"*|*:"No protocol specified"*)
            echo "X 服务器拒绝连接（${err}）；在宿主机执行 xhost +si:localuser:#$(id -u "${user}") 后自动恢复"
            ;;
        *) echo "连不上 X 服务器（${err}）" ;;
    esac
    return 1
}
