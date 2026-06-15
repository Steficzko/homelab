#!/usr/bin/env bash
# FAIL OVER: flip public DNS from Prague to the Greece failover tunnel (sticky).
# Run AFTER you've started the Greece failover stack (COMPOSE_PROFILES=failover) and
# re-activated workflows — see FAILOVER.md. Stays on Greece until you run failback.sh.
#
# Needs a Cloudflare API token (Zone:DNS:Edit + Account:Cloudflare Tunnel:Read) in
# $CF_API_TOKEN or ~/.cloudflare_token.
set -euo pipefail
TOKEN="${CF_API_TOKEN:-$(cat ~/.cloudflare_token 2>/dev/null || true)}"
[ -n "$TOKEN" ] || { echo "ERROR: no Cloudflare API token (set CF_API_TOKEN or ~/.cloudflare_token)"; exit 1; }

ACCT="90e7dc337477819281ed982a7f6afe32"
TUN="0fb9fd16-cf43-4235-b9d5-9dca0166bc3f"          # TeamElwany GR (failover)
GR="${TUN}.cfargotunnel.com"
ZK="8dff731485cfed2d9dea64c335b91254"               # kostikidis.net
ZT="bf7cb7f1d5d83b3416647fddee20b82c"               # teamelwany.com
APP_REC="889b8c44206aa183b31cf2ac1592c5b5"          # app.teamelwany.com
api(){ curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

# --- pre-flight: refuse to flip DNS to a tunnel that has no live connections ---
STATUS=$(api "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TUN" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Greece failover tunnel status: ${STATUS:-unknown}"
if [ "$STATUS" != "healthy" ] && [ "$STATUS" != "degraded" ]; then
  echo "ABORT: the Greece tunnel is not connected. Start the failover stack first:"
  echo "  Portainer bjj-failover -> add env COMPOSE_PROFILES=failover -> redeploy"
  echo "  (or: docker compose --profile failover up -d)"
  exit 1
fi

echo "==> app.teamelwany.com -> Greece"
api -X PUT "https://api.cloudflare.com/client/v4/zones/$ZT/dns_records/$APP_REC" \
  --data "{\"type\":\"CNAME\",\"name\":\"app.teamelwany.com\",\"content\":\"$GR\",\"proxied\":true}" \
  | grep -o '"success":[a-z]*'

echo "==> auto.kostikidis.net -> Greece (override the *.kostikidis.net wildcard)"
RID=$(api "https://api.cloudflare.com/client/v4/zones/$ZK/dns_records?type=CNAME&name=auto.kostikidis.net" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || true)  # grep returns 1 when no explicit record (wildcard) — don't let pipefail/errexit kill us before the create-branch
if [ -n "$RID" ]; then
  api -X PUT "https://api.cloudflare.com/client/v4/zones/$ZK/dns_records/$RID" \
    --data "{\"type\":\"CNAME\",\"name\":\"auto.kostikidis.net\",\"content\":\"$GR\",\"proxied\":true}" | grep -o '"success":[a-z]*'
else
  api -X POST "https://api.cloudflare.com/client/v4/zones/$ZK/dns_records" \
    --data "{\"type\":\"CNAME\",\"name\":\"auto.kostikidis.net\",\"content\":\"$GR\",\"proxied\":true}" | grep -o '"success":[a-z]*'
fi
echo "==> FAILED OVER to Greece. (sticky — Prague recovering will NOT reclaim traffic.)"
echo "    Revert with failback.sh once Prague holds Greece's data (see FAILBACK.md)."
