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
CF_ACCESS_HOSTNAME="${CF_ACCESS_HOSTNAME:-}"
CAMERA_URL="${CAMERA_URL:-}"
CAMERA_USERNAME="${CAMERA_USERNAME:-}"
CAMERA_PASSWORD="${CAMERA_PASSWORD:-}"
RCLONE_CONFIG_BASE64="${RCLONE_CONFIG_BASE64:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
TZ="${TZ:-Asia/Shanghai}"

echo "[init] 端口: ${PORT}"
echo "[init] 时区: ${TZ}"
echo "[init] Cloudflare: ${CLOUDFLARE_TOKEN:-未配置}"
echo "[init] CF Access: ${CF_ACCESS_HOSTNAME:-未配置}"
echo "[init] 摄像头: ${CAMERA_URL:-未配置}"
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

# ===== 3.5 启动 Cloudflare Access TCP (内网穿透) =====
if [ -n "${CF_ACCESS_HOSTNAME}" ]; then
    echo "[init] 正在将 Cloudflare Access TCP 加入 supervisor 管理..."
    cat >> /etc/supervisord.conf <<EOF

[program:cloudflared-access]
command=/usr/local/bin/cloudflared access tcp --hostname ${CF_ACCESS_HOSTNAME} --url 127.0.0.1:5554
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
    echo "[init] Cloudflare Access TCP 配置完成，本地已映射至 127.0.0.1:5554"
    echo "[init] 提示: 如果您使用了 CF_ACCESS_HOSTNAME，您的 CAMERA_URL 应该指向 127.0.0.1:5554 (例如 rtsp://127.0.0.1:5554/stream1)"
fi

# ===== 4. 动态端口绑定 =====
echo "[init] 配置 MotionEye 监听端口: ${PORT}"
cp /opt/motioneye/motioneye.conf /etc/motioneye/motioneye.conf
sed -i "s|^port .*|port ${PORT}|" /etc/motioneye/motioneye.conf

# (管理员密码设置逻辑已移除，改由用户在 Web UI 首次登录后配置)

# ===== 6. 摄像头配置 =====
if [ -n "${CAMERA_URL}" ]; then
    echo "[init] 生成摄像头配置..."
    cp /opt/motioneye/thread-1.conf.tmpl /etc/motioneye/thread-1.conf

    # 替换占位符
    sed -i "s|__CAMERA_URL__|${CAMERA_URL}|g" /etc/motioneye/thread-1.conf
    sed -i "s|__CAMERA_USERNAME__|${CAMERA_USERNAME}|g" /etc/motioneye/thread-1.conf
    sed -i "s|__CAMERA_PASSWORD__|${CAMERA_PASSWORD}|g" /etc/motioneye/thread-1.conf

    # 如果没有用户名密码，移除认证行
    if [ -z "${CAMERA_USERNAME}" ] && [ -z "${CAMERA_PASSWORD}" ]; then
        sed -i '/^netcam_userpass/d' /etc/motioneye/thread-1.conf
    fi

    echo "[init] 摄像头配置完成"
else
    echo "[init] 警告: 未设置 CAMERA_URL，请在 MotionEye Web UI 中手动添加摄像头"
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
