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
    echo "[OpenChamber] - UI password protection enabled (host=${OPENCHAMBER_HOST})"
else
    echo "[OpenChamber] - WARNING: OPENCHAMBER_UI_PASSWORD is not set, browser UI has no authentication" >&2
fi

# ==========================================
# Magpie 服务配置（可选，通过 ENABLE_MAGPIE=1 开启）
# ==========================================
# 网关与 Web UI 监听地址：容器场景默认 0.0.0.0 以便端口映射访问；
# 必须无条件导出供 supervisord.conf 模板插值（%(ENV_MAGPIE_WEB_ADDR)s）。
export MAGPIE_ADDR="${MAGPIE_ADDR:-0.0.0.0:3425}"
export MAGPIE_WEB_ADDR="${MAGPIE_WEB_ADDR:-0.0.0.0:3430}"
# Web 登录密钥：未设置时每次启动随机生成（32 位十六进制，满足 Magpie 的长度与字符集
# 要求）并记 MAGPIE_WEB_KEY_GENERATED=1（仅供本脚本及其 source 进来的模块判断，不
# 导出）。第三波任务据此定容器日志里 Web UI 入口行的形态：随机生成的带 key，容器日志
# 是取得登录链接的地方；固定密钥的不带 key。程序经 supervisord 进程环境继承本变量。
# Magpie 未启用时不生成（该情形下无组件使用）。
if [ "${ENABLE_MAGPIE:-0}" = "1" ] && [ -z "${MAGPIE_WEB_KEY:-}" ]; then
    MAGPIE_WEB_KEY="$(openssl rand -hex 16)" \
        || { echo "FATAL: 生成 MAGPIE_WEB_KEY 失败（openssl rand）" >&2; exit 1; }
    MAGPIE_WEB_KEY_GENERATED=1
fi
export MAGPIE_WEB_KEY
case "$MAGPIE_WEB_ADDR" in
    ''|*[!a-zA-Z0-9.:_\[\]-]*)
        echo "FATAL: MAGPIE_WEB_ADDR 含非法字符（期望 host:port，如 0.0.0.0:3430）" >&2
        exit 1
        ;;
esac

# ==========================================
# 持久化环境变量（供所有 shell 会话使用）
# ==========================================
cat > /etc/profile.d/opencode-env.sh <<'ENV_EOF'
# PNPM_HOME 按登录用户 HOME 展开（heredoc 引号形式构建期不展开，source 时生效）：
# 登录会话的用户级 pnpm 全局 bin 按实际 HOME 展开；镜像预装的共享资产
# （openchamber）位于 /opt/pnpm，入口经 /usr/local/bin 软链对所有会话可达。
# 前插 ${PNPM_HOME}/bin，保证用户自装的全局命令登录后可被解析。
export PNPM_HOME="${HOME}/.local/share/pnpm"
# PATH 仅含镜像内置组件；挂载式 SDK（flutter/android/gradle/rust/apk-tools）
# 的 PATH/env 由各 SDK.sh 写入 /etc/profile.d/zz-sdk-*.sh（字典序在本文件
# 之后加载，运行期追加注入，见 sdks/README.md）。
export PATH="${PNPM_HOME}/bin:/usr/local/go/bin:/opt/go/bin:/opt/bun/bin:/usr/lib/jvm/java-21-openjdk-current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export GOPATH=/opt/go
export BUN_INSTALL=/opt/bun
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-current
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
# exec/主进程链，SSH 等登录 shell 经由本文件继承，二者需同步维护。
export CODEGRAPH_NO_UPDATE_CHECK=1
export HYPERFRAMES_NO_UPDATE_CHECK=1
ENV_EOF
chmod +x /etc/profile.d/opencode-env.sh
# DISPLAY（宿主机显示转发，由 compose 传入）同样经本文件让登录 shell 继承。
if [ -n "${DISPLAY:-}" ]; then
    printf 'export DISPLAY=%q\n' "${DISPLAY}" >> /etc/profile.d/opencode-env.sh
fi

# ==========================================
# 主流程（必须 root）：三波启动，按依赖层级分批；
# 非 root 跳过全部初始化，直接进 supervisord。
#
# 第一波【基座】：SSH 全系列（同步拉起，容器最早可用服务）+ 家目录与工作区的
#   属主权限对齐、Clash TUN、GitHub known_hosts（后台并行）。
# 第二波【主服务】：exec supervisord 随之拉起 openchamber 主服务，后台任务
#   等它的程序段进入 RUNNING 后打状态行与入口地址行。
# 第三波【可选组件】：DockerD / Magpie（镜像内置，ENABLE 开关）+ 挂载式 SDK
#   （扫描 /opt/sdks/*/SDK.sh，后台任务，完成后经 supervisorctl 运行期拉起，
#   supervisord.conf 各项 autostart 恒为 false）。SDK 三类：工具链（Flutter /
#   Android / Gradle / Rust / apk-tools）首启下载部署、后续启动幂等秒过，env 写
#   /etc/profile.d/zz-sdk-*.sh 运行期注入；数据库（pg / mysql / opengauss /
#   kingbase / dm / redis）二进制由 Base 层安装，SDK.sh 只做首启初始化与拉起，
#   数据默认落容器可写层（容器重建即全新，docker restart 保留）；apt 安装清单
#   （apt-list）按 packages.txt 安装尚未安装的包。全部 SDK 任务
#   经并发闸门限流：同时在途最多 3 个，完成一个补位一个（见 sdk_gated_run）；
#   ENABLE_<目录名大写>=0 的 SDK 跳过；目录内提供 healthcheck.sh 的 SDK 参与
#   健康判定。不挂载或目录为空则完全无感，详见 sdks/README.md。
#
# 波次是发起优先级而非阻塞等待：三波任务互不依赖，第二/三波后台任务在
# exec supervisord 前发起，实际执行与主服务启动并行重叠。
#
# 失败语义：后台任务失败不终止容器——失败状态行（[阶段][服务] - [状态：失败]）
# 附任务日志路径指路，完整过程日志落 /var/log/init/<tag>.log；带健康判定的组件
# （DockerD / Magpie / 数据库 SDK）失败后 healthcheck 变红交由编排侧
# 决策，工具链 SDK 与 clash/keyscan 失败只暴露状态行；同步段（账号/SSH/配置）
# 维持 set -e 硬失败（此时 supervisord 未起）。
#
# 日志分层：容器 stdout（docker logs）只有状态行，三类日志各归其位——
#   - 任务日志：后台任务的 stdout/stderr 全量落 /var/log/init/<tag>.log（成功后改名
#     <阶段>-<tag>.log 归档，失败保持原名）；容器 stdout 对任务仅状态行——SDK 任务
#     下发时排队、获得并发槽位时部署中，其余任务下发即部署中，结束统一成功/失败，
#     另有停用 SDK 的跳过行与波次汇总行（[阶段] - [状态：n/m]）。
#   - 程序日志：supervisord 托管程序（openchamber / magpie / dockerd / 各数据库）的
#     stdout 与 stderr 合并落 /var/log/supervisor/<程序段名>.log，按大小轮转
#     （base/supervisord.conf），每次拉起前写一行带时间戳的启动分隔行；任务日志里
#     拉起程序的那一行附其路径。
#   - supervisord 自身日志：只写 /tmp/supervisord.log（silent=true）。
# 入口地址（OpenChamber 与 Magpie 的 Web UI 链接）以状态行进容器 stdout。
# ==========================================
if [ "$(id -u)" = '0' ]; then

    # 内置数据库统一密码（PG postgres / MySQL root / openGauss omm /
    # KingbaseES system / DM8 SYSDBA / Redis redis）。五个关系型数据库仅首启初始化时
    # 生效，已有数据卷不追溯（改密须进容器 ALTER USER）；Redis 每次启动按当前值重写
    # 配置，密码始终与本变量一致。必须 export：数据库由挂载式 SDK 部署，SDK.sh 是
    # 独立进程，只能继承已导出的变量（export 后 supervisord 同样可见；其托管的数据库与
    # dockerd 程序段以 env -i 从空环境起步，进程环境不含本变量，见 base/supervisord.conf
    # 文件头的环境约定）。
    # 默认值满足 openGauss 复杂度（>=8 位且大小写/数字/特殊字符至少三类，字符仅限
    # 数字、字母与指定特殊字符，不含空格与引号；不满足时首启 gs_initdb 直接失败
    # 退出）与 DM8 复杂度（8-48 位且含大写/小写/数字，弱密码 dminit 同样直接失败
    # 退出）；PG/MySQL/KingbaseES/Redis 无强制复杂度。
    export DB_PASSWORD="${DB_PASSWORD:-Opencode@123}"

    # ==========================================
    # 主账号 opencode：镜像预建的普通用户（Dockerfile.base），SSH 登录、
    # openchamber / magpie 与各 Agent 以它运行，免密 sudo 取 root；容器引导、
    # supervisord、sshd、dockerd 与各数据库仍由 root 负责。
    # ==========================================
    RUN_USER=opencode
    RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
    if [ -z "${RUN_HOME}" ] || [ ! -d "${RUN_HOME}" ]; then
        echo "FATAL: 镜像里没有主账号 ${RUN_USER} 的家目录（由 Dockerfile.base 预建）" >&2
        exit 1
    fi
    SSH_PORT="${SSH_PORT:-2223}"

    # ==========================================
    # 后台任务基础设施（共享库 source 注入：run_bg/run_sdk/日志分层/SDK 并发
    # 闸门/SDK 启用规则，三波薄包装、entrypoint.d 各 init 模块与数据库 SDK.sh
    # 复用同一契约）
    # ==========================================
    source /usr/local/share/entrypoint.d/lib.sh

    # 阶段计数目录与 SDK 并发闸门目录重建：清掉 docker restart 前次启动残留的
    # 计数与槽位文件（/run 跨 restart 保留，残留会让阶段汇总行统计错乱、槽位
    # 漏光后排队任务永不获槽）。必须先于任何任务下发：第一波起即有任务登记计数。
    rm -rf "${SDK_GATE_DIR:?}" "${STAGE_ROOT:?}" && mkdir -p "${SDK_GATE_DIR}" "${STAGE_ROOT}"

    # uid/gid 对齐宿主机：LOCAL_UID / LOCAL_GID 留空或为 0 即保持镜像预建的 1000；给了
    # 别的值且与现值不同时改号，家目录下的文件随 usermod 改属主。撞上别的账号（如 1001
    # 的 kingbase）时 usermod / groupmod 报错，入口脚本在此终止。
    IDS_CHANGED=0
    for var in LOCAL_UID LOCAL_GID; do
        v="${!var:-0}"
        if ! [[ "${v}" =~ ^(0|[1-9][0-9]{0,9})?$ ]]; then
            echo "FATAL: ${var} 必须是正整数、0 或留空（当前值 ${v}）" >&2
            exit 1
        fi
    done
    if [ -n "${LOCAL_UID:-}" ] && [ "${LOCAL_UID}" != "0" ] \
        && [ "$(id -u "${RUN_USER}")" != "${LOCAL_UID}" ]; then
        echo "[User] - 主账号 ${RUN_USER} 改为 uid=${LOCAL_UID}"
        usermod -u "${LOCAL_UID}" "${RUN_USER}"
        IDS_CHANGED=1
    fi
    if [ -n "${LOCAL_GID:-}" ] && [ "${LOCAL_GID}" != "0" ] \
        && [ "$(id -g "${RUN_USER}")" != "${LOCAL_GID}" ]; then
        echo "[User] - 主账号主组 ${RUN_USER} 改为 gid=${LOCAL_GID}"
        groupmod -g "${LOCAL_GID}" "${RUN_USER}"
        IDS_CHANGED=1
    fi

    # ==========================================
    # 家目录与工作区的属主权限：root 与主账号都要能读写。
    # 主账号经属主读写，root 经特权读写；各目录另带主账号组可读写的默认 ACL，
    # 之后 root 在其中新建的文件与目录自动继承，主账号也能直接改写。显式给出更严
    # 权限的文件（chmod 600、install -m 600 等）不受影响；带默认 ACL 的目录里 umask
    # 不生效，靠 umask 收权限的办法在这两棵树里不起作用。主账号的 .ssh 不带默认
    # ACL，ssh-keygen 这类靠 umask 077 建私钥的工具在那里照常得到 600。
    # 整棵树连嵌套的可写挂载点一次走完；只读挂载点保持原样。
    # mount_is_ro <路径>：路径所在的挂载是否只读（同一挂载点叠着多个文件系统时，
    # 以最上面的那个为准）。
    mount_is_ro() {
        findmnt -n -o OPTIONS -T "$1" | tail -n 1 | tr ',' '\n' | grep -qxF ro
    }
    # mounts_under <根路径>：根路径之下的挂载点（不含根自身），每行“<rw 或 ro><TAB><挂载点>”。
    # findmnt 的机器可读输出把挂载点路径里的空格等字符写成 \x20 一类的十六进制转义
    # （选项列不含这类字符），路径还原后再用；同一挂载点叠着多个文件系统时只留最上面的
    # 那个（挂载表按挂载先后排列）。
    mounts_under() {
        local root="$1" line target state
        while IFS= read -r line; do
            target="$(printf '%b' "${line#* }")"
            case "${target}" in "${root}"/*) ;; *) continue ;; esac
            if tr ',' '\n' <<<"${line%% *}" | grep -qxF ro; then state=ro; else state=rw; fi
            printf '%s\t%s\n' "${state}" "${target}"
        done < <(findmnt -rn -o OPTIONS,TARGET) \
            | awk -F '\t' '{ last[$2] = $1 } END { for (t in last) print last[t] "\t" t }'
    }
    # rw_layers <根路径>：根路径所在的挂载可写时列出根自身，加上其下可写的挂载点，每行一个。
    rw_layers() {
        local root="$1" state target
        mount_is_ro "${root}" || printf '%s\n' "${root}"
        while IFS=$'\t' read -r state target; do
            [ "${state}" = rw ] && printf '%s\n' "${target}"
        done < <(mounts_under "${root}")
    }
    # 家目录的标准数据目录：以主账号属主预建，主服务与各 Agent 起步即有处可写。
    RUN_DIRS=("${RUN_HOME}/.ssh" "${RUN_HOME}/.config/opencode" "${RUN_HOME}/.config/magpie"
        "${RUN_HOME}/.local/share/opencode" "${RUN_HOME}/.cache/magpie")
    mkdir -p "${RUN_DIRS[@]}"
    chmod 700 "${RUN_HOME}/.ssh"
    # 同步段：两个根、标准数据目录与各可写挂载点先把属主交给主账号（非递归），
    # 随 supervisord 自起的主服务立即有处可写；整棵树的递归对齐在后台任务里完成。
    while IFS= read -r p; do
        chown -h "${RUN_USER}:${RUN_USER}" "${p}"
    done < <(printf '%s\n' "${RUN_DIRS[@]}"; rw_layers "${RUN_HOME}"; rw_layers /workspace)
    # 后台任务：整棵树递归对齐——属主不符的条目交给主账号，各目录补默认 ACL。只读挂载点
    # 剪枝跳过；默认 ACL 不加在主账号的 .ssh 及其子目录上。主账号改过 uid/gid 时，
    # 镜像里归它的共享资产（Go 模块缓存）一并换属主。
    align_trees() {
        local roots=("${RUN_HOME}" /workspace) root state target
        local -a prunes=()
        [ "${IDS_CHANGED}" = 1 ] && roots+=(/opt/go)
        for root in "${roots[@]}"; do
            prunes=()
            while IFS=$'\t' read -r state target; do
                [ "${state}" = ro ] && prunes+=(-o -path "${target}")
            done < <(mounts_under "${root}")
            echo "==> 对齐 ${root}"
            find "${root}" \( -false "${prunes[@]}" \) -prune -o \
                \( ! -user "${RUN_USER}" -o ! -group "${RUN_USER}" \) -exec chown -h "${RUN_USER}:${RUN_USER}" {} + || return 1
            [ "${root}" = "${RUN_HOME}" ] && prunes+=(-o -path "${RUN_HOME}/.ssh")
            find "${root}" \( -false "${prunes[@]}" \) -prune -o \
                -type d -exec setfacl -m "d:g:${RUN_USER}:rwX" {} + || return 1
        done
    }
    run_bg 第一波 "目录权限" dir-perms align_trees

    # --- SSH 端口 / 密码认证 ---
    # 密码认证开关：设置 SSH_PASSWORD 即启用（公钥认证始终并存），未设置则维持仅公钥。
    if [ -n "${SSH_PASSWORD:-}" ]; then
        # chpasswd 的输入以换行分隔账号；拒绝多行密码，防止意外改写其他账户。
        case "$SSH_PASSWORD" in
            *$'\n'*) echo "FATAL: SSH_PASSWORD 不支持换行" >&2; exit 1 ;;
        esac
        printf '%s:%s\n' "$RUN_USER" "$SSH_PASSWORD" | chpasswd
        PASSWORD_AUTH=yes
        PASSWORD_AUTH_NOTE=" + 密码认证"
        echo "[SSH] - 密码认证已启用（用户 ${RUN_USER}，来自 SSH_PASSWORD）"
    else
        # 清除容器重启前残留的密码，避免未配置密码时仍能用旧密码登录。
        # 已锁定账户保持原样，避免累积锁定前缀。
        if [ "$(passwd -S "$RUN_USER" | cut -d' ' -f2)" != "L" ]; then
            passwd -l "$RUN_USER" >/dev/null
        fi
        PASSWORD_AUTH=no
        PASSWORD_AUTH_NOTE=""
        echo "[SSH] - 密码认证未启用（设置 SSH_PASSWORD 以开启；公钥认证始终可用）"
    fi

    # ==========================================
    # 宿主机 X11 显示（可选，DISPLAY 由 compose 传入即启用）
    # DISPLAY 与 /tmp/.X11-unix 由 compose 传入。这里以主账号实际连一次并把结果
    # 打成一行状态行；未连通不终止容器（SSH 与主服务不依赖它），healthcheck
    # 持续判定并给出同一行修复提示。
    # ==========================================
    if [ -n "${DISPLAY:-}" ]; then
        if X11_REASON="$(x11_probe "$RUN_USER")"; then
            echo "[X11] - 宿主机显示 ${DISPLAY} 已连通，容器内图形程序显示到宿主机屏幕"
        else
            echo "[X11] - 宿主机显示 ${DISPLAY} 未连通：${X11_REASON}"
        fi
    fi

    # ==========================================
    # ── 第一波【基座】── SSH 全系列同步拉起 + Clash/known_hosts 后台并行
    # SSH 是容器最早的可用服务（远程入口，仅依赖 host key 与配置文件，
    # 不等 clash/keyscan/数据库）；公钥可选（宿主机公钥挂载到
    # /home/opencode/.ssh/authorized_keys 即启用），密码认证见上方 SSH_PASSWORD。
    # ==========================================
    echo "[第一波] - 阶段开始"
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
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication ${PASSWORD_AUTH}
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
EOF

    # 密码认证与挂载公钥并存。宿主文件的属主与权限随宿主机而定（sshd 的 StrictModes
    # 不接受），因此复制到 root 持有的受保护目录，每次启动从挂载文件覆盖该副本。
    # 副本归 root、全员可读：sshd 以目标账号的身份读它。这一份公钥同时放行主账号与
    # root：已有的 `ssh root@` 用法、脚本与 IDE 连接不用改。
    mkdir -p /etc/ssh/opencode-authorized-keys
    chown root:root /etc/ssh/opencode-authorized-keys
    chmod 755 /etc/ssh/opencode-authorized-keys
    # 无挂载时也禁用默认路径，避免意外使用上次容器运行遗留的公钥。
    cat >> /etc/ssh/sshd_config.d/opencode.conf <<EOF
AuthorizedKeysFile none
EOF
    KEYS_NOTE=""
    if [ -L "${RUN_HOME}/.ssh/authorized_keys" ] || [ -e "${RUN_HOME}/.ssh/authorized_keys" ]; then
        [ -f "${RUN_HOME}/.ssh/authorized_keys" ] && [ -r "${RUN_HOME}/.ssh/authorized_keys" ] \
            || { echo "FATAL: ${RUN_HOME}/.ssh/authorized_keys 必须是可读文件" >&2; exit 1; }
        install -m 644 -o root -g root \
            "${RUN_HOME}/.ssh/authorized_keys" /etc/ssh/opencode-authorized-keys/primary
        cat >> /etc/ssh/sshd_config.d/opencode.conf <<EOF
Match User ${RUN_USER},root
    AuthorizedKeysFile /etc/ssh/opencode-authorized-keys/primary
EOF
        KEYS_NOTE="（同一份公钥放行 root）"
    else
        # 无挂载时不使用上次启动遗留的副本或默认公钥文件。
        rm -f /etc/ssh/opencode-authorized-keys/primary
        echo "[SSH] - 未挂载 ${RUN_HOME}/.ssh/authorized_keys（设置 SSH_PASSWORD 启用密码登录）"
    fi

    /usr/sbin/sshd -t
    /usr/sbin/sshd
    echo "[SSH] - SSH Server 已启动，端口 ${SSH_PORT}，主账号 ${RUN_USER}${KEYS_NOTE}，公钥认证${PASSWORD_AUTH_NOTE}"

    # ==========================================
    # GitHub SSH 私钥注入（同步，瞬时）+ known_hosts 扫描（后台并行）
    # ==========================================
    # gh 认证走持久化配置卷：首次使用时手动执行 `gh auth login`，凭据落在
    # ~/.config/gh（compose 已挂载 ./.config/gh 卷），容器重建后依然保持登录态。
    if [ -n "$GITHUB_SSH_KEY" ]; then
        echo "$GITHUB_SSH_KEY" | base64 -d > "${RUN_HOME}/.ssh/id_rsa"
        chmod 600 "${RUN_HOME}/.ssh/id_rsa"
        chown "${RUN_USER}:${RUN_USER}" "${RUN_HOME}/.ssh/id_rsa"
        echo "[GitHub] - 已注入 SSH 私钥 ${RUN_HOME}/.ssh/id_rsa"
        # known_hosts 扫描（网络 IO，最坏 10s）后台化：仅影响 git over SSH
        # 首次推送的 host 校验，不阻塞任何服务启动。
        bg_github_keyscan() {
            GITHUB_SSH_KEYSCAN_TIMEOUT="${GITHUB_SSH_KEYSCAN_TIMEOUT:-10s}"
            if ! timeout "$GITHUB_SSH_KEYSCAN_TIMEOUT" ssh-keyscan github.com >> "${RUN_HOME}/.ssh/known_hosts" 2>/dev/null; then
                echo "==> [GitHub] WARNING: known_hosts 扫描失败或超时（${GITHUB_SSH_KEYSCAN_TIMEOUT}），跳过继续"
            fi
            chown "${RUN_USER}:${RUN_USER}" "${RUN_HOME}/.ssh/known_hosts" 2>/dev/null || true
            echo "==> [GitHub] known_hosts 扫描完成"
        }
        run_bg 第一波 "GitHub known_hosts" github-keyscan bg_github_keyscan
    fi

    # ==========================================
    # mihomo (Clash) TUN 模式初始化（可选，通过 ENABLE_CLASH=1 开启，后台并行）
    # TUN 就绪前主服务已发起的出站请求走直连，TUN 接管后新建连接自动切换代理；
    # 初始化失败不阻塞主服务。
    # ==========================================
    if [ "${ENABLE_CLASH:-0}" = "1" ]; then
        bg_init_clash() {
            if /usr/local/bin/init-clash.sh; then
                echo "==> [Clash] TUN 模式已接管所有出站流量，无需代理环境变量"
            else
                echo "==> [Clash] WARNING: mihomo 初始化失败，跳过代理注入并继续启动主服务" >&2
            fi
        }
        run_bg 第一波 "Clash" clash-init bg_init_clash
    fi
    # 第一波收口：本波后台任务全部下发完毕，写 dispatched 标记（汇总行由
    # 最后完成者打印；无后台任务时此处兜底打 0/0）。
    stage_dispatch_done 第一波

    # ==========================================
    # ── 第二波【主服务】── OpenChamber 主服务随本脚本末尾 exec 的
    # supervisord 自启（supervisord.conf autostart=true）：后台任务等它的
    # 程序段进入 RUNNING 再收口，容器 stdout 由此得到主服务的状态行与入口
    # 地址；启动失败以失败状态行暴露，healthcheck 变红。
    # ==========================================
    echo "[第二波] - 阶段开始"
    bg_wait_openchamber() {
        supervisorctl_start openchamber || { log_fatal "OpenChamber 拉起失败"; return 1; }
        # 入口地址行：监听在通配地址时写 localhost，监听在指定地址时写该地址
        # （IPv6 字面量在 URL 里加方括号）。
        local oc_host="${OPENCHAMBER_HOST:-0.0.0.0}"
        case "${oc_host}" in
            ''|0.0.0.0|'::'|'[::]') oc_host=localhost ;;
            *\[*) ;;
            *:*) oc_host="[${oc_host}]" ;;
        esac
        log_status "[第二波][OpenChamber] - Web UI http://${oc_host}:4096"
    }
    run_bg 第二波 "OpenChamber" openchamber bg_wait_openchamber

    # 第二波收口（exec supervisord 前必须打，主进程此后消失）。
    stage_dispatch_done 第二波

    # ==========================================
    # ── 第三波【可选组件】── DockerD / Magpie（镜像内置，ENABLE 开关）+ 挂载式
    # SDK（/opt/sdks/*/SDK.sh）。DockerD 与 Magpie 无初始化步骤、非重资源组件，
    # 走 run_bg 直接拉起；SDK 任务（工具链下载解压、数据库首启初始化均为重资源
    # 动作：openGauss 共享内存 ~3.5G、DM8 首启初始化数据 ~0.8G、Android / Flutter
    # 下载解压数 GB……）统一经 sdk_gated_run 闸门限流：同时在途最多 3 个
    # （SDK_GATE_MAX），完成一个补位一个——不会多个重资源部署同时抢内存与磁盘。
    # 初始化失败：FATAL + healthcheck 变红，不终止容器（重试幂等）。
    # ==========================================
    # 本波镜像内置组件拼入开始行（SDK 组件由 init-sdks.sh 扫描后逐个下发并各打
    # 状态行；启用开关与默认值查 README/compose 注释）。
    WAVE3_COMPONENTS=""
    if [ "${ENABLE_DOCKERD:-0}" = "1" ]; then WAVE3_COMPONENTS="${WAVE3_COMPONENTS:+${WAVE3_COMPONENTS} / }DockerD"; fi
    if [ "${ENABLE_MAGPIE:-0}" = "1" ]; then WAVE3_COMPONENTS="${WAVE3_COMPONENTS:+${WAVE3_COMPONENTS} / }Magpie"; fi
    echo "[第三波] - 阶段开始（镜像内置组件: ${WAVE3_COMPONENTS:-无}；SDK 并发上限 ${SDK_GATE_MAX}）"

    # ==========================================
    # 第三波各组件模块：source 注入即分发——注释/函数/ENABLE 开关内聚在同一
    # 模块文件（改单组件不碰其他），source 顺序即发起顺序；
    # 共享设施（run_bg/run_sdk/SDK 并发闸门/SDK 启用规则）见 lib.sh。
    # init-sdks.sh：扫描 <SDKS_ROOT>/*/SDK.sh 逐个经 run_sdk 后台部署（并发
    # 闸门限流），与同波任务及主服务启动重叠执行，不阻塞任何服务就绪。
    # ==========================================
    source /usr/local/share/entrypoint.d/init-dockerd.sh
    source /usr/local/share/entrypoint.d/init-magpie.sh
    source /usr/local/share/entrypoint.d/init-sdks.sh
    # 第三波收口：本波组件全部下发完毕。
    stage_dispatch_done 第三波

    # 第二波收尾：立即 exec supervisord 拉起 openchamber（第二波主服务）；
    # 第三波后台任务（dockerd/magpie/sdks）已在上方发起，实际拉起动作等
    # supervisord 就绪后由各自 supervisorctl_start 完成（工具链 SDK 部署为
    # 纯文件动作无需 supervisord）；各后台任务输出经 run_bg 全量落
    # /var/log/init/<tag>.log，容器 stdout 仅状态行与波次汇总行
    # （容器停止时由 cgroup 级联清理，残留初始化标记由下次启动
    # 的判据逻辑恢复）。主服务 openchamber 随 supervisord 自启、不经
    # supervisorctl_start，它的启动分隔行由这里先写入程序日志。
    log_program_start openchamber
    exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
fi

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
