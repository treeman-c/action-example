#!/usr/bin/env bash
# =========================================================
# komari + Argo Tunnel 一体化容器入口脚本
# 环境变量含义见仓库 README
# =========================================================
set -uo pipefail

WORK_DIR="${WORK_DIR:-/app}"
DATA_DIR="${DATA_DIR:-/app/data}"
KOMARI_PORT="${KOMARI_PORT:-25774}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"

mkdir -p "$DATA_DIR"

# 确保预先生成 komari 官方校验所需的标识文件，防止备份包损坏/校验失败
touch "${DATA_DIR}/komari-backup-markup"

log() { echo -e "[$(date '+%F %T')] $*"; }

# ---------------------------------------------------------
# 0. 实例标识
# ---------------------------------------------------------
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
SUB_NAME="${SUB_NAME:-komari-node}"
log "实例标识 UUID=${UUID}  SUB_NAME=${SUB_NAME}"
echo "${UUID}" > "${DATA_DIR}/.instance_uuid"

# ---------------------------------------------------------
# 1. 下载加速前缀 (CF_IP 作为反代/加速域名，可留空使用官方源)
#    例如 CF_IP=cdn.814046.xyz 时，
#    实际下载地址会拼接为 https://${CF_IP}/https://github.com/...
# ---------------------------------------------------------
gh_dl() {
  local url="$1"
  if [ -n "${CF_IP:-}" ]; then
    echo "https://${CF_IP}/${url}"
  else
    echo "${url}"
  fi
}

# ---------------------------------------------------------
# 2. 安装 cloudflared（若镜像内未预置）
# ---------------------------------------------------------
install_cloudflared() {
  if [ -x "$CLOUDFLARED_BIN" ]; then
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="arm" ;;
    *) log "不支持的架构: $(uname -m)"; return 1 ;;
  esac
  local base_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  local url
  url="$(gh_dl "$base_url")"
  log "下载 cloudflared: $url"
  curl -fsSL -o "$CLOUDFLARED_BIN" "$url" && chmod +x "$CLOUDFLARED_BIN"
}

# ---------------------------------------------------------
# 3. GitHub 数据持久化：检查仓库是否非空，非空则下载，空则跳过
# ---------------------------------------------------------
setup_git_persistence() {
  if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
    log "未提供完整的 GH_USER/GH_PAT/GH_REPO，跳过 GitHub 持久化备份"
    return 0
  fi

  git config --global user.name "${GH_USER}"
  git config --global user.email "${GH_EMAIL:-${GH_USER}@users.noreply.github.com}"
  git config --global credential.helper store
  echo "https://${GH_USER}:${GH_PAT}@github.com" > ~/.git-credentials

  local repo_url="https://github.com/${GH_REPO}.git"
  log "检查远程备份仓库 ${GH_REPO} 状态..."

  # 使用 ls-remote 探测远程仓库是否有 commit refs
  local remote_refs
  remote_refs=$(git ls-remote --heads "$repo_url" 2>/dev/null || true)

  if [ -z "$remote_refs" ]; then
    log "检测到 GitHub 备份仓库为空（无任何 Commit），跳过数据恢复，直接以全新的数据启动"
  else
    log "检测到 GitHub 备份仓库非空，准备下载并还原历史数据..."
    if /usr/local/bin/restore.sh; then
      log "历史数据还原成功！"
    else
      log "数据还原过程出现警告/异常，将继续以当前数据启动"
    fi
  fi

  # 无论是否为空，再次确保关键的备份标识文件存在
  touch "${DATA_DIR}/komari-backup-markup"
}
setup_cron_backup() {
  if [ -n "${NO_AUTO_RENEW:-}" ] && [ "${NO_AUTO_RENEW}" = "1" ]; then
    log "NO_AUTO_RENEW=1，关闭自动定时备份"
    return 0
  fi

  if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
    log "缺少 GH_USER / GH_PAT / GH_REPO，跳过配置 Cron 定时备份"
    return 0
  fi

  # 1. 确保日志文件存在
  mkdir -p "${DATA_DIR:-/app/data}"
  CRON_LOG="${DATA_DIR:-/app/data}/backup_cron.log"
  touch "$CRON_LOG"

  # 2. 将环境变量和定时任务写入 cron 配置文件
  # 注意：必须把环境变量显式注入到 crontab 中，否则 cron 执行时找不到变量！
  cat <<EOF > /etc/cron.d/komari-backup
    GH_PAT="${GH_PAT}"
    GH_REPO="${GH_REPO}"
    GH_USER="${GH_USER}"
    SUB_NAME="${SUB_NAME:-main}"
    DATA_DIR="${DATA_DIR:-/app/data}"
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    
    # 每 30 分钟执行一次备份，并记录日志
    */30 * * * * root /usr/local/bin/backup.sh >> ${CRON_LOG} 2>&1
  EOF

  # 3. 设置严格的配置文件权限 (crontab 安全要求)
  chmod 0644 /etc/cron.d/komari-backup

  # 4. 启动 cron 守护进程
  # 兼容 Alpine (crond) 和 Debian/Ubuntu (cron)
  if command -v cron >/dev/null 2>&1; then
    cron
  elif command -v crond >/dev/null 2>&1; then
    crond -b
  else
    log "错误: 容器内未安装 cron/crond 工具，请在 Dockerfile 中安装 cron"
    return 1
  fi

  log "已成功启动 Cron 定时备份 (每 30 分钟执行)"
}

# ---------------------------------------------------------
# 4. komari 面板账号/令牌映射
# ---------------------------------------------------------
export ADMIN_USERNAME="${GH_USER:-admin}"
if [ -n "${DASH_TOKEN:-}" ]; then
  export ADMIN_PASSWORD="${DASH_TOKEN}"
fi

if [ -n "${API_TOKEN:-}" ]; then
  mkdir -p "${DATA_DIR:-/app/data}"
  echo "${API_TOKEN}" > "${DATA_DIR:-/app/data}/.api_token"
  log "已写入 API_TOKEN 到 ${DATA_DIR:-/app/data}/.api_token"
fi

if [ -n "${GH_CLIENTID:-}" ]; then
  export OAUTH_CLIENT_ID="${GH_CLIENTID}"
fi
if [ -n "${GH_CLIENTSECRET:-}" ]; then
  export OAUTH_CLIENT_SECRET="${GH_CLIENTSECRET}"
fi

# ---------------------------------------------------------
# 5. 启动 komari 面板（后台）
# ---------------------------------------------------------
start_komari() {
  log "启动 komari 面板，监听 0.0.0.0:${KOMARI_PORT}"
  /app/komari server -l "0.0.0.0:${KOMARI_PORT}" &
  KOMARI_PID=$!
}

# ---------------------------------------------------------
# 6. 启动 Argo (cloudflared) 隧道
# ---------------------------------------------------------
start_argo() {
  if [ -z "${ARGO_AUTH:-}" ]; then
    log "未设置 ARGO_AUTH，跳过 Argo 隧道，仅本地监听 ${KOMARI_PORT} 端口"
    return 0
  fi

  install_cloudflared || { log "cloudflared 安装失败"; return 1; }

  if echo "${ARGO_AUTH}" | jq -e . >/dev/null 2>&1; then
    log "检测到 ARGO_AUTH 为 JSON 凭证，使用具名隧道 + 自定义 ingress 模式"
    mkdir -p /etc/cloudflared
    echo "${ARGO_AUTH}" > /etc/cloudflared/tunnel.json
    TUNNEL_ID=$(echo "${ARGO_AUTH}" | jq -r '.TunnelID // .tunnel_id // empty')

    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/tunnel.json
ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${KOMARI_PORT}
  - service: http_status:404
EOF

    "$CLOUDFLARED_BIN" tunnel --config /etc/cloudflared/config.yml run &
    ARGO_PID=$!
  else
    log "检测到 ARGO_AUTH 为 Token 模式，使用远程管理隧道"
    "$CLOUDFLARED_BIN" tunnel run --token "${ARGO_AUTH}" &
    ARGO_PID=$!
  fi
  log "Argo 隧道已启动，外部访问地址: https://${ARGO_DOMAIN}"
}

# ---------------------------------------------------------
# 主流程
# ---------------------------------------------------------
setup_git_persistence
start_komari
start_argo
setup_cron_backup

# ---------------------------------------------------------
# 优雅退出：容器停止前做最后一次备份
# ---------------------------------------------------------
term_handler() {
  log "收到退出信号，执行最终备份..."
  if [ -n "${GH_PAT:-}" ] && [ -z "${NO_AUTO_RENEW:-}" ]; then
    # 退出前确保标识文件在数据包中
    touch "${DATA_DIR}/komari-backup-markup" 2>/dev/null || true
    /usr/local/bin/backup.sh || true
  fi
  [ -n "${ARGO_PID:-}" ] && kill "$ARGO_PID" 2>/dev/null
  [ -n "${KOMARI_PID:-}" ] && kill "$KOMARI_PID" 2>/dev/null
  exit 0
}
trap term_handler SIGTERM SIGINT

wait -n "$KOMARI_PID"
