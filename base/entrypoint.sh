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
# mihomo (Clash) TUN 模式初始化（可选，通过 ENABLE_CLASH=1 开启）
# ==========================================
if [ "${ENABLE_CLASH:-0}" = "1" ]; then
    if /usr/local/bin/init-clash.sh; then
        echo "==> [Clash] TUN 模式已接管所有出站流量，无需代理环境变量"
    else
        echo "==> [Clash] WARNING: mihomo 初始化失败，跳过代理注入并继续启动主服务" >&2
    fi
else
    echo "==> [Clash] mihomo 未启用 (设置 ENABLE_CLASH=1 以启用)"
fi

# ==========================================
# GitHub CLI 配置
# ==========================================
# gh 已不再通过 GITHUB_TOKEN 环境变量自动登录（历史方案已移除：
# 环境变量登录在实际使用中不稳定）。认证改走持久化配置卷：
# 首次使用时手动执行 `gh auth login`，凭据落在 ~/.config/gh
# （compose 已挂载 ./.config/gh 卷），容器重建后依然保持登录态。
# gh CLI 本体仍预装在 base 层，可正常使用。

if [ -n "$GITHUB_SSH_KEY" ]; then
    echo "Configuring GitHub SSH key..."
    mkdir -p /home/app/.ssh
    echo "$GITHUB_SSH_KEY" | base64 -d > /home/app/.ssh/id_rsa
    chmod 600 /home/app/.ssh/id_rsa
    GITHUB_SSH_KEYSCAN_TIMEOUT="${GITHUB_SSH_KEYSCAN_TIMEOUT:-10s}"
    if ! timeout "$GITHUB_SSH_KEYSCAN_TIMEOUT" ssh-keyscan github.com >> /home/app/.ssh/known_hosts 2>/dev/null; then
        echo "GitHub SSH known_hosts scan failed or timed out after ${GITHUB_SSH_KEYSCAN_TIMEOUT}; continuing startup." >&2
    fi
    # SSH 服务公钥的属主由下方 SSH 初始化段按 RUN_USER 修正，此处不重复 chown。
    echo "GitHub SSH key configured."
fi

# ==========================================
# 持久化环境变量（供所有 shell 会话使用）
# ==========================================
cat > /etc/profile.d/opencode-env.sh <<'ENV_EOF'
export PNPM_HOME=/home/app/.local/share/pnpm
export PATH=/usr/local/go/bin:/home/app/go/bin:/opt/bun/bin:/opt/cargo/bin:/opt/flutter/bin:/opt/gradle-9.0.0/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/build-tools/35.0.1:/opt/apk-tools/bin:/opt/apk-tools/jadx/bin:/opt/apk-tools/dex2jar:/usr/lib/jvm/java-21-openjdk-current/bin:/home/app/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GOPATH=/home/app/go
export BUN_INSTALL=/opt/bun
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-current
export GRADLE_HOME=/opt/gradle-9.0.0
export PLAYWRIGHT_BROWSERS_PATH=/home/app/.cache/ms-playwright
export PLAYWRIGHT_MCP_HEADLESS=1
export PLAYWRIGHT_MCP_BROWSER=chrome
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
# 主流程（必须 root）：账号创建、SSH/桌面初始化、supervisord 托管多服务
# 非 root 直接跳过全部初始化进 supervisord（历史兼容路径）。
# ==========================================
if [ "$(id -u)" = '0' ]; then
    LOCAL_UID=${LOCAL_UID:-10001}
    LOCAL_GID=${LOCAL_GID:-$LOCAL_UID}

    # supervisord 配置路径，供下方各段落的 sed 改写使用。
    SUPERVISOR_CONF="/etc/supervisor/supervisord.conf"

    # ==========================================
    # 主账号与目录属主（家目录固定 /home/app，与账号名解耦）
    # RUN_USER = SSH_USER（默认 root）：openchamber/serena 的运行账号。
    # ==========================================
    RUN_USER="${SSH_USER:-root}"
    SSH_PORT="${SSH_PORT:-2223}"

    # 递归 chown 仅在首次/uid 变化时执行：/home/app 挂载了数 G 数据，
    # 无条件遍历会拖垮 healthcheck 时序（历史教训见 Dockerfile.base 注释）。
    if [ "$RUN_USER" != "root" ]; then
        # --- 主账号创建（仅非 root；uid/gid 取 LOCAL_UID/LOCAL_GID）---
        # /home/app 由镜像预建（属主 10001:10001），加 -M 不触发 skel 拷贝与目录创建，
        # 避免把 root 属主的 skel 文件拷进挂载卷。
        if ! id -u "$RUN_USER" >/dev/null 2>&1; then
            echo "==> [User] Creating primary user '$RUN_USER' (uid=${LOCAL_UID}, home=/home/app)"
            useradd --home-dir /home/app --non-unique --uid "$LOCAL_UID" \
                --gid "$LOCAL_GID" --shell /bin/bash -M "$RUN_USER"
        fi
        # home 契约：主账号家目录固定 /home/app（数据路径不随账号名变化）
        [ "$(getent passwd "$RUN_USER" | cut -d: -f6)" = "/home/app" ] \
            || { echo "FATAL: home of '$RUN_USER' must be /home/app (got $(getent passwd "$RUN_USER" | cut -d: -f6))" >&2; exit 1; }
        # uid/gid 校正（如挂载卷属主与 LOCAL_UID 不一致）
        if [ "$(id -u "$RUN_USER")" != "$LOCAL_UID" ] || [ "$(id -g "$RUN_USER")" != "$LOCAL_GID" ]; then
            echo "Adjusting $RUN_USER to uid=$LOCAL_UID, gid=$LOCAL_GID"
            groupmod -o -g "$LOCAL_GID" "$RUN_USER"
            usermod -o -u "$LOCAL_UID" -g "$LOCAL_GID" "$RUN_USER"
            chown -R "$RUN_USER:$(id -gn "$RUN_USER")" /home/app /workspace 2>/dev/null || true
        elif [ "$(stat -c %U /home/app 2>/dev/null)" != "$RUN_USER" ]; then
            chown -R "$RUN_USER:$(id -gn "$RUN_USER")" /home/app /workspace 2>/dev/null || true
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
        echo "==> [SSH] 密码认证已启用（用户 ${RUN_USER}，来自 SSH_PASSWORD）"
    else
        PASSWORD_AUTH=no
        echo "==> [SSH] 密码认证未启用（设置 SSH_PASSWORD 以开启；公钥认证始终可用）"
    fi

    # ==========================================
    # SSH Server 初始化（公钥可选，密码认证见上方 SSH_PASSWORD）
    # 将宿主机公钥挂载到 /home/app/.ssh/authorized_keys 即可启用公钥登录。
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

    # /home/app/.ssh 属主统一归主账号（GITHUB_SSH_KEY 注入的 id_rsa 也在此目录）；
    # RUN_USER=root 时目录属主本就是 root，无需处理。
    if [ "$RUN_USER" != "root" ]; then
        chown -R "$RUN_USER:$(id -gn "$RUN_USER")" /home/app/.ssh
    fi

    # 多用户场景：同一份 authorized_keys 分发给 root / 主账号 / 桌面用户。
    # authorized_keys 本身支持每行一把公钥，多把公钥在宿主机文件里分行存放即可，
    # 不需要为每个用户单独挂载文件。这里不能用 >>（追加）：容器重启会重复叠加，
    # 必须用 cp（覆盖）保证幂等，来源是宿主机 :ro 挂载的唯一真相源文件。
    # 挂载文件不存在时跳过公钥分发（密码认证仍可用），不阻塞启动。
    if [ -f /home/app/.ssh/authorized_keys ] && [ -s /home/app/.ssh/authorized_keys ]; then
        mkdir -p /root/.ssh
        cp /home/app/.ssh/authorized_keys /root/.ssh/authorized_keys
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys

        chmod 700 /home/app/.ssh
        # authorized_keys 是 :ro 挂载文件：真 ro 场景 chmod 会 EPERM，属主/权限本就由宿主保证，
        # 容器内修正仅为幂等防御，失败不应阻塞启动。
        chmod 600 /home/app/.ssh/authorized_keys 2>/dev/null || true

        # 桌面用户公钥分发（用户名可能已被 DESKTOP_USER 改名，按名查找）
        if [ -n "${DESKTOP_USER:-}" ] && id "$DESKTOP_USER" >/dev/null 2>&1; then
            DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
            mkdir -p "${DESKTOP_HOME}/.ssh"
            cp /home/app/.ssh/authorized_keys "${DESKTOP_HOME}/.ssh/authorized_keys"
            chmod 700 "${DESKTOP_HOME}/.ssh"
            chmod 600 "${DESKTOP_HOME}/.ssh/authorized_keys"
            chown -R "$DESKTOP_USER:$DESKTOP_USER" "${DESKTOP_HOME}/.ssh"
        fi
    else
        echo "==> [SSH] 未挂载 authorized_keys，仅密码/密钥外认证可用（设置 SSH_PASSWORD 启用密码登录）"
    fi

    /usr/sbin/sshd
    echo "==> [SSH] SSH Server 已启动，端口 ${SSH_PORT}，用户 root/${RUN_USER}${DESKTOP_USER:+/${DESKTOP_USER}}，公钥认证${PASSWORD_AUTH:+ + 密码认证}"

    # ==========================================
    # 远程桌面 (xrdp) 初始化（可选，通过 ENABLE_DESKTOP=1 开启）
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
    # ==========================================
    if [ "${ENABLE_DESKTOP:-1}" = "1" ]; then
        if [ -x /usr/local/bin/init-desktop.sh ]; then
            /usr/local/bin/init-desktop.sh
        else
            echo "==> [Desktop] 当前为 slim 镜像（NoDesktop-Base，不含远程桌面），已跳过桌面初始化；如需 RDP 请使用 -desktop 后缀镜像"
        fi
    else
        echo "==> [Desktop] 远程桌面已禁用 (ENABLE_DESKTOP=${ENABLE_DESKTOP})"
    fi

    # ==========================================
    # supervisord 自身以 root 运行（声明 user=root 消除 CRIT 告警；
    # 非 root 环境下声明会因无法 setuid(0) 直接拒绝启动，实测
    # "Can't drop privilege as nonroot user"，故仅 root 分支注入）。
    # [program:x] 的 user= 由上方按 SSH_USER 替换，与本行互不影响。
    # docker restart 会重跑本脚本，必须先判重保证幂等。
    # ==========================================
    grep -q '^user=root' "$SUPERVISOR_CONF" || sed -i '/^\[supervisord\]/a user=root' "$SUPERVISOR_CONF"

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

    exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
