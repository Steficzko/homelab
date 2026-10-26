#!/usr/bin/env bash
# Seed the Greece failover stack from the latest backups in the local Greece MinIO.
# Run ON unraid-ptolemaida. Reads creds from /mnt/user/appdata/bjj-failover/.env:
#   MINIO_DR_USER MINIO_DR_PASSWORD POSTGRES_USER POSTGRES_DB N8N_ENCRYPTION_KEY
#
#   ./restore-from-minio.sh            # restore both
#   ./restore-from-minio.sh postgres   # or just one
set -euo pipefail
BASE=/mnt/user/appdata/bjj-failover
. "$BASE/.env"

# SAFETY: never overwrite a LIVE failover. If the n8n app container is running,
# we're failed over and serving real traffic — refuse to restore over it.
if docker ps --format '{{.Names}}' | grep -qx n8n; then
  echo "$(date '+%F %T'): n8n is RUNNING (failover active) — skipping warm-restore to protect live data."
  exit 0
fi
MINIO=http://100.85.129.88:9100
MC="docker run --rm -e MC_HOST_dr=http://${MINIO_DR_USER}:${MINIO_DR_PASSWORD}@100.85.129.88:9100 minio/mc"
what="${1:-all}"

restore_pg() {
  echo "==> Postgres: finding latest dump ..."
  local f; f=$($MC ls dr/app-backups/bjj-postgres/ | awk '{print $NF}' | sort | tail -1)
  [ -n "$f" ] || { echo "no postgres dump found"; return 1; }
  echo "    restoring $f"
  $MC cat "dr/app-backups/bjj-postgres/$f" > /tmp/restore.dump
  docker exec -i bjj-postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner < /tmp/restore.dump
  rm -f /tmp/restore.dump
  echo "    postgres restored."
}

restore_n8n() {
  echo "==> n8n: finding latest export ..."
  local f; f=$($MC ls dr/app-backups/n8n/ | awk '{print $NF}' | sort | tail -1)
  [ -n "$f" ] || { echo "no n8n export found"; return 1; }
  echo "    restoring $f"
  rm -rf /tmp/n8nrestore && mkdir -p /tmp/n8nrestore
  $MC cat "dr/app-backups/n8n/$f" | tar xzf - -C /tmp/n8nrestore
  install -d -o 1000 -g 1000 "$BASE/n8n"
  # n8n image entrypoint IS the n8n CLI, so pass subcommands as args (no shell)
  local run="docker run --rm --user 1000:1000 -e N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY -v $BASE/n8n:/home/node/.n8n -v /tmp/n8nrestore:/restore:ro n8nio/n8n:2.44.6@sha256:d02752c6ab446ae9db8deec2f9cc887c378f77cdcad31650814df936b7386dfb"
  $run import:workflow --separate --input=/restore/workflows
  $run import:credentials --input=/restore/credentials.json
  # import only adds/updates and leaves everything unpublished. Make Greece an exact,
  # failover-ready mirror: drop workflows Prague no longer has (cascades their history),
  # publish exactly the ones active in Prague (= what `publish:workflow` writes:
  # active + activeVersionId, guarded on the version existing; one statement instead of
  # ~9 min of CLI cold starts), then VACUUM (6h re-imports otherwise grow ~100 MB/day).
  # Failover then only has to start n8n.
  docker run --rm --user 1000:1000 -v $BASE/n8n:/home/node/.n8n -v /tmp/n8nrestore:/restore:ro --entrypoint node n8nio/n8n:2.44.6@sha256:d02752c6ab446ae9db8deec2f9cc887c378f77cdcad31650814df936b7386dfb -e "
const fs=require('fs'),dir='/restore/workflows';
const wfs=fs.readdirSync(dir).filter(f=>f.endsWith('.json')).map(f=>JSON.parse(fs.readFileSync(dir+'/'+f)));
if(wfs.length<10){console.log('    export has',wfs.length,'workflows - refusing to prune/publish');process.exit(1)}
const q=a=>a.map(w=>\"'\"+w.id+\"'\").join(','), all=q(wfs), act=q(wfs.filter(w=>w.active));
const s=require('/usr/local/lib/node_modules/n8n/node_modules/sqlite3');const d=new s.Database('/home/node/.n8n/database.sqlite');
const log=m=>function(e){console.log('    '+m+':',e?e.message:(this.changes??'ok'))};
d.serialize(()=>{d.run('PRAGMA foreign_keys=ON');
d.run('DELETE FROM workflow_entity WHERE id NOT IN ('+all+')',log('pruned stale workflows'));
d.run('UPDATE workflow_entity SET active=0, activeVersionId=NULL WHERE id NOT IN ('+act+')',log('unpublished (inactive in Prague)'));
d.run('UPDATE workflow_entity SET active=1, activeVersionId=versionId WHERE isArchived=0 AND id IN ('+act+') AND EXISTS (SELECT 1 FROM workflow_history h WHERE h.workflowId=workflow_entity.id AND h.versionId=workflow_entity.versionId)',log('published (active in Prague, expect '+act.split(',').length+')'));
d.run('VACUUM',e=>console.log('    vacuum:',e?e.message:'ok'))})"
  rm -rf /tmp/n8nrestore
  echo "    n8n restored (workflows + credentials)."
}

case "$what" in
  postgres) restore_pg ;;
  n8n)      restore_n8n ;;
  all)      restore_pg; restore_n8n ;;
  *) echo "usage: $0 [all|postgres|n8n]"; exit 1 ;;
esac
echo "==> Done."
