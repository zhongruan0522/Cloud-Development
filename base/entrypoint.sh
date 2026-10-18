#!/bin/bash
set -e

# ==========================================
# OpenChamber 服务配置
# ==========================================
# 监听地址：容器场景必须 0.0.0.0 才能被端口映射访问到，默认即 0.0.0.0。
export OPENCHAMBER_HOST="${OPENCHAMBER_HOST:-0.0.0.0}"
# 必须无条件导出（可为空串）：supervisord.conf 里以 %(ENV_OPENCHAMBER_UI_PASSWORD)s
# 插值注入子进程环境，变量未定义时 supervisord 启动会直接解析报错。
export OPENCHAMBER_UI_PASSWORD="${OPENCHAMBER_UI_PASSWORD:-}"
# UI 登录密码：未设置时 OpenChamber 无密码保护浏览器访问，
# 服务绑定 0.0.0.0 对外暴露前应务必设置该变量。
if [ -n "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
    echo "==> [OpenChamber] UI password protection enabled (host=${OPENCHAMBER_HOST})"
else
    echo "==> [OpenChamber] WARNING: OPENCHAMBER_UI_PASSWORD is not set, browser UI has no authentication" >&2
fi

# ==========================================
# 持久化环境变量（供所有 shell 会话使用）
# ==========================================
cat > /etc/profile.d/opencode-env.sh <<'ENV_EOF'
# PNPM_HOME 按登录用户 HOME 展开（heredoc 引号形式构建期不展开，source 时生效）：
# 登录会话的用户级 pnpm 全局 bin——root 主账号与旧路径一致，desktop 用户落自家
# 目录。镜像预装的共享资产（openchamber）已迁 /opt/pnpm 只读共享，入口经
# /usr/local/bin 软链对所有会话可达，不依赖本 PATH；用户级 pnpm add -g 须各自
# 可写目录（/root 0700，不可指回）。前插 ${PNPM_HOME}/bin 同时修正旧 PATH 只带
# PNPM_HOME 本身、缺 bin 子目录的问题（用户自装的全局命令登录后解析不到）。
export PNPM_HOME="${HOME}/.local/share/pnpm"
export PATH="${PNPM_HOME}/bin:/usr/local/go/bin:/root/go/bin:/opt/bun/bin:/opt/cargo/bin:/opt/flutter/bin:/opt/gradle-9.0.0/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.1:/opt/apk-tools/bin:/opt/apk-tools/jadx/bin:/opt/apk-tools/dex2jar:/usr/lib/jvm/java-21-openjdk-current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GOPATH=/root/go
export BUN_INSTALL=/opt/bun
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-current
export GRADLE_HOME=/opt/gradle-9.0.0
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PLAYWRIGHT_MCP_HEADLESS=1
export PLAYWRIGHT_MCP_BROWSER=chromium
export PLAYWRIGHT_MCP_SANDBOX=0
export ELECTRON_CACHE=/opt/electron-cache
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8
export EDITOR=vim
export PIP_BREAK_SYSTEM_PACKAGES=1
# 工具自更新关闭开关与镜像 ENV 保持一致：镜像级 ENV（Dockerfile）只注入 docker
# exec/主进程链，SSH/桌面等登录 shell 经由本文件继承，二者需同步维护。
export CODEGRAPH_NO_UPDATE_CHECK=1
export HYPERFRAMES_NO_UPDATE_CHECK=1
ENV_EOF
chmod +x /etc/profile.d/opencode-env.sh

# ==========================================
# 主流程（必须 root）：两波启动，最大化并行
# 非 root 直接跳过全部初始化进 supervisord（历史兼容路径）。
#
# 第一波（同步，最小关键路径）：账号创建 → sshd 拉起（第一优先，仅依赖
#   host key 与配置文件）→ 私钥注入 → exec supervisord，openchamber/serena
#   立即开始启动。
# 第二波（后台并行子 shell，互不阻塞）：clash TUN、GitHub known_hosts 扫描、
#   桌面初始化、三数据库初始化+拉起。这些组件与主服务零依赖，旧版串行执行
#   导致首启 openchamber 要等三库初始化（10-30s×3）+ clash（最坏 ~28s）+
#   keyscan（最坏 10s）才有资格启动。
#
# 数据库初始化改运行期拉起：supervisord.conf 三库 autostart 恒为 false，
# 后台任务初始化完成后经 supervisorctl start 拉起（等待控制通道就绪）。
# ==========================================
if [ "$(id -u)" = '0' ]; then
    LOCAL_UID=${LOCAL_UID:-10001}
    LOCAL_GID=${LOCAL_GID:-$LOCAL_UID}

    # supervisord 配置路径，供下方各段落的 sed 改写使用。
    SUPERVISOR_CONF="/etc/supervisor/supervisord.conf"

    # 内置数据库三库统一密码（PG postgres / MySQL root / openGauss omm）：
    # 仅首启初始化时生效，已有数据卷不追溯（改密须进容器 ALTER USER）。
    # 默认值满足 openGauss 强制复杂度（>=8 位且大小写/数字/特殊字符至少三类，
    # 弱密码会使 openGauss 首启 gs_initdb 直接失败退出）；PG/MySQL 无强制复杂度。
    DB_PASSWORD="${DB_PASSWORD:-Opencode@123}"

    # ==========================================
    # 主账号与目录（数据家目录统一 /root）
    # RUN_USER = SSH_USER（默认 root）：openchamber/serena 的运行账号。
    # builder/final 构建期 HOME=/root，go 产物与 compose 挂载点在 /root 下，
    # 主账号会话与服务进程共用同一 HOME，登录态/agent 配置不分裂；pnpm/uv/
    # playwright 等共享工具资产已迁 /opt 系统路径（/root 0700，desktop 用户
    # 不可穿透，详见 Dockerfile.base"用户和目录"注释）。
    # ==========================================
    RUN_USER="${SSH_USER:-root}"
    SSH_PORT="${SSH_PORT:-2223}"

    # ==========================================
    # 后台任务基础设施
    # ==========================================
    # 后台任务失败出口：保持"尽早失败不兜底"语义——FATAL 日志 + 终止 PID 1
    # 使容器退出，docker logs 即见原因。ENTRYPOINT 为 tini 链，PID 1 是
    # tini（转发 TERM 给子进程 supervisord 优雅停机）；docker restart 策略下
    # 的重启重试行为与旧同步路径 exit 1 一致，仅失败时点从 entrypoint 阻塞期
    # 移到启动后数秒。
    # 竞态防护：supervisord 启动窗口（约 1s）内到达的 TERM 会被内核丢弃
    # （PID 1 对未注册处置信号的默认保护，实测 stub 初始化瞬时失败时容器
    # 不退出），故 TERM 立即发一次后，每 2s 交替重发 TERM + supervisorctl
    # shutdown（控制通道就绪即生效），确保无论失败时序如何容器都会退出。
    fail_container() {
        echo "==> [FATAL] ${1}，终止容器以暴露问题" >&2
        local i
        kill -TERM 1 2>/dev/null || true
        for i in $(seq 1 30); do
            supervisorctl -c /etc/supervisor/supervisord.conf shutdown >/dev/null 2>&1 && break
            kill -TERM 1 2>/dev/null || true
            sleep 2
        done
        exit 1
    }

    # 等待 supervisord 控制通道就绪后拉起服务（exec 后 socket 需片刻出现）。
    # supervisorctl start 返回 0 表示进程已通过 startsecs 存活判定。
    supervisorctl_start() {
        local prog="$1" i err=""
        for i in $(seq 1 60); do
            if err="$(supervisorctl -c /etc/supervisor/supervisord.conf start "${prog}" 2>&1)"; then
                echo "==> [${prog}] 已由后台初始化任务拉起"
                return 0
            fi
            sleep 1
        done
        echo "==> [${prog}] supervisorctl start 失败：${err}" >&2
        return 1
    }

    # 后台任务带标签前缀运行：并行任务的 stdout/stderr 汇入容器同一输出流，
    # initdb×3 + supervisord + dockerd 行级交错无法区分归属（实测首启日志中
    # PG 中文 initdb 输出与 openGauss 英文输出逐段穿插、进度行被劈断成孤立
    # 残段如"128MB"，极易误判为初始化错乱）。sed -u 无缓冲保证实时性；任务
    # 子 shell 退出后管道 EOF，sed 随之退出（同样被 supervisord 收养收割，与
    # 任务子 shell 本身的 "reaped unknown pid" 噪音同源，不新增噪音类型）。
    # exec 2>&1 使 stderr 同样带标签——initdb/mysqld 的警告大多走 stderr。
    run_bg() {
        local tag="$1"
        shift
        (
            exec > >(sed -u "s/^/[${tag}] /") 2>&1
            "$@"
        ) &
    }

    # 主账号创建（uid/gid 取 LOCAL_UID/LOCAL_GID；主组 opencode 保留 docker 组继承）
    if [ "$RUN_USER" != "root" ]; then
        if ! id -u "$RUN_USER" >/dev/null 2>&1; then
            echo "==> [User] Creating primary user '$RUN_USER' (uid=${LOCAL_UID}, home=/root)"
            useradd --home-dir /root --non-unique --uid "$LOCAL_UID" \
                --gid "$LOCAL_GID" --shell /bin/bash -M "$RUN_USER"
            # docker 组（DinD）成员身份：root 天然可用 docker CLI，普通用户需显式加入
            if getent group docker >/dev/null 2>&1; then
                usermod -aG docker "$RUN_USER"
            fi
        fi
        # home 契约：主账号家目录固定 /root（数据路径不随账号名变化）
        [ "$(getent passwd "$RUN_USER" | cut -d: -f6)" = "/root" ] \
            || { echo "FATAL: home of '$RUN_USER' must be /root (got $(getent passwd "$RUN_USER" | cut -d: -f6))" >&2; exit 1; }
        # /root/.ssh（含 GITHUB_SSH_KEY 注入的 id_rsa）归主账号所有，
        # SSH 密钥与 git push 等用户态操作依赖该属主关系
        chown -R "$RUN_USER:$(id -gn "$RUN_USER")" /root/.ssh 2>/dev/null || true
        # uid/gid 校正（如挂载卷属主与 LOCAL_UID 不一致）
        if [ "$(id -u "$RUN_USER")" != "$LOCAL_UID" ] || [ "$(id -g "$RUN_USER")" != "$LOCAL_GID" ]; then
            echo "Adjusting $RUN_USER to uid=$LOCAL_UID, gid=$LOCAL_GID"
            groupmod -o -g "$LOCAL_GID" "$RUN_USER"
            usermod -o -u "$LOCAL_UID" -g "$LOCAL_GID" "$RUN_USER"
            chown -R "$RUN_USER:$(id -gn "$RUN_USER")" /root /workspace 2>/dev/null || true
        elif [ "$(stat -c %U /root 2>/dev/null)" != "$RUN_USER" ]; then
            chown -R "$RUN_USER:$(id -gn "$RUN_USER")" /root /workspace 2>/dev/null || true
        fi
    fi
    # RUN_USER=root 时目录属主本就是 root，无需处理。

    # --- supervisord 以 SSH_USER 运行主服务（root 或普通用户均合法；
    #     声明 user= 后 setuid(0) 为空操作，即服务可直接以 root 跑）---
    sed -i "s/^user=app$/user=${RUN_USER}/" "$SUPERVISOR_CONF"
    sed -i "s/USER=\"app\"/USER=\"${RUN_USER}\"/g" "$SUPERVISOR_CONF"

    # --- SSH 端口 / 密码认证 ---
    # 密码认证开关：设置 SSH_PASSWORD 即启用（公钥认证始终并存），未设置则维持仅公钥。
    if [ -n "${SSH_PASSWORD:-}" ]; then
        if [ "$RUN_USER" = "root" ]; then
            echo "root:${SSH_PASSWORD}" | chpasswd
        else
            echo "${RUN_USER}:${SSH_PASSWORD}" | chpasswd
        fi
        PASSWORD_AUTH=yes
        PASSWORD_AUTH_NOTE=" + 密码认证"
        echo "==> [SSH] 密码认证已启用（用户 ${RUN_USER}，来自 SSH_PASSWORD）"
    else
        PASSWORD_AUTH=no
        PASSWORD_AUTH_NOTE=""
        echo "==> [SSH] 密码认证未启用（设置 SSH_PASSWORD 以开启；公钥认证始终可用）"
    fi

    # ==========================================
    # SSH Server 初始化【第一波：sshd 第一优先拉起】
    # sshd 仅依赖 host key 与配置文件，不等 clash/keyscan/桌面/数据库。
    # 公钥可选（宿主机公钥挂载到 /root/.ssh/authorized_keys 即启用），
    # 密码认证见上方 SSH_PASSWORD。
    # sshd 需要 root 权限（绑定端口 + PAM 认证），不放进 supervisord。
    # ==========================================
    mkdir -p /run/sshd /etc/ssh/sshd_config.d

    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N '' -q
    fi
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -t rsa -b 4096 -f /etc/ssh/ssh_host_rsa_key -N '' -q
    fi

    # 强制修正 host key 权限：容器重启或某些挂载场景会导致权限变宽（如 0777），
    # sshd 会拒绝使用过宽权限的私钥，导致公钥认证失效。
    # 覆盖全部可能的 host key 类型，避免 sshd 因 ecdsa/dsa key 权限过宽告警。
    chmod 600 /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_dsa_key 2>/dev/null || true
    chmod 644 /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_dsa_key.pub 2>/dev/null || true

    cat > /etc/ssh/sshd_config.d/opencode.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication ${PASSWORD_AUTH}
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
EOF

    # 多用户场景公钥分发：同一份 authorized_keys（宿主机 :ro 挂载，唯一真相源）。
    # - root：家即 /root，直接读挂载点本体；
    # - 非 root 主账号：家也是 /root，与 root 同路径但挂载文件属 root:root 600，
    #   StrictModes 会拒绝用户读取他人属主的 keys 文件 → 复制为 .user 副本
    #   （属主改为该用户），并用 sshd Match 块把该用户的 AuthorizedKeysFile
    #   指向副本。不能用 >>（追加，重启会叠加），必须 cp 覆盖保证幂等。
    # - 桌面用户：家目录独立（/home/desktop），直接复制分发到其 .ssh 下。
    # 挂载文件不存在时跳过公钥分发（密码认证仍可用），不阻塞启动。
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        chmod 700 /root/.ssh
        # :ro 挂载文件 chmod 会 EPERM，属主/权限本就由宿主保证，失败不阻塞启动。
        chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true

        if [ "$RUN_USER" != "root" ]; then
            cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.user
            chown "$RUN_USER:$(id -gn "$RUN_USER")" /root/.ssh/authorized_keys.user
            chmod 600 /root/.ssh/authorized_keys.user
            cat >> /etc/ssh/sshd_config.d/opencode.conf <<EOF
Match User ${RUN_USER}
    AuthorizedKeysFile /root/.ssh/authorized_keys.user
EOF
        fi

        # 桌面用户公钥分发（用户名可能已被 DESKTOP_USER 改名，按名查找）
        if [ -n "${DESKTOP_USER:-}" ] && id "$DESKTOP_USER" >/dev/null 2>&1; then
            DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
            mkdir -p "${DESKTOP_HOME}/.ssh"
            cp /root/.ssh/authorized_keys "${DESKTOP_HOME}/.ssh/authorized_keys"
            chmod 700 "${DESKTOP_HOME}/.ssh"
            chmod 600 "${DESKTOP_HOME}/.ssh/authorized_keys"
            chown -R "$DESKTOP_USER:$DESKTOP_USER" "${DESKTOP_HOME}/.ssh"
        fi
    else
        echo "==> [SSH] 未挂载 authorized_keys，仅密码/密钥外认证可用（设置 SSH_PASSWORD 启用密码登录）"
    fi

    /usr/sbin/sshd
    echo "==> [SSH] SSH Server 已启动，端口 ${SSH_PORT}，用户 root/${RUN_USER}${DESKTOP_USER:+/${DESKTOP_USER}}，公钥认证${PASSWORD_AUTH_NOTE}"

    # ==========================================
    # GitHub SSH 私钥注入（同步，瞬时）+ known_hosts 扫描（后台并行）
    # ==========================================
    # gh 已不再通过 GITHUB_TOKEN 环境变量自动登录（历史方案已移除：
    # 环境变量登录在实际使用中不稳定）。认证改走持久化配置卷：
    # 首次使用时手动执行 `gh auth login`，凭据落在 ~/.config/gh
    # （compose 已挂载 ./.config/gh 卷），容器重建后依然保持登录态。
    # gh CLI 本体仍预装在 base 层，可正常使用。
    if [ -n "$GITHUB_SSH_KEY" ]; then
        echo "Configuring GitHub SSH key..."
        mkdir -p /root/.ssh
        echo "$GITHUB_SSH_KEY" | base64 -d > /root/.ssh/id_rsa
        chmod 600 /root/.ssh/id_rsa
        # 非 root 主账号：上方账号块已 chown 过 /root/.ssh，此处对齐新写入文件的属主
        if [ "$RUN_USER" != "root" ]; then
            chown "$RUN_USER:$(id -gn "$RUN_USER")" /root/.ssh/id_rsa
        fi
        # known_hosts 扫描（网络 IO，最坏 10s）后台化：仅影响 git over SSH
        # 首次推送的 host 校验，不阻塞任何服务启动。
        bg_github_keyscan() {
            GITHUB_SSH_KEYSCAN_TIMEOUT="${GITHUB_SSH_KEYSCAN_TIMEOUT:-10s}"
            if ! timeout "$GITHUB_SSH_KEYSCAN_TIMEOUT" ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null; then
                echo "GitHub SSH known_hosts scan failed or timed out after ${GITHUB_SSH_KEYSCAN_TIMEOUT}; continuing startup." >&2
            fi
            if [ "$RUN_USER" != "root" ]; then
                chown "$RUN_USER:$(id -gn "$RUN_USER")" /root/.ssh/known_hosts 2>/dev/null || true
            fi
            echo "==> [GitHub] known_hosts 扫描完成（后台任务）"
        }
        run_bg github-keyscan bg_github_keyscan
    fi

    # ==========================================
    # mihomo (Clash) TUN 模式初始化（可选，通过 ENABLE_CLASH=1 开启，后台并行）
    # TUN 就绪前主服务若已发起出站请求会走直连，TUN 接管后新建连接自动切换
    # 代理；与下方"初始化失败照样启动"的既有容错语义一致，不为此阻塞主服务。
    # ==========================================
    if [ "${ENABLE_CLASH:-0}" = "1" ]; then
        bg_init_clash() {
            if /usr/local/bin/init-clash.sh; then
                echo "==> [Clash] TUN 模式已接管所有出站流量，无需代理环境变量"
            else
                echo "==> [Clash] WARNING: mihomo 初始化失败，跳过代理注入并继续启动主服务" >&2
            fi
        }
        run_bg clash-init bg_init_clash
    else
        echo "==> [Clash] mihomo 未启用 (设置 ENABLE_CLASH=1 以启用)"
    fi

    # ==========================================
    # 远程桌面 (xrdp) 初始化（可选，通过 ENABLE_DESKTOP=1 开启，后台并行）
    # xrdp/dbus 与 supervisord 托管服务零依赖。
    # xrdp 需要 root 权限（绑定端口 + PAM 认证），不能放进 supervisord。
    # 容器内无 systemd，必须手动启动 xrdp-sesman（会话管理器）和 xrdp（RDP 守护进程）
    # 同时手动拉起系统 D-Bus（xfce4-polkit / udisks2 / Thunar 挂载都依赖它）
    # 默认桌面：XFCE4（xfwm4 窗口管理器 + xfce4-panel 任务栏 + xfdesktop 桌面图标）
    # 中文输入法：fcitx5；端口：3390
    # 登录用户：
    #   - DESKTOP_USER（默认 desktop）：独立普通权限账号，可 sudo。密码优先级：
    #       DESKTOP_USER_PASSWORD > DESKTOP_PASSWORD（复用）> 都空则无密码登录
    #   - 主账号（SSH_USER）：由 ALLOW_APP_DESKTOP 控制（1 允许 / 0 禁用），默认 1
    #     密码通过 DESKTOP_PASSWORD 设置（默认 "app"）
    # 与 clash/keyscan 的软失败不同：旧版桌面初始化失败会随 entrypoint（set -e）
    # 直接终止容器，此处保留同一硬失败语义（fail_container）。
    # ==========================================
    if [ "${ENABLE_DESKTOP:-1}" = "1" ]; then
        bg_init_desktop() {
            if [ -x /usr/local/bin/init-desktop.sh ]; then
                /usr/local/bin/init-desktop.sh || fail_container "桌面初始化失败（详见上方 init-desktop.sh 输出）"
            else
                echo "==> [Desktop] 当前为 slim 镜像（NoDesktop-Base，不含远程桌面），已跳过桌面初始化；如需 RDP 请使用 -desktop 后缀镜像"
            fi
        }
        run_bg desktop-init bg_init_desktop
    else
        echo "==> [Desktop] 远程桌面已禁用 (ENABLE_DESKTOP=${ENABLE_DESKTOP})"
    fi

    # ==========================================
    # PostgreSQL 17 本地数据库（默认关闭，ENABLE_PG=1 开启；后台并行初始化）
    # 集群初始化改在后台子 shell 进行：openchamber/serena 等主服务先行启动，
    # 初始化完成后经 supervisorctl 运行期拉起（supervisord.conf 恒 autostart=false，
    # 不再由 entrypoint sed 翻转）。
    # 与 clash/dockerd 的软失败不同：用户显式设了 ENABLE_PG=1 而初始化失败时
    # fail_container 终止容器让 docker logs 即见原因——尽早失败，不做兜底掩盖。
    # 检测判据 PG_VERSION（initdb 产物）对"镜像留空数据目录 / 挂空卷 / 挂已有
    # 数据卷"三场景统一且幂等（docker restart 重跑本脚本时判据文件已在即跳过，
    # 绝不重复初始化）。
    # 初始化中断恢复：后台 init 期间容器被停止会留下残缺数据目录，而 PG_VERSION
    # 由 initdb 早期写入、不能代表初始化完成——以 .initializing 标记识别（放数据
    # 目录之外的卷根：initdb 拒绝非空数据目录），见标记即强制清理重初始化。
    # 密码：postgres 超级用户密码由统一变量 DB_PASSWORD 在首启初始化时经
    # initdb --pwfile 写入（PG17 默认 scram-sha-256 存储，与官方 postgres 镜像
    # POSTGRES_PASSWORD 同机制）。
    # 认证：local socket 一律 trust（容器内 CLI 免密，官方 postgres 镜像同款）；
    # TCP 一律 scram-sha-256（连接须带密码；监听 0.0.0.0 + pg_hba 全接口放行行，
    # 对外暴露由 compose 端口映射控制）。
    # 容器内连接：psql -U postgres（socket 免密）；
    # PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U postgres（TCP）。
    # 运行中随时可手动拉起：supervisorctl start postgresql
    # ==========================================
    init_and_start_postgresql() {
        PG_DATA="/var/lib/postgresql/17/main"
        PG_CONF="/etc/postgresql/17/main"
        # 中断标记放数据目录之外的卷根（./postgres:/var/lib/postgresql）：
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
            touch "${PG_MARKER}" || fail_container "PostgreSQL 初始化标记创建失败"
            # pg_createcluster 拒绝已存在的配置目录（"cluster configuration already exists"）；
            # 该目录在镜像层且内容为包默认配置，删除重建安全。
            # 不带 --start：默认只创建不启动（--start 是布尔开关，无 =no 写法）。
            # " -- " 之后透传 initdb 参数：--pwfile 把 DB_PASSWORD 设为 postgres
            # 超级用户密码。密码文件须 postgres 可读（pg_createcluster 以 postgres
            # 跑 initdb），用后即删；DB_PASSWORD 含单引号等字符时无需转义（文件原样）。
            rm -rf "${PG_CONF}"
            PG_PWFILE=$(mktemp /tmp/.pgpw.XXXXXX)
            printf '%s' "${DB_PASSWORD}" > "${PG_PWFILE}" || fail_container "PostgreSQL 密码文件写入失败"
            chown postgres:postgres "${PG_PWFILE}"
            chmod 600 "${PG_PWFILE}"
            if ! pg_createcluster 17 main -- --pwfile="${PG_PWFILE}"; then
                rm -f "${PG_PWFILE}"
                fail_container "PostgreSQL 集群初始化失败（详见上方 pg_createcluster 输出）"
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
        # 三库统一 0.0.0.0 监听：对外暴露由 compose 端口映射控制（默认不发布端口）。
        # pg_conftool 幂等写 listen_addresses；pg_hba 追加全接口放行行（grep 幂等，
        # loopback 默认行在前首条命中，优先级不受影响；远程连接仍须 DB_PASSWORD）。
        pg_conftool 17 main set listen_addresses '*'
        grep -q '^host all all all scram-sha-256$' "${PG_CONF}/pg_hba.conf" \
            || echo 'host all all all scram-sha-256' >> "${PG_CONF}/pg_hba.conf"
        # 挂载卷属主对齐：仅 uid 不符才递归 chown（大卷无条件遍历会拖垮启动时序，
        # 与上方主账号 uid 校正块同策略）
        if [ "$(stat -c %u "${PG_DATA}")" != "$(id -u postgres)" ]; then
            echo "==> [PostgreSQL] 修正数据目录属主为 postgres"
            chown -R postgres:postgres "$(dirname "${PG_DATA}")" "${PG_CONF}" \
                || fail_container "PostgreSQL 数据目录属主修正失败"
        fi
        mkdir -p /var/run/postgresql && chown postgres:postgres /var/run/postgresql
        supervisorctl_start postgresql || fail_container "PostgreSQL 拉起失败"
    }
    if [ "${ENABLE_PG:-0}" = "1" ]; then
        run_bg pg-init init_and_start_postgresql
        echo "==> [PostgreSQL] 后台并行初始化已排队 (ENABLE_PG=1)，完成后自动拉起"
    else
        echo "==> [PostgreSQL] 开机自启已关闭 (默认)。需要时设 ENABLE_PG=1 或运行: supervisorctl start postgresql"
    fi

    # ==========================================
    # MySQL 8.4 本地数据库（默认关闭，ENABLE_MYSQL=1 开启；后台并行初始化）
    # 同上：初始化失败 fail_container 终止容器，尽早失败不兜底；检测判据为
    # 系统库目录 mysql/。
    # root 密码由统一变量 DB_PASSWORD 经官方 docker 镜像同款流程写入：
    # --initialize-insecure 建空密码 root -> 拉起 skip-networking 临时实例
    # （独享 socket）-> ALTER USER root@localhost 设密 + 建 root@'%'（远程 TCP 用，
    #   同密码全权限；root@localhost 仅回环，双账号并存与官方镜像一致）
    # -> 干净关停 -> 交 supervisord 正式拉起。
    # （不走 --init-file 捷径：官方文档明确 --initialize 引导模式不支持
    #   CREATE USER/GRANT 等账户管理语句。）
    # 首启合计约 10-30s（后台并行进行，不阻塞主服务）。仅首启生效，已有数据卷不追溯。
    # 容器内连接：mysql -u root -p（socket/TCP 同一密码，DB_PASSWORD；
    # 默认认证插件 caching_sha2_password，PyMySQL 需 cryptography，镜像已内置）。
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
            touch "${MYSQL_MARKER}" || fail_container "MySQL 初始化标记创建失败"
            chown mysql:mysql "${MYSQL_DATA}"
            if ! mysqld --initialize-insecure --user=mysql; then
                fail_container "MySQL 初始化失败（详见上方 mysqld 输出）"
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
                echo "==> [MySQL] FATAL: root 密码设置失败，临时实例日志如下，终止容器以暴露问题" >&2
                cat /tmp/mysql-init.log >&2
                fail_container "MySQL root 密码设置失败"
            fi
            if ! mysqladmin --socket="${MYSQL_INIT_SOCK}" -u root -p"${DB_PASSWORD}" shutdown; then
                echo "==> [MySQL] FATAL: 临时实例关停失败" >&2
                fail_container "MySQL 临时实例关停失败"
            fi
            rm -f "${MYSQL_MARKER}"
        fi
        if [ "$(stat -c %u "${MYSQL_DATA}")" != "$(id -u mysql)" ]; then
            echo "==> [MySQL] 修正数据目录属主为 mysql"
            chown -R mysql:mysql "${MYSQL_DATA}" \
                || fail_container "MySQL 数据目录属主修正失败"
        fi
        mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld
        supervisorctl_start mysql || fail_container "MySQL 拉起失败"
    }
    if [ "${ENABLE_MYSQL:-0}" = "1" ]; then
        run_bg mysql-init init_and_start_mysql
        echo "==> [MySQL] 后台并行初始化已排队 (ENABLE_MYSQL=1)，完成后自动拉起"
    else
        echo "==> [MySQL] 开机自启已关闭 (默认)。需要时设 ENABLE_MYSQL=1 或运行: supervisorctl start mysql"
    fi

    # ==========================================
    # openGauss 7.0.0 本地数据库（默认关闭，ENABLE_OPENGAUSS=1 开启；后台并行初始化）
    # 华为 GaussDB 企业版无公开安装包，免费可得的最完整版本即开源 openGauss 7.0.0 LTS。
    # 同上：初始化失败 fail_container 终止容器，尽早失败不兜底；检测判据为数据目录
    # PG_VERSION（gs_initdb 产物），对"镜像留空 / 挂空卷 / 挂已有数据卷"三场景统一
    # 且幂等。初始化中断恢复：.initializing 标记放数据目录之外的卷根（gs_initdb
    # 拒绝非空数据目录），残留即强制清理重初始化。
    # 密码：openGauss 内核强制 TCP 连接一律密码认证（pg_hba trust 不豁免，实测），
    # 初始用户 omm 的密码即三库统一变量 DB_PASSWORD（经 gs_initdb --pwfile 传入，
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
            || fail_container "openGauss 日志目录属主设置失败"
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
            touch "${OG_MARKER}" || fail_container "openGauss 初始化标记创建失败"
            chown omm:omm "${OG_DATA}" \
                || fail_container "openGauss 数据目录属主设置失败"
            # 密码经 --pwfile 传递（mktemp 路径无特殊字符，su -c 单引号串安全）；
            # 须 omm 可读（gs_initdb 以 omm 运行），失败/成功路径均用后即删。
            OG_PWFILE=$(mktemp /tmp/.ogpw.XXXXXX)
            printf '%s' "${DB_PASSWORD}" > "${OG_PWFILE}" || fail_container "openGauss 密码文件写入失败"
            chown omm:omm "${OG_PWFILE}" && chmod 600 "${OG_PWFILE}" \
                || fail_container "openGauss 密码文件权限设置失败"
            if ! su -s /bin/bash omm -c "export GAUSSHOME=/opt/opengauss LD_LIBRARY_PATH=/opt/opengauss/lib:/opt/opengauss/lib/postgresql LD_PRELOAD=liblapacke.so.3; /opt/opengauss/bin/gs_initdb --pgdata='${OG_DATA}' --nodename=sgnode --encoding=UTF-8 --dbcompatibility=A --pwfile='${OG_PWFILE}'"; then
                rm -f "${OG_PWFILE}"
                fail_container "openGauss 集群初始化失败（密码需 >=8 位且含大小写/数字/特殊字符至少三类，详见上方 gs_initdb 输出）"
            fi
            rm -f "${OG_PWFILE}"
            # 三库统一 0.0.0.0 监听 + pg_hba 全接口放行（TCP 仍内核强制密码认证，
            # 对外暴露由 compose 端口映射控制）。配置在数据目录内随卷持久化，
            # 仅新建数据目录时执行一次；直改文件离线生效，不依赖 gs_guc 运行环境。
            printf "listen_addresses = '*'\n" >> "${OG_DATA}/postgresql.conf"
            echo "host all all 0.0.0.0/0 sha256" >> "${OG_DATA}/pg_hba.conf"
            rm -f "${OG_MARKER}"
        fi
        if [ "$(stat -c %u "${OG_DATA}")" != "$(id -u omm)" ]; then
            echo "==> [openGauss] 修正数据目录属主为 omm"
            chown -R omm:omm "$(dirname "${OG_DATA}")" \
                || fail_container "openGauss 数据目录属主修正失败"
        fi
        supervisorctl_start opengauss || fail_container "openGauss 拉起失败"
    }
    if [ "${ENABLE_OPENGAUSS:-0}" = "1" ]; then
        run_bg og-init init_and_start_opengauss
        echo "==> [openGauss] 后台并行初始化已排队 (ENABLE_OPENGAUSS=1)，完成后自动拉起"
    else
        echo "==> [openGauss] 开机自启已关闭 (默认)。需要时设 ENABLE_OPENGAUSS=1 或运行: supervisorctl start opengauss"
    fi

    # ==========================================
    # DinD dockerd 开关（默认关闭以节省内存）
    # supervisord.conf 里 dockerd 默认 autostart=false，
    # 这里根据 ENABLE_DOCKERD 决定是否改为自启。
    # 运行中随时可手动拉起：supervisorctl start dockerd
    # ==========================================
    if [ "${ENABLE_DOCKERD:-0}" = "1" ]; then
        sed -i '/^\[program:dockerd\]/,/^\[/ s/^autostart=false/autostart=true/' "$SUPERVISOR_CONF"
        echo "==> [DockerD] 开机自启已启用 (ENABLE_DOCKERD=1)"
    else
        echo "==> [DockerD] 开机自启已关闭 (默认)。需要时运行: supervisorctl start dockerd"
    fi

    # ==========================================
    # supervisord 自身以 root 运行（声明 user=root 消除 CRIT 告警；
    # 非 root 环境下声明会因无法 setuid(0) 直接拒绝启动，实测
    # "Can't drop privilege as nonroot user"，故仅 root 分支注入）。
    # [program:x] 的 user= 由上方按 SSH_USER 替换，与本行互不影响。
    # docker restart 会重跑本脚本，必须先判重保证幂等。
    # ==========================================
    grep -q '^user=root' "$SUPERVISOR_CONF" || sed -i '/^\[supervisord\]/a user=root' "$SUPERVISOR_CONF"

    # 第一波收尾：立即 exec supervisord 拉起 openchamber/serena；
    # 上方各后台任务（clash/keyscan/桌面/三库，输出经 run_bg 打标签）随之收养为
    # supervisord 子进程继续并行运行（容器停止时由 cgroup 级联清理，残留初始化
    # 标记由下次启动的判据逻辑恢复；sed 前缀进程随任务 EOF 退出，同被 reap）。
    exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
