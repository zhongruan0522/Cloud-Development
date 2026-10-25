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
# 主流程（必须 root）：三波启动，按依赖层级分批
# 非 root 直接跳过全部初始化进 supervisord（历史兼容路径）。
#
# 第一波【基座】：SSH 全系列（同步拉起，容器最早可用服务）+ Clash TUN /
#   GitHub known_hosts（后台并行，网络基建）。
# 第二波【次基建】：远程桌面（后台并行）+ exec supervisord 随之拉起
#   openchamber 主服务。
# 第三波【资源组件】：PostgreSQL / MySQL / openGauss / KingbaseES / DM8 /
#   DockerD 并行初始化（后台任务，完成后经 supervisorctl 运行期拉起，
#   supervisord.conf 各项 autostart 恒为 false）；数据库任务经并行闸门
#   限流，单批最多 3 个并行（见 db_gated_run），其余排队补位。
#
# 波次是发起优先级而非阻塞等待：三波任务互不依赖，第二/三波后台任务在
# exec supervisord 前发起，实际执行与主服务启动并行重叠。
#
# 失败语义：后台任务失败不终止容器——FATAL 阶段行透传 stdout + 完成摘要
# 行必打（失败附任务日志尾部），完整过程日志落 /var/log/init/<tag>.log，
# healthcheck 诚实变红交由编排侧决策；同步段（账号/SSH/配置）维持 set -e
# 硬失败（此时 supervisord 未起，exit 与旧版语义一致）。
#
# 日志分层：任务 stdout/stderr 全量落任务日志文件，仅 ==> 开头的阶段行
# 透传容器 stdout（带 [tag] 前缀）——docker logs 只见关键节点与完成摘要，
# initdb/mysqld 的过程细节按需查任务日志，不再三库交错刷屏。
# ==========================================
if [ "$(id -u)" = '0' ]; then
    LOCAL_UID=${LOCAL_UID:-10001}
    LOCAL_GID=${LOCAL_GID:-$LOCAL_UID}

    # supervisord 配置路径，供下方各段落的 sed 改写使用。
    SUPERVISOR_CONF="/etc/supervisor/supervisord.conf"

    # 内置数据库五库统一密码（PG postgres / MySQL root / openGauss omm /
    # KingbaseES system / DM8 SYSDBA）：仅首启初始化时生效，已有数据卷不追溯
    # （改密须进容器 ALTER USER）。默认值满足 openGauss 强制复杂度（>=8 位且
    # 大小写/数字/特殊字符至少三类，弱密码会使 openGauss 首启 gs_initdb 直接
    # 失败退出）与 DM8 复杂度（8-48 位且含大写/小写/数字，弱密码 dminit 同样
    # 直接失败退出）；PG/MySQL/KingbaseES 无强制复杂度。
    DB_PASSWORD="${DB_PASSWORD:-Opencode@123}"

    # ==========================================
    # 主账号与目录（数据家目录统一 /root）
    # RUN_USER = SSH_USER（默认 root）：openchamber 的运行账号。
    # builder/final 构建期 HOME=/root，go 产物与 compose 挂载点在 /root 下，
    # 主账号会话与服务进程共用同一 HOME，登录态/agent 配置不分裂；pnpm/uv/
    # playwright 等共享工具资产已迁 /opt 系统路径（/root 0700，desktop 用户
    # 不可穿透，详见 Dockerfile.base"用户和目录"注释）。
    # ==========================================
    RUN_USER="${SSH_USER:-root}"
    SSH_PORT="${SSH_PORT:-2223}"

    # ==========================================
    # 后台任务基础设施（共享库 source 注入：run_bg/run_db/日志分层/并行闸门，
    # 第一~三波薄包装与 entrypoint.d 各 init 模块复用同一契约）
    # ==========================================
    source /usr/local/share/entrypoint.d/lib.sh

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
    # ── 第一波【基座】── SSH 全系列同步拉起 + Clash/known_hosts 后台并行
    # SSH 是容器最早的可用服务（远程入口，仅依赖 host key 与配置文件，
    # 不等 clash/keyscan/桌面/数据库）；公钥可选（宿主机公钥挂载到
    # /root/.ssh/authorized_keys 即启用），密码认证见上方 SSH_PASSWORD。
    # sshd 需要 root 权限（绑定端口 + PAM 认证），不放进 supervisord。
    # ==========================================
    echo "==> ── 第一波【基座】：SSH / Clash / GitHub known_hosts ──"
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
                echo "==> [GitHub] WARNING: known_hosts 扫描失败或超时（${GITHUB_SSH_KEYSCAN_TIMEOUT}），跳过继续"
            fi
            if [ "$RUN_USER" != "root" ]; then
                chown "$RUN_USER:$(id -gn "$RUN_USER")" /root/.ssh/known_hosts 2>/dev/null || true
            fi
            echo "==> [GitHub] known_hosts 扫描完成"
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
    # ── 第二波【次基建】── 远程桌面后台并行；OpenChamber 主服务随
    # 下方 exec supervisord 拉起（本波末尾）。
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
    # 桌面初始化失败：log_fatal 暴露 + healthcheck 变红，不终止容器（SSH/
    # 主服务照常可用，与 clash/keyscan 同为暴露不自杀；区别仅日志级别 FATAL）。
    # ==========================================
    echo "==> ── 第二波【次基建】：远程桌面 / OpenChamber ──"
    if [ "${ENABLE_DESKTOP:-1}" = "1" ]; then
        bg_init_desktop() {
            if [ -x /usr/local/bin/init-desktop.sh ]; then
                if ! /usr/local/bin/init-desktop.sh; then
                    log_fatal "桌面初始化失败（详见任务日志），RDP 不可用；SSH/主服务不受影响"
                    return 1
                fi
                echo "==> 远程桌面就绪：RDP 端口 3390（用户与密码见 compose 说明）"
            else
                echo "==> [Desktop] 当前为 slim 镜像（NoDesktop-Base，不含远程桌面），已跳过桌面初始化；如需 RDP 请使用 -desktop 后缀镜像"
            fi
        }
        run_bg desktop-init bg_init_desktop
    else
        echo "==> [Desktop] 远程桌面已禁用 (ENABLE_DESKTOP=${ENABLE_DESKTOP})"
    fi

    # ==========================================
    # ── 第三波【资源组件】── PostgreSQL / MySQL / openGauss / KingbaseES /
    # DM8 / DockerD 并行初始化+拉起。六者数据/端口/密码文件互不相交，并行无
    # 共享资源；均为重资源组件（gaussdb 共享内存 ~3.5G、MySQL ~500M），与主
    # 服务错开优先级。数据库任务经 db_gated_run 闸门限流：单批最多 3 个并行
    # （DB_GATE_MAX），超出的排队补位——五库全开时不再是五个初始化同时抢内存。
    # 初始化失败：log_fatal + healthcheck 变红，不终止容器（重试幂等）。
    # ==========================================
    # 闸门目录重建：清掉 docker restart 前次启动残留的槽位文件（残留会让计数
    # 虚高、槽位漏光后排队任务永不获槽）。
    rm -rf "${DB_GATE_DIR}" && mkdir -p "${DB_GATE_DIR}"
    echo "==> ── 第三波【资源组件】：PostgreSQL / MySQL / openGauss / KingbaseES / DM8 / DockerD（单批并行上限 ${DB_GATE_MAX}）──"

    # ==========================================
    # 第三波各组件模块：source 注入即分发——注释/函数/ENABLE 开关内聚在同一
    # 模块文件（改单库不碰其他库），source 顺序即发起顺序，与旧单文件版逐行
    # 等价；共享设施（run_bg/run_db/闸门）见 lib.sh。
    # ==========================================
    source /usr/local/share/entrypoint.d/init-postgresql.sh
    source /usr/local/share/entrypoint.d/init-mysql.sh
    source /usr/local/share/entrypoint.d/init-opengauss.sh
    source /usr/local/share/entrypoint.d/init-kingbase.sh
    source /usr/local/share/entrypoint.d/init-dm.sh
    source /usr/local/share/entrypoint.d/init-dockerd.sh

    # ==========================================
    # supervisord 自身以 root 运行（声明 user=root 消除 CRIT 告警；
    # 非 root 环境下声明会因无法 setuid(0) 直接拒绝启动，实测
    # "Can't drop privilege as nonroot user"，故仅 root 分支注入）。
    # [program:x] 的 user= 由上方按 SSH_USER 替换，与本行互不影响。
    # docker restart 会重跑本脚本，必须先判重保证幂等。
    # ==========================================
    grep -q '^user=root' "$SUPERVISOR_CONF" || sed -i '/^\[supervisord\]/a user=root' "$SUPERVISOR_CONF"

    # 第二波收尾：立即 exec supervisord 拉起 openchamber（第二波主服务）；
    # 第三波后台任务（五库/dockerd）已在上方发起，实际拉起动作等 supervisord
    # 就绪后由各自 supervisorctl_start 完成；各后台任务输出经 run_bg 落
    # /var/log/init/<tag>.log 并透传阶段行（容器停止时由 cgroup 级联清理，
    # 残留初始化标记由下次启动的判据逻辑恢复）。
    exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
