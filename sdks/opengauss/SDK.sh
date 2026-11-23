#!/usr/bin/env bash
# ==========================================
# openGauss 7.0.0 本地数据库挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：二进制由 Base 层安装（见 Dockerfile.base），本脚本
# 只做首启初始化与拉起；数据目录 /var/lib/opengauss/data 在挂载目录之外，默认落
# 容器可写层——容器重建即全新、docker restart 保留；需要跨重建保留时在 compose 为
# /var/lib/opengauss 挂卷。检测判据为数据目录 PG_VERSION（gs_initdb 产物），对
# "镜像留空 / 挂空卷 / 挂已有数据卷"三场景统一且幂等。
# 华为 GaussDB 企业版无公开安装包，免费可得的最完整版本即开源 openGauss 7.0.0 LTS。
# 初始化中断恢复：.initializing 标记放数据目录之外的卷根（gs_initdb 拒绝非空数据
# 目录），残留即强制清理重初始化。
# 密码：openGauss 内核强制 TCP 连接一律密码认证（pg_hba trust 不豁免）；
# 初始用户 omm 的密码即统一变量 DB_PASSWORD，经 gs_initdb --pwfile 原样传入。
# gs_initdb 对初始用户密码的校验（官方《设置密码安全策略》）：不少于 8 位且
# 大写/小写/数字/特殊字符至少三类，不得与用户名相同或互为倒序；字符仅限数字、
# 字母与官方表列出的特殊字符（~!@#$%^&*()-_=+\|[{}]:;,.<>/?）——空格、双引号、
# 反引号不在其列，单引号虽在 CREATE USER 的规则内但 gs_initdb 同样拒绝。
# 不满足时 initdb 直接失败退出（尽早失败）。仅首启初始化生效，已有数据不追溯。
# 监听：首启初始化后统一置 listen_addresses='*' 并向 pg_hba.conf 追加 0.0.0.0/0
# 放行行（同样仅新数据目录生效）；对外暴露由 compose 端口映射控制，TCP 一律密码。
# 端口：5433（supervisord 命令行 -p 5433），避让 PostgreSQL 17 的 5432，
# 两库才可同时启用。gaussdb 另固定监听 port+1（5434，官方"通信矩阵"所称
# 内部工具连接端口 dataPortBase+1，安装后默认开启）；单节点未配置
# replconninfo，启动期 "could not create any HA TCP/IP sockets" 警告属预期。
# 容器内连接：local socket 免密仅限初始用户 omm 以系统账号 omm 身份连接
# （官方通信矩阵：local trust 仅限初始化用户且与运行数据库的 OS 用户同名），
# 即 healthcheck.sh 的 su 形式；其余连接一律密码。gsql 命令入口
# /usr/local/bin/gsql 由本脚本每次启动重建（install_client_entry），不认
# PGPASSWORD，-W 须直接带密码参数：
#   gsql -h 127.0.0.1 -p 5433 -U omm -W "$DB_PASSWORD" -d postgres
# gs_initdb 拒绝 root 运行，以预建系统账号 omm 执行；--dbcompatibility=A 为
# Oracle 兼容模式（国产化迁移场景默认）。首启初始化约 10-30s（后台并行进行）。
# 运行中随时可手动拉起：supervisorctl start opengauss
# ==========================================
set -euo pipefail

SDK_NAME="opengauss"
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 入口模块库（镜像内）：supervisorctl_start 等待 supervisord 控制通道就绪后拉起程序段
[ -f /usr/local/share/entrypoint.d/lib.sh ] \
    || fatal "未找到 /usr/local/share/entrypoint.d/lib.sh（镜像入口模块库）"
source /usr/local/share/entrypoint.d/lib.sh

[ -x /opt/opengauss/bin/gaussdb ] || fatal "未找到 /opt/opengauss/bin/gaussdb（仅 Base 层镜像内置 openGauss）"
[ -n "${DB_PASSWORD:-}" ] || fatal "DB_PASSWORD 未设置（统一数据库密码，openGauss 用户 omm）"

# 数据目录属主对齐的判据：所给路径的 uid:gid 全部等于该系统账号的 uid:gid
owner_matches() {
    local user="$1" path want
    want="$(id -u "${user}"):$(id -g "${user}")"
    for path in "${@:2}"; do
        [ "$(stat -c '%u:%g' "${path}")" = "${want}" ] || return 1
    done
}

# 客户端命令入口 /usr/local/bin/gsql：包装脚本导出包内库路径 LD_LIBRARY_PATH 后转执行
# 真正的 gsql。/usr/local/bin 在镜像 ENV PATH 与登录 shell 默认 PATH 上，任何账号的
# 登录/非登录 shell 均可直接调用。每次启动重建，内容固定故幂等；写入同目录临时文件
# 再 mv 原子替换，路径上已有的旧入口（含软链）被整体替换。位于初始化之前：初始化
# 失败时客户端同样可用。
install_client_entry() {
    local entry="/usr/local/bin/gsql"
    local tmp="/usr/local/bin/.gsql.$$"
    cat > "${tmp}" <<'EOF' \
        || { rm -f "${tmp}"; fatal "gsql 命令入口写入失败"; }
#!/bin/sh
# openGauss 客户端入口：由 /opt/sdks/opengauss/SDK.sh 每次容器启动重建
export LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql
exec /opt/opengauss/bin/gsql "$@"
EOF
    chmod 755 "${tmp}" \
        || { rm -f "${tmp}"; fatal "gsql 命令入口权限设置失败"; }
    mv -f "${tmp}" "${entry}" \
        || { rm -f "${tmp}"; fatal "gsql 命令入口安装失败"; }
}

init_and_start_opengauss() {
    OG_DATA="/var/lib/opengauss/data"
    # GAUSSLOG 日志目录：缺失时 gaussdb 启动刷 "[EXECUTOR] Failed to obtain
    # environment value $GAUSSLOG" 警告（supervisord 已传同名 env 指向此处）。
    # 可写层目录，每次启动幂等补建（与数据目录是否初始化无关）。
    OG_LOG="/var/log/opengauss"
    mkdir -p "${OG_LOG}"
    chown omm:omm "${OG_LOG}" \
        || fatal "openGauss 日志目录属主设置失败"
    # 中断标记放数据目录之外的卷根（挂卷时为 ./opengauss:/var/lib/opengauss）：
    # gs_initdb 拒绝非空数据目录，标记不能落在 OG_DATA 内。
    OG_MARKER="/var/lib/opengauss/.initializing"
    if [ -f "${OG_MARKER}" ]; then
        echo "==> [openGauss] 检测到上次后台初始化未完成（残留标记），清理残缺数据重新初始化"
        OG_NEED_INIT=1
    elif [ ! -f "${OG_DATA}/PG_VERSION" ]; then
        OG_NEED_INIT=1
    else
        OG_NEED_INIT=0
    fi
    if [ "${OG_NEED_INIT}" = "1" ]; then
        echo "==> [openGauss] 数据目录为空，后台初始化单节点集群 (gs_initdb)"
        # 挂卷时镜像层预建的 data/ 子目录被卷遮住，须先补建再清理属主
        mkdir -p "${OG_DATA}"
        find "${OG_DATA}" -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${OG_MARKER}" || fatal "openGauss 初始化标记创建失败"
        chown omm:omm "${OG_DATA}" \
            || fatal "openGauss 数据目录属主设置失败"
        # 密码经 --pwfile 传递（mktemp 路径无特殊字符，su -c 单引号串安全）；
        # 须 omm 可读（gs_initdb 以 omm 运行），失败/成功路径均用后即删。
        OG_PWFILE=$(mktemp /tmp/.ogpw.XXXXXX)
        printf '%s' "${DB_PASSWORD}" > "${OG_PWFILE}" \
            || { rm -f "${OG_PWFILE}"; fatal "openGauss 密码文件写入失败"; }
        chown omm:omm "${OG_PWFILE}" && chmod 600 "${OG_PWFILE}" \
            || { rm -f "${OG_PWFILE}"; fatal "openGauss 密码文件权限设置失败"; }
        if ! su -s /bin/bash omm -c "export GAUSSHOME=/opt/opengauss LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql LD_PRELOAD=liblapacke.so.3; /opt/opengauss/bin/gs_initdb --pgdata='${OG_DATA}' --nodename=sgnode --encoding=UTF-8 --dbcompatibility=A --pwfile='${OG_PWFILE}'"; then
            rm -f "${OG_PWFILE}"
            fatal "openGauss 集群初始化失败（密码须 >=8 位、含大小写/数字/特殊字符至少三类，且仅限数字、字母与官方文档列出的特殊字符，不含空格与引号；详见任务日志），可 supervisorctl start opengauss 重试"
        fi
        rm -f "${OG_PWFILE}"
        # 各库统一 0.0.0.0 监听 + pg_hba 全接口放行（TCP 仍内核强制密码认证，
        # 对外暴露由 compose 端口映射控制）。配置在数据目录内随数据保留，
        # 仅新建数据目录时执行一次；直改文件离线生效，不依赖 gs_guc 运行环境。
        printf "listen_addresses = '*'\n" >> "${OG_DATA}/postgresql.conf"
        echo "host all all 0.0.0.0/0 sha256" >> "${OG_DATA}/pg_hba.conf"
        rm -f "${OG_MARKER}"
    fi
    # 数据目录属主对齐：数据文件归数据库自己的系统账号。卷根（compose 挂卷时的挂载点，
    # Docker 代建的宿主目录归 root）或数据目录的属主与之不符即递归 chown；相符则不遍历
    # （大卷无条件遍历会拖垮启动时序）。
    if ! owner_matches omm "$(dirname "${OG_DATA}")" "${OG_DATA}"; then
        echo "==> [openGauss] 数据目录属主对齐为 omm"
        chown -R omm:omm "$(dirname "${OG_DATA}")" \
            || fatal "openGauss 数据目录属主对齐失败"
    fi
    supervisorctl_start opengauss || fatal "openGauss 拉起失败"
    log 'openGauss 7.0 就绪：TCP 0.0.0.0:5433（omm + DB_PASSWORD）/ 容器内连接：gsql -h 127.0.0.1 -p 5433 -U omm -W "$DB_PASSWORD" -d postgres'
}

install_client_entry
init_and_start_opengauss
