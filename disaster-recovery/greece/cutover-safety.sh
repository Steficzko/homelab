#!/usr/bin/env bash
# 05:15 SAFETY NET for the one-time cutover test: independently GUARANTEE the site is
# back on Prague + Greece is in standby, even if cutover-test.sh's process was killed
# before its own trap ran. Idempotent (safe when already on Prague). Then self-cleans
# the one-time cron entries.
DIR="$(cd "$(dirname "$0")" && pwd)"; export DIR
LOG="$HOME/cutover-test.log"
[ -t 1 ] || exec >>"$LOG" 2>&1
echo "===== cutover-safety $(date '+%F %T %Z') ====="
bash "$DIR/failback.sh" || echo "   WARN failback.sh nonzero"
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes root@100.85.129.88 'docker rm -f bjj-failover-cloudflared n8n bjj-app >/dev/null 2>&1 || true'
python3 - <<'PY'
import os,json,urllib.request,urllib.error,pathlib,subprocess
et=subprocess.run(["ssh","-i",os.path.expanduser("~/.ssh/id_ed25519"),"-o","IdentitiesOnly=yes","-o","BatchMode=yes","root@100.85.129.88","cat /mnt/user/appdata/bjj-failover/.env"],capture_output=True,text=True,timeout=40).stdout
ei=dict(l.split("=",1) for l in et.splitlines() if "=" in l and not l.startswith("#"))
ptok=pathlib.Path.home().joinpath(".portainer_token").read_text().strip()
cftok=pathlib.Path.home().joinpath(".cf_failover_tunnel_token").read_text().strip()
compose=pathlib.Path(os.environ["DIR"]+"/failover-stack.yml").read_text()
env=[{"name":k,"value":ei[k]} for k in ["POSTGRES_USER","POSTGRES_DB","POSTGRES_PASSWORD","N8N_ENCRYPTION_KEY"] if k in ei]
env.append({"name":"CF_TUNNEL_TOKEN","value":cftok})
body=json.dumps({"stackFileContent":compose,"env":env,"prune":False,"pullImage":False}).encode()
req=urllib.request.Request("http://100.85.129.88:9000/api/stacks/11?endpointId=3",data=body,method="PUT",headers={"X-API-Key":ptok,"Content-Type":"application/json"})
try:
    with urllib.request.urlopen(req,timeout=200) as r: print("   portainer standby ->",r.status)
except Exception as e: print("   portainer off err:",e)
PY
# self-clean the one-time cron entries
crontab -l 2>/dev/null | grep -v 'cutover-test.sh' | grep -v 'cutover-safety.sh' | grep -v 'downtime-probe.sh' | grep -v 'cutover-drill-extended.sh' | crontab - 2>/dev/null || true
echo "===== cutover-safety done (Prague ensured, standby, cron cleaned) ====="
