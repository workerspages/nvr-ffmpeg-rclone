# NVR-FFmpeg-Rclone

[![Build and Push](https://github.com/workerspages/nvr-ffmpeg-rclone/actions/workflows/docker-build.yml/badge.svg)](https://github.com/workerspages/nvr-ffmpeg-rclone/actions/workflows/docker-build.yml)

基于 **MotionEye NVR** + **FFmpeg** + **Rclone** 的 Docker 镜像，专为 **1C1G PaaS 平台**（如 Zeabur、Railway、Render、Fly.io）设计。

通过 ZeroTier 穿透连接家庭网络摄像头，实时录制并自动备份到云网盘。

## 架构设计

```
┌─────────────────────────────────────────────┐
│           Docker Container (PaaS)           │
│                                             │
│  ┌─────────────┐                              │
│  │  ZeroTier   │  ← 加入家庭网络                │
│  └──────┬──────┘                              │
│         │                                    │
│  ┌──────┴──────┐    ┌──────────────────┐    │
│  │  MotionEye  │    │   Rclone Cron    │    │
│  │  (Web UI +  │    │  (定时备份到网盘) │    │
│  │   录制)     │    │                  │    │
│  └──────┬──────┘    └────────┬─────────┘    │
│         │                    │              │
│         ▼                    ▼              │
│  ┌──────────────────────────────────┐       │
│  │  /var/lib/motioneye (临时存储)    │       │
│  └──────────────────────────────────┘       │
│                                             │
│  supervisord 进程管理                        │
└──────────────┬──────────────────────────────┘
               │ $PORT
               ▼
          用户浏览器

家庭摄像头 ──(ZeroTier 穿透)──▶ 容器内 ZeroTier ──▶ MotionEye (RTSP)
```

## 核心特性

- **ZeroTier 内置客户端**：容器启动时自动加入 ZeroTier 网络，直接访问家庭局域网
- **Passthrough 直通模式**：不解码、不重编码，极低 CPU/内存消耗
- **动态端口绑定**：自动读取 PaaS 注入的 `$PORT` 环境变量
- **Rclone 自动备份**：定时将录像移动到云网盘，释放本地空间
- **多架构支持**：同时构建 `linux/amd64` 和 `linux/arm64`
- **PaaS 友好**：全目录可写，适配临时文件系统

## 快速开始

### Docker 拉取

```bash
# 从 GitHub Container Registry
docker pull ghcr.io/workerspages/nvr-ffmpeg-rclone:latest

# 从 Docker Hub
docker pull <your-dockerhub-username>/nvr-ffmpeg-rclone:latest
```

### 本地运行

```bash
docker run -d \
  --name nvr \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -p 8080:8080 \
  -e ZEROTIER_NETWORK_ID="your_16_char_network_id" \
  -e CAMERA_URL="rtsp://user:pass@10.x.x.x:554/stream" \
  -e RCLONE_CONFIG_BASE64="$(cat rclone.conf | base64 -w 0)" \
  -e RCLONE_REMOTE="remote:nvr-backup" \
  -e TZ="Asia/Shanghai" \
  ghcr.io/workerspages/nvr-ffmpeg-rclone:latest
```

启动后访问 `http://localhost:8080` 进入 MotionEye 管理界面。

> 🔑 **默认登录凭据：**
> - **Username (用户名)**: `admin`
> - **Password (密码)**: *(留空，不需要输入任何字符)*
>
> 首次登录成功后，请务必立即在左上角的 **Settings (设置)** 面板中为 admin 账户设置新密码！

## 环境变量

| 变量名 | 必填 | 默认值 | 说明 |
|--------|:----:|--------|------|
| `PORT` | 否 | `8080` | HTTP 监听端口（PaaS 平台自动注入） |
| `ZEROTIER_NETWORK_ID` | 推荐 | - | ZeroTier 网络 ID（16 位十六进制） |
| `CAMERA_URL` | 推荐 | - | 摄像头 RTSP/MJPEG 流地址 |
| `CAMERA_USERNAME` | 否 | - | 摄像头认证用户名 |
| `CAMERA_PASSWORD` | 否 | - | 摄像头认证密码 |
| `RCLONE_CONFIG_BASE64` | 否 | - | `rclone.conf` 文件的 Base64 编码 |
| `RCLONE_REMOTE` | 否 | `remote:nvr-backup` | Rclone 远程目标路径 |
| `SYNC_INTERVAL` | 否 | `300` | Rclone 同步间隔（秒） |
| `TZ` | 否 | `Asia/Shanghai` | 容器时区 |

## ZeroTier 配置指南

ZeroTier 用于让 PaaS 容器加入你的家庭虚拟局域网，从而访问家里的摄像头。

### 1. 获取 Network ID

1. 访问 [ZeroTier Central](https://my.zerotier.com)
2. 登录你的账号
3. 点击你的网络（即家里路由器已加入的网络）
4. 页面顶部的 **Network ID** 就是你需要的 16 位十六进制字符串

示例：`a1b2c3d4e5f67890`

### 2. 配置环境变量

在 PaaS 平台设置：

```
ZEROTIER_NETWORK_ID=a1b2c3d4e5f67890
```

### 3. 授权新节点

容器首次启动时，ZeroTier 会生成一个新的节点 ID。你需要在 ZeroTier Central 中授权该节点：

1. 启动容器后，查看容器日志，找到 `节点 ID: xxxxxxxxxx`
2. 在 ZeroTier Central → 你的网络 → Members 列表中，找到该节点
3. 勾选 **Auth** 复选框授权
4. 等待几秒，容器将自动获取 ZeroTier IP 地址

> **重要**：PaaS 平台的容器可能不支持 TUN/TAP 设备。如果 ZeroTier 无法工作，你可以考虑：
> - 使用支持特权容器的 PaaS（如 Fly.io）
> - 或在 VPS 上直接部署（使用 `docker run --cap-add NET_ADMIN --device /dev/net/tun`）

### 4. 摄像头地址

授权成功后，你的摄像头地址应使用 ZeroTier 分配的内网 IP：

```
# 示例：假设摄像头在 ZeroTier 网络中的 IP 是 10.147.17.50
CAMERA_URL=rtsp://user:pass@10.147.17.50:554/stream
```

## Rclone 配置指南

### 1. 生成 rclone.conf

在本地机器上运行：

```bash
rclone config
```

按提示配置你的网盘（支持 Google Drive、OneDrive、S3、Dropbox 等 40+ 种）。

### 2. 编码为 Base64

```bash
# Linux/macOS
cat ~/.config/rclone/rclone.conf | base64 -w 0

# 将输出的字符串设置为 RCLONE_CONFIG_BASE64 环境变量
```

### 3. 部署时传入

在 PaaS 平台的环境变量设置中添加 `RCLONE_CONFIG_BASE64`。

> **安全提示**：`rclone.conf` 包含敏感的 API 令牌，请务必通过 PaaS 平台的 Secret/环境变量功能注入，切勿硬编码在代码中。

## PaaS 平台部署

### Zeabur

1. Fork 本仓库或连接 GitHub
2. 在 Zeabur 创建新服务，选择 Docker 类型
3. 设置环境变量
4. 部署

### Railway

1. 连接 GitHub 仓库
2. 在 Variables 中设置所有需要的环境变量
3. Railway 会自动注入 `$PORT`

### Fly.io

```bash
fly launch --image ghcr.io/workerspages/nvr-ffmpeg-rclone:latest
fly secrets set CAMERA_URL="rtsp://..." RCLONE_CONFIG_BASE64="..."
```

## GitHub Actions 自动构建

本项目使用 GitHub Actions 自动构建多架构 Docker 镜像。

### 需要配置的 Secrets

在 GitHub 仓库 → Settings → Secrets and variables → Actions 中添加：

| Secret 名称 | 说明 |
|-------------|------|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名 |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token |

> `GITHUB_TOKEN` 由 GitHub 自动提供，无需手动配置。

### 触发条件

- 推送到 `main` 分支
- 创建 `v*` 格式的 Git Tag
- 手动触发（workflow_dispatch）

### 镜像发布位置

- **GHCR**: `ghcr.io/workerspages/nvr-ffmpeg-rclone`
- **Docker Hub**: `<username>/nvr-ffmpeg-rclone`

## 项目结构

```
nvr-ffmpeg-rclone/
├── Dockerfile                  # Docker 镜像定义
├── README.md                   # 项目文档
├── supervisord.conf            # 进程管理配置
├── entrypoint.sh               # 容器入口脚本
├── rclone-sync.sh              # Rclone 定时同步脚本
├── motioneye/
│   ├── motioneye.conf          # MotionEye 主配置
│   └── thread-1.conf.tmpl      # 摄像头配置模板
└── .github/
    └── workflows/
        └── docker-build.yml    # CI/CD 工作流
```

## 注意事项

1. **内存限制**：本镜像已配置 Passthrough 模式，关闭图像解码和运动检测，但仍建议监控内存使用情况
2. **录像分片**：默认每 5 分钟生成一个视频文件（`movie_max_time=300`），便于 Rclone 快速搬运
3. **ZeroTier 网络**：确保 PaaS 容器可以通过 ZeroTier 网络访问家庭摄像头的 RTSP 地址
4. **重启恢复**：PaaS 容器重启后，未被 Rclone 搬走的录像会丢失。建议将 `SYNC_INTERVAL` 设置为较短的值（如 60 秒）

## License

MIT
