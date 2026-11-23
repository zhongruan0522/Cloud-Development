#!/usr/bin/env bash
# ==========================================
# MySQL 8.4 本地数据库挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：二进制由 Base 层安装（Oracle 官方 apt 源，见
# Dockerfile.base），本脚本只做首启初始化与拉起；数据目录 /var/lib/mysql 在挂载
# 目录之外，默认落容器可写层——容器重建即全新、docker restart 保留；需要跨重建保留
# 时在 compose 为该路径挂卷，脚本对"镜像留空数据目录 / 挂空卷 / 挂已有数据卷"
# 三场景统一且幂等。检测判据为系统库目录 mysql/。
# root 密码由统一变量 DB_PASSWORD 按以下流程写入：
# --initialize-insecure 建空密码 root -> 拉起 skip-networking 临时实例
# （独享 socket）-> ALTER USER root@localhost 设密 + 建 root@'%'（远程 TCP 用，
#   同密码全权限；root@localhost 仅回环，双账号并存与官方镜像一致）
# -> 干净关停 -> 交 supervisord 正式拉起。
# 仅首启生效，已有数据不追溯；首启合计约 10-30s（后台并行进行，不阻塞主服务）。
# 默认认证插件 caching_sha2_password，PyMySQL 需 cryptography，镜像已内置。
# 监听：0.0.0.0:13306（supervisord 命令行 --bind-address、--port 覆盖包默认的回环
# 地址与 3306；端口约定见 sdks/README.md），对外暴露由 compose 端口映射控制。
# 容器内 mysql 客户端默认走 socket，连接命令不带端口。
# 初始化中断恢复：.initializing 标记（mysqld --initialize 忽略 datadir 中的 dotfile）
# 全程在场，完整成功后移除；期间容器被停止 → 残留标记触发清理重初始化（幂等）。
# 运行中随时可手动拉起：supervisorctl start mysql
# ==========================================
set -euo pipefail

SDK_NAME="mysql"
log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 入口模块库（镜像内）：supervisorctl_start 等待 supervisord 控制通道就绪后拉起程序段
[ -f /usr/local/share/entrypoint.d/lib.sh ] \
    || fatal "未找到 /usr/local/share/entrypoint.d/lib.sh（镜像入口模块库）"
source /usr/local/share/entrypoint.d/lib.sh

[ -x /usr/sbin/mysqld ] || fatal "未找到 /usr/sbin/mysqld（仅 Base 层镜像内置 MySQL）"
[ -n "${DB_PASSWORD:-}" ] || fatal "DB_PASSWORD 未设置（统一数据库密码，MySQL 用户 root）"

# 数据目录属主对齐的判据：所给路径的 uid:gid 全部等于该系统账号的 uid:gid
owner_matches() {
    local user="$1" path want
    want="$(id -u "${user}"):$(id -g "${user}")"
    for path in "${@:2}"; do
        [ "$(stat -c '%u:%g' "${path}")" = "${want}" ] || return 1
    done
}

init_and_start_mysql() {
    MYSQL_DATA="/var/lib/mysql"
    MYSQL_MARKER="${MYSQL_DATA}/.initializing"
    # socket/pid 目录 /var/run/mysqld：临时实例与正式实例都落在这里，须先于临时实例
    # 就位。镜像层已预建，但 /run 为 tmpfs 的运行时里容器启动后不在，故每次启动补建。
    mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld \
        || fatal "MySQL 运行目录创建失败"
    if [ -f "${MYSQL_MARKER}" ]; then
        echo "==> [MySQL] 检测到上次后台初始化未完成（残留标记），清理残缺数据重新初始化"
        MYSQL_NEED_INIT=1
    elif [ ! -d "${MYSQL_DATA}/mysql" ]; then
        MYSQL_NEED_INIT=1
    else
        MYSQL_NEED_INIT=0
    fi
    if [ "${MYSQL_NEED_INIT}" = "1" ]; then
        echo "==> [MySQL] 数据目录为空，后台初始化 (mysqld --initialize-insecure + 临时实例设 root 密码)"
        mkdir -p "${MYSQL_DATA}"
        find "${MYSQL_DATA}" -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），完整成功后移除
        touch "${MYSQL_MARKER}" || fatal "MySQL 初始化标记创建失败"
        chown mysql:mysql "${MYSQL_DATA}"
        if ! mysqld --initialize-insecure --user=mysql; then
            fatal "MySQL 初始化失败（详见任务日志），可 supervisorctl start mysql 重试"
        fi
        # --- 临时实例（skip-networking + 独享 socket）设 root 密码 ---
        # root@'%' 同步创建（监听 0.0.0.0 后供端口映射/跨容器 TCP 使用，同 DB_PASSWORD）
        MYSQL_INIT_SOCK="/tmp/mysql-init.sock"
        mysqld --user=mysql --skip-networking --socket="${MYSQL_INIT_SOCK}" >/tmp/mysql-init.log 2>&1 &
        MYSQL_INIT_PID=$!
        MYSQL_READY=0
        for _ in $(seq 1 60); do
            mysqladmin --socket="${MYSQL_INIT_SOCK}" -u root ping >/dev/null 2>&1 && MYSQL_READY=1 && break
            sleep 1
        done
        # heredoc 定界符无引号（需展开变量），展开值不二次求值（$/反引号安全），
        # 唯一注入面是 SQL 字符串字面量：反斜杠是 MySQL 字面量的转义符（不构成转义
        # 序列时被吞掉），先加倍；单引号按 SQL 标准写成 ''。密码含二者亦原样入库。
        MYSQL_PW_ESC="${DB_PASSWORD//\\/\\\\}"
        MYSQL_PW_ESC="${MYSQL_PW_ESC//\'/\'\'}"
        if [ "${MYSQL_READY}" != "1" ] \
            || ! mysql --socket="${MYSQL_INIT_SOCK}" -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PW_ESC}';
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_PW_ESC}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
SQL
        then
            kill "${MYSQL_INIT_PID}" 2>/dev/null || true
            echo "==> [${SDK_NAME}] 临时实例日志尾部：" >&2
            tail -n 15 /tmp/mysql-init.log >&2 || true
            fatal "MySQL root 密码设置失败（详见上方临时实例日志），可 supervisorctl start mysql 重试"
        fi
        if ! mysqladmin --socket="${MYSQL_INIT_SOCK}" -u root -p"${DB_PASSWORD}" shutdown; then
            kill "${MYSQL_INIT_PID}" 2>/dev/null || true
            fatal "MySQL 临时实例关停失败"
        fi
        rm -f "${MYSQL_MARKER}"
    fi
    # 数据目录属主对齐：数据文件归数据库自己的系统账号（挂卷时的挂载点即数据目录，
    # Docker 代建的宿主目录归 root）；属主相符则不遍历（大卷无条件遍历会拖垮启动时序）。
    if ! owner_matches mysql "${MYSQL_DATA}"; then
        echo "==> [MySQL] 数据目录属主对齐为 mysql"
        chown -R mysql:mysql "${MYSQL_DATA}" \
            || fatal "MySQL 数据目录属主对齐失败"
    fi
    supervisorctl_start mysql || fatal "MySQL 拉起失败"
    log 'MySQL 8.4 就绪：TCP 0.0.0.0:13306（root + DB_PASSWORD）/ 容器内连接 mysql -u root -p"$DB_PASSWORD"'
}

init_and_start_mysql
