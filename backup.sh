#!/bin/bash
set -e

BASE="/backup"
SNAPSHOT="$BASE/snapshot"
HISTORY="$BASE/history"

mkdir -p $SNAPSHOT $HISTORY

echo "[BACKUP] $(date)"

# ========= snapshot =========
rm -rf $SNAPSHOT/*
echo "$(date)" > $SNAPSHOT/time.txt

# 👉 这里替换真实数据
# cp -r /data/* $SNAPSHOT/

# ========= git init =========
cd $BASE

if [ ! -d .git ]; then
  git init
  git remote add origin "https://$GH_USER:$GH_PAT@github.com/$GH_USER/$GH_REPO.git"
fi

git config user.email "$GH_EMAIL"
git config user.name "$GH_USER"

git add .

git commit -m "snapshot $(date)" || true

# ========= push =========
git push origin main --force || true

# ========= 保留历史（压缩） =========
DATE=$(date +%F_%H-%M)
ARCHIVE="$HISTORY/$DATE.tar.gz"

tar -czf $ARCHIVE -C $SNAPSHOT .

# ========= 删除旧备份（只保留5个） =========
cd $HISTORY
ls -t *.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f

echo "[CLEAN] keep latest 5 backups only"
