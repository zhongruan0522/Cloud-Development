#!/usr/bin/env bash
# ==========================================
# Gradle 挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：sdk/gradle-<完整版本>/ 本体（按版本分目录，
# 可多版本共存，stamp 记录当前激活版本）；cache/gradle-home 即
# GRADLE_USER_HOME——wrapper 发行版与项目依赖缓存随挂载持久化，重建容器无需重下依赖。
# 幂等：激活版本已部署即跳过；改 GRADLE_VERSION 自动部署新版本目录并切换
# 软链，其他版本目录保留。
# 依赖：Base 层 JDK 21。
# 注意：发行 zip 内层目录是完整版本号（如 gradle-9.6.0-bin.zip → gradle-9.6.0/），
# 禁止猜测目录名——从 zip 清单解析并写入 stamp。
# ==========================================
set -euo pipefail

SDK_NAME="gradle"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
GRADLE_VERSION="${GRADLE_VERSION:-9.6.0}" # 版本覆盖：compose environment / 命令行 env / 直接改此默认值（默认对齐 rikkahub wrapper 9.6.0）
SDK_OWNER="${SDK_OWNER:-}"
STAMP="${SDK_DIR}/sdk/.active-dist" # 内容："<GRADLE_VERSION> <zip内层目录名>"

log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

[ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ] \
    || fatal "需要 JDK 21（Base 层 temurin-21-jdk 提供）：JAVA_HOME 未设置或不可执行"
export PATH="${JAVA_HOME}/bin:${PATH}"

ACTIVE_VERSION="$(cut -d' ' -f1 "${STAMP}" 2>/dev/null || true)"
DIST_DIR="$(cut -d' ' -f2 "${STAMP}" 2>/dev/null || true)"
TARGET="${SDK_DIR}/sdk/${DIST_DIR}"

if [ "${ACTIVE_VERSION}" != "${GRADLE_VERSION}" ] || [ ! -x "${TARGET}/bin/gradle" ]; then
    log "部署 Gradle ${GRADLE_VERSION} → ${SDK_DIR}/sdk/（旧版本目录保留共存）"
    mkdir -p "${SDK_DIR}/tmp" "${SDK_DIR}/sdk"
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_DIR}/tmp/gradle.zip" \
        "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
    # 内层目录名从 zip 清单解析（官方 zip 顶层唯一目录），断言唯一防布局漂移
    DIST_DIR="$(unzip -Z1 "${SDK_DIR}/tmp/gradle.zip" | sed -n 's#^\([^/]*\)/.*$#\1#p' | sort -u)"
    case "${DIST_DIR}" in
        ''|*[^[:print:]]*|*$'\n'*) fatal "无法从 zip 清单解析唯一顶层目录（got '${DIST_DIR}'），上游布局可能已变更" ;;
    esac
    TARGET="${SDK_DIR}/sdk/${DIST_DIR}"
    rm -rf "${TARGET}"
    unzip -q "${SDK_DIR}/tmp/gradle.zip" -d "${SDK_DIR}/sdk"
    rm -rf "${SDK_DIR}/tmp" # 一次性产物即时清理
    echo "${GRADLE_VERSION} ${DIST_DIR}" > "${STAMP}"
else
    log "已部署（${ACTIVE_VERSION} → ${DIST_DIR}），跳过下载"
fi

ln -sf "${TARGET}/bin/gradle" /usr/local/bin/gradle
mkdir -p "${SDK_DIR}/cache/gradle-home"
cat > /etc/profile.d/zz-sdk-gradle.sh <<EOF
# 由 sdks/gradle/SDK.sh 生成（每次启动重写，勿手改）
export GRADLE_HOME="${TARGET}"
export GRADLE_USER_HOME="${SDK_DIR}/cache/gradle-home"
export PATH="\${PATH}:${TARGET}/bin"
EOF

if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi

log "Gradle 就绪：${GRADLE_VERSION}（GRADLE_USER_HOME=${SDK_DIR}/cache/gradle-home，依赖缓存随挂载持久化）"
