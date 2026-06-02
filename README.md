# NVR-FFmpeg-Rclone

[![Build and Push](https://github.com/workerspages/nvr-ffmpeg-rclone/actions/workflows/docker-build.yml/badge.svg)](https://github.com/workerspages/nvr-ffmpeg-rclone/actions/workflows/docker-build.yml)

基于 **MotionEye NVR** + **FFmpeg** + **Rclone** 的 Docker 镜像，专为 **1C1G PaaS 平台**（如 Zeabur、Railway、Render、Fly.io）设计。

支持集成 Cloudflare Tunnel 穿透，便于在不支持虚拟网卡的 PaaS 平台中暴露服务并访问内网摄像头，实时录制并自动备份到云网盘。

## 架构设计

```
┌─────────────────────────────────────────────┐
│           Docker Container (PaaS)           │
│                                             │
│  ┌─────────────┐                            │
│  │ Cloudflare  │  ← Tunnel 内网穿透          │
│  └──────┬──────┘                            │
│         │                                   │
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

家庭摄像头 ──(Cloudflare 穿透)──▶ 容器内 Tunnel ──▶ MotionEye (RTSP)
```

## 核心特性

- **Cloudflare Tunnel 集成**：支持以无状态隧道方式暴露服务，彻底解决 PaaS 平台缺少 /dev/net/tun 权限的限制
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
  -p 8080:8080 \
  -e CLOUDFLARE_TOKEN="your_cloudflare_tunnel_token" \
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
| `CLOUDFLARE_TOKEN` | 否 | - | Cloudflare Tunnel Token（用于暴露服务） |
| `CAMERA_URL` | 推荐 | - | 摄像头 RTSP/MJPEG 流地址 |
| `CAMERA_USERNAME` | 否 | - | 摄像头认证用户名 |
| `CAMERA_PASSWORD` | 否 | - | 摄像头认证密码 |
| `RCLONE_CONFIG_BASE64` | 否 | - | `rclone.conf` 文件的 Base64 编码 |
| `RCLONE_REMOTE` | 否 | `remote:nvr-backup` | Rclone 远程目标路径 |
| `SYNC_INTERVAL` | 否 | `300` | Rclone 同步间隔（秒） |
| `TZ` | 否 | `Asia/Shanghai` | 容器时区 |

## Cloudflare Tunnel 配置指南

Cloudflare Tunnel (`cloudflared`) 用于在没有公网 IP 且不支持创建虚拟网卡的 PaaS 平台中，安全地将服务暴露出去，或者配合 Cloudflare Access 访问内网资源。

### 1. 获取 Cloudflare Token

1. 访问 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) 控制台。
2. 导航至 **Networks** -> **Tunnels**。
3. 点击 **Create a tunnel**，选择 **Cloudflared**。
4. 命名 Tunnel 并保存。
5. 在安装环境选项卡中，复制命令中 `--token` 后面的字符串，这就是你的 `CLOUDFLARE_TOKEN`。

### 2. 路由配置 (Public Hostname)

为了能够从外部访问容器的面板，你需要配置路由：

1. 在刚刚创建的 Tunnel 中，进入 **Public Hostname** 选项卡。
2. 点击 **Add a public hostname**。
3. 填入你想要的子域名和域名。
4. **Service** 类型选择 `HTTP`，URL 填入 `localhost:8080`。
5. 保存配置。

### 3. 注入环境变量

部署时注入环境变量：

```
CLOUDFLARE_TOKEN=ey...（你的Token）
```

> 部署成功后，`cloudflared` 进程将自动启动并连接至 Cloudflare 边缘节点，你可以直接通过配置的 Public Hostname 域名访问 MotionEye，无需再从 PaaS 映射端口。

### 4. 内网摄像头流接入

如果在家庭网络端，你已经通过 Cloudflare 暴露了摄像头的 HTTP(S)/RTSP 流，可以直接将经过 HTTPS/TCP 包装的 URL 配置到 `CAMERA_URL`，系统将直接拉取：

```
CAMERA_URL=https://camera.yourdomain.com/stream
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
3. **内网穿透**：如果摄像头位于家庭内网，请确保其能被处于公网或通过 Cloudflare 隧道连接的 PaaS 容器访问
4. **重启恢复**：PaaS 容器重启后，未被 Rclone 搬走的录像会丢失。建议将 `SYNC_INTERVAL` 设置为较短的值（如 60 秒）

## License

MIT
