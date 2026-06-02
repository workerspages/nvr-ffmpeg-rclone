# ==============================================================================
# NVR-FFmpeg-Rclone Docker 镜像
# 基于 MotionEye NVR + Rclone 云备份
# 适用于 1C1G PaaS 平台，支持 linux/amd64 和 linux/arm64
# ==============================================================================

FROM python:3.11-slim-bookworm

LABEL maintainer="workerspages"
LABEL org.opencontainers.image.source="https://github.com/workerspages/nvr-ffmpeg-rclone"
LABEL org.opencontainers.image.description="MotionEye NVR + FFmpeg + Rclone for PaaS platforms"

# ===== 环境变量 =====
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    PORT=8080 \
    CLOUDFLARE_TOKEN= \
    RCLONE_REMOTE=remote:nvr-backup \
    SYNC_INTERVAL=300

# ===== 安装系统依赖 =====
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Motion 守护进程（MotionEye 底层引擎）
    motion \
    # FFmpeg（视频处理）
    ffmpeg \
    # Supervisor（进程管理）
    supervisor \
    # 工具
    curl \
    unzip \
    tzdata \
    gnupg \
    fdisk \
    # Motion 运行依赖
    libmicrohttpd12 \
    v4l-utils \
    && rm -rf /var/lib/apt/lists/*

# ===== 安装 Cloudflare Tunnel (cloudflared) =====
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared; \
    elif [ "$ARCH" = "arm64" ]; then \
        curl -sSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /usr/local/bin/cloudflared; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/cloudflared

# ===== 安装 MotionEye =====
RUN pip install --no-cache-dir --break-system-packages \
    motioneye==0.43.1b1

# ===== 安装 Rclone（自动适配架构） =====
RUN curl -sSL https://rclone.org/install.sh | bash

# ===== 创建目录结构并设置权限 =====
RUN mkdir -p \
    /etc/motioneye \
    /var/lib/motioneye \
    /var/run/motioneye \
    /var/log/motioneye \
    /config/rclone \
    /opt/motioneye \
    && chmod -R 777 \
    /etc/motioneye \
    /var/lib/motioneye \
    /var/run/motioneye \
    /var/log/motioneye \
    /config/rclone

# ===== 复制配置文件 =====
# MotionEye 配置模板
COPY motioneye/motioneye.conf /opt/motioneye/motioneye.conf
COPY motioneye/thread-1.conf.tmpl /opt/motioneye/thread-1.conf.tmpl

# Supervisord 配置
COPY supervisord.conf /etc/supervisord.conf

# 脚本
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY rclone-sync.sh /usr/local/bin/rclone-sync.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/rclone-sync.sh

# ===== 暴露端口（CloudFlare HTTP 兼容） =====
EXPOSE 8080

# ===== 健康检查 =====
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:${PORT}/ || exit 1

# ===== 入口点 =====
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
