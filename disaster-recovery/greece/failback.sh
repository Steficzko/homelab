#!/usr/bin/env bash
# FAIL BACK: revert public DNS from Greece to Prague.
# ONLY run after Prague holds Greece's current data (reverse-restore) — see FAILBACK.md.
# Needs a Cloudflare API token (Zone:DNS:Edit) in $CF_API_TOKEN or ~/.cloudflare_token.
set -euo pipefail
TOKEN="${CF_API_TOKEN:-$(cat ~/.cloudflare_token 2>/dev/null || true)}"
[ -n "$TOKEN" ] || { echo "ERROR: no Cloudflare API token"; exit 1; }

PRG_APP="9bb353e8-09a8-4b4d-9eca-5fa360aa6270.cfargotunnel.com"   # TeamElwany PRG
ZK="8dff731485cfed2d9dea64c335b91254"               # kostikidis.net
ZT="bf7cb7f1d5d83b3416647fddee20b82c"               # teamelwany.com
APP_REC="889b8c44206aa183b31cf2ac1592c5b5"          # app.teamelwany.com
api(){ curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

echo "==> app.teamelwany.com -> Prague"
api -X PUT "https://api.cloudflare.com/client/v4/zones/$ZT/dns_records/$APP_REC" \
  --data "{\"type\":\"CNAME\",\"name\":\"app.teamelwany.com\",\"content\":\"$PRG_APP\",\"proxied\":true}" \
  | grep -o '"success":[a-z]*'

echo "==> auto.kostikidis.net -> delete override (reverts to *.kostikidis.net wildcard -> Prague)"
RID=$(api "https://api.cloudflare.com/client/v4/zones/$ZK/dns_records?type=CNAME&name=auto.kostikidis.net" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)  # grep returns 1 when no override present — don't let pipefail/errexit abort before the no-op branch
if [ -n "$RID" ]; then
  api -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZK/dns_records/$RID" | grep -o '"success":[a-z]*'
else
  echo "   (no override present — already on the wildcard/Prague)"
fi
echo "==> FAILED BACK to Prague. Stop the Greece app tier (remove COMPOSE_PROFILES=failover)."
