#!/usr/bin/env bash
# Full DR CUTOVER TEST (one-time drill). Run from dev-seat (has all tokens + SSH).
#   start Greece failover profile -> wait healthy -> failover.sh (flip DNS to Greece)
#   -> verify both hosts served from Greece -> ALWAYS fail back + return to standby.
#
# SAFETY: a trap on EXIT guarantees failback + standby run on success, error, or signal.
# An independent 05:15 'at' job (see install) is the second net if this process is killed.
#
#   ./cutover-test.sh            # full live cutover (flips real DNS ~3-5 min)
#   MODE=dryrun ./cutover-test.sh  # verify-plumbing only: no profile, no DNS flip
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"; export DIR
LOG="$HOME/cutover-test.log"
[ -t 1 ] || exec >>"$LOG" 2>&1
echo "===== cutover-test ${MODE:-live} $(date '+%F %T %Z') ====="

ACCT="90e7dc337477819281ed982a7f6afe32"
TUN="0fb9fd16-cf43-4235-b9d5-9dca0166bc3f"; GRTGT="$TUN.cfargotunnel.com"
GH="100.85.129.88"
ZK="8dff731485cfed2d9dea64c335b91254"   # kostikidis.net
ZT="bf7cb7f1d5d83b3416647fddee20b82c"   # teamelwany.com
CF="$(cat ~/.cloudflare_token)"
KPUSH="$(cat ~/.kuma_cutover_push 2>/dev/null || true)"
result="down"; detail="did not complete"

push(){ [ -n "$KPUSH" ] && curl -s -G "$KPUSH" --data-urlencode "status=$1" --data-urlencode "msg=$2" -o /dev/null --max-time 10 || true; }
dns_target(){ curl -s -H "Authorization: Bearer $CF" "https://api.cloudflare.com/client/v4/zones/$1/dns_records?type=CNAME&name=$2" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4; }
http_code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1"; }
portainer_profile(){ MODE2="$1" python3 - <<'PY'
import os,json,urllib.request,urllib.error,pathlib,subprocess
mode=os.environ["MODE2"]
et=subprocess.run(["ssh","-o","BatchMode=yes","root@100.85.129.88","cat /mnt/user/appdata/bjj-failover/.env"],capture_output=True,text=True,timeout=40).stdout
ei=dict(l.split("=",1) for l in et.splitlines() if "=" in l and not l.startswith("#"))
ptok=pathlib.Path.home().joinpath(".portainer_token").read_text().strip()
cftok=pathlib.Path.home().joinpath(".cf_failover_tunnel_token").read_text().strip()
compose=pathlib.Path(os.environ["DIR"]+"/failover-stack.yml").read_text()
env=[{"name":k,"value":ei[k]} for k in ["POSTGRES_USER","POSTGRES_DB","POSTGRES_PASSWORD","N8N_ENCRYPTION_KEY"] if k in ei]
env.append({"name":"CF_TUNNEL_TOKEN","value":cftok})
if mode=="on": env.append({"name":"COMPOSE_PROFILES","value":"failover"})
body=json.dumps({"stackFileContent":compose,"env":env,"prune":False,"pullImage":False}).encode()
req=urllib.request.Request("http://100.85.129.88:9000/api/stacks/11?endpointId=3",data=body,method="PUT",headers={"X-API-Key":ptok,"Content-Type":"application/json"})
with urllib.request.urlopen(req,timeout=200) as r: print("   portainer",mode,"->",r.status)
PY
}
verify(){  # 0 if BOTH CNAMEs now point at Greece AND the Greece origins are healthy.
  # NB: public https URLs are behind Cloudflare Access (302 for unauthenticated curl),
  # so we verify the Greece origins DIRECTLY over the tailnet, not via the public URL.
  local i d1 d2 n8nok bjj
  for i in $(seq 1 12); do
    d1=$(dns_target "$ZK" auto.kostikidis.net); d2=$(dns_target "$ZT" app.teamelwany.com)
    n8nok=$(ssh -o BatchMode=yes root@$GH 'docker exec n8n wget -qO- http://localhost:5678/healthz 2>/dev/null' | grep -o ok)
    bjj=$(http_code http://$GH:8088)   # Greece bjj-app (tailnet-exposed by the failover stack)
    echo "   verify try $i: dns auto=${d1:-none} app=${d2:-none} | greece n8n=${n8nok:-no} bjj:8088=$bjj"
    if [ "$d1" = "$GRTGT" ] && [ "$d2" = "$GRTGT" ] && [ "$n8nok" = "ok" ] && [ "$bjj" = "200" ]; then return 0; fi
    sleep 5
  done
  return 1
}

# ---------- DRY RUN: only exercise the checks + push, never flip DNS / start profile ----------
if [ "${MODE:-}" = "dryrun" ]; then
  echo "DRYRUN: DNS read + Kuma push plumbing only (no profile, no DNS flip):"
  echo "  auto.kostikidis.net cname=$(dns_target $ZK auto.kostikidis.net || echo '(wildcard / none on standby)')"
  echo "  app.teamelwany.com  cname=$(dns_target $ZT app.teamelwany.com)"
  echo "  (live verify uses Greece origins directly; public URLs are behind Cloudflare Access)"
  push up "dryrun ok $(date '+%F %T')"
  echo "DRYRUN done. Kuma push sent (monitor 'DR Cutover Drill')."
  exit 0
fi

# ---------- LIVE CUTOVER ----------
cleanup(){
  echo ">>> cleanup: ALWAYS fail back to Prague + return to standby"
  bash "$DIR/failback.sh" || echo "   WARN failback.sh nonzero"
  ssh -o BatchMode=yes root@$GH 'docker rm -f bjj-failover-cloudflared n8n bjj-app >/dev/null 2>&1 || true'
  portainer_profile off || echo "   WARN portainer off nonzero"
  local d1=$(dns_target $ZK auto.kostikidis.net) d2=$(dns_target $ZT app.teamelwany.com)
  echo "   post-failback DNS: auto=${d1:-deleted/wildcard} app=$d2"
  push "$result" "$detail"
  echo "===== end: $result | $detail ====="
}
trap cleanup EXIT

echo "-> start failover profile"; portainer_profile on || { detail="portainer start failed"; exit 1; }
echo "-> wait for Greece tunnel healthy + n8n"
ok=0
for i in $(seq 1 18); do
  st=$(curl -s -H "Authorization: Bearer $CF" "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TUN" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  hz=$(ssh -o BatchMode=yes root@$GH 'docker exec n8n wget -qO- http://localhost:5678/healthz 2>/dev/null' | grep -o 'ok')
  echo "   try $i: tunnel=$st n8n=${hz:-...}"
  [ "$st" = "healthy" ] && [ -n "$hz" ] && { ok=1; break; }
  sleep 5
done
[ "$ok" = 1 ] || { detail="greece not healthy (tunnel=$st)"; exit 1; }

echo "-> flip DNS to Greece (failover.sh)"; bash "$DIR/failover.sh" || { detail="failover.sh failed"; exit 1; }
echo "-> verify Greece is serving both hosts"
if verify; then result="up"; detail="cutover OK: auto+app 200 from Greece, DNS flipped, failing back"
else result="down"; detail="verify FAILED (see log) — failing back"; fi
echo "-> $result: $detail"
exit 0   # trap cleanup runs: failback + standby + push
