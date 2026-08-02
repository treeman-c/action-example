#!/usr/bin/env bash
# 将 /app/data 下的 komari 数据备份到 GH_REPO（私有仓库建议）
set -uo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
BACKUP_DIR="/tmp/komari-backup"
BRANCH="${SUB_NAME:-main}"

if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
  echo "缺少 GH_USER/GH_PAT/GH_REPO，无法备份"
  exit 1
fi

rm -rf "$BACKUP_DIR"
if git clone --depth 1 --branch "$BRANCH" "https://github.com/${GH_REPO}.git" "$BACKUP_DIR" 2>/dev/null; then
  :
else
  # 分支不存在则初始化一个新仓库工作区
  mkdir -p "$BACKUP_DIR"
  cd "$BACKUP_DIR"
  git init -q
  git remote add origin "https://github.com/${GH_REPO}.git"
  git checkout -q -b "$BRANCH"
fi

cd "$BACKUP_DIR"
mkdir -p data
cp -f "${DATA_DIR}"/*.db data/ 2>/dev/null || true
[ -f "${DATA_DIR}/.instance_uuid" ] && cp -f "${DATA_DIR}/.instance_uuid" data/

echo "${UUID:-unknown}" > data/UUID
echo "$(date '+%F %T')" > data/last_backup.txt

git add -A
if git diff --cached --quiet; then
  echo "数据无变化，跳过提交"
  exit 0
fi

git commit -q -m "backup: ${SUB_NAME:-komari} $(date '+%F %T')"
git push -q -u origin "$BRANCH"
echo "备份完成 -> ${GH_REPO}@${BRANCH}"
