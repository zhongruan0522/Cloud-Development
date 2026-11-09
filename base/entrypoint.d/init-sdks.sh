# ==========================================
# 第四波【SDK 组件】：挂载式 SDK 自动部署（sdks/ 可扩展模式）
# ==========================================
# 扫描挂载目录 <SDKS_ROOT>（默认 /opt/sdks，compose: ./sdks:/opt/sdks）下的
# */SDK.sh，逐个经 run_bg 后台并行执行——与前三波任务及主服务启动重叠，
# 不阻塞任何服务就绪。目录结构 / SDK.sh 契约 / 官方模板见 sdks/README.md
# （随仓库自带；未挂载或目录为空则完全无感）。
#
# SDK 为可选增强组件：部署失败以"失败"状态行暴露（附任务日志路径），
# 不终止容器、不参与 healthcheck；不设并行闸门（下载是网络 IO 非内存资源）。
# ==========================================
init_sdks() {
    local sdks_root="${SDKS_ROOT:-/opt/sdks}" f dir name found=0
    if [ ! -d "${sdks_root}" ]; then
        echo "[第四波] - 未挂载 ${sdks_root}（compose: ./sdks:/opt/sdks），无 SDK 需要部署"
        return 0
    fi
    # SDK.sh 契约：SDK_DIR（本组件目录）与 SDK_OWNER（主账号，非 root 时部署
    # 完成后 chown）由本模块注入；手动容器内重跑时 SDK_DIR 缺省会取脚本自身
    # 所在目录，SDK_OWNER 缺省则不做 chown。
    export SDK_OWNER="${RUN_USER:-root}"
    for f in "${sdks_root}"/*/SDK.sh; do
        [ -f "${f}" ] || continue
        found=1
        dir="$(dirname "${f}")"
        name="$(basename "${dir}")"
        SDK_DIR="${dir}" run_bg 第四波 "SDK:${name}" "sdk-${name}" bash "${f}"
    done
    if [ "${found}" = "0" ]; then
        echo "[第四波] - ${sdks_root} 存在但无任何 */SDK.sh，跳过"
    fi
}
init_sdks
