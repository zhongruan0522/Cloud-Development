#!/bin/sh
# xrdp 容器定制启动脚本
# 加载系统 profile（locale、PATH 等环境变量）
if test -r /etc/profile; then
    . /etc/profile
fi

# 设置 XDG_RUNTIME_DIR（容器无 systemd-logind，pam_systemd 不会自动设）
# 目录由 entrypoint.sh 在容器启动时按登录用户 UID 预创建。
# fcitx5/dconf/GTK 应用都依赖该变量；缺失会导致 fcitx5 静默失败、输入法不可用。
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

# 输入法环境变量必须在 startxfce4 之前导出，
# 否则 GTK/Qt 应用启动后无法切换出 fcitx5
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export GLFW_IM_MODULE=ibus

# 启动 fcitx5 中文输入法（-d 后台 --replace 接管已有会话）
# fcitx5 通过 XDG_RUNTIME_DIR 创建 socket，目录由 entrypoint.sh 提前创建
fcitx5 -d --replace >/dev/null 2>&1 &

# 启动 XFCE4 会话：xfwm4 窗口管理器 + xfce4-panel + xfdesktop 桌面图标
#
# 不手动 dbus-launch（重要）：
#   startxfce4 → xinitrc 会自动从 /etc/X11/xinit/xinitrc.d/* 拉起 dbus-daemon，
#   手动启 dbus-launch 会导致两个 session bus 共存，RDP 重连时遗留僵尸进程，
#   且 --exit-with-session 在 exec 替换后无法被回收。
#   参考：ArchWiki/Gentoo 论坛明确建议 "应该移除 dbus-launch，它从 xinitrc.d 自动启动"。
exec startxfce4
