# ==========================================
# DinD dockerd 开关（默认关闭以节省内存）
# 与五库同模式（第三波资源组件）：supervisord.conf autostart 恒为 false，
# ENABLE_DOCKERD=1 时后台任务经 supervisorctl 运行期拉起（dockerd 无初始化
# 步骤，等待 supervisord 就绪即拉起）。
# 运行中随时可手动拉起：supervisorctl start dockerd
# ==========================================
start_dockerd() {
    supervisorctl_start dockerd || { log_fatal "DockerD 拉起失败"; return 1; }
    echo "==> DockerD 就绪：unix:///var/run/docker.sock（DinD，数据目录 /tmp/docker）"
}
if [ "${ENABLE_DOCKERD:-0}" = "1" ]; then
    run_bg dockerd-init start_dockerd
    echo "==> [DockerD] 后台并行拉起已排队 (ENABLE_DOCKERD=1)"
else
    echo "==> [DockerD] 开机自启已关闭 (默认)。需要时运行: supervisorctl start dockerd"
fi
