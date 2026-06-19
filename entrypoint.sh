#!/bin/bash
set -e

echo "[INIT] system starting..."

# komari
komari &

# ========= cron (every 2 hours) =========
echo "0 */2 * * * /backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

echo "[INFO] Backup schedule: every 2 hours"

crond -f &

# ========= cloudflared =========
if [ -n "$TUNNEL_TOKEN" ]; then
  exec cloudflared tunnel run --token "$TUNNEL_TOKEN"
else
  echo "$ARGO_AUTH" > /tmp/argo.json
  exec cloudflared tunnel --credentials-file /tmp/argo.json run
fi
