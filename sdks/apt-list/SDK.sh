#!/usr/bin/env bash
# ==========================================
# apt 安装清单挂载式部署脚本（随仓库自带，官方模板）
# ==========================================
# 清单是同目录的 packages.txt，由使用者维护：一行一个包名，# 之后是注释，空行
# 忽略。本脚本每次容器启动时对照清单，把尚未安装的包用 apt 装进容器可写层
# （docker restart 保留；容器重建后下次启动自动重装）。清单里没有未安装的包时
# 不访问 apt 源。包名按 Debian 的命名规则校验，出现不合法的行则整份清单不执行。
# 契约详见 sdks/README.md。
# ==========================================
set -euo pipefail

SDK_NAME="apt-list"
SDK_DIR="${SDK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LIST_FILE="${SDK_DIR}/packages.txt"

log()   { echo "==> [${SDK_NAME}] $*"; }
fatal() { echo "==> [${SDK_NAME}] FATAL: $*" >&2; exit 1; }

[ -f "${LIST_FILE}" ] || fatal "未找到清单 ${LIST_FILE}（一行一个包名）"

# 读清单：去掉注释与首尾空白后逐行校验，合法的包名存进 packages。
packages=()
lineno=0
while IFS= read -r line || [ -n "${line}" ]; do
    lineno=$((lineno + 1))
    name="${line%%#*}"
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    if [ -z "${name}" ]; then
        continue
    fi
    if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]]; then
        fatal "${LIST_FILE} 第 ${lineno} 行不是合法的包名：${name}"
    fi
    packages+=("${name}")
done < "${LIST_FILE}"

if [ "${#packages[@]}" -eq 0 ]; then
    log "清单为空，无需安装"
    exit 0
fi

missing=()
for name in "${packages[@]}"; do
    if [ "$(dpkg-query -W -f='${db:Status-Status}' "${name}" 2>/dev/null || true)" != "installed" ]; then
        missing+=("${name}")
    fi
done
if [ "${#missing[@]}" -eq 0 ]; then
    log "清单里的 ${#packages[@]} 个包都已安装，无需处理"
    exit 0
fi

log "安装 ${#missing[@]} 个尚未安装的包：${missing[*]}"
export DEBIAN_FRONTEND=noninteractive
# 源列表只服务于本次安装，成败都清掉，不在可写层里留下几十 MB 的索引。
drop_lists() { rm -rf /var/lib/apt/lists/*; }
apt-get update || { drop_lists; fatal "apt-get update 失败（见上方输出）"; }
rc=0
apt-get install -y "${missing[@]}" || rc=$?
drop_lists
if [ "${rc}" != 0 ]; then
    fatal "apt-get install 失败：${missing[*]}（见上方输出）"
fi
log "已安装：${missing[*]}"
