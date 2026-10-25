# ==========================================
# openGauss 7.0.0 本地数据库（默认关闭，ENABLE_OPENGAUSS=1 开启；后台并行初始化）
# 华为 GaussDB 企业版无公开安装包，免费可得的最完整版本即开源 openGauss 7.0.0 LTS。
# 初始化失败 log_fatal 暴露 + healthcheck 变红，不终止容器；检测判据为数据目录
# PG_VERSION（gs_initdb 产物），对"镜像留空 / 挂空卷 / 挂已有数据卷"三场景统一
# 且幂等。初始化中断恢复：.initializing 标记放数据目录之外的卷根（gs_initdb
# 拒绝非空数据目录），残留即强制清理重初始化。
# 密码：openGauss 内核强制 TCP 连接一律密码认证（pg_hba trust 不豁免，实测），
# 初始用户 omm 的密码即统一变量 DB_PASSWORD（经 gs_initdb --pwfile 传入，
# 与 PG 同机制：su -c 单引号串内拼 -w '${DB_PASSWORD}' 在密码含单引号时会被
# 截断破坏，pwfile 原样读取无转义问题，实测 gs_initdb 支持）；
# 密码须满足 openGauss 复杂度策略（>=8 位，含大小写/数字/特殊字符至少三类），
# 弱密码时 initdb 直接失败退出（尽早失败）。仅首启初始化生效，已有数据卷不追溯。
# 监听：首启初始化后统一置 listen_addresses='*' 并向 pg_hba.conf 追加 0.0.0.0/0
# 放行行（同样仅新数据目录生效）；对外暴露由 compose 端口映射控制，TCP 一律密码。
# 端口：5433（supervisord 命令行 -p 5433），避让 PostgreSQL 17 的 5432，
# 两库才可同时启用。单节点未配置 replconninfo 时不监听 port+1 的 HA 通道
# （实测 ss 无 5434），启动期 "could not create any HA TCP/IP sockets" 警告
# 属预期，无需理会。
# 容器内连接：local socket 免密（gsql -p 5433 -d postgres）；TCP 需密码且
# gsql 不认 PGPASSWORD，-W 须直接带密码参数（与原生 psql 的 -W 无参含义不同，
# 实测报 "The option '-W' need a parameter"）：
#   gsql -h 127.0.0.1 -p 5433 -U omm -W "$DB_PASSWORD" -d postgres
# gs_initdb 拒绝 root 运行，以预建系统账号 omm 执行；--dbcompatibility=A 为
# Oracle 兼容模式（国产化迁移场景默认）。首启初始化约 10-30s（后台并行进行）。
# 运行中随时可手动拉起：supervisorctl start opengauss
# ==========================================
init_and_start_opengauss() {
    OG_DATA="/var/lib/opengauss/data"
    # GAUSSLOG 日志目录：缺失时 gaussdb 启动刷 "[EXECUTOR] Failed to obtain
    # environment value $GAUSSLOG" 警告（supervisord 已传同名 env 指向此处）。
    # 可写层目录，每次启动幂等补建（与数据卷是否初始化无关）。
    OG_LOG="/var/log/opengauss"
    mkdir -p "${OG_LOG}"
    chown omm:omm "${OG_LOG}" \
        || { log_fatal "openGauss 日志目录属主设置失败"; return 1; }
    # 中断标记放数据目录之外的卷根（./opengauss:/var/lib/opengauss）：
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
        # compose 挂载 /var/lib/opengauss 时镜像层预建的 data/ 子目录被卷遮住，
        # 须先补建再清理属主（PG 由 pg_createcluster 建全路径、MySQL 已有 mkdir）
        mkdir -p "${OG_DATA}"
        find "${OG_DATA}" -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${OG_MARKER}" || { log_fatal "openGauss 初始化标记创建失败"; return 1; }
        chown omm:omm "${OG_DATA}" \
            || { log_fatal "openGauss 数据目录属主设置失败"; return 1; }
        # 密码经 --pwfile 传递（mktemp 路径无特殊字符，su -c 单引号串安全）；
        # 须 omm 可读（gs_initdb 以 omm 运行），失败/成功路径均用后即删。
        OG_PWFILE=$(mktemp /tmp/.ogpw.XXXXXX)
        printf '%s' "${DB_PASSWORD}" > "${OG_PWFILE}" || { rm -f "${OG_PWFILE}"; log_fatal "openGauss 密码文件写入失败"; return 1; }
        chown omm:omm "${OG_PWFILE}" && chmod 600 "${OG_PWFILE}" \
            || { rm -f "${OG_PWFILE}"; log_fatal "openGauss 密码文件权限设置失败"; return 1; }
        if ! su -s /bin/bash omm -c "export GAUSSHOME=/opt/opengauss LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql LD_PRELOAD=liblapacke.so.3; /opt/opengauss/bin/gs_initdb --pgdata='${OG_DATA}' --nodename=sgnode --encoding=UTF-8 --dbcompatibility=A --pwfile='${OG_PWFILE}'"; then
            rm -f "${OG_PWFILE}"
            log_fatal "openGauss 集群初始化失败（密码需 >=8 位且含大小写/数字/特殊字符至少三类，详见任务日志），可 supervisorctl start opengauss 重试"
            return 1
        fi
        rm -f "${OG_PWFILE}"
        # 各库统一 0.0.0.0 监听 + pg_hba 全接口放行（TCP 仍内核强制密码认证，
        # 对外暴露由 compose 端口映射控制）。配置在数据目录内随卷持久化，
        # 仅新建数据目录时执行一次；直改文件离线生效，不依赖 gs_guc 运行环境。
        printf "listen_addresses = '*'\n" >> "${OG_DATA}/postgresql.conf"
        echo "host all all 0.0.0.0/0 sha256" >> "${OG_DATA}/pg_hba.conf"
        rm -f "${OG_MARKER}"
    fi
    if [ "$(stat -c %u "${OG_DATA}")" != "$(id -u omm)" ]; then
        echo "==> [openGauss] 修正数据目录属主为 omm"
        chown -R omm:omm "$(dirname "${OG_DATA}")" \
            || { log_fatal "openGauss 数据目录属主修正失败"; return 1; }
    fi
    supervisorctl_start opengauss || { log_fatal "openGauss 拉起失败"; return 1; }
    echo "==> openGauss 7.0 就绪：TCP 0.0.0.0:5433（omm + DB_PASSWORD）/ 容器内 socket 免密（gsql -p 5433 -d postgres）"
}
if [ "${ENABLE_OPENGAUSS:-0}" = "1" ]; then
    run_db og-init init_and_start_opengauss
    echo "==> [openGauss] 后台并行初始化已排队 (ENABLE_OPENGAUSS=1)，完成后自动拉起"
else
    echo "==> [openGauss] 开机自启已关闭 (默认)。需要时设 ENABLE_OPENGAUSS=1 或运行: supervisorctl start opengauss"
fi
