# ==========================================
# 第三波【可选组件】：挂载式 SDK 自动部署（sdks/ 可扩展模式）
# ==========================================
# 扫描挂载目录 <SDKS_ROOT>（默认 /opt/sdks，compose: ./sdks:/opt/sdks）下的
# */SDK.sh，逐个经 run_sdk 后台部署（并发闸门限流：同时在途最多 3 个，完成一个
# 补位一个，顺序为目录名字典序）——与同波 DockerD / Magpie 及主服务启动重叠，
# 不阻塞任何服务就绪。目录结构 / SDK.sh 契约 / 官方模板见 sdks/README.md
# （随仓库自带；未挂载或目录为空则完全无感）。
#
# 组件两类：工具链（flutter/android/gradle/rust/apk-tools）首启下载部署到挂载
# 目录内、后续启动幂等秒过；数据库（pg/mysql/opengauss/kingbase/dm/redis）二进制
# 由 Base 层安装，SDK.sh 只做首启初始化与 supervisorctl 拉起，数据落挂载目录
# 之外（默认容器可写层，容器重建即全新）。
#
# SDK 为可选增强组件：部署失败以"失败"状态行暴露（附任务日志路径），不终止
# 容器；目录内提供 healthcheck.sh 的组件（数据库）失败后 healthcheck 变红。
# 停用开关 ENABLE_<目录名大写>=0：不下发部署、不参与健康检查（规则见 lib.sh）。
# ==========================================
init_sdks() {
    local sdks_root="${SDKS_ROOT:-/opt/sdks}" f dir name found=0
    if [ ! -d "${sdks_root}" ]; then
        echo "[第三波] - 未挂载 ${sdks_root}（compose: ./sdks:/opt/sdks），无 SDK 需要部署"
        return 0
    fi
    # SDK.sh 契约：SDK_DIR（本组件目录）与 SDK_OWNER（主账号，非 root 时部署
    # 完成后 chown）由本模块注入；手动容器内重跑时 SDK_DIR 缺省会取脚本自身
    # 所在目录，SDK_OWNER 缺省则不做 chown。
    export SDK_OWNER="${RUN_USER:-root}"
    for f in "${sdks_root}"/*/SDK.sh; do
        [ -f "${f}" ] || continue
        dir="$(dirname "${f}")"
        name="$(basename "${dir}")"
        if ! sdk_is_enabled "${name}"; then
            echo "[第三波][SDK:${name}] - [状态：跳过] - [$(sdk_enable_var "${name}")=0]"
            continue
        fi
        found=1
        SDK_DIR="${dir}" run_sdk 第三波 "SDK:${name}" "sdk-${name}" bash "${f}"
    done
    if [ "${found}" = "0" ]; then
        echo "[第三波] - ${sdks_root} 存在但无启用的 */SDK.sh，跳过"
    fi
}
init_sdks
