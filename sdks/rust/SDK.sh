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

if [ ! -x "${CARGO_HOME}/bin/rustup" ]; then
    log "部署 Rust 工具链 ${RUST_VERSION}（minimal + clippy/rustfmt/rust-src，约 1G）"
    mkdir -p "${SDK_DIR}/tmp" "${SDK_DIR}/sdk"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "${SDK_DIR}/tmp/rustup-init.sh"
    sh "${SDK_DIR}/tmp/rustup-init.sh" -y --no-modify-path \
        --default-toolchain "${RUST_VERSION}" --profile minimal
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
export PATH="\${PATH}:${CARGO_HOME}/bin"
EOF

if [ "$(id -u)" = "0" ] && [ -n "${SDK_OWNER}" ] && [ "${SDK_OWNER}" != "root" ]; then
    chown -R "${SDK_OWNER}" "${SDK_DIR}"
fi

log "Rust 工具链就绪：$("${CARGO_HOME}/bin/rustc" --version)（cargo registry 缓存随挂载持久化）"
