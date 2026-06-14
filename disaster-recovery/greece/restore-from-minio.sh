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
  local run="docker run --rm --user 1000:1000 -e N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY -v $BASE/n8n:/home/node/.n8n -v /tmp/n8nrestore:/restore:ro n8nio/n8n:2.25.1"
  $run import:workflow --separate --input=/restore/workflows
  $run import:credentials --input=/restore/credentials.json
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
