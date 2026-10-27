#!/bin/bash
set -euo pipefail

# xrdp 与 SSH 使用同一系统账号；密码只由 entrypoint.sh 设置。

start_system_dbus_for_desktop() {
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

prepare_xdg_runtime_directory() {
    local primary_user="${SSH_USER:-root}"
    local primary_uid primary_gid
    primary_uid="$(id -u "${primary_user}")"
    primary_gid="$(id -g "${primary_user}")"
    mkdir -p "/run/user/${primary_uid}"
    chown "${primary_uid}:${primary_gid}" "/run/user/${primary_uid}"
    chmod 700 "/run/user/${primary_uid}"
}

install_desktop_launchers() {
    local primary_user="${SSH_USER:-root}"
    local source_launcher_dir="/usr/local/share/opencode-desktop-launchers"
    local target_desktop_dir="/root/Desktop"

    mkdir -p "${target_desktop_dir}"
    cp "${source_launcher_dir}"/*.desktop "${target_desktop_dir}/"
    chmod 755 "${target_desktop_dir}"/*.desktop
    chown "${primary_user}:$(id -gn "${primary_user}")" "${target_desktop_dir}" "${target_desktop_dir}"/*.desktop
}

start_xrdp_services() {
    xrdp-sesman
    xrdp

    echo "==> [Desktop] xrdp 已启动，端口 3390"
    echo "==> [Desktop] RDP 客户端连接：localhost:3390（或宿主机映射端口）"
    echo "==> [Desktop] 登录用户：${SSH_USER:-root}；密码来自 SSH_PASSWORD"
    if [ -z "${SSH_PASSWORD:-}" ]; then
        echo "==> [Desktop] SSH_PASSWORD 未设置，RDP 密码登录不可用" >&2
    fi
}

main() {
    echo "==> [Desktop] 初始化 xrdp + XFCE4 远程桌面..."

    start_system_dbus_for_desktop
    prepare_xrdp_runtime_directories
    prepare_xdg_runtime_directory
    install_desktop_launchers
    start_xrdp_services
}

main "$@"
