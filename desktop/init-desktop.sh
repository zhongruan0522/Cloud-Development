#!/bin/bash
set -euo pipefail

# xrdp + XFCE4 desktop bootstrap for the container runtime.
# This script intentionally keeps root-only work out of entrypoint.sh: PAM users,
# system D-Bus, xrdp runtime directories, XDG runtime directories, and per-user
# desktop shortcuts all need to be prepared before the main process drops to app.

install_xsession_for_user() {
    local target_home="$1"
    local target_user="$2"

    cat > "${target_home}/.xsession" <<'XSESSION_EOF'
exec startxfce4
XSESSION_EOF
    chown "${target_user}:${target_user}" "${target_home}/.xsession"
    chmod 644 "${target_home}/.xsession"
}

# plank dock 的用户级设置（dconf 键值）。
# plank 无系统级全局配置文件，读取每个用户的 dconf（net.launchpad.plank）。
# 这里用 dconf update 机制写入 /etc/dconf/db/local.d/（系统级默认值），
# 用户 home 里的 dconf 若无显式设置则回落到这些默认。
configure_plank_defaults() {
    # plank 属于 GSettings（dconf）应用，需要 profiles 目录
    mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
    cat > /etc/dconf/profile/user <<'PROFILE_EOF'
user-db:user
system-db:local
PROFILE_EOF

    # macOS 风格 dock 参数：贴底居中、48px 图标、WhiteSur-Dark 圆角半透明主题
    cat > /etc/dconf/db/local.d/00-plank <<'PLANK_EOF'
[net/launchpad/plank/docks/dock1]
theme='WhiteSur-Dark'
mode='bottom'
hide-mode='intelligent'
position-alignment='center'
icon-size=48
zoom-enabled=false
show-dock-item=false
pinned-only=false
auto-pinning=true
lock-items=false
tooltips-enabled=true
PLANK_EOF

    dconf update
    echo "==> [Desktop] plank dock 系统级默认已写入（WhiteSur-Dark / 底部居中 / 48px）"
}

# 为 RDP 登录用户预置 plank 常驻应用（.dockitem 文件），
# 与底部 Dock 面板 launcher 保持一致：终端/工作区/浏览器/OpenCode
install_plank_launchers_for_user() {
    local target_home="$1"
    local target_user="$2"
    local target_config_dir="${target_home}/.config/plank/dock1/launchers"

    mkdir -p "${target_config_dir}"
    local desktop_entry launcher_name
    for desktop_entry in \
        opencode-terminal.desktop \
        opencode-workspace.desktop \
        opencode-browser.desktop \
        opencode-webui.desktop; do
        launcher_name="${desktop_entry%.desktop}.dockitem"
        cat > "${target_config_dir}/${launcher_name}" <<DOCKITEM_EOF
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/${desktop_entry}
DOCKITEM_EOF
    done
    chown -R "${target_user}:${target_user}" "${target_home}/.config/plank"
    # 关键：mkdir -p 以 root 身份创建了 ~/.config，其属主是 root。
    # 若不归还给用户，登录时 xfconfd 无权在 ~/.config/xfce4 下建目录而启动失败，
    # 桌面报 "Unable to determine failsafe session name / xfconfd isn't running"。
    chown "${target_user}:${target_user}" "${target_home}/.config"
    # 首启固定（lock），防止拖拽丢失；用户可自行解锁调整
    echo "==> [Desktop] plank launchers 已预置到 ${target_user}"
}

configure_desktop_login_users() {
    if [ -n "${DESKTOP_USER_PASSWORD:-}" ]; then
        echo "desktop:${DESKTOP_USER_PASSWORD}" | chpasswd
        echo "==> [Desktop] desktop 用户密码来源：DESKTOP_USER_PASSWORD"
    elif [ -n "${DESKTOP_PASSWORD:-}" ]; then
        echo "desktop:${DESKTOP_PASSWORD}" | chpasswd
        echo "==> [Desktop] desktop 用户密码来源：DESKTOP_PASSWORD（复用）"
    else
        passwd -d desktop >/dev/null 2>&1 || echo "==> [Desktop] WARNING: 清除 desktop 密码失败，沿用镜像占位密码"
        echo "==> [Desktop] desktop 用户无密码登录（DESKTOP_USER_PASSWORD/DESKTOP_PASSWORD 均未设置）"
    fi
    install_xsession_for_user /home/desktop desktop

    if [ "${ALLOW_APP_DESKTOP:-1}" = "1" ]; then
        DESKTOP_PASSWORD="${DESKTOP_PASSWORD:-app}"
        echo "app:${DESKTOP_PASSWORD}" | chpasswd
        install_xsession_for_user /home/app app
        echo "==> [Desktop] app 用户允许桌面登录（ALLOW_APP_DESKTOP=1）"
    else
        usermod -L app 2>/dev/null || true
        rm -f /home/app/.xsession
        echo "==> [Desktop] app 用户桌面登录已禁用（ALLOW_APP_DESKTOP=0）"
    fi
}

start_system_dbus_for_desktop() {
    if ! command -v dbus-daemon >/dev/null 2>&1; then
        echo "==> [Desktop] WARNING: dbus-daemon 不存在，跳过系统 D-Bus 启动" >&2
        return
    fi

    mkdir -p /run/dbus
    if [ -f /run/dbus/pid ]; then
        kill "$(sed -n '1p' /run/dbus/pid 2>/dev/null)" 2>/dev/null || true
        rm -f /run/dbus/pid
    fi

    dbus-daemon --system --fork
    echo "==> [Desktop] 系统 D-Bus 已启动"
}

prepare_xrdp_runtime_directories() {
    mkdir -p /var/run/xrdp /tmp/.X11-unix
    touch /var/log/xrdp.log /var/log/xrdp-sesman.log
    chown xrdp:xrdp /var/run/xrdp /var/log/xrdp.log /var/log/xrdp-sesman.log
    chmod 2775 /var/run/xrdp
    chmod 1777 /tmp/.X11-unix

    rm -f /var/run/xrdp/xrdp-sesman.pid /var/run/xrdp/xrdp.pid
}

prepare_xdg_runtime_directories() {
    local desktop_user
    local desktop_user_id

    for desktop_user in desktop app; do
        desktop_user_id="$(id -u "${desktop_user}" 2>/dev/null || true)"
        if [ -n "${desktop_user_id}" ]; then
            mkdir -p "/run/user/${desktop_user_id}"
            chown "${desktop_user}:${desktop_user}" "/run/user/${desktop_user_id}"
            chmod 700 "/run/user/${desktop_user_id}"
        fi
    done
}

install_desktop_launchers_for_user() {
    local target_home="$1"
    local target_user="$2"
    local source_launcher_dir="/usr/local/share/opencode-desktop-launchers"
    local target_desktop_dir="${target_home}/Desktop"

    if [ ! -d "${source_launcher_dir}" ]; then
        return
    fi

    mkdir -p "${target_desktop_dir}"
    cp "${source_launcher_dir}"/*.desktop "${target_desktop_dir}/"
    chmod 755 "${target_desktop_dir}"/*.desktop
    chown -R "${target_user}:${target_user}" "${target_desktop_dir}"
}

install_desktop_launchers() {
    install_desktop_launchers_for_user /home/desktop desktop

    if [ "${ALLOW_APP_DESKTOP:-1}" = "1" ]; then
        install_desktop_launchers_for_user /home/app app
    fi
}

install_plank_launchers() {
    install_plank_launchers_for_user /home/desktop desktop

    if [ "${ALLOW_APP_DESKTOP:-1}" = "1" ]; then
        install_plank_launchers_for_user /home/app app
    fi
}

start_xrdp_services() {
    xrdp-sesman
    xrdp

    echo "==> [Desktop] xrdp 已启动，端口 3390"
    echo "==> [Desktop] RDP 客户端连接：localhost:3390（或宿主机映射端口）"
    echo "==> [Desktop] 默认登录用户：desktop（普通权限，可 sudo）；app 桌面登录：ALLOW_APP_DESKTOP=${ALLOW_APP_DESKTOP:-1}"
}

main() {
    echo "==> [Desktop] 初始化 xrdp + XFCE4 远程桌面..."

    configure_desktop_login_users
    configure_plank_defaults
    start_system_dbus_for_desktop
    prepare_xrdp_runtime_directories
    prepare_xdg_runtime_directories
    install_desktop_launchers
    install_plank_launchers
    start_xrdp_services
}

main "$@"
