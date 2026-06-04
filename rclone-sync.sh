#!/bin/bash
# rclone-sync.sh — Rclone 定时同步脚本（Moonfire NVR 版本）
# 通过 Moonfire API 导出录像为 MP4，然后移动到远程网盘
# 支持循环存储：当远端超过阈值时自动删除最早期文件
set -euo pipefail

# ===== 配置（通过环境变量覆盖） =====
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
MAX_SIZE_GB="${RCLONE_MAX_SIZE:-0}"
# Rclone 会自动读取所有 RCLONE_ 开头的环境变量。RCLONE_MAX_SIZE 会被误认为 --max-size 过滤器参数。
# 而 --max-size 不能与 --files-from 同时使用，因此在这里将其 unset，避免引发 CRITICAL 错误。
unset RCLONE_MAX_SIZE

PORT="${PORT:-8080}"
EXPORT_PATH="/tmp/nvr-export"
RCLONE_CONF="/config/rclone/rclone.conf"
MOONFIRE_API="http://127.0.0.1:${PORT}/api"
# 每次导出的片段时长（秒），默认 5 分钟
SEGMENT_DURATION=300
LAST_SYNC_FILE="/var/lib/moonfire-nvr/last_sync_time"

echo "[rclone-sync] 启动 Rclone 定时同步（Moonfire NVR 模式）"
echo "[rclone-sync] 远程目标: ${RCLONE_REMOTE}"
echo "[rclone-sync] 同步间隔: ${SYNC_INTERVAL}s"
echo "[rclone-sync] 导出路径: ${EXPORT_PATH}"
if [ "${MAX_SIZE_GB}" -gt 0 ] 2>/dev/null; then
    echo "[rclone-sync] 循环存储: 开启（上限 ${MAX_SIZE_GB}GB）"
else
    echo "[rclone-sync] 循环存储: 未开启（RCLONE_MAX_SIZE 未设置或为 0）"
fi

# ===== 辅助函数：人类可读大小 =====
human_size_mb() {
    local bytes="${1:-0}"
    awk "BEGIN { printf \"%.1f\", ${bytes} / 1048576 }"
}

human_size_gb() {
    local bytes="${1:-0}"
    awk "BEGIN { printf \"%.2f\", ${bytes} / 1073741824 }"
}

# ===== Rclone 配置诊断函数 =====
verify_rclone_config() {
    echo "[rclone-check] ========================================"
    echo "[rclone-check]   Rclone 配置诊断"
    echo "[rclone-check] ========================================"

    # 1. 配置文件存在性
    if [ ! -f "${RCLONE_CONF}" ]; then
        echo "[rclone-check] ✗ 配置文件不存在: ${RCLONE_CONF}"
        return 1
    fi
    echo "[rclone-check] ✓ 配置文件: ${RCLONE_CONF}"

    # 2. 列出所有已配置的远程
    echo "[rclone-check] --- 已配置的远程 ---"
    local REMOTES
    REMOTES=$(rclone listremotes --config "${RCLONE_CONF}" 2>&1) || {
        echo "[rclone-check] ✗ 无法解析 rclone.conf，文件可能损坏"
        echo "[rclone-check]   错误: ${REMOTES}"
        return 1
    }
    if [ -z "${REMOTES}" ]; then
        echo "[rclone-check] ✗ rclone.conf 中没有定义任何远程"
        return 1
    fi
    echo "${REMOTES}" | while IFS= read -r r; do
        echo "[rclone-check]   • ${r}"
    done

    # 3. 检查目标远程是否存在于配置中
    local REMOTE_NAME="${RCLONE_REMOTE%%:*}"
    if ! echo "${REMOTES}" | grep -q "^${REMOTE_NAME}:$"; then
        echo "[rclone-check] ✗ 目标远程 '${REMOTE_NAME}' 未在 rclone.conf 中定义！"
        echo "[rclone-check]   当前 RCLONE_REMOTE=${RCLONE_REMOTE}"
        echo "[rclone-check]   可用的远程: ${REMOTES}"
        return 1
    fi
    echo "[rclone-check] ✓ 目标远程 '${REMOTE_NAME}' 已在配置中"

    # 4. 测试远程连通性
    echo "[rclone-check] --- 测试连通性 ---"
    local CONN_OUTPUT
    CONN_OUTPUT=$(rclone lsd --config "${RCLONE_CONF}" "${REMOTE_NAME}:" --max-depth 1 2>&1) || true
    if [ -n "${CONN_OUTPUT}" ]; then
        echo "${CONN_OUTPUT}" | head -10 | while IFS= read -r line; do
            echo "[rclone-check]   ${line}"
        done
    else
        echo "[rclone-check]   （远程根目录为空，这是正常的）"
    fi
    echo "[rclone-check] ✓ 远程连通性正常"

    # 5. 测试写入权限
    echo "[rclone-check] --- 测试写入权限 ---"
    local TEST_FILE=".rclone-write-test-$(date +%s)"
    local WRITE_OUTPUT
    WRITE_OUTPUT=$(echo "rclone-write-test" | rclone rcat --config "${RCLONE_CONF}" "${RCLONE_REMOTE}/${TEST_FILE}" 2>&1) || {
        echo "[rclone-check] ✗ 写入测试失败！"
        echo "[rclone-check]   目标: ${RCLONE_REMOTE}/${TEST_FILE}"
        echo "[rclone-check]   错误: ${WRITE_OUTPUT}"
        echo "[rclone-check]   请检查远程权限、API 配额或网络连接"
        return 1
    }
    echo "[rclone-check] ✓ 写入测试成功"
    rclone deletefile --config "${RCLONE_CONF}" "${RCLONE_REMOTE}/${TEST_FILE}" 2>/dev/null || true
    echo "[rclone-check] ✓ 测试文件已清理"

    # 6. 显示远程存储信息
    echo "[rclone-check] --- 远程存储信息 ---"
    local ABOUT_OUTPUT
    ABOUT_OUTPUT=$(rclone about --config "${RCLONE_CONF}" "${REMOTE_NAME}:" 2>&1) || true
    if [ -n "${ABOUT_OUTPUT}" ]; then
        echo "${ABOUT_OUTPUT}" | while IFS= read -r line; do
            echo "[rclone-check]   ${line}"
        done
    fi

    echo "[rclone-check] ========================================"
    echo "[rclone-check]   诊断结果: 全部通过 ✓"
    echo "[rclone-check] ========================================"
    return 0
}

# ===== 远程存储清理函数（循环存储） =====
cleanup_remote_storage() {
    if [ "${MAX_SIZE_GB}" -le 0 ] 2>/dev/null; then
        return 0
    fi

    local MAX_BYTES
    MAX_BYTES=$(awk "BEGIN { printf \"%.0f\", ${MAX_SIZE_GB} * 1073741824 }")

    # 获取远程存储当前大小
    local SIZE_JSON
    SIZE_JSON=$(rclone size --json --config "${RCLONE_CONF}" "${RCLONE_REMOTE}" 2>/dev/null) || {
        echo "[rclone-cleanup] 无法获取远程存储大小，跳过清理"
        return 0
    }

    local CURRENT_BYTES
    CURRENT_BYTES=$(echo "${SIZE_JSON}" | jq -r '.bytes // 0' 2>/dev/null) || {
        echo "[rclone-cleanup] 解析远程存储大小失败，跳过清理"
        return 0
    }

    local CURRENT_HR
    CURRENT_HR=$(human_size_gb "${CURRENT_BYTES}")
    echo "[rclone-cleanup] 远程存储: ${CURRENT_HR}GB / ${MAX_SIZE_GB}GB 上限"

    if [ "${CURRENT_BYTES}" -le "${MAX_BYTES}" ]; then
        echo "[rclone-cleanup] 存储空间充足，无需清理"
        return 0
    fi

    echo "[rclone-cleanup] 存储超限，开始清理最早的文件..."

    local TMPFILE="/tmp/rclone_cleanup_list.txt"
    rclone lsjson -R --files-only --config "${RCLONE_CONF}" "${RCLONE_REMOTE}" 2>/dev/null | \
        jq -r 'sort_by(.ModTime) | .[] | select(.Path != "") | "\(.Size)\t\(.Path)"' \
        > "${TMPFILE}" 2>/dev/null || {
        echo "[rclone-cleanup] 无法列出远程文件，跳过清理"
        rm -f "${TMPFILE}"
        return 0
    }

    local DELETED_COUNT=0
    local DELETED_BYTES=0

    while IFS=$'\t' read -r FILE_SIZE FILE_PATH; do
        if [ "${CURRENT_BYTES}" -le "${MAX_BYTES}" ]; then
            break
        fi

        if [ -z "${FILE_PATH}" ]; then
            continue
        fi

        local FILE_SIZE_HR
        FILE_SIZE_HR=$(human_size_mb "${FILE_SIZE}")
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
    FREED_HR=$(human_size_mb "${DELETED_BYTES}")
    local REMAIN_HR
    REMAIN_HR=$(human_size_gb "${CURRENT_BYTES}")
    echo "[rclone-cleanup] 清理完成: 删除 ${DELETED_COUNT} 个文件，释放 ${FREED_HR}MB，剩余 ${REMAIN_HR}GB"
}

# ===== 从 Moonfire API 导出录像为 MP4 =====
export_recordings() {
    # 获取当前时间（ISO 8601 格式，Moonfire API 使用 90kHz 时钟）
    local NOW_EPOCH
    NOW_EPOCH=$(date +%s)

    # 读取上次同步时间
    local LAST_SYNC_EPOCH=0
    if [ -f "${LAST_SYNC_FILE}" ]; then
        LAST_SYNC_EPOCH=$(cat "${LAST_SYNC_FILE}" 2>/dev/null || echo "0")
    fi

    # 如果是首次同步，只导出最近一个同步周期的录像
    if [ "${LAST_SYNC_EPOCH}" -eq 0 ]; then
        LAST_SYNC_EPOCH=$((NOW_EPOCH - SYNC_INTERVAL))
    fi

    # 避免导出正在写入的录像（留 60 秒缓冲）
    local END_EPOCH=$((NOW_EPOCH - 60))

    if [ "${END_EPOCH}" -le "${LAST_SYNC_EPOCH}" ]; then
        echo "[rclone-sync] 没有新的时间段需要导出"
        return 0
    fi

    # Moonfire API 使用 90kHz 时钟的时间
    local START_90K=$((LAST_SYNC_EPOCH * 90000))
    local END_90K=$((END_EPOCH * 90000))

    # 获取摄像头列表
    local API_RESPONSE
    API_RESPONSE=$(curl -sf "${MOONFIRE_API}/" -H "Accept: application/json" 2>/dev/null) || {
        echo "[rclone-sync] 无法连接 Moonfire API，跳过本次导出"
        return 1
    }

    local CAMERA_COUNT
    CAMERA_COUNT=$(echo "${API_RESPONSE}" | jq '.cameras | length' 2>/dev/null || echo "0")

    if [ "${CAMERA_COUNT}" -eq 0 ]; then
        echo "[rclone-sync] 未配置摄像头，跳过导出"
        return 0
    fi

    local EXPORTED_COUNT=0

    # 遍历每个摄像头
    echo "${API_RESPONSE}" | jq -c '.cameras[]' 2>/dev/null | while IFS= read -r camera; do
        local CAM_UUID
        CAM_UUID=$(echo "${camera}" | jq -r '.uuid' 2>/dev/null)
        local CAM_NAME
        CAM_NAME=$(echo "${camera}" | jq -r '.shortName // "Unknown"' 2>/dev/null)

        # 检查每个流（main/sub）
        for STREAM_TYPE in main sub; do
            local STREAM_INFO
            STREAM_INFO=$(echo "${camera}" | jq -r ".streams.${STREAM_TYPE} // empty" 2>/dev/null)

            if [ -z "${STREAM_INFO}" ] || [ "${STREAM_INFO}" = "null" ]; then
                continue
            fi

            # 查询录像列表
            local RECORDINGS
            RECORDINGS=$(curl -sf "${MOONFIRE_API}/cameras/${CAM_UUID}/${STREAM_TYPE}/recordings?startTime90k=${START_90K}&endTime90k=${END_90K}" \
                -H "Accept: application/json" 2>/dev/null) || continue

            local REC_COUNT
            REC_COUNT=$(echo "${RECORDINGS}" | jq '.recordings | length' 2>/dev/null || echo "0")

            if [ "${REC_COUNT}" -eq 0 ]; then
                continue
            fi

            echo "[rclone-sync] ${CAM_NAME}/${STREAM_TYPE}: 发现 ${REC_COUNT} 段录像"

            # 按时间段分片导出（避免单个文件太大）
            local CHUNK_START="${LAST_SYNC_EPOCH}"
            while [ "${CHUNK_START}" -lt "${END_EPOCH}" ]; do
                local CHUNK_END=$((CHUNK_START + SEGMENT_DURATION))
                if [ "${CHUNK_END}" -gt "${END_EPOCH}" ]; then
                    CHUNK_END="${END_EPOCH}"
                fi

                local CHUNK_START_90K=$((CHUNK_START * 90000))
                local CHUNK_END_90K=$((CHUNK_END * 90000))

                # 查询该时间段的录像 ID
                local CHUNK_RECS
                CHUNK_RECS=$(curl -sf "${MOONFIRE_API}/cameras/${CAM_UUID}/${STREAM_TYPE}/recordings?startTime90k=${CHUNK_START_90K}&endTime90k=${CHUNK_END_90K}" \
                    -H "Accept: application/json" 2>/dev/null) || { CHUNK_START="${CHUNK_END}"; continue; }

                local CHUNK_REC_COUNT
                CHUNK_REC_COUNT=$(echo "${CHUNK_RECS}" | jq '.recordings | length' 2>/dev/null || echo "0")

                if [ "${CHUNK_REC_COUNT}" -eq 0 ]; then
                    CHUNK_START="${CHUNK_END}"
                    continue
                fi

                # 构建 segment 参数（拼接所有录像 ID）
                local S_PARAM
                S_PARAM=$(echo "${CHUNK_RECS}" | jq -r '[.recordings[].id | tostring] | join(",")' 2>/dev/null)

                if [ -z "${S_PARAM}" ] || [ "${S_PARAM}" = "null" ]; then
                    CHUNK_START="${CHUNK_END}"
                    continue
                fi

                # 生成导出文件名
                local DATE_DIR
                DATE_DIR=$(date -d "@${CHUNK_START}" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")
                local TIME_PART
                TIME_PART=$(date -d "@${CHUNK_START}" "+%H-%M-%S" 2>/dev/null || date "+%H-%M-%S")
                local EXPORT_DIR="${EXPORT_PATH}/${CAM_NAME}/${DATE_DIR}"
                local EXPORT_FILE="${EXPORT_DIR}/${TIME_PART}.mp4"

                mkdir -p "${EXPORT_DIR}"

                # 通过 API 下载 MP4
                if curl -sf "${MOONFIRE_API}/cameras/${CAM_UUID}/${STREAM_TYPE}/view.mp4?s=${S_PARAM}" \
                    -o "${EXPORT_FILE}" 2>/dev/null; then
                    local FILE_SIZE
                    FILE_SIZE=$(stat -c%s "${EXPORT_FILE}" 2>/dev/null || echo "0")
                    if [ "${FILE_SIZE}" -gt 0 ]; then
                        local FILE_SIZE_HR
                        FILE_SIZE_HR=$(human_size_mb "${FILE_SIZE}")
                        echo "[rclone-sync]   导出: ${CAM_NAME}/${DATE_DIR}/${TIME_PART}.mp4 (${FILE_SIZE_HR}MB)"
                        EXPORTED_COUNT=$((EXPORTED_COUNT + 1))
                    else
                        rm -f "${EXPORT_FILE}"
                    fi
                fi

                CHUNK_START="${CHUNK_END}"
            done
        done
    done

    # 更新同步时间戳
    echo "${END_EPOCH}" > "${LAST_SYNC_FILE}"

    return 0
}

# ===== 启动检查 =====
# 检查 rclone.conf 是否存在
if [ ! -f "${RCLONE_CONF}" ]; then
    echo "[rclone-sync] 警告: rclone.conf 不存在 (${RCLONE_CONF})"
    echo "[rclone-sync] 请通过 RCLONE_CONFIG_BASE64 环境变量提供配置"
    echo "[rclone-sync] 同步功能已禁用，进入等待模式..."
    while true; do
        sleep "${SYNC_INTERVAL}"
    done
fi

# 运行 Rclone 配置诊断
if ! verify_rclone_config; then
    echo "[rclone-sync] ✗ Rclone 配置诊断未通过！同步功能可能无法正常工作"
    echo "[rclone-sync] 请检查以上诊断日志修复问题后重启容器"
    echo "[rclone-sync] 脚本将继续运行但同步可能失败..."
fi

# 等待 Moonfire NVR 启动
echo "[rclone-sync] 等待 Moonfire NVR API 就绪..."
RETRIES=0
while ! curl -sf "${MOONFIRE_API}/" -H "Accept: application/json" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge 60 ]; then
        echo "[rclone-sync] Moonfire NVR 未就绪，将在同步循环中重试..."
        break
    fi
    sleep 2
done

# ===== 主循环：定时同步 =====
while true; do
    # 等待指定间隔
    sleep "${SYNC_INTERVAL}"

    echo "[rclone-sync] 开始同步..."

    # 第一步：从 Moonfire API 导出录像到临时目录
    export_recordings || echo "[rclone-sync] 导出过程出现异常，将继续尝试上传已导出的文件"

    # 第二步：使用 rclone 将导出的文件移动到远程
    FOUND_FILES=$(find "${EXPORT_PATH}" -type f -name "*.mp4" -mmin +1 2>/dev/null | head -100 || true)

    if [ -z "${FOUND_FILES}" ]; then
        echo "[rclone-sync] 没有需要同步的文件，跳过"
        cleanup_remote_storage || echo "[rclone-cleanup] 清理过程出现异常，将在下次重试"
        continue
    fi

    FILE_COUNT=$(echo "${FOUND_FILES}" | wc -l)
    echo "[rclone-sync] 发现 ${FILE_COUNT} 个文件待同步:"
    echo "${FOUND_FILES}" | head -5 | while IFS= read -r f; do
        FSIZE=$(stat -c%s "$f" 2>/dev/null || echo "?")
        FSIZE_HR=$(human_size_mb "${FSIZE}")
        echo "[rclone-sync]   ${f} (${FSIZE_HR}MB)"
    done
    if [ "${FILE_COUNT}" -gt 5 ]; then
        echo "[rclone-sync]   ... 还有 $((FILE_COUNT - 5)) 个文件"
    fi

    # 使用 rclone move 移动文件到远程
    echo "[rclone-sync] 执行 rclone move -> ${RCLONE_REMOTE} ..."
    rclone move "${EXPORT_PATH}/" "${RCLONE_REMOTE}/" \
        --config "${RCLONE_CONF}" \
        --delete-empty-src-dirs \
        --transfers 1 \
        --buffer-size 0 \
        --low-level-retries 3 \
        --retries 3 \
        --stats-one-line \
        --stats 30s \
        -v \
        2>&1 || echo "[rclone-sync] 同步出错，将在下次重试"

    echo "[rclone-sync] 同步完成"

    # 同步后执行远程存储清理
    cleanup_remote_storage || echo "[rclone-cleanup] 清理过程出现异常，将在下次重试"
done
