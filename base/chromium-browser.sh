#!/bin/bash
#
# Chromium 浏览器启动包装器（Base 层，hyperframes 经 HYPERFRAMES_BROWSER_PATH 引用）
#
# 作用：
# 1. 统一入口：hyperframes 经 HYPERFRAMES_BROWSER_PATH 调用，命令行手动启动
#    浏览器时同样用它，root 与普通账号行为一致；
# 2. 统一追加 --no-sandbox：Chromium 拒绝以 root 带默认沙箱启动；普通账号的默认
#    沙箱依赖宿主机放行非特权用户命名空间（Debian 的 chromium 不带 setuid 辅助
#    程序，Ubuntu 23.10 起默认限制），容器里不能指望它可用。
#

CHROMIUM_BIN=/usr/bin/chromium

if [ ! -x "${CHROMIUM_BIN}" ]; then
    echo "chromium not found at ${CHROMIUM_BIN}" >&2
    exit 1
fi

# --test-type 抑制 "--no-sandbox 为非官方参数" 的黄条提示
exec "${CHROMIUM_BIN}" --no-sandbox --test-type "$@"
