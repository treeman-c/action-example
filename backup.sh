#!/usr/bin/env bash
# 全量备份 /app/data 下的所有文件和子目录到 GitHub 仓库
set -uo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
BACKUP_DIR="/tmp/komari-backup"
BRANCH="${SUB_NAME:-main}"

if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
  echo "缺少 GH_USER/GH_PAT/GH_REPO，无法备份"
  exit 1
fi

rm -rf "$BACKUP_DIR"
if git clone --depth 1 --branch "$BRANCH" "https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git" "$BACKUP_DIR" 2>/dev/null; then
  :
else
  # 分支不存在则初始化新工作区
  mkdir -p "$BACKUP_DIR"
  cd "$BACKUP_DIR"
  git init -q
  git remote add origin "https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git"
  git checkout -q -b "$BRANCH"
fi

cd "$BACKUP_DIR"

# 1. 生成 Komari 官方还原识别标记
touch komari-backup-markup

# 2. 全量复制 /app/data 下的所有文件与文件夹（包含隐藏文件）到备份目录
#    使用 find 排除 . 和 .. 避免报错
find "$DATA_DIR" -maxdepth 1 ! -path "$DATA_DIR" -exec cp -rf {} ./ \;

# 3. 写入元数据
echo "${UUID:-unknown}" > UUID
echo "$(date '+%F %T')" > last_backup.txt

# 4. 检查差异并提交
git add -A
if git diff --cached --quiet; then
  echo "数据无变化，跳过提交"
  exit 0
fi

git commit -q -m "backup: ${SUB_NAME:-komari} $(date '+%F %T')"
git push -q -u origin "$BRANCH"
echo "全量备份完成 -> ${GH_REPO}@${BRANCH}"
