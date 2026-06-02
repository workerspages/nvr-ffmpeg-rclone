#!/bin/bash
# entrypoint.sh — Docker 容器入口脚本
# 功能：动态端口适配、配置初始化、Rclone 配置注入、启动 supervisord
set -euo pipefail

echo "======================================"
echo "  NVR-FFmpeg-Rclone 容器启动"
echo "======================================"

# ===== 1. 环境变量默认值 =====
PORT="${PORT:-8080}"
CLOUDFLARE_TOKEN="${CLOUDFLARE_TOKEN:-}"
RCLONE_CONFIG_BASE64="${RCLONE_CONFIG_BASE64:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
TZ="${TZ:-Asia/Shanghai}"

echo "[init] 端口: ${PORT}"
echo "[init] 时区: ${TZ}"
echo "[init] Cloudflare Tunnel: ${CLOUDFLARE_TOKEN:-未配置}"
echo "[init] Rclone 远程: ${RCLONE_REMOTE}"

# ===== 2. 创建必要目录 =====
echo "[init] 初始化目录结构..."
mkdir -p /etc/motioneye
mkdir -p /var/lib/motioneye
mkdir -p /var/run/motioneye
mkdir -p /var/log/motioneye
mkdir -p /config/rclone

# 确保目录可写（PaaS 环境）
chmod -R 777 /etc/motioneye /var/lib/motioneye /var/run/motioneye /var/log/motioneye /config/rclone

# ===== 3. 启动 Cloudflare Tunnel (cloudflared) =====
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



# ===== 4. 动态端口绑定 =====
echo "[init] 配置 MotionEye 监听端口: ${PORT}"
cp /opt/motioneye/motioneye.conf /etc/motioneye/motioneye.conf
sed -i "s|^port .*|port ${PORT}|" /etc/motioneye/motioneye.conf

# (管理员密码设置逻辑已移除，改由用户在 Web UI 首次登录后配置)

# ===== 6. 摄像头与 TCP 穿透动态配置 (支持多设备) =====
# 循环处理 CAMERA_URL_1 到 CAMERA_URL_9 (包含没后缀的作为 1)
HAS_CAMERA=0
for i in {1..9}; do
    # 向后兼容：如果是 1 号，且带后缀的变量为空，则尝试读取无后缀的旧变量
    VAR_URL="CAMERA_URL_${i}"
    URL="${!VAR_URL:-}"
    VAR_USER="CAMERA_USERNAME_${i}"
    USER="${!VAR_USER:-}"
    VAR_PASS="CAMERA_PASSWORD_${i}"
    PASS="${!VAR_PASS:-}"
    VAR_CF="CF_ACCESS_HOSTNAME_${i}"
    CF_HOST="${!VAR_CF:-}"

    if [ "$i" -eq 1 ]; then
        URL="${URL:-${CAMERA_URL:-}}"
        USER="${USER:-${CAMERA_USERNAME:-}}"
        PASS="${PASS:-${CAMERA_PASSWORD:-}}"
        CF_HOST="${CF_HOST:-${CF_ACCESS_HOSTNAME:-}}"
    fi

    # 如果配置了 CF Access Hostname，则分配本地端口
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

    if [ -n "${URL}" ]; then
        echo "[init] [$i] 生成摄像头配置 Camera${i} ..."
        cp /opt/motioneye/thread-1.conf.tmpl "/etc/motioneye/camera-${i}.conf"

        STREAM_PORT=$((8080 + i))
        sed -i "s|__CAMERA_ID__|${i}|g" "/etc/motioneye/camera-${i}.conf"
        sed -i "s|__STREAM_PORT__|${STREAM_PORT}|g" "/etc/motioneye/camera-${i}.conf"
        sed -i "s|__CAMERA_NAME__|Camera${i}|g" "/etc/motioneye/camera-${i}.conf"
        sed -i "s|__CAMERA_URL__|${URL}|g" "/etc/motioneye/camera-${i}.conf"
        sed -i "s|__CAMERA_USERNAME__|${USER}|g" "/etc/motioneye/camera-${i}.conf"
        sed -i "s|__CAMERA_PASSWORD__|${PASS}|g" "/etc/motioneye/camera-${i}.conf"

        if [ -z "${USER}" ] && [ -z "${PASS}" ]; then
            sed -i '/^netcam_userpass/d' "/etc/motioneye/camera-${i}.conf"
        fi
        
        # 将摄像头配置加入主配置文件使其生效
        echo "camera camera-${i}.conf" >> /etc/motioneye/motioneye.conf

        HAS_CAMERA=1
    fi
done

if [ "$HAS_CAMERA" -eq 0 ]; then
    echo "[init] 警告: 未设置任何 CAMERA_URL，请在 MotionEye Web UI 中手动添加摄像头"
fi

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
export PORT CLOUDFLARE_TOKEN CAMERA_URL RCLONE_REMOTE SYNC_INTERVAL TZ

# ===== 9. 启动 supervisord =====
echo "[init] 启动服务..."
echo "======================================"
exec /usr/bin/supervisord -c /etc/supervisord.conf
