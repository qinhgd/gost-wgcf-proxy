# Cloudflare WARP Proxy with GOST (ARM64)

[![GitHub Actions Workflow Status](https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/actions/workflows/docker-build.yml/badge.svg)](https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME/actions)

本项目通过 Docker 将 Cloudflare WARP 与 GOST 代理服务结合，为 `arm64` 架构设备（如树莓派、各类ARM开发板及服务器）提供一个稳定、高效、开箱即用的网络代理解决方案。

脚本会自动优选 Cloudflare WARP 的 Endpoint IP，并通过 WireGuard 建立连接，然后利用 GOST 将其作为 SOCKS5 和 HTTP 代理暴露出来。整个过程被设计为高度自动化、具备断线重连和状态通知功能。

## ✨ 核心功能

- **Cloudflare WARP**: 利用 `wgcf` 注册并连接到 Cloudflare 的 WARP 网络，获取更纯净、安全的网络访问。
- **智能IP优选**: 集成 `warp` 扫描工具，自动扫描并排序最优的 WARP Endpoint IP，确保连接速度和稳定性。
- **高效代理服务**: 使用 `gost` 提供高性能的 SOCKS5 和 HTTP 代理服务。
- **智能重连逻辑**:
    - **快速重连**: 普通断线后，会立即使用现有的优选IP列表进行快速重连尝试。
    - **自动优选**: 仅在现有IP列表全部失效、或定时任务触发时，才执行耗时的IP优选，避免不必要的延迟。
- **状态持久化**: 首次运行后，WARP账户信息将被保存在挂载的数据卷中，容器重启无需重新注册。
- **Telegram 消息通知**: 可配置通过Telegram机器人实时接收服务状态通知，包括：
    - 首次连接成功
    - 定时优选重连成功
    - 断线重连成功
    - 连接彻底失败
- **全自动化构建 (CI/CD)**: 集成 GitHub Actions，在创建 Release 时自动构建并推送镜像到 GHCR，同时打包 `.tar` 文件作为 Release 附件。

## 🚀 快速上手

### 方法一：使用 `docker run`

这是最直接的运行方式。请确保您的设备已安装 Docker。

1.  **拉取镜像**
    从 GitHub Container Registry (GHCR) 拉取最新镜像。请将 `YOUR_GITHUB_USERNAME` 和 `YOUR_REPO_NAME` 替换为您自己的信息。
    ```bash
    docker pull ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:latest
    ```

2.  **创建持久化目录**
    ```bash
    mkdir -p /opt/wgcf_data
    ```

3.  **运行容器**
    复制下面的命令，并将环境变量替换为您自己的值。
    ```bash
    docker run -d \
      --name my-wgcf-proxy \
      -p 1080:1080 \
      -p 8080:8080 \
      -v /opt/wgcf_data:/wgcf \
      -e TG_BOT_TOKEN="YOUR_BOT_TOKEN" \
      -e TG_CHAT_ID="YOUR_CHAT_ID" \
      -e HOSTNAME="My-ARM-Server" \
      --privileged \
      --restart always \
      ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:latest
    ```

### 方法二：使用 `docker-compose` (推荐)

使用 `docker-compose` 可以更方便地管理配置。

1.  创建一个名为 `docker-compose.yml` 的文件，并粘贴以下内容：

    ```yaml
    version: '3.8'

    services:
      warp-proxy:
        # 替换为您的GHCR镜像地址
        image: ghcr.io/YOUR_GITHUB_USERNAME/YOUR_REPO_NAME:latest
        container_name: my-wgcf-proxy
        restart: always
        # 特权模式，确保WireGuard有足够权限
        privileged: true
        ports:
          - "1080:1080" # SOCKS5 端口
          - "8080:8080" # HTTP 端口
        volumes:
          # 将本地的 ./wgcf_data 目录挂载到容器的 /wgcf
          - ./wgcf_data:/wgcf
        environment:
          # --- 基础配置 ---
          - PORT=1080
          - HTTP_PORT=8080
          # - USER=your_username  # (可选) 代理用户名
          # - PASSWORD=your_password # (可选) 代理密码

          # --- Telegram 通知配置 ---
          - TG_BOT_TOKEN="YOUR_BOT_TOKEN"
          - TG_CHAT_ID="YOUR_CHAT_ID"
          - HOSTNAME="My-ARM-Server" # (可选) 自定义在TG消息中显示的主机名

          # --- 高级配置 (可使用默认值) ---
          - OPTIMIZE_INTERVAL=21600 # IP优选间隔 (秒)，默认6小时
          - HEALTH_CHECK_INTERVAL=60  # 健康检查间隔 (秒)，默认60秒
    ```

2.  在 `docker-compose.yml` 文件所在目录，运行以下命令启动服务：
    ```bash
    docker-compose up -d
    ```

## ⚙️ 配置参数

您可以通过环境变量来配置容器的行为：

| 环境变量              | 描述                                     | 默认值          |
| --------------------- | ---------------------------------------- | --------------- |
| `PORT`                | SOCKS5 代理端口                          | `1080`          |
| `HTTP_PORT`           | HTTP 代理端口 (如果留空则不启用)         | `(空)`          |
| `USER`                | 代理认证用户名 (与`PASSWORD`一同使用)      | `(空)`          |
| `PASSWORD`            | 代理认证密码                             | `(空)`          |
| `TG_BOT_TOKEN`        | Telegram Bot 的 Token                    | `(空)`          |
| `TG_CHAT_ID`          | 接收通知的 Telegram Chat ID              | `(空)`          |
| `HOSTNAME`            | 在TG通知中显示的主机名/设备名            | `WARP`          |
| `OPTIMIZE_INTERVAL`   | 定时优选IP的间隔（秒）                   | `21600` (6小时) |
| `BEST_IP_COUNT`       | 每次优选保留的IP数量                     | `30`            |
| `HEALTH_CHECK_INTERVAL` | 健康检查的间隔（秒）                     | `60`            |
| `HEALTH_CHECK_TIMEOUT`| 健康检查的超时时间（秒）                 | `10`            |

## 🛠️ 使用代理

服务启动后，在您的设备或浏览器上设置代理：
- **代理类型**: SOCKS5 或 HTTP
- **服务器/主机**: 运行 Docker 的设备 IP 地址
- **端口**: `1080` (SOCKS5) 或 `8080` (HTTP)
- **用户名/密码**: 如果您已设置

## 📦 自动化部署

本仓库已配置 GitHub Actions，在每次创建 Release 时会自动执行以下操作：
1.  构建 `linux/arm64` 架构的 Docker 镜像。
2.  将镜像推送到本仓库关联的 GitHub Container Registry (GHCR)。
3.  将镜像打包成 `wgcf-gost-arm64.tar` 文件，并作为附件上传到该 Release。

您可以根据需要选择拉取GHCR的镜像或下载Release中的`.tar`文件进行部署。

## 📁 项目文件结构

- `.github/workflows/docker-build.yml`: GitHub Actions 工作流配置文件。
- `Dockerfile.alpine`: 用于构建镜像的Dockerfile (请重命名为 `Dockerfile` 或在工作流中指定)。
- `entry.sh`: 容器的入口脚本，包含所有核心逻辑。
- `warp-arm64`: WARP IP 优选工具 (ARM64)。
- `gost-linux-arm64.tar.gz`: GOST 代理工具 (ARM64)。

## 📜 License

本项目基于 [MIT License](LICENSE) 授权。
