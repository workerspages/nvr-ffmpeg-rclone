#!/bin/bash
# rclone-sync.sh — Rclone 定时同步脚本
# 将 MotionEye 录像文件移动到远程网盘
# 支持循环存储：当远端超过阈值时自动删除最早期文件
set -euo pipefail

# ===== 配置（通过环境变量覆盖） =====
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
MAX_SIZE_GB="${RCLONE_MAX_SIZE:-0}"
# Rclone 会自动读取所有 RCLONE_ 开头的环境变量。RCLONE_MAX_SIZE 会被误认为 --max-size 过滤器参数。
# 而 --max-size 不能与 --files-from 同时使用，因此在这里将其 unset，避免引发 CRITICAL 错误。
unset RCLONE_MAX_SIZE

MEDIA_PATH="/var/lib/motioneye"
RCLONE_CONF="/config/rclone/rclone.conf"

echo "[rclone-sync] 启动 Rclone 定时同步"
echo "[rclone-sync] 远程目标: ${RCLONE_REMOTE}"
echo "[rclone-sync] 同步间隔: ${SYNC_INTERVAL}s"
echo "[rclone-sync] 媒体路径: ${MEDIA_PATH}"
if [ "${MAX_SIZE_GB}" -gt 0 ] 2>/dev/null; then
    echo "[rclone-sync] 循环存储: 开启（上限 ${MAX_SIZE_GB}GB）"
else
    echo "[rclone-sync] 循环存储: 未开启（RCLONE_MAX_SIZE 未设置或为 0）"
fi

# ===== Rclone 配置诊断函数 =====
# 启动时运行，逐项检查配置文件、远程连通性、写入权限
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

    # 5. 测试写入权限（创建测试文件然后删除）
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
    # 清理测试文件
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
# 当远端存储超过阈值时，按修改时间从早到晚逐个删除文件
cleanup_remote_storage() {
    # 之前这里是 local MAX_SIZE_GB="${RCLONE_MAX_SIZE:-0}"，现在直接使用全局的 MAX_SIZE_GB

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
    CURRENT_HR=$(python3 -c "print(f'{${CURRENT_BYTES}/1073741824:.2f}')" 2>/dev/null) || CURRENT_HR="unknown"
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
        FILE_SIZE_HR=$(python3 -c "print(f'{${FILE_SIZE}/1048576:.1f}')" 2>/dev/null) || FILE_SIZE_HR="?"
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
    FREED_HR=$(python3 -c "print(f'{${DELETED_BYTES}/1048576:.1f}')" 2>/dev/null) || FREED_HR="?"
    local REMAIN_HR
    REMAIN_HR=$(python3 -c "print(f'{${CURRENT_BYTES}/1073741824:.2f}')" 2>/dev/null) || REMAIN_HR="?"
    echo "[rclone-cleanup] 清理完成: 删除 ${DELETED_COUNT} 个文件，释放 ${FREED_HR}MB，剩余 ${REMAIN_HR}GB"
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

# 主循环：定时同步
while true; do
    # 等待指定间隔
    sleep "${SYNC_INTERVAL}"

    echo "[rclone-sync] 开始同步..."

    # 使用临时文件记录要同步的文件列表，供 rclone --files-from 使用
    TMP_FILE_LIST="/tmp/rclone_sync_files.txt"
    > "${TMP_FILE_LIST}"

    # 切换到媒体目录，使用 find 查找并输出相对路径
    cd "${MEDIA_PATH}" || continue
    FOUND_FILES=$(find . -type f \( -name "*.mp4" -o -name "*.avi" -o -name "*.mkv" -o -name "*.mov" \) -mmin +1 2>/dev/null | sed 's|^\./||' || true)
    
    if [ -z "${FOUND_FILES}" ]; then
        FILE_COUNT=0
    else
        FILE_COUNT=$(echo "${FOUND_FILES}" | wc -l)
        echo "${FOUND_FILES}" > "${TMP_FILE_LIST}"
    fi

    if [ "${FILE_COUNT}" -eq 0 ]; then
        # 额外诊断：列出所有视频文件（不限 mmin）以帮助排查
        ALL_FILES=$(find . -type f \( -name "*.mp4" -o -name "*.avi" -o -name "*.mkv" -o -name "*.mov" \) 2>/dev/null || true)
        if [ -z "${ALL_FILES}" ]; then
            ALL_COUNT=0
        else
            ALL_COUNT=$(echo "${ALL_FILES}" | wc -l)
        fi
        if [ "${ALL_COUNT}" -gt 0 ]; then
            echo "[rclone-sync] 没有满足条件的文件（修改时间 >1 分钟），但发现 ${ALL_COUNT} 个视频文件:"
            echo "${ALL_FILES}" | head -5 | while IFS= read -r f; do
                FSIZE=$(stat -c%s "$f" 2>/dev/null || echo "?")
                FMTIME=$(stat -c%Y "$f" 2>/dev/null || echo "0")
                NOW=$(date +%s)
                AGE_SEC=$((NOW - FMTIME))
                FSIZE_HR=$(python3 -c "print(f'{${FSIZE}/1048576:.1f}')" 2>/dev/null || echo "?")
                echo "[rclone-sync]   ${f} (${FSIZE_HR}MB, ${AGE_SEC}秒前修改)"
            done
            if [ "${ALL_COUNT}" -gt 5 ]; then
                echo "[rclone-sync]   ... 还有 $((ALL_COUNT - 5)) 个文件"
            fi
        else
            echo "[rclone-sync] 没有需要同步的文件，跳过"
        fi
        # 即使没有新文件，也执行清理检查
        cleanup_remote_storage || echo "[rclone-cleanup] 清理过程出现异常，将在下次重试"
        continue
    fi

    echo "[rclone-sync] 发现 ${FILE_COUNT} 个文件待同步:"
    echo "${FOUND_FILES}" | head -5 | while IFS= read -r f; do
        FSIZE=$(stat -c%s "$f" 2>/dev/null || echo "?")
        FSIZE_HR=$(python3 -c "print(f'{${FSIZE}/1048576:.1f}')" 2>/dev/null || echo "?")
        echo "[rclone-sync]   ${f} (${FSIZE_HR}MB)"
    done
    if [ "${FILE_COUNT}" -gt 5 ]; then
        echo "[rclone-sync]   ... 还有 $((FILE_COUNT - 5)) 个文件"
    fi

    # 使用 rclone move 移动文件到远程（移动后本地删除，节省空间）
    echo "[rclone-sync] 执行 rclone move -> ${RCLONE_REMOTE} ..."
    rclone move "${MEDIA_PATH}/" "${RCLONE_REMOTE}/" \
        --config "${RCLONE_CONF}" \
        --files-from "${TMP_FILE_LIST}" \
        --delete-empty-src-dirs \
        --transfers 1 \
        --buffer-size 0 \
        --low-level-retries 3 \
        --retries 3 \
        --stats-one-line \
        --stats 30s \
        -v \
        2>&1 || echo "[rclone-sync] 同步出错，将在下次重试"

    rm -f "${TMP_FILE_LIST}"

    echo "[rclone-sync] 同步完成"

    # 同步后执行远程存储清理（循环存储）
    cleanup_remote_storage || echo "[rclone-cleanup] 清理过程出现异常，将在下次重试"
done
