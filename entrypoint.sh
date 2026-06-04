#!/bin/bash
# entrypoint.sh — Docker 容器入口脚本
# 功能：Moonfire NVR 初始化、摄像头自动注册、Cloudflare Tunnel 配置、启动 supervisord
set -euo pipefail

echo "======================================"
echo "  NVR-FFmpeg-Rclone 容器启动"
echo "  NVR 引擎: Moonfire NVR"
echo "======================================"

# ===== 1. 环境变量默认值 =====
PORT="${PORT:-8080}"
CLOUDFLARE_TOKEN="${CLOUDFLARE_TOKEN:-}"
RCLONE_CONFIG_BASE64="${RCLONE_CONFIG_BASE64:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
TZ="${TZ:-Asia/Shanghai}"
MOONFIRE_RETENTION_GB="${MOONFIRE_RETENTION_GB:-2}"

echo "[init] 端口: ${PORT}"
echo "[init] 时区: ${TZ}"
echo "[init] Cloudflare Tunnel: ${CLOUDFLARE_TOKEN:+已配置}${CLOUDFLARE_TOKEN:-未配置}"
echo "[init] Rclone 远程: ${RCLONE_REMOTE}"
echo "[init] 本地保留空间: ${MOONFIRE_RETENTION_GB}GB/摄像头"

# ===== 2. 创建必要目录 =====
echo "[init] 初始化目录结构..."
mkdir -p /var/lib/moonfire-nvr/db
mkdir -p /var/lib/moonfire-nvr/sample
mkdir -p /tmp/nvr-export
mkdir -p /config/rclone

# 确保目录可写（PaaS 环境）
chmod -R 777 /var/lib/moonfire-nvr /tmp/nvr-export /config/rclone

# ===== 3. 生成 Moonfire NVR 配置文件 =====
echo "[init] 生成 Moonfire NVR 配置..."
cat > /etc/moonfire-nvr.toml <<EOF
[[binds]]
ipv4 = "0.0.0.0:${PORT}"
allowUnauthenticatedPermissions = { viewVideo = true, viewVideoGridScreenshots = true }

[[binds]]
unix = "/var/lib/moonfire-nvr/sock"
ownUidIsPrivileged = true
EOF
echo "[init] 配置文件已写入 /etc/moonfire-nvr.toml"

# ===== 4. 初始化 Moonfire NVR 数据库（仅首次启动） =====
if [ ! -f /var/lib/moonfire-nvr/db/db ]; then
    echo "[init] 首次启动，初始化 Moonfire NVR 数据库..."
    moonfire-nvr init
    echo "[init] 数据库初始化完成"
else
    echo "[init] 数据库已存在，跳过初始化"
fi

# ===== 5. 启动 Cloudflare Tunnel (cloudflared) =====
if [ -n "${CLOUDFLARE_TOKEN}" ]; then
    echo "[init] 正在将 Cloudflare Tunnel 加入 supervisor 管理..."
    cat >> /etc/supervisord.conf <<EOF

[program:cloudflared]
command=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${CLOUDFLARE_TOKEN}
autostart=true
autorestart=true
startsecs=5
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=15
EOF
    echo "[init] Cloudflare Tunnel 配置完成"
else
    echo "[init] 提示: 未设置 CLOUDFLARE_TOKEN，跳过 Cloudflare Tunnel 配置"
fi

# ===== 6. Cloudflare Access TCP 穿透配置（多摄像头支持） =====
for i in {1..9}; do
    VAR_CF="CF_ACCESS_HOSTNAME_${i}"
    CF_HOST="${!VAR_CF:-}"

    if [ "$i" -eq 1 ]; then
        CF_HOST="${CF_HOST:-${CF_ACCESS_HOSTNAME:-}}"
    fi

    if [ -n "${CF_HOST}" ]; then
        LOCAL_PORT=$((5553 + i))
        echo "[init] [$i] 配置 Cloudflare Access TCP，映射 ${CF_HOST} 至 127.0.0.1:${LOCAL_PORT} ..."
        cat >> /etc/supervisord.conf <<EOF

[program:cloudflared-access-${i}]
command=/usr/local/bin/cloudflared access tcp --hostname ${CF_HOST} --url 127.0.0.1:${LOCAL_PORT}
autostart=true
autorestart=true
startsecs=3
startretries=3
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
priority=16
EOF
    fi
done

# ===== 7. Rclone 配置注入 =====
if [ -n "${RCLONE_CONFIG_BASE64}" ]; then
    echo "[init] 注入 Rclone 配置..."
    echo "${RCLONE_CONFIG_BASE64}" | base64 -d > /config/rclone/rclone.conf
    chmod 600 /config/rclone/rclone.conf
    echo "[init] Rclone 配置就绪"
else
    echo "[init] 提示: 未设置 RCLONE_CONFIG_BASE64，Rclone 同步功能未启用"
fi

# ===== 8. 导出环境变量供子进程使用 =====
export PORT CLOUDFLARE_TOKEN RCLONE_REMOTE SYNC_INTERVAL RCLONE_MAX_SIZE TZ MOONFIRE_RETENTION_GB

# ===== 9. 启动 supervisord（Moonfire NVR + Rclone + Cloudflare） =====
echo "[init] 启动服务..."
echo "======================================"

# 启动 supervisord 并后台运行
/usr/bin/supervisord -c /etc/supervisord.conf &
SUPERVISORD_PID=$!

# ===== 10. 等待 Moonfire NVR 就绪后自动配置摄像头 =====
echo "[init] 等待 Moonfire NVR 启动..."
RETRIES=0
MAX_RETRIES=30
while ! curl -sf "http://127.0.0.1:${PORT}/api/" -H "Accept: application/json" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
        echo "[init] 错误: Moonfire NVR 启动超时（${MAX_RETRIES}s），请检查日志"
        wait $SUPERVISORD_PID
        exit 1
    fi
    sleep 1
done
echo "[init] Moonfire NVR 已就绪"

# 检查是否需要初始化配置（通过 API 检查是否已有摄像头）
EXISTING_CAMERAS=$(curl -sf "http://127.0.0.1:${PORT}/api/" -H "Accept: application/json" | jq -r '.cameras | length' 2>/dev/null || echo "0")

if [ "${EXISTING_CAMERAS}" = "0" ]; then
    echo "[init] 未检测到已配置的摄像头，开始自动配置..."

    # 通过 Unix socket（特权模式）操作 API
    SOCK="/var/lib/moonfire-nvr/sock"

    # 10a. 添加存储目录
    echo "[init] 添加存储目录..."
    RETENTION_BYTES=$(awk "BEGIN { printf \"%.0f\", ${MOONFIRE_RETENTION_GB} * 1073741824 }")
    curl -sf --unix-socket "${SOCK}" "http://localhost/api/dirs" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"/var/lib/moonfire-nvr/sample\", \"retainBytes\": ${RETENTION_BYTES}, \"gcOnCheck\": true}" \
        -X POST > /dev/null 2>&1 && echo "[init] 存储目录添加成功" || echo "[init] 存储目录可能已存在，跳过"

    # 获取存储目录 ID
    DIR_ID=$(curl -sf --unix-socket "${SOCK}" "http://localhost/api/" -H "Accept: application/json" \
        | jq -r '.sampleFileDirs | to_entries | .[0].key // empty' 2>/dev/null || echo "")

    if [ -z "${DIR_ID}" ]; then
        echo "[init] 警告: 无法获取存储目录 ID，摄像头将需要手动配置"
    else
        echo "[init] 存储目录 ID: ${DIR_ID}"

        # 10b. 循环添加摄像头
        HAS_CAMERA=0
        for i in {1..9}; do
            VAR_URL="CAMERA_URL_${i}"
            URL="${!VAR_URL:-}"
            VAR_USER="CAMERA_USERNAME_${i}"
            CAM_USER="${!VAR_USER:-}"
            VAR_PASS="CAMERA_PASSWORD_${i}"
            CAM_PASS="${!VAR_PASS:-}"

            if [ "$i" -eq 1 ]; then
                URL="${URL:-${CAMERA_URL:-}}"
                CAM_USER="${CAM_USER:-${CAMERA_USERNAME:-}}"
                CAM_PASS="${CAM_PASS:-${CAMERA_PASSWORD:-}}"
            fi

            if [ -n "${URL}" ]; then
                echo "[init] [$i] 注册摄像头 Camera${i}..."

                # 构建 RTSP URL（如有用户名密码则嵌入）
                FULL_URL="${URL}"

                # 创建摄像头并配置主流
                CAMERA_JSON=$(jq -n \
                    --arg name "Camera${i}" \
                    --arg url "${FULL_URL}" \
                    --arg user "${CAM_USER}" \
                    --arg pass "${CAM_PASS}" \
                    --arg dirId "${DIR_ID}" \
                    --argjson retain "${RETENTION_BYTES}" \
                    '{
                        "shortName": $name,
                        "description": "",
                        "onvifBaseUrl": "",
                        "username": $user,
                        "password": $pass,
                        "streams": {
                            "main": {
                                "rtspUrl": $url,
                                "sampleFileDirId": ($dirId | tonumber),
                                "retainBytes": $retain,
                                "record": true
                            }
                        }
                    }')

                RESULT=$(curl -sf --unix-socket "${SOCK}" "http://localhost/api/cameras" \
                    -H "Content-Type: application/json" \
                    -d "${CAMERA_JSON}" \
                    -X POST 2>&1) && \
                    echo "[init] [$i] Camera${i} 注册成功" || \
                    echo "[init] [$i] Camera${i} 注册失败: ${RESULT}"

                HAS_CAMERA=1
            fi
        done

        if [ "$HAS_CAMERA" -eq 0 ]; then
            echo "[init] 警告: 未设置任何 CAMERA_URL，请在 Moonfire NVR Web UI 中手动添加摄像头"
        fi
    fi
else
    echo "[init] 已检测到 ${EXISTING_CAMERAS} 个摄像头配置，跳过自动配置"
fi

echo "[init] 所有服务已启动"
echo "======================================"

# 等待 supervisord 进程
wait $SUPERVISORD_PID
