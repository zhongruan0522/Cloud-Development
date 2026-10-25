# ==========================================
# 达梦 DM8 本地数据库（默认关闭，ENABLE_DM=1 开启；后台并行初始化）
# 安装 /opt/dmdbms（Dockerfile.base 尾部层经强装补丁安装——此 20260817
# 构建的二进制含无条件 AVX-512 指令，CI 跑机无 AVX-512 时安装器探针
# SIGILL，详见 Dockerfile.base 注释），数据 /var/lib/dm8/data/DAMENG
# （dminit 按 DB_NAME 建库目录），端口 5236（官方默认，避让 PG 5432 /
# openGauss 5433 / KingbaseES 54321）。
# 密码：SYSDBA 与 SYSAUDITOR（达梦强制并存的审计员账号）均取五库统一变量
# DB_PASSWORD，经 dminit 命令行参数写入。达梦 dminit 无 --pwfile 等价物，
# 改用 runuser 直传 argv（不经中间 shell 二次求值，密码含单引号等任意字符
# 安全，对比 PG/openGauss/金仓的 pwfile 方案）。密码须满足达梦复杂度
# （8-48 位且含大写/小写/数字），弱密码 dminit 直接失败退出（尽早失败）。
# 初始化参数对齐官方 Docker 镜像常用值：PAGE_SIZE=16 / EXTENT_SIZE=32 /
# CHARSET=1（UTF-8）/ CASE_SENSITIVE=Y（默认，Oracle 迁移主流形态）；
# LOG_SIZE=256 取下限（缺省 4096×2 个日志文件会预写 8G，开发容器不必要）。
# PAGE_SIZE/CHARSET/CASE_SENSITIVE 仅初始化时生效，建库后不可改。
# 监听：dmserver 默认即监听 *:5236（dm.ini 无需放开，已实测），对外暴露由
# compose 端口映射控制；达梦无 local socket 免密通道，TCP 一律密码认证。
# 容器内连接：disql 'SYSDBA/"$DB_PASSWORD"@localhost:5236'（连接串里密码
# 含 @ 等字符时须整体双引号括起，disql 语义）。
# 检测判据 dm.ctl（dminit 产物；写入早于初始化完成，中断残留由
# .initializing 标记识别强制重初始化，同四库先例。标记放数据目录之外的
# 卷根 ./dm8:/var/lib/dm8——dminit 要求 PATH 目录为空）。
# 授权：内置试用授权随构建滚动（20260817 构建 2027-07-07 到期），到期前
# 换新镜像即可；正式授权时将 dm.key 挂载覆盖 /opt/dmdbms/bin/dm.key。
# 运行中随时可手动拉起：supervisorctl start dm
# ==========================================
init_and_start_dm() {
    # AVX-512 运行时门禁：此 DM8 构建（20260817）的 libdmdpi.so 含无条件
    # AVX-512 指令（vcvtusi2sd，达梦社区 GDB 定位，同款介质在 GHA 跑机与
    # 无 AVX-512 的桌面 CPU 上均复现 SIGILL），不支持 AVX-512 的 CPU 上
    # dmserver/dminit/disql 一律 core dump。尽早明确报错，不留给神秘 132。
    if ! grep -qw avx512f /proc/cpuinfo; then
        log_fatal "DM8 当前构建要求 AVX-512 指令集，当前 CPU 不支持（需换用非 AVX-512 的达梦介质构建）"
        return 1
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
        # compose 挂载 /var/lib/dm8 时镜像层预建的 data/ 子目录被卷遮住，
        # 须先补建再清理属主（同 openGauss/KingbaseES 先例）
        mkdir -p /var/lib/dm8/data
        find /var/lib/dm8/data -mindepth 1 -delete 2>/dev/null || true
        # 标记在 wipe 之后写入（避免被 find 清掉），成功后移除
        touch "${DM_MARKER}" || { log_fatal "DM8 初始化标记创建失败"; return 1; }
        chown -R dmdba:dmdba /var/lib/dm8 \
            || { log_fatal "DM8 数据目录属主设置失败"; return 1; }
        if ! runuser -u dmdba -- /opt/dmdbms/bin/dminit \
                PATH=/var/lib/dm8/data PAGE_SIZE=16 EXTENT_SIZE=32 LOG_SIZE=256 \
                CHARSET=1 CASE_SENSITIVE=Y PORT_NUM=5236 \
                SYSDBA_PWD="${DB_PASSWORD}" SYSAUDITOR_PWD="${DB_PASSWORD}"; then
            log_fatal "DM8 实例初始化失败（密码需 8-48 位且含大写/小写/数字，详见任务日志），可 supervisorctl start dm 重试"
            return 1
        fi
        rm -f "${DM_MARKER}"
    fi
    if [ "$(stat -c %u /var/lib/dm8)" != "$(id -u dmdba)" ]; then
        echo "==> [DM8] 修正数据目录属主为 dmdba"
        chown -R dmdba:dmdba /var/lib/dm8 \
            || { log_fatal "DM8 数据目录属主修正失败"; return 1; }
    fi
    supervisorctl_start dm || { log_fatal "DM8 拉起失败"; return 1; }
    echo "==> DM8 就绪：TCP 0.0.0.0:5236（SYSDBA + DB_PASSWORD）/ 容器内连接 disql SYSDBA/密码@localhost:5236（密码含特殊字符时整体加双引号）"
}
if [ "${ENABLE_DM:-0}" = "1" ]; then
    run_db dm-init init_and_start_dm
    echo "==> [DM8] 后台并行初始化已排队 (ENABLE_DM=1)，完成后自动拉起"
else
    echo "==> [DM8] 开机自启已关闭 (默认)。需要时设 ENABLE_DM=1 或运行: supervisorctl start dm"
fi
