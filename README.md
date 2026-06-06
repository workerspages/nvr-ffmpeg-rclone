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
| `CLOUDFLARE_TOKEN` | 否 | - | Cloudflare Tunnel Token（用于将容器服务暴露到外网） |
| `CF_ACCESS_HOSTNAME_1` | 否 | - | 1号摄像头的 Cloudflare TCP 内网穿透域名（可选支持 _1 到 _9） |
| `CAMERA_URL_1` | 推荐 | - | 1号摄像头的流地址（若使用了 CF 穿透，填 `rtsp://127.0.0.1:5554/...`，可选支持 _1 到 _9） |
| `CAMERA_USERNAME_1` | 否 | - | 1号摄像头的认证用户名 |
| `CAMERA_PASSWORD_1` | 否 | - | 1号摄像头的认证密码 |
| `RCLONE_CONFIG_BASE64` | 否 | - | `rclone.conf` 文件的 Base64 编码 |
| `RCLONE_REMOTE` | 否 | `remote:nvr-backup` | Rclone 远程目标路径 |
| `SYNC_INTERVAL` | 否 | `300` | Rclone 同步间隔（秒） |
| `RCLONE_MAX_SIZE` | 否 | `10` | 远程网盘存储上限（GB），超过后自动删除最早文件。设为 `0` 关闭循环清理 |
| `BARK_URL` | 否 | - | Bark 推送通知地址（如 `https://api.day.app/YOUR_KEY`），支持上传失败和摄像头断联告警 |
| `TZ` | 否 | `Asia/Shanghai` | 容器时区 |

## Cloudflare Tunnel 部署架构与防坑指南

本系统在 Cloudflare 网络架构中支持**双向内网穿透**。但在使用时，一定要注意区分**“服务端隧道（PaaS端）”**和**“源端隧道（家庭端）”**，切勿将两者的 Token 混用，否则会导致严重的路由回环冲突！

### 架构一：使用 PaaS 自带域名访问面板（推荐，最简单）

如果您的 PaaS 平台（如 Zeabur, Railway 等）已经为您分配了可以访问 `8080` 端口的公网域名，那么您**完全不需要**在云端配置 Cloudflare Tunnel 来暴露面板。
你只需要配置访问家庭摄像头的单向穿透即可：

1. **家庭路由器端**：在家里的设备（如 NAS、路由器）上部署一条 Cloudflare Tunnel（例如命名为 `Home-Camera`）。
2. **配置家庭端路由**：在 Zero Trust 后台中，为这条隧道添加一个 Public Hostname（如 `cam1.yourdomain.com`），服务类型选择 `TCP`，URL 指向您本地摄像头的内网地址（如 `192.168.31.242:554`）。
3. **PaaS 容器端（云端）**：在 PaaS 的环境变量中填入以下配置：
   - **千万不要填写** `CLOUDFLARE_TOKEN`（留空或删除此变量）。脚本会自动跳过云端的 Tunnel 创建。
   - `CF_ACCESS_HOSTNAME_1=cam1.yourdomain.com`
   - `CAMERA_URL_1=rtsp://127.0.0.1:5554/stream1`
4. **效果**：云端容器启动后，会自动通过 Access TCP 去拉取家里的视频流。而您可以通过 PaaS 提供的域名直接访问 Web 页面。

### 架构二：使用 Cloudflare 域名访问面板（需要两条独立隧道）

如果您希望通过自己的 Cloudflare 域名（例如 `motioneye.yourdomain.com`）来访问云端面板，那么您必须建立**两条完全独立**的隧道。

> ⚠️ **高危排雷警告**：绝对不可以在“家庭路由器”和“PaaS 云端容器”中使用同一个 `CLOUDFLARE_TOKEN`！如果共用 Token，Cloudflare 会在家庭和云端之间进行随机负载均衡，导致视频流（TCP）和网页流（HTTP）各有一半概率请求失败（报错 `i/o timeout`）。

#### 第一条隧道：家庭端（只负责推流）
1. 在 Zero Trust 中新建 Tunnel，例如命名为 `Home-Camera`。
2. 配置 Public Hostname：`cam1.yourdomain.com` -> `tcp://192.168.31.242:554`。
3. 获取 **Token A**，并把它部署在与摄像头同一局域网的家庭设备（NAS/路由器）中。

#### 第二条隧道：PaaS 云端（只负责展示面板）
1. 在 Zero Trust 中新建另一条完全独立的 Tunnel，例如命名为 `Cloud-NVR`。
2. 配置 Public Hostname：`motioneye.yourdomain.com` -> `http://localhost:8080`。
3. 获取 **Token B**。
4. 将 **Token B** 填入 PaaS 环境变量的 `CLOUDFLARE_TOKEN` 中。
5. 依然在 PaaS 填入拉流环境变量：
   - `CF_ACCESS_HOSTNAME_1=cam1.yourdomain.com`
   - `CAMERA_URL_1=rtsp://127.0.0.1:5554/stream1`

### 动态端口打洞与多摄像头支持

无论使用上述哪种架构，脚本都支持最多 9 个摄像头自动进行本地 TCP 打洞映射：
- 1号摄像头 (`CF_ACCESS_HOSTNAME_1`) 会在云端容器内映射至本地 `127.0.0.1:5554` 端口。
- 2号摄像头 (`CF_ACCESS_HOSTNAME_2`) 会在云端容器内映射至本地 `127.0.0.1:5555` 端口，依此类推。
MotionEye 将自动读取这些本地映射生成对应的 `.conf` 配置文件。

> 兼容性提示：如果您不带数字后缀，直接配置 `CAMERA_URL` 和 `CF_ACCESS_HOSTNAME`，脚本会默认将其作为 1 号摄像头处理。

## Rclone 配置指南

### 1. 生成 rclone.conf

在本地机器上运行：

```bash
rclone config
```

按提示配置你的网盘（支持 Google Drive、OneDrive、S3、Dropbox 等 40+ 种）。

### 2. 编码为 Base64

- Linux/macOS
> 假设 rclone.conf 在默认路径
```bash
base64 -w 0 ~/.config/rclone/rclone.conf
```

- Windows
> 假设 rclone.conf 在默认的 AppData 路径
```bash
$configPath = "$env:APPDATA\rclone\rclone.conf"
[Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath))
```

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
5. **保存1周**：`/motioneye/thread-1.conf.tmpl` 中设置录像保存7天
6. **循环存储**：当 `RCLONE_MAX_SIZE` 大于 0 时，每次同步后脚本会检查远程网盘占用，超限时自动按日期删除最早的录像文件（永久删除，不进回收站）。例如 Google Drive 免费 15GB 空间，建议设为 `10`，预留 5GB 缓冲

## License

MIT
