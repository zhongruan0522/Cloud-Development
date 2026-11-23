#!/usr/bin/env bash
# ==========================================
# KingbaseES V9R2 本地数据库挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：二进制由 Base 层安装（DEB 精简包直装，见
# Dockerfile.base 尾部层），本脚本只做首启初始化与拉起；数据目录
# /var/lib/kingbase/data 在挂载目录之外，默认落容器可写层——容器重建即全新、
# docker restart 保留；需要跨重建保留时在 compose 为 /var/lib/kingbase 挂卷。
# 检测判据为数据目录 SYS_VERSION（initdb 产物，对应 PostgreSQL 的 PG_VERSION），
# 对"镜像留空 / 挂空卷 / 挂已有数据卷"三场景统一且幂等；初始化中断恢复：
# .initializing 标记放数据目录之外的卷根（initdb 拒绝非空数据目录），残留即
# 强制清理重初始化。
# 人大金仓。端口 54321（官方默认；其余各库的端口约定见 sdks/README.md）。
# 初始用户 system 的密码即统一变量 DB_PASSWORD（经 initdb --pwfile 传入，
# 与 PG/openGauss 同机制）；initdb -m oracle 取 Oracle 兼容模式（金仓最主流
# 模式，license 四种 dbmode 全开，改 -m 可换 mysql/postgresql/sqlserver）。
# 仅首启初始化生效，已有数据不追溯。
# 自带 180 天浮动试用授权（首次加载起算，每个新容器满额），无需单独授权文件。
# 运行中随时可手动拉起：supervisorctl start kingbase
# ==========================================
set -euo pipefail

SDK_NAME="kingbase"
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 入口模块库（镜像内）：supervisorctl_start 等待 supervisord 控制通道就绪后拉起程序段，
# 以程序段进入 RUNNING 为成功判据
[ -f /usr/local/share/entrypoint.d/lib.sh ] \
    || fatal "未找到 /usr/local/share/entrypoint.d/lib.sh（镜像入口模块库）"
source /usr/local/share/entrypoint.d/lib.sh

KES_BIN=/opt/Kingbase/ES/Server/bin
[ -x "${KES_BIN}/kingbase" ] || fatal "未找到 ${KES_BIN}/kingbase（仅 Base 层镜像内置 KingbaseES）"
[ -n "${DB_PASSWORD:-}" ] || fatal "DB_PASSWORD 未设置（统一数据库密码，KingbaseES 用户 system）"

# 数据目录属主对齐的判据：所给路径的 uid:gid 全部等于该系统账号的 uid:gid
owner_matches() {
    local user="$1" path want
    want="$(id -u "${user}"):$(id -g "${user}")"
    for path in "${@:2}"; do
        [ "$(stat -c '%u:%g' "${path}")" = "${want}" ] || return 1
    done
}

# 客户端命令入口 /usr/local/bin/ksql：包装脚本转执行真正的 ksql。/usr/local/bin 在镜像
# ENV PATH 与登录 shell 默认 PATH 上，任何账号的登录/非登录 shell 均可直接调用。
# 每次启动重建，内容固定故幂等；写入同目录临时文件再 mv 原子替换，路径上已有的
# 旧入口（含软链）被整体替换。位于初始化之前：初始化失败时客户端同样可用。
install_client_entry() {
    local entry="/usr/local/bin/ksql"
    local tmp="/usr/local/bin/.ksql.$$"
    cat > "${tmp}" <<'EOF' \
        || { rm -f "${tmp}"; fatal "ksql 命令入口写入失败"; }
#!/bin/sh
# KingbaseES 客户端入口：由 /opt/sdks/kingbase/SDK.sh 每次容器启动重建
exec /opt/Kingbase/ES/Server/bin/ksql "$@"
EOF
    chmod 755 "${tmp}" \
        || { rm -f "${tmp}"; fatal "ksql 命令入口权限设置失败"; }
    mv -f "${tmp}" "${entry}" \
        || { rm -f "${tmp}"; fatal "ksql 命令入口安装失败"; }
}

init_and_start_kingbase() {
    KES_DATA=/var/lib/kingbase/data
    # 中断标记放数据目录之外的卷根（挂卷时为 ./kingbase:/var/lib/kingbase）：
    # initdb 拒绝非空数据目录，标记不能落在 KES_DATA 内。
    KES_MARKER=/var/lib/kingbase/.initializing
    if [ -f "${KES_MARKER}" ]; then
        echo "==> [KingbaseES] 检测到上次后台初始化未完成（残留标记），清理残缺数据重新初始化"
        KES_NEED_INIT=1
    elif [ ! -f "${KES_DATA}/SYS_VERSION" ]; then
        KES_NEED_INIT=1
    else
        KES_NEED_INIT=0
    fi
    if [ "${KES_NEED_INIT}" = "1" ]; then
        echo "==> [KingbaseES] 数据目录为空，后台初始化实例 (initdb -m oracle)"
        # 挂卷时镜像层预建的 data/ 子目录被卷遮住，须先补建再清理属主
        mkdir -p "${KES_DATA}"
        find "${KES_DATA}" -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${KES_MARKER}" || fatal "KingbaseES 初始化标记创建失败"
        chown kingbase:kingbase "${KES_DATA}" \
            || fatal "KingbaseES 数据目录属主设置失败"
        # 密码经 --pwfile 传递（原样读取，密码含单引号亦不破坏）；
        # 须 kingbase 可读，失败/成功路径均用后即删。
        # --auth-local=trust --auth-host=scram-sha-256：容器内 local socket 免密，
        # TCP 一律 scram 密码认证。
        KES_PWFILE=$(mktemp /tmp/.kespw.XXXXXX)
        printf '%s' "${DB_PASSWORD}" > "${KES_PWFILE}" \
            || { rm -f "${KES_PWFILE}"; fatal "KingbaseES 密码文件写入失败"; }
        chown kingbase:kingbase "${KES_PWFILE}" && chmod 600 "${KES_PWFILE}" \
            || { rm -f "${KES_PWFILE}"; fatal "KingbaseES 密码文件权限设置失败"; }
        if ! su -s /bin/bash kingbase -c "${KES_BIN}/initdb -D '${KES_DATA}' -U system --pwfile='${KES_PWFILE}' -E UTF8 --locale=zh_CN.UTF-8 -m oracle --auth-local=trust --auth-host=scram-sha-256"; then
            rm -f "${KES_PWFILE}"
            fatal "KingbaseES 实例初始化失败，详见任务日志，可 supervisorctl start kingbase 重试"
        fi
        rm -f "${KES_PWFILE}"
        # 各库统一 0.0.0.0 监听 + 远程连接放行（TCP 仍 scram 密码认证，对外
        # 暴露由 compose 端口映射控制）。金仓配置文件对应 postgresql.conf/
        # pg_hba.conf 的改名件：kingbase.conf / sys_hba.conf。配置在数据目录
        # 内随数据保留，仅新建数据目录时执行一次；直改文件离线生效。
        printf "listen_addresses = '*'\nport = 54321\n" >> "${KES_DATA}/kingbase.conf"
        echo "host all all 0.0.0.0/0 scram-sha-256" >> "${KES_DATA}/sys_hba.conf"
        chown kingbase:kingbase "${KES_DATA}/kingbase.conf" "${KES_DATA}/sys_hba.conf"
        rm -f "${KES_MARKER}"
    fi
    # 数据目录属主对齐：数据文件归数据库自己的系统账号。卷根（compose 挂卷时的挂载点，
    # Docker 代建的宿主目录归 root）或数据目录的属主与之不符即递归 chown；相符则不遍历
    # （大卷无条件遍历会拖垮启动时序）。
    if ! owner_matches kingbase "$(dirname "${KES_DATA}")" "${KES_DATA}"; then
        echo "==> [KingbaseES] 数据目录属主对齐为 kingbase"
        chown -R kingbase:kingbase "$(dirname "${KES_DATA}")" \
            || fatal "KingbaseES 数据目录属主对齐失败"
    fi
    supervisorctl_start kingbase || fatal "KingbaseES 拉起失败"
    log 'KingbaseES V9R2 就绪：TCP 0.0.0.0:54321（system + DB_PASSWORD，oracle 模式）/ 容器内 socket 免密 ksql -p 54321 -U system -d test'
}

install_client_entry
init_and_start_kingbase
