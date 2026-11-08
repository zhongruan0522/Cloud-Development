#!/usr/bin/env bash
# ==========================================
# Android SDK 挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：sdk/ 即 ANDROID_SDK_ROOT 本体（持久，含
# sdkmanager 增量装的 platforms/build-tools）；tmp/ 一次性下载产物即清。
# 幂等：cmdline-tools 已部署且包清单未变时跳过；清单变更走 sdkmanager
# 增量安装（不重下 cmdline-tools，已装组件自动跳过）。
# 依赖：Base 层 JDK 21（sdkmanager 硬依赖）。
# ==========================================
set -euo pipefail

SDK_NAME="android"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# cmdline-tools 构建号（dl.google.com 固定直链，与拆出前 Base 层版本一致）
CT_BUILD="${ANDROID_CMDLINE_TOOLS_BUILD:-11076708}"
# 预装包清单（空格分隔，';' 语义保留）；变更后下次启动 sdkmanager 增量安装
ANDROID_SDK_PACKAGES="${ANDROID_SDK_PACKAGES:-build-tools;35.0.1 build-tools;30.0.2 platform-tools platforms;android-36 platforms;android-35 platforms;android-34 platforms;android-30}"
SDK_OWNER="${SDK_OWNER:-}"
SDK_ROOT="${SDK_DIR}/sdk"
STAMP="${SDK_DIR}/sdk/.packages-stamp"

log()      { echo "==> [${SDK_NAME}] $*"; }
fatal()    { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 依赖自检
[ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ] \
    || fatal "需要 JDK 21（Base 层 temurin-21-jdk 提供）：JAVA_HOME 未设置或不可执行"
export PATH="${JAVA_HOME}/bin:${PATH}"
SDKMANAGER="${SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"

if [ ! -x "${SDKMANAGER}" ]; then
    log "部署 Android cmdline-tools（build ${CT_BUILD}）→ ${SDK_ROOT}"
    mkdir -p "${SDK_ROOT}/cmdline-tools" "${SDK_DIR}/tmp"
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_DIR}/tmp/cmdline-tools.zip" \
        "https://dl.google.com/android/repository/commandlinetools-linux-${CT_BUILD}_latest.zip"
    unzip -q "${SDK_DIR}/tmp/cmdline-tools.zip" -d "${SDK_DIR}/tmp/ct"
    rm -rf "${SDK_ROOT}/cmdline-tools/latest"
    mv "${SDK_DIR}/tmp/ct/cmdline-tools" "${SDK_ROOT}/cmdline-tools/latest"
    rm -rf "${SDK_DIR}/tmp" # 一次性产物即时清理
else
    log "cmdline-tools 已部署，跳过下载"
fi

STAMP_NOW="$(printf '%s\n' "${ANDROID_SDK_PACKAGES}" | md5sum | cut -d' ' -f1)"
if [ "$(cat "${STAMP}" 2>/dev/null || true)" != "${STAMP_NOW}" ]; then
    export PATH="${SDK_ROOT}/cmdline-tools/latest/bin:${PATH}"
    # 接受许可（yes 收到 SIGPIPE 退出码 141 属管道预期，pipefail 需临时关闭；
    # sdkmanager 自身退出码在 pipefail 关闭后如实保留）
    log "接受 SDK 许可并安装组件包（增量，已装组件自动跳过）"
    set +o pipefail
    if ! yes | "${SDKMANAGER}" --licenses > /dev/null 2>&1; then
        fatal "sdkmanager --licenses 失败（详见任务日志 /var/log/init/sdk-android.log）"
    fi
    if ! "${SDKMANAGER}" --install ${ANDROID_SDK_PACKAGES}; then
        fatal "sdkmanager --install 失败（详见任务日志 /var/log/init/sdk-android.log）"
    fi
    set -o pipefail
    echo "${STAMP_NOW}" > "${STAMP}"
    rm -rf "${SDK_ROOT}/.temp" # sdkmanager 一次性下载缓存
else
    log "组件包清单未变化，跳过安装（${ANDROID_SDK_PACKAGES}）"
fi

# /usr/local/bin 软链（对齐拆出前 Base 层先例）；platform-tools/build-tools
# 类软链按目标存在性守卫（用户自定义 ANDROID_SDK_PACKAGES 可能不含对应包）
ln -sf "${SDKMANAGER}" /usr/local/bin/sdkmanager
ln -sf "${SDK_ROOT}/cmdline-tools/latest/bin/avdmanager" /usr/local/bin/avdmanager
if [ -e "${SDK_ROOT}/platform-tools/adb" ]; then ln -sf "${SDK_ROOT}/platform-tools/adb" /usr/local/bin/adb; fi
if [ -e "${SDK_ROOT}/build-tools/35.0.1/apksigner" ]; then ln -sf "${SDK_ROOT}/build-tools/35.0.1/apksigner" /usr/local/bin/apksigner; fi
if [ -e "${SDK_ROOT}/build-tools/35.0.1/zipalign" ]; then ln -sf "${SDK_ROOT}/build-tools/35.0.1/zipalign" /usr/local/bin/zipalign; fi

cat > /etc/profile.d/zz-sdk-android.sh <<EOF
# 由 sdks/android/SDK.sh 生成（每次启动重写，勿手改）
export ANDROID_SDK_ROOT="${SDK_ROOT}"
export ANDROID_HOME="${SDK_ROOT}"
export PATH="\${PATH}:${SDK_ROOT}/cmdline-tools/latest/bin:${SDK_ROOT}/platform-tools:${SDK_ROOT}/build-tools/35.0.1"
EOF

if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi

log "Android SDK 就绪：${SDK_ROOT}（ANDROID_SDK_ROOT；增量包随挂载持久化）"
