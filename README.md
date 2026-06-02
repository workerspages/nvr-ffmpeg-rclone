基础信息：
1.我的冢宽带没有固定的 IP 地址
2.我在家路由器上安装了zerotier参透工具，供外网访问
3.家里有一个网络摄像头
要求：
构建一个docker镜像.镜像部署在1C1G（1核 CPU，1GB 内存）PaaS平台
此镜像功能为：使用NVR 软件 MotionEye 链接（zerotier参透）家里的网络摄像头，并将录制保存在本地，使用rclone定时将本地录制文件备份到网盘长期备份

在 1C1G（1核 CPU，1GB 内存）的海外云服务器上通过 PaaS 平台（如 Zeabur、Railway、Render、Fly.io 等）部署 MotionEye，需要特别解决以下三个 PaaS 平台的原生痛点：

动态端口绑定：PaaS 平台通常会随机分配端口并注入到环境变量 $PORT 中，而 MotionEye 默认固定在 8765 端口。

只读/临时文件系统：PaaS 的容器重启后数据会清空。因此，MotionEye 的配置目录 /etc/motioneye 和临时缓存目录 /var/lib/motioneye 必须具备全写权限，且录像必须快速被 Rclone 搬运走。

极度苛刻的内存限制：必须彻底关闭图像解码与移动侦测，完全开启 Passthrough（流直通）。


使用github actions自动构建镜像 并保存到 ghcr.io 和 hub.docker.com
