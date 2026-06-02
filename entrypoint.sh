#!/bin/bash
# entrypoint.sh — Docker 容器入口脚本
# 功能：动态端口适配、配置初始化、Rclone 配置注入、启动 supervisord
set -euo pipefail

echo "======================================"
echo "  NVR-FFmpeg-Rclone 容器启动"
echo "======================================"

# ===== 1. 环境变量默认值 =====
PORT="${PORT:-8080}"
ZEROTIER_NETWORK_ID="${ZEROTIER_NETWORK_ID:-}"
CAMERA_URL="${CAMERA_URL:-}"
CAMERA_USERNAME="${CAMERA_USERNAME:-}"
CAMERA_PASSWORD="${CAMERA_PASSWORD:-}"
RCLONE_CONFIG_BASE64="${RCLONE_CONFIG_BASE64:-}"
RCLONE_REMOTE="${RCLONE_REMOTE:-remote:nvr-backup}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
TZ="${TZ:-Asia/Shanghai}"

echo "[init] 端口: ${PORT}"
echo "[init] 时区: ${TZ}"
echo "[init] ZeroTier: ${ZEROTIER_NETWORK_ID:-未配置}"
echo "[init] 摄像头: ${CAMERA_URL:-未配置}"
echo "[init] Rclone 远程: ${RCLONE_REMOTE}"

# ===== 2. 创建必要目录 =====
echo "[init] 初始化目录结构..."
mkdir -p /etc/motioneye
mkdir -p /var/lib/motioneye
mkdir -p /var/run/motioneye
mkdir -p /var/log/motioneye
mkdir -p /config/rclone
mkdir -p /var/lib/zerotier-one

# 确保目录可写（PaaS 环境）
chmod -R 777 /etc/motioneye /var/lib/motioneye /var/run/motioneye /var/log/motioneye /config/rclone /var/lib/zerotier-one

# ===== 3. 启动 ZeroTier（虚拟局域网穿透） =====
if [ -n "${ZEROTIER_NETWORK_ID}" ]; then
    echo "[init] 检查虚拟网络设备..."
    if [ ! -e /dev/net/tun ]; then
        echo "[init] 尝试创建 /dev/net/tun 设备..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || echo "[init] 警告: 创建 /dev/net/tun 失败，如果 ZeroTier 无法工作，请确认平台权限"
        chmod 666 /dev/net/tun 2>/dev/null || true
    fi

    echo "[init] 启动 ZeroTier 守护进程..."
    zerotier-one -d

    # 等待 ZeroTier 服务就绪
    echo "[init] 等待 ZeroTier 服务就绪..."
    RETRY=0
    MAX_RETRY=10
    while [ $RETRY -lt $MAX_RETRY ]; do
        if zerotier-cli status 2>/dev/null | grep -q "ONLINE"; then
            break
        fi
        RETRY=$((RETRY + 1))
        sleep 1
    done

    if [ $RETRY -ge $MAX_RETRY ]; then
        echo "[init] 警告: ZeroTier 服务启动超时，继续启动..."
    else
        echo "[init] ZeroTier 服务已就绪"
    fi

    # 加入 ZeroTier 网络
    echo "[init] 加入 ZeroTier 网络: ${ZEROTIER_NETWORK_ID}"
    zerotier-cli join "${ZEROTIER_NETWORK_ID}" || echo "[init] 警告: 加入网络失败"

    # 输出节点信息供用户授权，不阻塞启动过程
    echo "[init] ==================================================="
    echo "[init] 您的 ZeroTier 节点 ID 为: $(zerotier-cli info 2>/dev/null | awk '{print $3}')"
    echo "[init] 请务必前往 ZeroTier Central (https://my.zerotier.com)"
    echo "[init] 勾选 Auth 授权此节点，否则无法获取 IP 及访问摄像头！"
    echo "[init] ==================================================="
    echo "[init] MotionEye 将继续启动，ZeroTier 会在后台尝试连接..."
else
    echo "[init] 提示: 未设置 ZEROTIER_NETWORK_ID，跳过 ZeroTier 配置"
fi

# ===== 4. 动态端口绑定 =====
echo "[init] 配置 MotionEye 监听端口: ${PORT}"
cp /opt/motioneye/motioneye.conf /etc/motioneye/motioneye.conf
sed -i "s|^port .*|port ${PORT}|" /etc/motioneye/motioneye.conf

# ===== 5. 管理员密码配置 =====
if [ -n "${ADMIN_PASSWORD}" ]; then
    echo "[init] 配置管理员账户..."
    # MotionEye 在首次启动时会创建 admin 用户
    # 通过在配置目录中预置 shadow 文件来设置密码
    # 注：密码将在 MotionEye 首次启动时通过 Web UI 设置
fi

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
export PORT ZEROTIER_NETWORK_ID CAMERA_URL RCLONE_REMOTE SYNC_INTERVAL TZ

# ===== 9. 启动 supervisord =====
echo "[init] 启动服务..."
echo "======================================"
exec /usr/bin/supervisord -c /etc/supervisord.conf
