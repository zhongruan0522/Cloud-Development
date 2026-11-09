#!/usr/bin/env bash
# ==========================================
# Flutter SDK 挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：
# - 运行时机：entrypoint 第四波后台并行执行（root，SDK_DIR/SDK_OWNER 由
#   init-sdks.sh 注入）；也可容器内手动重跑：
#   sudo SDK_DIR=/opt/sdks/flutter bash /opt/sdks/flutter/SDK.sh
# - 目录布局：sdk/   Flutter 本体（持久，随挂载跨重建保留）
#             cache/ 持久性缓存（PUB_CACHE pub 包缓存）
#             tmp/   一次性产物（下载包），部署完成即清理
# - 幂等：本体已部署且版本一致时跳过下载；版本变更（改 SDK_VERSION）
#   自动整目录重部署
# - 依赖：Base 层 JDK 21（JAVA_HOME）+ 挂载式 Android SDK（同挂载目录下
#   android/SDK.sh，缺失直接失败暴露——Flutter Android 构建硬依赖）
# ==========================================
set -euo pipefail

SDK_NAME="flutter"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SDK_VERSION="${FLUTTER_VERSION:-3.44.4}" # 版本覆盖：compose environment / 命令行 env / 直接改此默认值
SDK_OWNER="${SDK_OWNER:-}"
SDKS_ROOT="$(dirname "${SDK_DIR}")"
TARGET="${SDK_DIR}/sdk/flutter"
STAMP="${SDK_DIR}/sdk/.flutter-version"

log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# 依赖自检（尽早失败暴露，不做静默补装）
[ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ] \
    || fatal "需要 JDK 21（Base 层 temurin-21-jdk 提供）：JAVA_HOME 未设置或不可执行"
[ -f "${SDKS_ROOT}/android/SDK.sh" ] \
    || fatal "缺少 Android SDK：${SDKS_ROOT}/android/SDK.sh 不存在（Flutter Android 构建硬依赖，请同挂载 android 组件）"
export PATH="${JAVA_HOME}/bin:${PATH}"

if [ ! -x "${TARGET}/bin/flutter" ] || [ "$(cat "${STAMP}" 2>/dev/null || true)" != "${SDK_VERSION}" ]; then
    log "部署 Flutter SDK ${SDK_VERSION} → ${TARGET}（首启下载 ~1G tarball，解压后 ~3-4G）"
    mkdir -p "${SDK_DIR}/tmp" "${SDK_DIR}/sdk"
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_DIR}/tmp/flutter.tar.xz" \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${SDK_VERSION}-stable.tar.xz"
    rm -rf "${TARGET}"
    # --no-same-owner：tarball 记录 Google 打包机 UID，root 解压必须丢弃原属主
    tar --no-same-owner -xJf "${SDK_DIR}/tmp/flutter.tar.xz" -C "${SDK_DIR}/sdk"
    rm -rf "${SDK_DIR}/tmp" # 一次性产物即时清理
    # SDK 是 git 仓库且属主 root：非 root 主账号会话触发 dubious ownership，
    # --system 级写 safe.directory 对所有用户生效（幂等判重后再 add）
    git config --system --get-all safe.directory 2>/dev/null | grep -qxF "${TARGET}" \
        || git config --system --add safe.directory "${TARGET}"
    echo "${SDK_VERSION}" > "${STAMP}"
    # 预热 Dart 工具链缓存进 bin/cache（随挂载持久化，首次需下载 ~1G）
    log "预热 Dart 工具链缓存（flutter --version，首次约 1-3 分钟）"
    "${TARGET}/bin/flutter" --version
else
    log "已部署（${SDK_VERSION}），跳过下载"
fi

# /usr/local/bin 软链：非登录 shell（docker exec）也能解析（登录会话走 profile.d）
ln -sf "${TARGET}/bin/flutter" /usr/local/bin/flutter
DART_BIN="${TARGET}/bin/cache/dart-sdk/bin/dart"
if [ -x "${DART_BIN}" ]; then ln -sf "${DART_BIN}" /usr/local/bin/dart; fi

mkdir -p "${SDK_DIR}/cache/pub"
cat > /etc/profile.d/zz-sdk-flutter.sh <<EOF
# 由 sdks/flutter/SDK.sh 生成（每次启动重写，勿手改）
export FLUTTER_ROOT="${TARGET}"
export PUB_CACHE="${SDK_DIR}/cache/pub"
export PATH="\${PATH}:${TARGET}/bin"
EOF

# 非 root 主账号场景：部署产物归属主账号（SDK_OWNER 由 init-sdks.sh 注入）
if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi

log "Flutter SDK 就绪：${SDK_VERSION}（PUB_CACHE=${SDK_DIR}/cache/pub，缓存随挂载持久化）"
