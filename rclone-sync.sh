#!/bin/bash
# rclone-sync.sh — Rclone 定时同步脚本
# 将 MotionEye 录像文件移动到远程网盘
# 支持循环存储：当远端超过阈值时自动删除最早期文件
set -euo pipefail

# ===== 配置（通过环境变量覆盖） =====
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
RCLONE_MAX_SIZE="${RCLONE_MAX_SIZE:-0}"
MEDIA_PATH="/var/lib/motioneye"
RCLONE_CONF="/config/rclone/rclone.conf"

echo "[rclone-sync] 启动 Rclone 定时同步"
echo "[rclone-sync] 远程目标: ${RCLONE_REMOTE}"
echo "[rclone-sync] 同步间隔: ${SYNC_INTERVAL}s"
echo "[rclone-sync] 媒体路径: ${MEDIA_PATH}"
if [ "${RCLONE_MAX_SIZE}" -gt 0 ] 2>/dev/null; then
    echo "[rclone-sync] 循环存储: 开启（上限 ${RCLONE_MAX_SIZE}GB）"
else
    echo "[rclone-sync] 循环存储: 未开启（RCLONE_MAX_SIZE 未设置或为 0）"
fi

# ===== 远程存储清理函数（循环存储） =====
# 当远端存储超过阈值时，按修改时间从早到晚逐个删除文件
cleanup_remote_storage() {
    local MAX_SIZE_GB="${RCLONE_MAX_SIZE:-0}"

    # 如果未配置或设为 0，跳过清理
    if [ "${MAX_SIZE_GB}" -le 0 ] 2>/dev/null; then
        return 0
    fi

    local MAX_BYTES=$((MAX_SIZE_GB * 1073741824))

    # 获取远程存储当前大小
    local SIZE_JSON
    SIZE_JSON=$(rclone size --json --config "${RCLONE_CONF}" "${RCLONE_REMOTE}" 2>/dev/null) || {
        echo "[rclone-cleanup] 无法获取远程存储大小，跳过清理"
        return 0
    }

    local CURRENT_BYTES
    CURRENT_BYTES=$(echo "${SIZE_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('bytes', 0))" 2>/dev/null) || {
        echo "[rclone-cleanup] 解析远程存储大小失败，跳过清理"
        return 0
    }

    local CURRENT_HR
    CURRENT_HR=$(python3 -c "print(f'{${CURRENT_BYTES}/1073741824:.2f}')")
    echo "[rclone-cleanup] 远程存储: ${CURRENT_HR}GB / ${MAX_SIZE_GB}GB 上限"

    if [ "${CURRENT_BYTES}" -le "${MAX_BYTES}" ]; then
        echo "[rclone-cleanup] 存储空间充足，无需清理"
        return 0
    fi

    echo "[rclone-cleanup] 存储超限，开始清理最早的文件..."

    # 列出所有文件并按修改时间排序（最早的在前），输出格式：SIZE\tPATH
    local TMPFILE="/tmp/rclone_cleanup_list.txt"
    rclone lsjson -R --files-only --config "${RCLONE_CONF}" "${RCLONE_REMOTE}" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    files = json.load(sys.stdin)
    files.sort(key=lambda f: f.get('ModTime', ''))
    for f in files:
        size = f.get('Size', 0)
        path = f.get('Path', '')
        if path:
            print(f'{size}\t{path}')
except Exception as e:
    print(f'[error] {e}', file=sys.stderr)
" > "${TMPFILE}" 2>/dev/null || {
        echo "[rclone-cleanup] 无法列出远程文件，跳过清理"
        rm -f "${TMPFILE}"
        return 0
    }

    local DELETED_COUNT=0
    local DELETED_BYTES=0

    while IFS=$'\t' read -r FILE_SIZE FILE_PATH; do
        # 已低于阈值，停止删除
        if [ "${CURRENT_BYTES}" -le "${MAX_BYTES}" ]; then
            break
        fi

        if [ -z "${FILE_PATH}" ]; then
            continue
        fi

        local FILE_SIZE_HR
        FILE_SIZE_HR=$(python3 -c "print(f'{${FILE_SIZE}/1048576:.1f}')")
        echo "[rclone-cleanup] 删除: ${FILE_PATH} (${FILE_SIZE_HR}MB)"

        if rclone deletefile --config "${RCLONE_CONF}" "${RCLONE_REMOTE}/${FILE_PATH}" 2>/dev/null; then
            CURRENT_BYTES=$((CURRENT_BYTES - FILE_SIZE))
            DELETED_BYTES=$((DELETED_BYTES + FILE_SIZE))
            DELETED_COUNT=$((DELETED_COUNT + 1))
        else
            echo "[rclone-cleanup] 删除失败: ${FILE_PATH}"
        fi
    done < "${TMPFILE}"

    rm -f "${TMPFILE}"

    # 清理远端空目录
    rclone rmdirs --config "${RCLONE_CONF}" "${RCLONE_REMOTE}" --leave-root 2>/dev/null || true

    local FREED_HR
    FREED_HR=$(python3 -c "print(f'{${DELETED_BYTES}/1048576:.1f}')")
    local REMAIN_HR
    REMAIN_HR=$(python3 -c "print(f'{${CURRENT_BYTES}/1073741824:.2f}')")
    echo "[rclone-cleanup] 清理完成: 删除 ${DELETED_COUNT} 个文件，释放 ${FREED_HR}MB，剩余 ${REMAIN_HR}GB"
}

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
        # 即使没有新文件，也执行清理检查（防止之前上传后未来得及清理）
        cleanup_remote_storage
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

    # 同步后执行远程存储清理（循环存储）
    cleanup_remote_storage
done
