# NVR-FFmpeg-Rclone

[![Build and Push](https://github.com/workerspages/nvr-ffmpeg-rclone/actions/workflows/docker-build.yml/badge.svg)](https://github.com/workerspages/nvr-ffmpeg-rclone/actions/workflows/docker-build.yml)

基于 **Moonfire NVR** + **FFmpeg** + **Rclone** 的 Docker 镜像，专为 **1C1G PaaS 平台**（如 Zeabur、Railway、Render、Fly.io）设计。

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
│  │  Moonfire   │    │   Rclone Cron    │    │
│  │  NVR        │    │  (定时备份到网盘) │    │
│  │  (Web UI +  │    │                  │    │
│  │   录制)     │    │                  │    │
│  └──────┬──────┘    └────────┬─────────┘    │
│         │                    │              │
│         ▼                    ▼              │
│  ┌──────────────────────────────────┐       │
│  │  /var/lib/moonfire-nvr (录像缓存) │       │
│  └──────────────────────────────────┘       │
│                                             │
│  supervisord 进程管理                        │
└──────────────┬──────────────────────────────┘
               │ $PORT
               ▼
          用户浏览器

家庭摄像头 ──(Cloudflare 穿透)──▶ 容器内 Tunnel ──▶ Moonfire NVR (RTSP)
```

## 核心特性

- **Moonfire NVR**：用 Rust 编写的轻量级 NVR，零依赖静态二进制，极低资源消耗
- **无解码直通录制**：直接保存原始 H.264 流，不解码、不重编码，CPU/内存消耗极低
- **现代 Web UI**：内置 React 前端，支持实时预览、录像回放、时间轴浏览
- **Cloudflare Tunnel 集成**：支持以无状态隧道方式暴露服务，彻底解决 PaaS 平台缺少 /dev/net/tun 权限的限制
- **动态端口绑定**：自动读取 PaaS 注入的 `$PORT` 环境变量
- **Rclone 自动备份**：定时通过 API 导出录像并上传到云网盘，释放本地空间
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
  -e CAMERA_URL_1="rtsp://user:pass@10.x.x.x:554/stream" \
  -e RCLONE_CONFIG_BASE64="$(cat rclone.conf | base64 -w 0)" \
  -e RCLONE_REMOTE="remote:nvr-backup" \
  -e MOONFIRE_RETENTION_GB="2" \
  -e TZ="Asia/Shanghai" \
  -v moonfire-data:/var/lib/moonfire-nvr \
  ghcr.io/workerspages/nvr-ffmpeg-rclone:latest
```

启动后访问 `http://localhost:8080` 进入 Moonfire NVR 管理界面。

> 📝 **关于登录：**
> 容器首次启动时，系统会自动根据环境变量配置摄像头，无需额外登录。
> Moonfire NVR 默认以未认证模式允许查看视频。如需设置用户认证，请在 Web UI 中配置。

## 环境变量

| 变量名 | 必填 | 默认值 | 说明 |
|--------|:----:|--------|------|
| `PORT` | 否 | `8080` | HTTP 监听端口（PaaS 平台自动注入） |
| `CLOUDFLARE_TOKEN` | 否 | - | Cloudflare Tunnel Token（用于将容器服务暴露到外网） |
| `CF_ACCESS_HOSTNAME_1` | 否 | - | 1号摄像头的 Cloudflare TCP 内网穿透域名（可选支持 _1 到 _9） |
| `CAMERA_URL_1` | 推荐 | - | 1号摄像头的 RTSP 流地址（若使用了 CF 穿透，填 `rtsp://127.0.0.1:5554/...`，可选支持 _1 到 _9） |
| `CAMERA_USERNAME_1` | 否 | - | 1号摄像头的认证用户名 |
| `CAMERA_PASSWORD_1` | 否 | - | 1号摄像头的认证密码 |
| `MOONFIRE_RETENTION_GB` | 否 | `2` | 每个摄像头的本地录像缓存空间（GB），超出后自动覆盖最旧录像 |
| `RCLONE_CONFIG_BASE64` | 否 | - | `rclone.conf` 文件的 Base64 编码 |
| `RCLONE_REMOTE` | 否 | `remote:nvr-backup` | Rclone 远程目标路径 |
| `SYNC_INTERVAL` | 否 | `300` | Rclone 同步间隔（秒） |
| `RCLONE_MAX_SIZE` | 否 | `10` | 远程网盘存储上限（GB），超过后自动删除最早文件。设为 `0` 关闭循环清理 |
| `TZ` | 否 | `Asia/Shanghai` | 容器时区 |

## Cloudflare Tunnel 部署架构与防坑指南

本系统在 Cloudflare 网络架构中支持**双向内网穿透**。但在使用时，一定要注意区分**"服务端隧道（PaaS端）"**和**"源端隧道（家庭端）"**，切勿将两者的 Token 混用，否则会导致严重的路由回环冲突！

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

如果您希望通过自己的 Cloudflare 域名（例如 `moonfire.yourdomain.com`）来访问云端面板，那么您必须建立**两条完全独立**的隧道。

> ⚠️ **高危排雷警告**：绝对不可以在"家庭路由器"和"PaaS 云端容器"中使用同一个 `CLOUDFLARE_TOKEN`！如果共用 Token，Cloudflare 会在家庭和云端之间进行随机负载均衡，导致视频流（TCP）和网页流（HTTP）各有一半概率请求失败（报错 `i/o timeout`）。

#### 第一条隧道：家庭端（只负责推流）
1. 在 Zero Trust 中新建 Tunnel，例如命名为 `Home-Camera`。
2. 配置 Public Hostname：`cam1.yourdomain.com` -> `tcp://192.168.31.242:554`。
3. 获取 **Token A**，并把它部署在与摄像头同一局域网的家庭设备（NAS/路由器）中。

#### 第二条隧道：PaaS 云端（只负责展示面板）
1. 在 Zero Trust 中新建另一条完全独立的 Tunnel，例如命名为 `Cloud-NVR`。
2. 配置 Public Hostname：`moonfire.yourdomain.com` -> `http://localhost:8080`。
3. 获取 **Token B**。
4. 将 **Token B** 填入 PaaS 环境变量的 `CLOUDFLARE_TOKEN` 中。
5. 依然在 PaaS 填入拉流环境变量：
   - `CF_ACCESS_HOSTNAME_1=cam1.yourdomain.com`
   - `CAMERA_URL_1=rtsp://127.0.0.1:5554/stream1`

### 动态端口打洞与多摄像头支持

无论使用上述哪种架构，脚本都支持最多 9 个摄像头自动进行本地 TCP 打洞映射：
- 1号摄像头 (`CF_ACCESS_HOSTNAME_1`) 会在云端容器内映射至本地 `127.0.0.1:5554` 端口。
- 2号摄像头 (`CF_ACCESS_HOSTNAME_2`) 会在云端容器内映射至本地 `127.0.0.1:5555` 端口，依此类推。
容器启动时会自动通过 Moonfire NVR API 注册这些摄像头。

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

## Rclone 同步机制

与传统 NVR 不同，Moonfire NVR 不直接生成 MP4 文件，而是将原始视频帧以高效的内部格式存储。Rclone 同步脚本的工作流程：

1. **查询录像**：定时通过 Moonfire NVR API 查询各摄像头已录制的时间段
2. **导出 MP4**：调用 `view.mp4` API 按时间分片下载为标准 MP4 文件
3. **上传云盘**：使用 Rclone 将导出的 MP4 文件移动到远程网盘
4. **循环清理**：当远端存储超过 `RCLONE_MAX_SIZE` 时，自动删除最早的文件

本地空间仅作为缓冲区使用，`MOONFIRE_RETENTION_GB` 控制每个摄像头的本地保留空间。

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
fly secrets set CAMERA_URL_1="rtsp://..." RCLONE_CONFIG_BASE64="..."
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

- 推送到 `cloudflare` 分支
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
├── docker-compose.yml          # 本地开发/测试配置
└── .github/
    └── workflows/
        └── docker-build.yml    # CI/CD 工作流
```

## 注意事项

1. **极低资源消耗**：Moonfire NVR 使用 Rust 编写，静态链接零依赖，直通录制不解码视频，非常适合 1C1G PaaS 环境
2. **本地空间管理**：`MOONFIRE_RETENTION_GB` 控制每个摄像头的本地缓存空间，超出后自动覆盖最旧的录像。建议设为 2GB 以上
3. **内网穿透**：如果摄像头位于家庭内网，请确保其能被处于公网或通过 Cloudflare 隧道连接的 PaaS 容器访问
4. **重启恢复**：PaaS 容器重启后，如果未挂载持久化卷，数据库和录像缓存会丢失。建议使用命名卷（如 docker-compose.yml 中的配置）
5. **循环存储**：当 `RCLONE_MAX_SIZE` 大于 0 时，每次同步后脚本会检查远程网盘占用，超限时自动按日期删除最早的录像文件。例如 Google Drive 免费 15GB 空间，建议设为 `10`，预留 5GB 缓冲
6. **首次启动**：容器首次启动时会自动初始化数据库并注册摄像头，后续重启会复用已有配置

## License

MIT
