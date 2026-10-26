#!/usr/bin/env bash
# Full DR drill 2026-10-26: real webhooks served from Greece, then ALWAYS fail back.
# Differs from cutover-test.sh: publishes the 92 webhook-only workflows (not schedule/
# telegram/error ones -> no double-firing alongside Prague), probes a real public webhook
# continuously, proves Greece served it, and reports any writes taken during the window.
set +e
G=/mnt/devdata/homelab/disaster-recovery/greece
S=${S:-$(mktemp -d)}   # working dir; needs wh_ids.json (ids of active webhook-only workflows)
GH=root@100.85.129.88
ACCT=90e7dc337477819281ed982a7f6afe32; TUN=0fb9fd16-cf43-4235-b9d5-9dca0166bc3f
HOLD=${HOLD:-300}
IMG='n8nio/n8n:2.44.6@sha256:d02752c6ab446ae9db8deec2f9cc887c378f77cdcad31650814df936b7386dfb'
PROBE='https://auto.kostikidis.net/webhook/kimono-offer-state'
WF_PROBE=wMRGuMRK09FOfUQh
gsh(){ ssh -o BatchMode=yes -o ConnectTimeout=15 $GH "$@"; }
ts(){ date '+%T'; }
log(){ echo "[$(ts)] $*"; }
# pg_stat write counters on the Greece standby (postgres is not restarted during the drill)
writes(){ gsh "docker exec bjj-postgres psql -U bjj -d bjj -Atc \"select relname||'='||(n_tup_ins+n_tup_upd+n_tup_del) from pg_stat_user_tables order by 1\""; }
gexec(){ gsh "docker exec n8n node -e \"const s=require('/usr/local/lib/node_modules/n8n/node_modules/sqlite3');const d=new s.Database('/home/node/.n8n/database.sqlite');d.get(\\\"select count(*) c from execution_entity where workflowId='$WF_PROBE'\\\",(e,r)=>console.log(e?'ERR':r.c))\"" 2>/dev/null; }
profile(){ # on|off — same Portainer call cutover-test.sh uses
  DIR=$G MODE2=$1 python3 - <<'PY'
import os,json,urllib.request,pathlib,subprocess
et=subprocess.run(["ssh","-o","BatchMode=yes","root@100.85.129.88","cat /mnt/user/appdata/bjj-failover/.env"],capture_output=True,text=True,timeout=40).stdout
ei=dict(l.split("=",1) for l in et.splitlines() if "=" in l and not l.startswith("#"))
env=[{"name":k,"value":ei[k]} for k in ["POSTGRES_USER","POSTGRES_DB","POSTGRES_PASSWORD","N8N_ENCRYPTION_KEY"] if k in ei]
env.append({"name":"CF_TUNNEL_TOKEN","value":pathlib.Path.home().joinpath(".cf_failover_tunnel_token").read_text().strip()})
if os.environ["MODE2"]=="on": env.append({"name":"COMPOSE_PROFILES","value":"failover"})
body=json.dumps({"stackFileContent":pathlib.Path(os.environ["DIR"]+"/failover-stack.yml").read_text(),"env":env,"prune":False,"pullImage":False}).encode()
req=urllib.request.Request("http://100.85.129.88:9000/api/stacks/11?endpointId=3",data=body,method="PUT",headers={"X-API-Key":pathlib.Path.home().joinpath(".portainer_token").read_text().strip(),"Content-Type":"application/json"})
with urllib.request.urlopen(req,timeout=200) as r: print("portainer",os.environ["MODE2"],r.status)
PY
}
PROBE_PID=
cleanup(){
  log "CLEANUP: failback DNS -> Prague"
  bash $G/failback.sh
  sleep 60   # keep probing across the flip back
  [ -n "$PROBE_PID" ] && kill $PROBE_PID
  gsh 'docker rm -f bjj-failover-cloudflared n8n >/dev/null 2>&1; true'
  profile off
  log "standby restored: $(gsh 'docker ps --format "{{.Names}}" | grep -E "^(n8n|bjj-failover-cloudflared|bjj-postgres|gotenberg)$" | tr "\n" " "')"
  writes > $S/writes_after.txt
  log "WRITES during window (table=delta):"
  join -t= $S/writes_before.txt $S/writes_after.txt | awk -F= '$3!=$2{print "   "$1"="$3-$2}'
  log "PROBE summary:"; python3 - $S/probe.log <<'PY'
import sys,collections
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
c=collections.Counter(r[1] for r in rows); worst=run=0
for r in rows:
    run = run+1 if r[1]!="200" else 0; worst=max(worst,run)
print("   samples",len(rows),"codes",dict(c),"worst consecutive non-200 =",worst,"samples")
PY
  log "post DNS auto: $(curl -s -H "Authorization: Bearer $(cat ~/.cloudflare_token)" 'https://api.cloudflare.com/client/v4/zones/8dff731485cfed2d9dea64c335b91254/dns_records?type=CNAME&name=auto.kostikidis.net' | grep -o '"content":"[^"]*"' || echo 'override gone -> wildcard -> Prague')"
  log "DRILL END"
}
trap cleanup EXIT

log "1/7 fresh restore from Greece MinIO"
gsh 'bash /mnt/user/appdata/bjj-failover/restore-from-minio.sh 2>&1 | grep -E "restoring|imported|Done"'
writes > $S/writes_before.txt
log "2/7 publish $(python3 -c "import json;print(len(json.load(open('$S/wh_ids.json'))))") webhook-only workflows (one-off container, n8n not running yet)"
IDS=$(python3 -c "import json;print(' '.join(json.load(open('$S/wh_ids.json'))))")
gsh "cd /mnt/user/appdata/bjj-failover && . ./.env && docker run --rm --user 1000:1000 -e N8N_ENCRYPTION_KEY=\$N8N_ENCRYPTION_KEY -v \$PWD/n8n:/home/node/.n8n --entrypoint sh $IMG -c 'ok=0; for id in $IDS; do n8n publish:workflow --id=\$id >/dev/null 2>&1 && ok=\$((ok+1)); done; echo published \$ok'"
log "3/7 failover profile ON"
profile on || exit 1
log "4/7 wait for n8n healthz + tunnel healthy + probe webhook registered on origin"
ok=0
for i in $(seq 1 36); do
  st=$(curl -s -H "Authorization: Bearer $(cat ~/.cloudflare_token)" https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TUN | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
  wh=$(gsh "docker exec n8n wget -qS -O /dev/null http://localhost:5678/webhook/kimono-offer-state 2>&1 | grep -o 'HTTP/1.1 [0-9]*' | tail -1")
  echo "   try $i tunnel=$st origin=$wh"
  [ "$st" = healthy ] && [ "$wh" = "HTTP/1.1 200" ] && { ok=1; break; }
  sleep 5
done
[ $ok = 1 ] || { log "ABORT: Greece not ready"; exit 1; }
log "5/7 start public probe (1/s)"
( while :; do echo "$(date +%s) $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROBE?drill=$RANDOM$RANDOM")"; sleep 1; done ) > $S/probe.log &
PROBE_PID=$!
sleep 20
E0=$(gexec); log "Greece probe-workflow executions before flip: $E0"
log "6/7 FLIP DNS -> Greece"
bash $G/failover.sh || { log "ABORT: failover.sh failed"; exit 1; }
log "7/7 LIVE ON GREECE — hold ${HOLD}s"
end=$(( $(date +%s) + HOLD ))
while [ $(date +%s) -lt $end ]; do sleep 60; log "   hold: Greece executions=$(gexec) (was $E0)  last probe codes: $(tail -60 $S/probe.log | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"; done
E1=$(gexec); log "RESULT: Greece served $((E1-E0)) public probe requests during hold"
exit 0
