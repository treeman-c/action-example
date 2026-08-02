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
# 3. GitHub 数据持久化：启动前尝试还原，退出/定时时备份
#    需要 GH_USER / GH_EMAIL / GH_PAT / GH_REPO
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

  log "尝试从 GH_REPO=${GH_REPO} 还原历史数据..."
  /usr/local/bin/restore.sh || log "未找到可还原的历史数据，将使用全新数据启动"
}

start_backup_loop() {
  if [ -n "${NO_AUTO_RENEW:-}" ] && [ "${NO_AUTO_RENEW}" = "1" ]; then
    log "NO_AUTO_RENEW=1，关闭自动定时备份"
    return 0
  fi
  if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ]; then
    return 0
  fi
  (
    while true; do
      sleep 1800  # 每 30 分钟备份一次
      /usr/local/bin/backup.sh || log "备份失败，将在下个周期重试"
    done
  ) &
  log "已启动后台自动备份循环 (间隔 1800s)"
}

# ---------------------------------------------------------
# 4. komari 面板账号/令牌映射
#    DASH_TOKEN -> ADMIN_PASSWORD（面板登录密码）
#    API_TOKEN  -> 落盘，供对接 Agent 时核对使用
# ---------------------------------------------------------
export ADMIN_USERNAME="${GH_USER:-admin}"
if [ -n "${DASH_TOKEN:-}" ]; then
  export ADMIN_PASSWORD="${DASH_TOKEN}"
fi
if [ -n "${API_TOKEN:-}" ]; then
  echo "${API_TOKEN}" > "${DATA_DIR}/.api_token"
  log "已写入 API_TOKEN 到 ${DATA_DIR}/.api_token（如面板暂不支持环境变量注入，请在管理后台核对/替换为该值）"
fi

# GitHub OAuth 客户端信息（若 komari 版本已支持，将作为环境变量透传给主进程）
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
#    ARGO_AUTH: 支持两种形式
#      a) Cloudflare Zero Trust 远程管理隧道的 Token（一段较长字符串）
#      b) 隧道凭证 JSON（tunnel credentials-file 内容）
#    ARGO_DOMAIN: 对外域名，例如 nz.treeman.xx.kg
# ---------------------------------------------------------
start_argo() {
  if [ -z "${ARGO_AUTH:-}" ]; then
    log "未设置 ARGO_AUTH，跳过 Argo 隧道，仅本地监听 ${KOMARI_PORT} 端口"
    return 0
  fi

  install_cloudflared || { log "cloudflared 安装失败"; return 1; }

  # 判断 ARGO_AUTH 是否为 JSON（隧道凭证），否则按 Token 模式处理
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
    log "检测到 ARGO_AUTH 为 Token 模式，使用远程管理隧道（域名路由已在 Cloudflare 后台绑定 ${ARGO_DOMAIN}）"
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
start_backup_loop

# ---------------------------------------------------------
# 优雅退出：容器停止前做最后一次备份
# ---------------------------------------------------------
term_handler() {
  log "收到退出信号，执行最终备份..."
  if [ -n "${GH_PAT:-}" ] && [ -z "${NO_AUTO_RENEW:-}" ]; then
    /usr/local/bin/backup.sh || true
  fi
  [ -n "${ARGO_PID:-}" ] && kill "$ARGO_PID" 2>/dev/null
  [ -n "${KOMARI_PID:-}" ] && kill "$KOMARI_PID" 2>/dev/null
  exit 0
}
trap term_handler SIGTERM SIGINT

wait -n "$KOMARI_PID"
