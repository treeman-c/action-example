# =========================================================
# komari + Argo Tunnel + GitHub 持久化备份 一体化镜像
# 基于官方 komari 镜像叠加：cloudflared 隧道 / git 备份还原
# 参数体系仿照 daxia2023/nezv1 (哪吒探针+Argo 常见模式) 迁移到 komari
# =========================================================
FROM ghcr.io/komari-monitor/komari:latest

# 官方镜像基于 alpine，这里补充运行所需工具
# bash: 运行控制脚本 / curl+ca-certificates: 下载 cloudflared / git+openssh-client: GitHub 备份
# sqlite: 校验数据库文件 / tzdata: 时区
RUN apk add --no-cache bash curl dcron ca-certificates git openssh-client sqlite tzdata jq \
    && rm -rf /var/cache/apk/*

ENV TZ=Asia/Shanghai \
    KOMARI_PORT=25774 \
    WORK_DIR=/app \
    DATA_DIR=/app/data \
    CLOUDFLARED_BIN=/usr/local/bin/cloudflared

WORKDIR /app

# 拷贝控制脚本
COPY entrypoint.sh /entrypoint.sh
COPY backup.sh /usr/local/bin/backup.sh
COPY restore.sh /usr/local/bin/restore.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/backup.sh /usr/local/bin/restore.sh

EXPOSE 25774

ENTRYPOINT ["/entrypoint.sh"]
