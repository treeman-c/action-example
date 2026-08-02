#!/usr/bin/env bash
# 容器启动时从 GH_REPO 拉取历史 komari 数据，实现无状态平台上的数据持久化
set -uo pipefail

DATA_DIR="${DATA_DIR:-/app/data}"
RESTORE_DIR="/tmp/komari-restore"
BRANCH="${SUB_NAME:-main}"

if [ -z "${GH_PAT:-}" ] || [ -z "${GH_REPO:-}" ]; then
  exit 1
fi

rm -rf "$RESTORE_DIR"
if ! git clone --depth 1 --branch "$BRANCH" "https://github.com/${GH_REPO}.git" "$RESTORE_DIR" 2>/dev/null; then
  echo "远程仓库/分支不存在，视为首次部署"
  exit 1
fi

if [ -d "${RESTORE_DIR}/data" ]; then
  cp -f "${RESTORE_DIR}"/data/*.db "$DATA_DIR"/ 2>/dev/null || true
  [ -f "${RESTORE_DIR}/data/.instance_uuid" ] && cp -f "${RESTORE_DIR}/data/.instance_uuid" "$DATA_DIR"/
  echo "历史数据已还原"
  exit 0
fi

exit 1
