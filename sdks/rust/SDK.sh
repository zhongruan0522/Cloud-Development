#!/usr/bin/env bash
# ==========================================
# Rust 工具链挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 契约（详见 sdks/README.md）：sdk/rustup = RUSTUP_HOME、sdk/cargo =
# CARGO_HOME（含 registry/git 缓存与已装二进制，随挂载持久化）；tmp/ 一次性
# 产物即清。minimal profile + clippy/rustfmt/rust-src（nightly 全家桶体积
# ~1.4G 无引用方，不装，对齐拆出前 Base 层策略）；share/doc|man 安装后裁剪。
# 幂等：rustup 已装且版本一致时跳过；改 RUST_VERSION 走 rustup 增量装新
# 工具链（旧工具链保留，rustup 官方多工具链机制）。
# 镜像：默认国内 rsproxy.cn（rustup-init / dist 工具链 / cargo crates 全链路），
# 安装失败自动退化官方源重试一次；RUST_MIRROR=official 强制官方；
# 外部显式设置 RUSTUP_DIST_SERVER / RUSTUP_UPDATE_ROOT 时完全尊重外部值。
# ==========================================
set -euo pipefail

SDK_NAME="rust"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
RUST_VERSION="${RUST_VERSION:-1.95.0}" # 版本覆盖：compose environment / 命令行 env / 直接改此默认值
SDK_OWNER="${SDK_OWNER:-}"
RUSTUP_HOME="${SDK_DIR}/sdk/rustup"
CARGO_HOME="${SDK_DIR}/sdk/cargo"
STAMP="${SDK_DIR}/sdk/.rust-version"
export RUSTUP_HOME CARGO_HOME

log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

# ---------- 镜像源决策（默认国内 rsproxy，安装失败退化官方重试） ----------
MIRROR_MODE="official"
RUSTUP_INIT_URL="https://sh.rustup.rs"
if [ -n "${RUSTUP_DIST_SERVER:-}" ] || [ -n "${RUSTUP_UPDATE_ROOT:-}" ]; then
    MIRROR_MODE="external" # 外部显式指定源：完全尊重，不做镜像切换
    log "镜像源：外部指定（DIST_SERVER=${RUSTUP_DIST_SERVER:-<官方>} UPDATE_ROOT=${RUSTUP_UPDATE_ROOT:-<官方>}）"
elif [ "${RUST_MIRROR:-cn}" != "official" ]; then
    MIRROR_MODE="cn"
    export RUSTUP_DIST_SERVER="https://rsproxy.cn"
    export RUSTUP_UPDATE_ROOT="https://rsproxy.cn/rustup"
    RUSTUP_INIT_URL="https://rsproxy.cn/rustup-init.sh"
    log "镜像源：rsproxy.cn（国内；RUST_MIRROR=official 可强制官方）"
else
    log "镜像源：官方 static.rust-lang.org（RUST_MIRROR=official）"
fi

# && 链保证 curl 失败即整体失败（errexit 在 if ! 测试上下文中不触发，靠返回值传递）
install_toolchain() {
    mkdir -p "${SDK_DIR}/tmp" "${SDK_DIR}/sdk"
    curl --proto '=https' --tlsv1.2 -sSf "${RUSTUP_INIT_URL}" -o "${SDK_DIR}/tmp/rustup-init.sh" &&
        sh "${SDK_DIR}/tmp/rustup-init.sh" -y --no-modify-path \
            --default-toolchain "${RUST_VERSION}" --profile minimal
}

if [ ! -x "${CARGO_HOME}/bin/rustup" ]; then
    log "部署 Rust 工具链 ${RUST_VERSION}（minimal + clippy/rustfmt/rust-src，约 1G）"
    if ! install_toolchain; then
        if [ "${MIRROR_MODE}" = "cn" ]; then
            log "国内镜像源安装失败（见上方输出），退化官方源 static.rust-lang.org 重试"
            unset RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT
            RUSTUP_INIT_URL="https://sh.rustup.rs"
            rm -rf "${SDK_DIR}/tmp" "${RUSTUP_HOME}" "${CARGO_HOME}/bin" # 清半截产物干净重来
            install_toolchain || fatal "官方源重试仍失败（见上方输出），请检查网络/代理后重启容器重试"
        else
            rm -rf "${SDK_DIR}/tmp"
            fatal "安装失败（见上方输出），请检查网络后重启容器重试"
        fi
    fi
    rm -rf "${SDK_DIR}/tmp" # 一次性产物即时清理
    echo "${RUST_VERSION}" > "${STAMP}"
elif [ "$(cat "${STAMP}" 2>/dev/null || true)" != "${RUST_VERSION}" ]; then
    log "切换默认工具链 → ${RUST_VERSION}（rustup 增量安装，旧工具链保留）"
    "${CARGO_HOME}/bin/rustup" toolchain install "${RUST_VERSION}" --profile minimal
    "${CARGO_HOME}/bin/rustup" default "${RUST_VERSION}"
    echo "${RUST_VERSION}" > "${STAMP}"
else
    log "已部署（${RUST_VERSION}），跳过下载"
fi

# cargo registry 镜像：国内默认 rsproxy sparse（幂等，每次启动重写）；
# official 模式清理配置回官方；external 模式不动用户已有 config.toml
case "${MIRROR_MODE}" in
    cn)
        cat > "${CARGO_HOME}/config.toml" <<'EOF'
[source.crates-io]
replace-with = 'rsproxy-sparse'

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"

[registries.rsproxy]
index = "sparse+https://rsproxy.cn/crates.io-index/"

[net]
git-fetch-with-cli = true
EOF
        log "cargo registry → rsproxy sparse（${CARGO_HOME}/config.toml，随挂载持久化）"
        ;;
    official)
        if [ -f "${CARGO_HOME}/config.toml" ]; then
            rm -f "${CARGO_HOME}/config.toml"
            log "cargo registry → 官方 crates.io（已清理 rsproxy 配置）"
        fi
        ;;
esac

# clippy/rustfmt/rust-src：部署/升级路径补装（幂等，已装秒过）
if [ "$(cat "${STAMP}" 2>/dev/null || true)" != "$(cat "${SDK_DIR}/sdk/.components-done" 2>/dev/null || true)" ]; then
    "${CARGO_HOME}/bin/rustup" component add clippy rustfmt rust-src
    # share/doc 与 share/man 对运行无用，裁剪省 ~百 MB（对齐拆出前策略）
    rm -rf "${RUSTUP_HOME}"/toolchains/*/share/doc "${RUSTUP_HOME}"/toolchains/*/share/man
    echo "$(cat "${STAMP}")" > "${SDK_DIR}/sdk/.components-done"
fi

# /usr/local/bin 软链（rustup 三件套代理，非登录 shell 可用）
ln -sf "${CARGO_HOME}/bin/rustup" /usr/local/bin/rustup
ln -sf "${CARGO_HOME}/bin/cargo" /usr/local/bin/cargo
ln -sf "${CARGO_HOME}/bin/rustc" /usr/local/bin/rustc

cat > /etc/profile.d/zz-sdk-rust.sh <<EOF
# 由 sdks/rust/SDK.sh 生成（每次启动重写，勿手改）
export RUSTUP_HOME="${RUSTUP_HOME}"
export CARGO_HOME="${CARGO_HOME}"
export RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://static.rust-lang.org}"
export RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-https://static.rust-lang.org/rustup}"
export PATH="\${PATH}:${CARGO_HOME}/bin"
EOF

if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi

log "Rust 工具链就绪：$("${CARGO_HOME}/bin/rustc" --version)（cargo registry 缓存随挂载持久化）"
