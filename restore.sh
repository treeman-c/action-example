#!/usr/bin/env bash
# 容器启动时从 GH_REPO 拉取历史 komari 数据，实现无状态平台上的数据持久化
# 与 backup.sh 保持一致：数据直接存放在仓库根目录（而非 data/ 子目录）
set -uo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
RESTORE_DIR="/tmp/komari-restore"
BRANCH="${SUB_NAME:-main}"

if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ] || [ -z "${GH_USER:-}" ]; then
  exit 1
fi
if [[ "${GH_REPO}" != */* ]]; then
  echo "GH_REPO='${GH_REPO}' 格式不对，必须是 '用户名/仓库名'"
  exit 1
fi

rm -rf "$RESTORE_DIR"
# 私有仓库需要带凭证才能 clone，和 backup.sh 保持一致
if ! git clone --depth 1 --branch "$BRANCH" "https://${GH_USER}:${GH_PAT}@github.com/${GH_REPO}.git" "$RESTORE_DIR" 2>/dev/null; then
  echo "远程仓库/分支不存在，视为首次部署"
  exit 1
fi

# 校验是否为 komari-backup-markup 标记的备份（避免误还原一个无关仓库）
if [ ! -f "${RESTORE_DIR}/komari-backup-markup" ]; then
  echo "远程仓库中未找到备份标记 komari-backup-markup，跳过还原"
  exit 1
fi

# 把仓库根目录下的所有文件（除 .git 外）还原到 DATA_DIR
find "$RESTORE_DIR" -mindepth 1 -maxdepth 1 ! -name ".git" -exec cp -rf {} "$DATA_DIR"/ \;

# 清理还原回来的嵌套 .git 目录，避免历史遗留的内嵌仓库反复循环
find "$DATA_DIR" -mindepth 1 -name ".git" -exec rm -rf {} + 2>/dev/null || true

echo "历史数据已还原"
exit 0
