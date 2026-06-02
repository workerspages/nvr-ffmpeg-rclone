#!/bin/bash
# rclone-sync.sh — Rclone 定时同步脚本
# 将 MotionEye 录像文件移动到远程网盘
set -euo pipefail

# ===== 配置（通过环境变量覆盖） =====
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
MEDIA_PATH="/var/lib/motioneye"
RCLONE_CONF="/config/rclone/rclone.conf"

echo "[rclone-sync] 启动 Rclone 定时同步"
echo "[rclone-sync] 远程目标: ${RCLONE_REMOTE}"
echo "[rclone-sync] 同步间隔: ${SYNC_INTERVAL}s"
echo "[rclone-sync] 媒体路径: ${MEDIA_PATH}"

# 检查 rclone.conf 是否存在
if [ ! -f "${RCLONE_CONF}" ]; then
    echo "[rclone-sync] 警告: rclone.conf 不存在 (${RCLONE_CONF})"
    echo "[rclone-sync] 请通过 RCLONE_CONFIG_BASE64 环境变量提供配置"
    echo "[rclone-sync] 同步功能已禁用，进入等待模式..."
    while true; do
        sleep "${SYNC_INTERVAL}"
    done
fi

# 主循环：定时同步
while true; do
    # 等待指定间隔
    sleep "${SYNC_INTERVAL}"

    echo "[rclone-sync] 开始同步..."

    # 检查是否有文件需要同步
    FILE_COUNT=$(find "${MEDIA_PATH}" -type f \( -name "*.mp4" -o -name "*.avi" -o -name "*.mkv" -o -name "*.mov" \) -mmin +1 2>/dev/null | wc -l)

    if [ "${FILE_COUNT}" -eq 0 ]; then
        echo "[rclone-sync] 没有需要同步的文件，跳过"
        continue
    fi

    echo "[rclone-sync] 发现 ${FILE_COUNT} 个文件待同步"

    # 使用 rclone move 移动文件到远程（移动后本地删除，节省空间）
    rclone move "${MEDIA_PATH}/" "${RCLONE_REMOTE}/" \
        --config "${RCLONE_CONF}" \
        --min-age 1m \
        --include "*.mp4" \
        --include "*.avi" \
        --include "*.mkv" \
        --include "*.mov" \
        --delete-empty-src-dirs \
        --transfers 1 \
        --buffer-size 0 \
        --low-level-retries 3 \
        --retries 3 \
        --stats-one-line \
        -v \
        2>&1 || echo "[rclone-sync] 同步出错，将在下次重试"

    echo "[rclone-sync] 同步完成"
done
