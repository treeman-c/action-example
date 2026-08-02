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

# 初始化 PID 变量，避免 set -u 误报未定义变量
KOMARI_PID=""
ARGO_PID=""

mkdir -p "$DATA_DIR"

# 确保预先生成 komari 官方校验所需的标识文件，防止备份包损坏/校验失败
touch "${DATA_DIR}/komari-backup-markup"

log() { echo -e "[$(date '+%F %T')] $*"; }

# ---------------------------------------------------------
# 0. 实例标识
# ---------------------------------------------------------
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
SUB_NAME="${SUB_NAME:-komari-node}"
log "实例标识 UUID=${UUID} SUB_NAME=${SUB_NAME}"
echo "${UUID}" > "${DATA_DIR}/.instance_uuid"

# ---------------------------------------------------------
# 1. 下载加速前缀
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
# 2. 安装 cloudflared
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
  local origin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  local tmp_file="/tmp/cloudflared.download"

  if [ -n "${CF_IP:-}" ]; then
    local mirror_url
    mirror_url="$(gh_dl "$origin_url")"
    log "下载 cloudflared（加速）: $mirror_url"
    if curl -fsSL --connect-timeout 10 -o "$tmp_file" "$mirror_url"; then
      mv "$tmp_file" "$CLOUDFLARED_BIN"
      chmod +x "$CLOUDFLARED_BIN"
      return 0
    fi
    log "加速下载失败，回退到官方地址重试"
  fi

  log "下载 cloudflared（官方源）: $origin_url"
  if curl -fsSL --connect-timeout 10 -o "$tmp_file" "$origin_url"; then
    mv "$tmp_file" "$CLOUDFLARED_BIN"
    chmod +x "$CLOUDFLARED_BIN"
    return 0
  fi

  log "cloudflared 下载失败：加速源和官方源均不可用，请检查出站网络"
  return 1
}

# ---------------------------------------------------------
# 3. GitHub 数据持久化：启动前还原
# ---------------------------------------------------------
setup_git_persistence() {
  if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
    log "未提供完整的 GH_USER/GH_PAT/GH_REPO，跳过 GitHub 持久化备份"
    return 0
  fi
  if [[ "${GH_REPO}" != */* ]]; then
    log "警告：GH_REPO='${GH_REPO}' 格式不对，必须是 '用户名/仓库名'，已跳过 GitHub 持久化备份"
    return 0
  fi

  git config --global user.name "${GH_USER}"
  git config --global user.email "${GH_EMAIL:-${GH_USER}@users.noreply.github.com}"
  git config --global credential.helper store
  echo "https://${GH_USER}:${GH_PAT}@github.com" > ~/.git-credentials

  local repo_url="https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git"
  local branch="${SUB_NAME:-main}"
  log "检查远程备份仓库 ${GH_REPO}@${branch} 状态..."

  local remote_refs
  remote_refs=$(git ls-remote --heads "$repo_url" "$branch" 2>/dev/null || true)

  if [ -z "$remote_refs" ]; then
    log "检测到远程分支不存在或仓库为空，跳过数据恢复，直接以全新数据启动"
  else
    log "检测到远程备份存在，准备下载并还原历史数据..."
    if /usr/local/bin/restore.sh; then
      log "历史数据还原成功！"
    else
      log "数据还原过程出现警告/异常，将继续以当前数据启动"
    fi
  fi

  touch "${DATA_DIR}/komari-backup-markup"
}

# ---------------------------------------------------------
# 3.1 定时备份：使用 Alpine/busybox 自带的 crond
#     关键点：busybox crond 只认 /etc/crontabs/<用户名>，
#     不支持 Debian 风格的 /etc/cron.d/ 目录！
#     这个函数与 NO_AUTO_RENEW 完全无关——只要配置了
#     GH_USER/GH_PAT/GH_REPO 就会持续备份。
# ---------------------------------------------------------
setup_cron_backup() {
  if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
    log "缺少 GH_USER / GH_PAT / GH_REPO，跳过配置定时备份"
    return 0
  fi
  if [[ "${GH_REPO}" != */* ]]; then
    log "GH_REPO 格式不对，跳过配置定时备份"
    return 0
  fi

  mkdir -p /etc/crontabs
  local cron_file="/etc/crontabs/root"
  local cron_log="${DATA_DIR}/backup_cron.log"
  local interval_min="${BACKUP_INTERVAL_MINUTES:-5}"
  touch "$cron_file" "$cron_log"

  # 去重：清掉我们自己之前可能写过的旧条目，避免重复追加
  grep -v "backup.sh" "$cron_file" > "${cron_file}.tmp" 2>/dev/null || true
  mv "${cron_file}.tmp" "$cron_file"

  {
    echo "GH_PAT=${GH_PAT}"
    echo "GH_REPO=${GH_REPO}"
    echo "GH_USER=${GH_USER}"
    echo "SUB_NAME=${SUB_NAME:-main}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "*/${interval_min} * * * * /usr/local/bin/backup.sh >> ${cron_log} 2>&1"
  } >> "$cron_file"

  if ! command -v crond >/dev/null 2>&1; then
    log "错误：容器内未找到 crond 命令，请在 Dockerfile 中确认基础镜像自带 busybox crond（一般 alpine 默认自带，无需额外安装）"
    return 1
  fi

  if ! pgrep -x crond >/dev/null 2>&1; then
    crond -b -l 8
    log "已启动 crond 后台守护进程"
  else
    log "crond 已在运行，无需重复启动"
  fi

  log "已写入定时备份任务到 ${cron_file}（每 ${interval_min} 分钟执行一次，与 NO_AUTO_RENEW 无关）"

  # 容器刚启动时先立即做一次备份，不用等第一个 cron 周期，
  # 缩短"重新部署窗口内数据还没落盘"的风险
  (
    sleep 60
    /usr/local/bin/backup.sh >> "$cron_log" 2>&1 || log "首次即时备份失败，等待下个 cron 周期重试"
  ) &
}

# ---------------------------------------------------------
# 4. komari 面板账号/令牌映射
# ---------------------------------------------------------
export ADMIN_USERNAME="${GH_USER:-admin}"
if [ -n "${DASH_TOKEN:-}" ]; then
  export ADMIN_PASSWORD="${DASH_TOKEN}"
fi

if [ -n "${API_TOKEN:-}" ]; then
  echo "${API_TOKEN}" > "${DATA_DIR}/.api_token"
  log "已写入 API_TOKEN 到 ${DATA_DIR}/.api_token"
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
  - hostname: ${ARGO_DOMAIN:-localhost}
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
  log "Argo 隧道已启动，外部访问地址: https://${ARGO_DOMAIN:-localhost}"
}

# ---------------------------------------------------------
# 7. 优雅退出处理函数（与 NO_AUTO_RENEW 无关，始终尝试最后备份一次）
# ---------------------------------------------------------
term_handler() {
  log "收到退出信号，执行最终备份..."
  if [ -n "${GH_PAT:-}" ] && [ -n "${GH_REPO:-}" ]; then
    touch "${DATA_DIR}/komari-backup-markup" 2>/dev/null || true
    /usr/local/bin/backup.sh || true
  fi
  [ -n "${ARGO_PID}" ] && kill "$ARGO_PID" 2>/dev/null || true
  [ -n "${KOMARI_PID}" ] && kill "$KOMARI_PID" 2>/dev/null || true
  exit 0
}

# ---------------------------------------------------------
# 主流程
# ---------------------------------------------------------
trap term_handler SIGTERM SIGINT

setup_git_persistence
start_komari
start_argo
setup_cron_backup

if [ -n "$KOMARI_PID" ]; then
  wait "$KOMARI_PID"
fi
