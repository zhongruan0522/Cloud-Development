#!/bin/bash
#
# Chromium 浏览器启动包装器（Base 层，hyperframes 经 HYPERFRAMES_BROWSER_PATH 引用）
#
# 作用：
# 1. 统一入口：hyperframes 经 HYPERFRAMES_BROWSER_PATH 调用，命令行手动启动
#    浏览器时同样用它，root 与普通账号行为一致；
# 2. root 账号下 Chromium 拒绝启动，需追加 --no-sandbox；
#    非 root 账号保持默认沙箱，无需该参数。
#

CHROMIUM_BIN=/usr/bin/chromium

if [ ! -x "${CHROMIUM_BIN}" ]; then
    echo "chromium not found at ${CHROMIUM_BIN}" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    # --test-type 抑制 "--no-sandbox 为非官方参数" 的黄条提示
    exec "${CHROMIUM_BIN}" --no-sandbox --test-type "$@"
fi

exec "${CHROMIUM_BIN}" "$@"
