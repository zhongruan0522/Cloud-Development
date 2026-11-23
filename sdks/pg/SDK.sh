#!/usr/bin/env bash
# ==========================================
# PostgreSQL 17 本地数据库挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：二进制由 Base 层安装（PGDG 官方仓库，见
# Dockerfile.base），本脚本只做首启初始化与拉起；数据目录 /var/lib/postgresql 在
# 挂载目录之外，默认落容器可写层——容器重建即全新、docker restart 保留；需要跨重建
# 保留时在 compose 为该路径挂卷，脚本对"镜像留空数据目录 / 挂空卷 / 挂已有数据卷"
# 三场景统一且幂等。
# 初始化在本脚本进行：openchamber 等主服务先行启动，初始化完成后经 supervisorctl
# 运行期拉起（supervisord.conf 恒 autostart=false）。检测判据 PG_VERSION（initdb
# 产物），docker restart 重跑本脚本时判据文件已在即跳过，绝不重复初始化。
# 初始化中断恢复：后台 init 期间容器被停止会留下残缺数据目录，而 PG_VERSION
# 由 initdb 早期写入、不能代表初始化完成——以 .initializing 标记识别（放数据
# 目录之外的卷根：initdb 拒绝非空数据目录），见标记即强制清理重初始化。
# 密码：postgres 超级用户密码由统一变量 DB_PASSWORD 在首启初始化时经
# initdb --pwfile 写入（PG17 默认 scram-sha-256 存储，与官方 postgres 镜像
# POSTGRES_PASSWORD 同机制）；仅首启生效，已有数据不追溯。
# 认证：local socket 一律 trust（容器内 CLI 免密）；
# TCP 一律 scram-sha-256（连接须带密码；监听 0.0.0.0 + pg_hba 全接口放行行，
# 对外暴露由 compose 端口映射控制）。
# 版本升级（如 17→18）需同步修改 base/supervisord.conf、本脚本与同目录
# healthcheck.sh 中硬编码的 17 版本路径。
# 运行中随时可手动拉起：supervisorctl start postgresql
# ==========================================
set -euo pipefail

SDK_NAME="pg"
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 入口模块库（镜像内）：supervisorctl_start 等待 supervisord 控制通道就绪后拉起程序段
[ -f /usr/local/share/entrypoint.d/lib.sh ] \
    || fatal "未找到 /usr/local/share/entrypoint.d/lib.sh（镜像入口模块库）"
source /usr/local/share/entrypoint.d/lib.sh

[ -x /usr/lib/postgresql/17/bin/postgres ] || fatal "未找到 PostgreSQL 17（仅 Base 层镜像内置）"
[ -n "${DB_PASSWORD:-}" ] || fatal "DB_PASSWORD 未设置（统一数据库密码，PostgreSQL 用户 postgres）"

init_and_start_postgresql() {
    PG_DATA="/var/lib/postgresql/17/main"
    PG_CONF="/etc/postgresql/17/main"
    # 中断标记放数据目录之外的卷根（挂卷时为 ./postgres:/var/lib/postgresql）：
    # initdb 拒绝非空数据目录，标记不能落在 PG_DATA 内。
    PG_MARKER="/var/lib/postgresql/.initializing"
    mkdir -p "$(dirname "${PG_MARKER}")"
    if [ -f "${PG_MARKER}" ]; then
        echo "==> [PostgreSQL] 检测到上次后台初始化未完成（残留标记），清理残缺数据重新初始化"
        PG_NEED_INIT=1
    elif [ ! -f "${PG_DATA}/PG_VERSION" ]; then
        PG_NEED_INIT=1
    else
        PG_NEED_INIT=0
    fi
    if [ "${PG_NEED_INIT}" = "1" ]; then
        echo "==> [PostgreSQL] 数据目录为空，后台初始化集群 (pg_createcluster 17 main --pwfile)"
        # 兼容挂载点残留（如 lost+found），pg_createcluster 要求空目录
        mkdir -p "${PG_DATA}"
        find "${PG_DATA}" -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${PG_MARKER}" || fatal "PostgreSQL 初始化标记创建失败"
        # pg_createcluster 拒绝已存在的配置目录（"cluster configuration already exists"）；
        # 该目录在镜像层且内容为包默认配置，删除重建安全。
        # 不带 --start：默认只创建不启动（--start 是布尔开关，无 =no 写法）。
        # -p 5432 钉死端口：不指定时 pg_createcluster 取"下一个空闲端口"，/etc/postgresql/17
        # 下若另有集群目录占用 5432 会被静默顺延（5433 是 openGauss 的端口）；端口是本脚本、
        # supervisord.conf 与 healthcheck.sh 的共同约定。
        # " -- " 之后透传 initdb 参数：--pwfile 把 DB_PASSWORD 设为 postgres
        # 超级用户密码。密码文件须 postgres 可读（pg_createcluster 以 postgres
        # 跑 initdb），用后即删；DB_PASSWORD 含单引号等字符时无需转义（文件原样）。
        rm -rf "${PG_CONF}"
        PG_PWFILE=$(mktemp /tmp/.pgpw.XXXXXX)
        printf '%s' "${DB_PASSWORD}" > "${PG_PWFILE}" \
            || { rm -f "${PG_PWFILE}"; fatal "PostgreSQL 密码文件写入失败"; }
        chown postgres:postgres "${PG_PWFILE}"
        chmod 600 "${PG_PWFILE}"
        if ! pg_createcluster 17 main -p 5432 -- --pwfile="${PG_PWFILE}"; then
            rm -f "${PG_PWFILE}"
            fatal "PostgreSQL 集群初始化失败（详见任务日志），可 supervisorctl start postgresql 重试"
        fi
        rm -f "${PG_PWFILE}"
        rm -f "${PG_MARKER}"
    fi
    # 开发友好：local socket 一律 trust；TCP 保持一律 scram-sha-256 密码认证
    # （监听放开不放松认证）。
    # 必须在初始化分支之外每次执行：容器重建后可写层丢失、/etc 配置回到
    # 镜像层默认（local peer + localhost 监听），而数据卷集群仍在的幂等路径
    # 同样需要本段统一改写。
    sed -i 's/\bpeer\b/trust/g' "${PG_CONF}/pg_hba.conf"
    # 各库统一 0.0.0.0 监听：对外暴露由 compose 端口映射控制（默认不发布端口）。
    # pg_conftool 幂等写 listen_addresses；pg_hba 追加全接口放行行（grep 幂等，
    # loopback 默认行在前首条命中，优先级不受影响；远程连接仍须 DB_PASSWORD）。
    pg_conftool 17 main set listen_addresses '*'
    grep -q '^host all all all scram-sha-256$' "${PG_CONF}/pg_hba.conf" \
        || echo 'host all all all scram-sha-256' >> "${PG_CONF}/pg_hba.conf"
    # 挂载卷属主对齐：仅 uid 不符才递归 chown（大卷无条件遍历会拖垮启动时序）
    if [ "$(stat -c %u "${PG_DATA}")" != "$(id -u postgres)" ]; then
        echo "==> [PostgreSQL] 修正数据目录属主为 postgres"
        chown -R postgres:postgres "$(dirname "${PG_DATA}")" "${PG_CONF}" \
            || fatal "PostgreSQL 数据目录属主修正失败"
    fi
    mkdir -p /var/run/postgresql && chown postgres:postgres /var/run/postgresql
    supervisorctl_start postgresql || fatal "PostgreSQL 拉起失败"
    log "PostgreSQL 17 就绪：TCP 0.0.0.0:5432（postgres + DB_PASSWORD）/ 容器内 socket 免密（psql -U postgres）"
}

init_and_start_postgresql
