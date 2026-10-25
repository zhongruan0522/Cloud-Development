# ==========================================
# MySQL 8.4 本地数据库（默认关闭，ENABLE_MYSQL=1 开启；后台并行初始化）
# 初始化失败 log_fatal 暴露 + healthcheck 变红，不终止容器；检测判据为
# 系统库目录 mysql/。
# root 密码由统一变量 DB_PASSWORD 经官方 docker 镜像同款流程写入：
# --initialize-insecure 建空密码 root -> 拉起 skip-networking 临时实例
# （独享 socket）-> ALTER USER root@localhost 设密 + 建 root@'%'（远程 TCP 用，
#   同密码全权限；root@localhost 仅回环，双账号并存与官方镜像一致）
# -> 干净关停 -> 交 supervisord 正式拉起。
# （不走 --init-file 捷径：官方文档明确 --initialize 引导模式不支持
#   CREATE USER/GRANT 等账户管理语句。）
# 首启合计约 10-30s（后台并行进行，不阻塞主服务）。仅首启生效，已有数据卷不追溯。
# 默认认证插件 caching_sha2_password，PyMySQL 需 cryptography，镜像已内置。
# 监听：0.0.0.0（镜像构建期注释 bind-address），对外暴露由 compose 端口映射控制。
# 初始化中断恢复：.initializing 标记（实测 mysqld --initialize 容忍 datadir
# 中的 dotfile，MySQL 8.4 验证）全程在场，完整成功后移除；期间容器被停止 →
# 残留标记触发清理重初始化（幂等）。
# 运行中随时可手动拉起：supervisorctl start mysql
# ==========================================
init_and_start_mysql() {
    MYSQL_DATA="/var/lib/mysql"
    MYSQL_MARKER="${MYSQL_DATA}/.initializing"
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
        touch "${MYSQL_MARKER}" || { log_fatal "MySQL 初始化标记创建失败"; return 1; }
        chown mysql:mysql "${MYSQL_DATA}"
        if ! mysqld --initialize-insecure --user=mysql; then
            log_fatal "MySQL 初始化失败（详见任务日志），可 supervisorctl start mysql 重试"
            return 1
        fi
        # --- 官方 docker 镜像同款：临时实例（skip-networking + 独享 socket）设 root 密码 ---
        # root@'%' 同步创建（监听 0.0.0.0 后供端口映射/跨容器 TCP 使用，同 DB_PASSWORD）
        MYSQL_INIT_SOCK="/tmp/mysql-init.sock"
        mysqld --user=mysql --skip-networking --socket="${MYSQL_INIT_SOCK}" >/tmp/mysql-init.log 2>&1 &
        MYSQL_INIT_PID=$!
        MYSQL_READY=0
        for _ in $(seq 1 60); do
            mysqladmin --socket="${MYSQL_INIT_SOCK}" -u root ping >/dev/null 2>&1 && MYSQL_READY=1 && break
            sleep 1
        done
        # heredoc 定界符无引号（需展开变量），展开值不再二次求值（$/反引号安全），
        # 唯一注入面是 SQL 单引号——按 SQL 标准 '' 转义，密码含单引号不再破坏
        # 初始化（PG 已用 --pwfile 从根上规避，MySQL 无等价物故转义处理）。
        MYSQL_PW_ESC="${DB_PASSWORD//\'/\'\'}"
        if [ "${MYSQL_READY}" != "1" ] \
            || ! mysql --socket="${MYSQL_INIT_SOCK}" -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_PW_ESC}';
CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_PW_ESC}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
SQL
        then
            kill "${MYSQL_INIT_PID}" 2>/dev/null || true
            log_fatal "MySQL root 密码设置失败，临时实例日志尾部如下"
            tail -n 15 /tmp/mysql-init.log >&2 || true
            log_fatal "MySQL 初始化失败，可 supervisorctl start mysql 重试"
            return 1
        fi
        if ! mysqladmin --socket="${MYSQL_INIT_SOCK}" -u root -p"${DB_PASSWORD}" shutdown; then
            log_fatal "MySQL 临时实例关停失败"
            return 1
        fi
        rm -f "${MYSQL_MARKER}"
    fi
    if [ "$(stat -c %u "${MYSQL_DATA}")" != "$(id -u mysql)" ]; then
        echo "==> [MySQL] 修正数据目录属主为 mysql"
        chown -R mysql:mysql "${MYSQL_DATA}" \
            || { log_fatal "MySQL 数据目录属主修正失败"; return 1; }
    fi
    mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld
    supervisorctl_start mysql || { log_fatal "MySQL 拉起失败"; return 1; }
    echo "==> MySQL 8.4 就绪：TCP 0.0.0.0:3306（root + DB_PASSWORD）/ 容器内 socket 免密（mysql -u root）"
}
if [ "${ENABLE_MYSQL:-0}" = "1" ]; then
    run_db mysql-init init_and_start_mysql
    echo "==> [MySQL] 后台并行初始化已排队 (ENABLE_MYSQL=1)，完成后自动拉起"
else
    echo "==> [MySQL] 开机自启已关闭 (默认)。需要时设 ENABLE_MYSQL=1 或运行: supervisorctl start mysql"
fi
