# ==============================================================================
# STAGE 1: Builder/Preparer
# ==============================================================================
FROM alpine:3.17 AS builder

# 安装构建阶段需要的依赖 (curl, tar, bash)
# 在同一行内添加并清理缓存
RUN apk update && apk --no-cache add curl tar bash && \
    rm -rf /var/cache/apk/*

# --- 准备 GOST ---
# 复制并解压，只为了提取出 gost 二进制文件
COPY gost-linux-arm64.tar.gz /tmp/gost.tar.gz
RUN cd /tmp && tar -xf gost.tar.gz && chmod +x gost

# --- 准备 WARP 工具 ---
# 复制 warp 工具并授权
COPY warp-arm64 /tmp/warp
RUN chmod +x /tmp/warp

# --- 准备 WGCF 工具 ---
# 下载并运行安装脚本，将 wgcf 安装到 /usr/local/bin
RUN curl -fsSL git.io/wgcf.sh | bash

# 至此，所有需要的最终文件都已备好：
# - /tmp/gost
# - /tmp/warp
# - /usr/local/bin/wgcf


# ==============================================================================
# STAGE 2: Final Image
# ==============================================================================
FROM alpine:3.17

# 安装运行阶段所必需的依赖
# 同样，在同一行内添加并清理缓存
RUN apk update && apk --no-cache add \
    ca-certificates \
    iproute2 \
    iptables \
    wireguard-tools \
    openresolv && \
    rm -rf /var/cache/apk/*

# --- 从 builder 阶段复制已准备好的二进制文件 ---
# 只复制我们需要的最终产物，不带任何临时文件和下载脚本
COPY --from=builder /tmp/gost /usr/local/bin/gost
COPY --from=builder /tmp/warp /usr/local/bin/warp
COPY --from=builder /usr/local/bin/wgcf /usr/local/bin/wgcf

# --- 最终设置 ---
WORKDIR /wgcf
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh

ENTRYPOINT ["/entry.sh"]
