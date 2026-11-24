#!/usr/bin/env bash
# ==========================================
# 达梦 DM8 本地数据库挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：二进制由 Base 层安装（经强装补丁安装，见
# Dockerfile.base），本脚本只做首启初始化与拉起；数据目录 /var/lib/dm8/data/DAMENG
# 在挂载目录之外，默认落容器可写层——容器重建即全新、docker restart 保留；需要
# 跨重建保留时在 compose 为 /var/lib/dm8 挂卷。dminit 按 DB_NAME 建库目录。
# 端口：DM_PORT（端口约定见 sdks/README.md），即 dm.ini 的 PORT_NUM（静态参数，
# dmserver 启动时读取）：首启由 dminit 写入，之后每次启动对齐为同一约定值，
# 与实例是新建还是随数据卷已有无关。
# 密码：SYSDBA 与 SYSAUDITOR（达梦强制并存的审计员账号）均取统一变量
# DB_PASSWORD，经 dminit 命令行参数写入。dminit 以命令行参数接收密码，经
# runuser 直传 argv（不经中间 shell 二次求值，密码含单引号等字符安全）。密码须满足
# 达梦复杂度（8-48 位且含大写/小写/数字），弱密码 dminit 直接失败退出（尽早失败）。
# 仅首启初始化生效，已有数据不追溯。
# 初始化参数对齐官方 Docker 镜像常用值：PAGE_SIZE=16 / EXTENT_SIZE=32 /
# CHARSET=1（UTF-8）/ CASE_SENSITIVE=Y（默认，Oracle 迁移主流形态）；
# LOG_SIZE=256 取下限（缺省 4096×2 个日志文件会预写 8G，开发容器不必要）。
# AUTO_ADJ_MEM=4096：内存类参数（MEMORY_POOL、BUFFER、RECYCLE、MAX_SESSIONS 等）由
# dminit 在初始化时按此预算推导并写入 dm.ini，之后改它不再重算。
# PAGE_SIZE/CHARSET/CASE_SENSITIVE 仅初始化时生效，建库后不可改。
# 监听：dmserver 默认即监听 *:DM_PORT（dm.ini 无需放开），对外暴露由
# compose 端口映射控制；达梦无 local socket 免密通道，TCP 一律密码认证。
# 容器内连接：disql 'SYSDBA/"$DB_PASSWORD"@localhost:15236'（连接串里密码含 @ 等字符
# 时须整体双引号括起，disql 语义）；密码本身含双引号时连接串无法表达，改
# disql SYSDBA@localhost:15236 按提示输入。
# 检测判据 dm.ctl（dminit 产物；写入早于初始化完成，中断残留由
# .initializing 标记识别强制重初始化。标记放数据目录之外的卷根
# /var/lib/dm8——dminit 要求 PATH 目录为空）。
# AVX-512 运行时门禁：此 DM8 构建（20260817）的 libdmdpi.so 含无条件
# AVX-512 指令（vcvtusi2sd），不支持 AVX-512 的 CPU 上 dmserver/dminit/disql
# 一律 SIGILL。不满足时 FATAL 不拉起、容器不终止（其余服务不受影响）。
# 授权：内置试用授权随构建滚动（20260817 构建 2027-07-07 到期），到期前
# 换新镜像即可；正式授权时将 dm.key 挂载覆盖 /opt/dmdbms/bin/dm.key。
# 运行中随时可手动拉起：supervisorctl start dm
# ==========================================
set -euo pipefail

SDK_NAME="dm"
DM_PORT=15236
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 入口模块库（镜像内）：supervisorctl_start 等待 supervisord 控制通道就绪后拉起程序段，
# 以程序段进入 RUNNING 为成功判据
[ -f /usr/local/share/entrypoint.d/lib.sh ] \
    || fatal "未找到 /usr/local/share/entrypoint.d/lib.sh（镜像入口模块库）"
source /usr/local/share/entrypoint.d/lib.sh

[ -x /opt/dmdbms/bin/dmserver ] || fatal "未找到 /opt/dmdbms/bin/dmserver（仅 Base 层镜像内置达梦 DM8）"
[ -n "${DB_PASSWORD:-}" ] || fatal "DB_PASSWORD 未设置（统一数据库密码，达梦用户 SYSDBA）"

# 数据目录属主对齐的判据：所给路径的 uid:gid 全部等于该系统账号的 uid:gid
owner_matches() {
    local user="$1" path want
    want="$(id -u "${user}"):$(id -g "${user}")"
    for path in "${@:2}"; do
        [ "$(stat -c '%u:%g' "${path}")" = "${want}" ] || return 1
    done
}

# 客户端命令入口 /usr/local/bin/disql：包装脚本转执行真正的 disql。/usr/local/bin 在镜像
# ENV PATH 与登录 shell 默认 PATH 上，任何账号的登录/非登录 shell 均可直接调用。
# 每次启动重建，内容固定故幂等；写入同目录临时文件再 mv 原子替换，路径上已有的
# 旧入口（含软链）被整体替换。位于初始化之前：初始化失败时客户端同样可用。
install_client_entry() {
    local entry="/usr/local/bin/disql"
    local tmp="/usr/local/bin/.disql.$$"
    cat > "${tmp}" <<'EOF' \
        || { rm -f "${tmp}"; fatal "disql 命令入口写入失败"; }
#!/bin/sh
# 达梦客户端入口：由 /opt/sdks/dm/SDK.sh 每次容器启动重建
exec /opt/dmdbms/bin/disql "$@"
EOF
    chmod 755 "${tmp}" \
        || { rm -f "${tmp}"; fatal "disql 命令入口权限设置失败"; }
    mv -f "${tmp}" "${entry}" \
        || { rm -f "${tmp}"; fatal "disql 命令入口安装失败"; }
}

init_and_start_dm() {
    # AVX-512 运行时门禁：尽早明确报错
    if ! grep -qw avx512f /proc/cpuinfo; then
        fatal "DM8 当前构建要求 AVX-512 指令集，当前 CPU 不支持（需换用非 AVX-512 的达梦介质构建）"
    fi
    DM_DATA=/var/lib/dm8/data/DAMENG
    DM_MARKER=/var/lib/dm8/.initializing
    if [ -f "${DM_MARKER}" ]; then
        echo "==> [DM8] 检测到上次后台初始化未完成（残留标记），清理残缺数据重新初始化"
        DM_NEED_INIT=1
    elif [ ! -f "${DM_DATA}/dm.ctl" ]; then
        DM_NEED_INIT=1
    else
        DM_NEED_INIT=0
    fi
    if [ "${DM_NEED_INIT}" = "1" ]; then
        echo "==> [DM8] 数据目录为空，后台初始化实例 (dminit)"
        # 挂卷时镜像层预建的 data/ 子目录被卷遮住，须先补建再清理属主
        mkdir -p /var/lib/dm8/data
        find /var/lib/dm8/data -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${DM_MARKER}" || fatal "DM8 初始化标记创建失败"
        chown -R dmdba:dmdba /var/lib/dm8 \
            || fatal "DM8 数据目录属主设置失败"
        if ! runuser -u dmdba -- /opt/dmdbms/bin/dminit \
                PATH=/var/lib/dm8/data PAGE_SIZE=16 EXTENT_SIZE=32 LOG_SIZE=256 AUTO_ADJ_MEM=4096 \
                CHARSET=1 CASE_SENSITIVE=Y PORT_NUM="${DM_PORT}" \
                SYSDBA_PWD="${DB_PASSWORD}" SYSAUDITOR_PWD="${DB_PASSWORD}"; then
            fatal "DM8 实例初始化失败（密码需 8-48 位且含大写/小写/数字，详见任务日志），可 supervisorctl start dm 重试"
        fi
        rm -f "${DM_MARKER}"
    fi
    # 端口对齐：dm.ini 的 PORT_NUM 每次启动置为约定值，只换数字、保留行内注释。
    # 先于属主对齐执行，挂卷带入的实例文件由此一并归到 dmdba 名下。
    sed -i -E -e 's/^([[:space:]]*PORT_NUM[[:space:]]*=[[:space:]]*)[0-9]+/\1@PORT@/' \
        -e "s/@PORT@/${DM_PORT}/" "${DM_DATA}/dm.ini"

    # 数据目录属主对齐：数据文件归数据库自己的系统账号。卷根（compose 挂卷时的挂载点，
    # Docker 代建的宿主目录归 root）或实例目录的属主与之不符即递归 chown；相符则不遍历
    # （大卷无条件遍历会拖垮启动时序）。
    if ! owner_matches dmdba /var/lib/dm8 "${DM_DATA}"; then
        echo "==> [DM8] 数据目录属主对齐为 dmdba"
        chown -R dmdba:dmdba /var/lib/dm8 \
            || fatal "DM8 数据目录属主对齐失败"
    fi
    supervisorctl_start dm || fatal "DM8 拉起失败"
    log "DM8 就绪：TCP 0.0.0.0:${DM_PORT}（SYSDBA + DB_PASSWORD）/ 容器内连接 disql SYSDBA/密码@localhost:${DM_PORT}（密码含特殊字符时整体加双引号）"
}

install_client_entry
init_and_start_dm
