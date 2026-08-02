#!/usr/bin/env bash
# 容器启动时从 GH_REPO 拉取历史 komari 数据，实现无状态平台上的数据持久化
set -uo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
RESTORE_DIR="/tmp/komari-restore"
BRANCH="${SUB_NAME:-main}"

mkdir -p "$DATA_DIR"

if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ]; then
  echo "缺少 GH_PAT 或 GH_REPO 环境变量，跳过还原"
  exit 0
fi

rm -rf "$RESTORE_DIR"

# 1. 带有 GH_PAT 鉴权拉取私有仓库
echo "正在拉取备份仓库 ${GH_REPO}@${BRANCH}..."
if ! git clone --depth 1 --branch "$BRANCH" "https://${GH_PAT}@github.com/${GH_REPO}.git" "$RESTORE_DIR" 2>/dev/null; then
  echo "远程仓库/分支不存在，视为首次部署"
  exit 0
fi

# 2. 全量还原仓库中的所有文件和文件夹到 /app/data/
echo "开始还原历史数据到 ${DATA_DIR}..."

# 如果历史备份存放在仓库的 data/ 子目录下，兼容支持
if [ -d "${RESTORE_DIR}/data" ]; then
  cp -rf "${RESTORE_DIR}/data"/* "$DATA_DIR"/ 2>/dev/null || true
  cp -rf "${RESTORE_DIR}/data"/.* "$DATA_DIR"/ 2>/dev/null || true
fi

# 还原仓库根目录下的全量备份文件（排除 .git 目录和 . / .. 指针）
find "$RESTORE_DIR" -maxdepth 1 ! -name "." ! -name ".." ! -name ".git" -exec cp -rf {} "$DATA_DIR"/ \;

# 3. 补全双向兼容软链接 (komari.db <-> data.db)，防止不同版本文件名不匹配
if [ -f "${DATA_DIR}/komari.db" ] && [ ! -f "${DATA_DIR}/data.db" ]; then
  ln -s "${DATA_DIR}/komari.db" "${DATA_DIR}/data.db" || true
elif [ -f "${DATA_DIR}/data.db" ] && [ ! -f "${DATA_DIR}/komari.db" ]; then
  ln -s "${DATA_DIR}/data.db" "${DATA_DIR}/komari.db" || true
fi

# 4. 清理临时目录
rm -rf "$RESTORE_DIR"
echo "历史数据还原成功！"
exit 0
