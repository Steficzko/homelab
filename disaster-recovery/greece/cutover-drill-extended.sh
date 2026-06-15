#!/usr/bin/env bash
# EXTENDED DR CUTOVER DRILL (one-time, 2026-06-16 06:00 Prague / 07:00 +03).
# Fail over to Greece, stay LIVE for HOLD_MIN minutes running repeated verification +
# Greece<->Prague data-parity rounds, then ALWAYS fail back to Prague + standby (trap).
# Window writes are DISCARDED on failback (no reverse-restore) — per the drill decision.
# Produces a timestamped markdown report at $REPORT (the FAILOVER.md runbook is untouched).
set +e
DIR="$(cd "$(dirname "$0")" && pwd)"; export DIR
HOLD_MIN="${HOLD_MIN:-30}"
ROUND_EVERY="${ROUND_EVERY:-300}"          # a verify+parity round every 5 min
NS="${NS:-bjj}"
KEY_TABLES="members attendance ledger_entries belt_promotions class_sessions staff"
LOG="$HOME/cutover-drill-2026-06-16.log"
REPORT="${REPORT:-$DIR/drill-2026-06-16.md}"
[ -t 1 ] || exec >>"$LOG" 2>&1

ACCT="90e7dc337477819281ed982a7f6afe32"
TUN="0fb9fd16-cf43-4235-b9d5-9dca0166bc3f"; GRTGT="$TUN.cfargotunnel.com"
GH="100.85.129.88"
ZK="8dff731485cfed2d9dea64c335b91254"        # kostikidis.net
ZT="bf7cb7f1d5d83b3416647fddee20b82c"        # teamelwany.com
CF="$(cat ~/.cloudflare_token)"
KPUSH="$(cat ~/.kuma_cutover_push 2>/dev/null || true)"

TIMELINE=(); PARITY=(); served_all=1; result="down"; detail="did not complete"

ts(){ date '+%F %T %Z'; }
pts(){ TZ=Europe/Prague date '+%H:%M:%S'; }
step(){ echo ">>> $(ts)  [$1] $2"; TIMELINE+=("| \`$(date '+%T')\` | $(pts) | $1 | $2 |"); }
push(){ [ -n "$KPUSH" ] && curl -s -G "$KPUSH" --data-urlencode "status=$1" --data-urlencode "msg=$2" -o /dev/null --max-time 10 || true; }
api(){ curl -s -H "Authorization: Bearer $CF" "$@"; }
dns_target(){ api "https://api.cloudflare.com/client/v4/zones/$1/dns_records?type=CNAME&name=$2" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4; }
http_code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1"; }

gr_counts(){ ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$GH" 'bash -s' <<'REMOTE' 2>/dev/null
cd /mnt/user/appdata/bjj-failover 2>/dev/null && . ./.env 2>/dev/null
for t in members attendance ledger_entries belt_promotions class_sessions staff; do
  echo "$t=$(docker exec bjj-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from $t" 2>/dev/null | tr -d '[:space:]')"
done
REMOTE
}
pr_counts(){ kubectl exec -n "$NS" deploy/postgres -- sh -c 'for t in members attendance ledger_entries belt_promotions class_sessions staff; do echo "$t=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from $t" 2>/dev/null | tr -d "[:space:]")"; done' 2>/dev/null; }

portainer_profile(){ MODE2="$1" python3 - <<'PY'
import os,json,urllib.request,pathlib,subprocess
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

round(){
  local n="$1" d1 d2 n8nok bjj served="ok" verdict="MATCH" row="" g p t GC PC
  d1=$(dns_target "$ZK" auto.kostikidis.net); d2=$(dns_target "$ZT" app.teamelwany.com)
  n8nok=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$GH" 'docker exec n8n wget -qO- http://localhost:5678/healthz 2>/dev/null' 2>/dev/null | grep -o ok)
  bjj=$(http_code "http://$GH:8088")
  { [ "$d1" = "$GRTGT" ] && [ "$d2" = "$GRTGT" ] && [ "$n8nok" = ok ] && [ "$bjj" = 200 ]; } || { served="FAIL"; served_all=0; }
  step "VERIFY r$n" "serving=$served — dns auto=$([ "$d1" = "$GRTGT" ] && echo Greece || echo "${d1:-none}") app=$([ "$d2" = "$GRTGT" ] && echo Greece || echo "${d2:-none}"), n8n=${n8nok:-no}, bjj:8088=$bjj"
  GC="$(gr_counts)"; PC="$(pr_counts)"
  for t in $KEY_TABLES; do
    g=$(echo "$GC" | grep -m1 "^$t=" | cut -d= -f2); p=$(echo "$PC" | grep -m1 "^$t=" | cut -d= -f2)
    g=${g:-NA}; p=${p:-NA}; [ "$g" != "$p" ] && verdict="LAG"; row+=" $g/$p |"
  done
  PARITY+=("| r$n | $(date '+%T') | $served / $verdict |$row")
  step "PARITY r$n" "serving=$served data=$verdict (Greece/Prague counts captured)"
}

write_report(){
  local sep="|---|---|---|" hdr="| Round | Time (+03) | Serving / Data |" t
  for t in $KEY_TABLES; do hdr+=" $t |"; sep+="---|"; done
  {
    echo "# DR Cutover Drill — 2026-06-16, 06:00 Prague (07:00 +03)"
    echo
    echo "**Type:** extended live failover — ${HOLD_MIN}-minute hold on Greece, repeated verification + Greece↔Prague data-parity, then automatic failback. Window writes discarded (no reverse-restore)."
    echo "**Result:** \`$result\` — $detail"
    echo "**Log:** \`$LOG\`  ·  **Generated:** $(ts)"
    echo
    echo "## Step-by-step timeline"
    echo
    echo "| Time (+03) | Prague | Step | Detail |"
    echo "|---|---|---|---|"
    printf '%s\n' "${TIMELINE[@]}"
    echo
    echo "## Greece ↔ Prague data parity (per verification round)"
    echo
    echo "Counts shown **Greece / Prague**. Greece is a backup-restored standby trailing Prague by the RPO (~1h), so a difference is **lag, not corruption** — e.g. a ledger flush can even make Greece transiently higher. \`MATCH\` = identical; \`LAG\` = differs (expected)."
    echo
    echo "$hdr"
    echo "$sep"
    printf '%s\n' "${PARITY[@]}"
    echo
    echo "## Mechanism"
    echo "- Failover: Portainer profile \`failover\` on → wait Greece tunnel healthy + n8n → \`failover.sh\` (sticky DNS flip of app.teamelwany.com + auto.kostikidis.net to the Greece tunnel)."
    echo "- Serving verified against Greece origins directly over the tailnet (public URLs sit behind Cloudflare Access)."
    echo "- Failback: \`failback.sh\` (DNS → Prague) + Portainer profile off (standby). Independent 07:40 safety net is the backstop and cleans the one-time cron."
  } > "$REPORT"
  echo ">>> report written: $REPORT"
}

cleanup(){
  step "FAILBACK" "hold over / exit — reverting DNS to Prague + standby (window writes discarded)"
  bash "$DIR/failback.sh" >>"$LOG" 2>&1 && step "FAILBACK" "DNS reverted to Prague (failback.sh ok)" || step "FAILBACK" "WARN failback.sh nonzero"
  ssh -o BatchMode=yes "root@$GH" 'docker rm -f bjj-failover-cloudflared n8n bjj-app >/dev/null 2>&1 || true'
  portainer_profile off >>"$LOG" 2>&1 && step "STANDBY" "Greece app tier stopped (profile off)" || step "STANDBY" "WARN portainer off nonzero"
  local d1 d2; d1=$(dns_target "$ZK" auto.kostikidis.net); d2=$(dns_target "$ZT" app.teamelwany.com)
  step "POST-STATE" "DNS auto=${d1:-deleted/wildcard→Prague} app=$d2"
  push "$result" "$detail"
  write_report
  echo "===== extended drill end: $result | $detail ====="
}
trap cleanup EXIT

echo "===== extended drill $(ts) ====="
step "START" "extended DR drill — hold ${HOLD_MIN}min, verify+parity every $((ROUND_EVERY/60))min"
step "RESTORE" "seeding Greece from latest MinIO backup before failover (real-failover RPO — runbook step 1, skips if already failed over)"
ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$GH" 'bash /mnt/user/appdata/bjj-failover/restore-from-minio.sh' >>"$LOG" 2>&1 \
  && step "RESTORE" "fresh restore complete (Greece now holds the newest backup)" \
  || step "RESTORE" "WARN restore nonzero — continuing with existing standby data"
step "FAILOVER" "starting Greece failover profile (Portainer)"
portainer_profile on >>"$LOG" 2>&1 || { detail="portainer start failed"; step "FAILOVER" "ABORT — portainer start failed"; exit 1; }
step "WAIT" "waiting for Greece tunnel healthy + n8n"
ok=0
for i in $(seq 1 18); do
  st=$(api "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TUN" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  hz=$(ssh -o BatchMode=yes "root@$GH" 'docker exec n8n wget -qO- http://localhost:5678/healthz 2>/dev/null' 2>/dev/null | grep -o ok)
  [ "$st" = healthy ] && [ -n "$hz" ] && { ok=1; break; }
  sleep 5
done
[ "$ok" = 1 ] || { detail="greece not healthy (tunnel=$st)"; step "WAIT" "ABORT — greece not healthy (tunnel=$st)"; exit 1; }
step "WAIT" "Greece tunnel healthy + n8n ok"
step "FLIP" "flipping DNS to Greece (failover.sh)"
bash "$DIR/failover.sh" >>"$LOG" 2>&1 && step "FLIP" "DNS flipped to Greece (app.teamelwany.com + auto.kostikidis.net)" || { detail="failover.sh failed"; step "FLIP" "ABORT — failover.sh failed"; exit 1; }
step "HOLD" "now LIVE on Greece — holding ${HOLD_MIN}min with verification rounds"

hold_end=$(( $(date +%s) + HOLD_MIN*60 )); n=0
while [ "$(date +%s)" -lt "$hold_end" ]; do
  n=$((n+1)); round "$n"
  remain=$(( hold_end - $(date +%s) )); [ "$remain" -le 0 ] && break
  s=$ROUND_EVERY; [ "$remain" -lt "$s" ] && s=$remain; sleep "$s"
done
step "HOLD" "hold complete after $n verification rounds"
if [ "$served_all" = 1 ]; then result="up"; detail="Greece served all $n rounds over ${HOLD_MIN}min (n8n+bjj 200, DNS on Greece); data within RPO lag of Prague";
else result="down"; detail="serving FAILED in >=1 of $n rounds — see report"; fi
step "RESULT" "$result — $detail"
exit 0   # trap cleanup -> failback + standby + report
