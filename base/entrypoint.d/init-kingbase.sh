# ==========================================
# KingbaseES V9R2 本地数据库（人大金仓；默认关闭，ENABLE_KINGBASE=1 开启；后台并行初始化）
# 安装 /opt/Kingbase/ES/Server（DEB 精简包直装，见 Dockerfile.base 尾部层），
# 数据 /var/lib/kingbase/data，端口 54321（官方默认，避让 PG 5432 / openGauss 5433）。
# 初始用户 system 的密码即统一变量 DB_PASSWORD（经 initdb --pwfile 传入，
# 与 PG/openGauss 同机制）；initdb -m oracle 取 Oracle 兼容模式（金仓最主流
# 模式，license 四种 dbmode 全开，改 -m 可换 mysql/postgresql/sqlserver）。
# 自带 180 天浮动试用授权（首次加载起算，每个新容器满额），无需单独授权文件。
# ==========================================
init_and_start_kingbase() {
    KES_DATA=/var/lib/kingbase/data
    KES_BIN=/opt/Kingbase/ES/Server/bin
    # 中断标记放数据目录之外的卷根（./kingbase:/var/lib/kingbase）：
    # initdb 拒绝非空数据目录，标记不能落在 KES_DATA 内。
    KES_MARKER=/var/lib/kingbase/.initializing
    if [ -f "${KES_MARKER}" ]; then
        echo "==> [KingbaseES] 检测到上次后台初始化未完成（残留标记），清理残缺数据重新初始化"
        KES_NEED_INIT=1
    elif [ ! -f "${KES_DATA}/PG_VERSION" ]; then
        KES_NEED_INIT=1
    else
        KES_NEED_INIT=0
    fi
    if [ "${KES_NEED_INIT}" = "1" ]; then
        echo "==> [KingbaseES] 数据目录为空，后台初始化实例 (initdb -m oracle)"
        # compose 挂载 /var/lib/kingbase 时镜像层预建的 data/ 子目录被卷遮住，
        # 须先补建再清理属主（同 openGauss 先例）
        mkdir -p "${KES_DATA}"
        find "${KES_DATA}" -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${KES_MARKER}" || { log_fatal "KingbaseES 初始化标记创建失败"; return 1; }
        chown kingbase:kingbase "${KES_DATA}" \
            || { log_fatal "KingbaseES 数据目录属主设置失败"; return 1; }
        # 密码经 --pwfile 传递（su -c 单引号串内拼密码在含单引号时会被打断，
        # 同 PG/openGauss 先例）；须 kingbase 可读，失败/成功路径均用后即删。
        # --auth-local=trust --auth-host=scram-sha-256：容器内 local socket
        # 免密（对齐 PG peer / MySQL socket / openGauss 内核免密的容器内体验），
        # TCP 一律 scram 密码认证。
        KES_PWFILE=$(mktemp /tmp/.kespw.XXXXXX)
        printf '%s' "${DB_PASSWORD}" > "${KES_PWFILE}" || { rm -f "${KES_PWFILE}"; log_fatal "KingbaseES 密码文件写入失败"; return 1; }
        chown kingbase:kingbase "${KES_PWFILE}" && chmod 600 "${KES_PWFILE}" \
            || { rm -f "${KES_PWFILE}"; log_fatal "KingbaseES 密码文件权限设置失败"; return 1; }
        if ! su -s /bin/bash kingbase -c "${KES_BIN}/initdb -D '${KES_DATA}' -U system --pwfile='${KES_PWFILE}' -E UTF8 --locale=zh_CN.UTF-8 -m oracle --auth-local=trust --auth-host=scram-sha-256"; then
            rm -f "${KES_PWFILE}"
            log_fatal "KingbaseES 实例初始化失败，详见任务日志，可 supervisorctl start kingbase 前重试"
            return 1
        fi
        rm -f "${KES_PWFILE}"
        # 各库统一 0.0.0.0 监听 + 远程连接放行（TCP 仍 scram 密码认证，对外
        # 暴露由 compose 端口映射控制）。金仓配置文件对应 postgresql.conf/
        # pg_hba.conf 的改名件：kingbase.conf / sys_hba.conf。配置在数据目录
        # 内随卷持久化，仅新建数据目录时执行一次；直改文件离线生效。
        printf "listen_addresses = '*'\nport = 54321\n" >> "${KES_DATA}/kingbase.conf"
        echo "host all all 0.0.0.0/0 scram-sha-256" >> "${KES_DATA}/sys_hba.conf"
        chown kingbase:kingbase "${KES_DATA}/kingbase.conf" "${KES_DATA}/sys_hba.conf"
        rm -f "${KES_MARKER}"
    fi
    if [ "$(stat -c %u "${KES_DATA}")" != "$(id -u kingbase)" ]; then
        echo "==> [KingbaseES] 修正数据目录属主为 kingbase"
        chown -R kingbase:kingbase "$(dirname "${KES_DATA}")" \
            || { log_fatal "KingbaseES 数据目录属主修正失败"; return 1; }
    fi
    supervisorctl_start kingbase || { log_fatal "KingbaseES 拉起失败"; return 1; }
    echo "==> KingbaseES V9R2 就绪：TCP 0.0.0.0:54321（system + DB_PASSWORD，oracle 模式）/ 容器内 socket 免密（ksql -p 54321 -U system）"
}
if [ "${ENABLE_KINGBASE:-0}" = "1" ]; then
    run_db kes-init init_and_start_kingbase
    echo "==> [KingbaseES] 后台并行初始化已排队 (ENABLE_KINGBASE=1)，完成后自动拉起"
else
    echo "==> [KingbaseES] 开机自启已关闭 (默认)。需要时设 ENABLE_KINGBASE=1 或运行: supervisorctl start kingbase"
fi
