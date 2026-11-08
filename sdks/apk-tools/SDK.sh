#!/usr/bin/env bash
# ==========================================
# APK 反编译工具链挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：sdk/ = jar/解压产物本体（apktool.jar /
# uber-apk-signer.jar / jadx / dex2jar）；bin/ = 统一 wrapper 目录（唯一
# PATH 注入点，jadx 与 d2j-* 均收敛于此）；tmp/ 一次性下载产物即清。
# 幂等：四组件版本指纹一致且产物齐全时跳过；任一版本变更整目录重部署。
# 依赖：Base 层 JDK 21（全部工具基于 jar 运行）。
# ==========================================
set -euo pipefail

SDK_NAME="apk-tools"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
APKTOOL_VERSION="${APKTOOL_VERSION:-3.0.2}"
JADX_VERSION="${JADX_VERSION:-1.5.5}"
DEX2JAR_VERSION="${DEX2JAR_VERSION:-2.4.35}" # ThexXTURBOXx fork（含 d2j-asm-verify）
UBER_APK_SIGNER_VERSION="${UBER_APK_SIGNER_VERSION:-1.3.0}"
SDK_OWNER="${SDK_OWNER:-}"
SDK_ROOT="${SDK_DIR}/sdk"
BIN_DIR="${SDK_DIR}/bin"
STAMP="${SDK_DIR}/sdk/.versions"

log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

[ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ] \
    || fatal "需要 JDK 21（Base 层 temurin-21-jdk 提供）：JAVA_HOME 未设置或不可执行"
export PATH="${JAVA_HOME}/bin:${PATH}"

VERSIONS_FINGERPRINT="${APKTOOL_VERSION}/${JADX_VERSION}/${DEX2JAR_VERSION}/${UBER_APK_SIGNER_VERSION}"
if [ ! -f "${SDK_ROOT}/apktool.jar" ] || [ ! -x "${SDK_ROOT}/jadx/bin/jadx" ] \
    || [ ! -x "${SDK_ROOT}/dex2jar/d2j-dex2jar.sh" ] || [ ! -f "${SDK_ROOT}/uber-apk-signer.jar" ] \
    || [ "$(cat "${STAMP}" 2>/dev/null || true)" != "${VERSIONS_FINGERPRINT}" ]; then
    log "部署 APK 工具链：apktool ${APKTOOL_VERSION} / jadx ${JADX_VERSION} / dex2jar ${DEX2JAR_VERSION} / uber-apk-signer ${UBER_APK_SIGNER_VERSION}"
    rm -rf "${SDK_ROOT}" "${BIN_DIR}"
    mkdir -p "${SDK_ROOT}" "${BIN_DIR}" "${SDK_DIR}/tmp"
    # apktool — 反编译/重打包 APK 资源和 smali
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_ROOT}/apktool.jar" \
        "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar"
    # jadx — dex 反编译为 Java 源码（zip 解压后 bin/ 下已有 jadx / jadx-gui 启动脚本）
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_DIR}/tmp/jadx.zip" \
        "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip"
    unzip -q "${SDK_DIR}/tmp/jadx.zip" -d "${SDK_ROOT}/jadx"
    chmod +x "${SDK_ROOT}/jadx/bin/jadx" "${SDK_ROOT}/jadx/bin/jadx-gui"
    # dex2jar — dex 与 jar 互转（解压后根目录含 d2j-*.sh，lib/ 同层，脚本靠
    # dirname 自身路径定位 lib，wrapper 用绝对路径调用即可，不要 cd）
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_DIR}/tmp/dex-tools.zip" \
        "https://github.com/ThexXTURBOXx/dex2jar/releases/download/${DEX2JAR_VERSION}/dex-tools-${DEX2JAR_VERSION}.zip"
    unzip -q "${SDK_DIR}/tmp/dex-tools.zip" -d "${SDK_DIR}/tmp/dxt"
    mv "${SDK_DIR}/tmp/dxt"/dex-tools-* "${SDK_ROOT}/dex2jar"
    chmod +x "${SDK_ROOT}"/dex2jar/d2j-*.sh
    # uber-apk-signer — APK 签名/zipalign/校验
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
        -o "${SDK_ROOT}/uber-apk-signer.jar" \
        "https://github.com/patrickfav/uber-apk-signer/releases/download/v${UBER_APK_SIGNER_VERSION}/uber-apk-signer-${UBER_APK_SIGNER_VERSION}.jar"
    rm -rf "${SDK_DIR}/tmp" # 一次性产物即时清理
    echo "${VERSIONS_FINGERPRINT}" > "${STAMP}"
else
    log "已部署（${VERSIONS_FINGERPRINT}），跳过下载"
fi

# 统一 wrapper：jar 入口 java -jar；jadx/d2j-* 经绝对路径 exec（不 cd，保用户相对路径）
printf '#!/usr/bin/env bash\nexec java -jar %s/apktool.jar "$@"\n'        "${SDK_ROOT}" > "${BIN_DIR}/apktool"
printf '#!/usr/bin/env bash\nexec java -jar %s/uber-apk-signer.jar "$@"\n' "${SDK_ROOT}" > "${BIN_DIR}/uber-apk-signer"
printf '#!/usr/bin/env bash\nexec %s/jadx/bin/jadx "$@"\n'                "${SDK_ROOT}" > "${BIN_DIR}/jadx"
printf '#!/usr/bin/env bash\nexec %s/jadx/bin/jadx-gui "$@"\n'            "${SDK_ROOT}" > "${BIN_DIR}/jadx-gui"
printf '#!/usr/bin/env bash\nexec %s/dex2jar/d2j-dex2jar.sh "$@"\n'       "${SDK_ROOT}" > "${BIN_DIR}/d2j-dex2jar"
printf '#!/usr/bin/env bash\nexec %s/dex2jar/d2j-baksmali.sh "$@"\n'      "${SDK_ROOT}" > "${BIN_DIR}/d2j-baksmali"
printf '#!/usr/bin/env bash\nexec %s/dex2jar/d2j-asm-verify.sh "$@"\n'    "${SDK_ROOT}" > "${BIN_DIR}/d2j-asm-verify"
chmod +x "${BIN_DIR}"/*

# 主命令软链到 /usr/local/bin（非登录 shell 可用）
for cmd in apktool uber-apk-signer jadx jadx-gui d2j-dex2jar; do
    ln -sf "${BIN_DIR}/${cmd}" "/usr/local/bin/${cmd}"
done

cat > /etc/profile.d/zz-sdk-apk-tools.sh <<EOF
# 由 sdks/apk-tools/SDK.sh 生成（每次启动重写，勿手改）
export PATH="\${PATH}:${BIN_DIR}"
EOF

if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi

log "APK 工具链就绪：apktool / jadx / d2j-dex2jar / uber-apk-signer（${VERSIONS_FINGERPRINT}）"
