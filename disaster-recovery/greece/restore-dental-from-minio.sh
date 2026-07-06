#!/usr/bin/env bash
# Seed the Greece dental warm-standby from the latest backups in the local Greece MinIO.
# Run ON unraid-ptolemaida. Reads creds from /mnt/user/appdata/dental-failover/.env:
#   MINIO_DR_USER MINIO_DR_PASSWORD
#   CLINIC_POSTGRES_USER CLINIC_POSTGRES_DB CLINIC_DATABASE_URL_SUPERUSER
#   CLINIC_APP_DB_PASSWORD GOMPHA_N8N_ENCRYPTION_KEY
# The age PRIVATE key that decrypts the dental DB dumps lives at (Option A — key in Greece):
#   /mnt/user/appdata/dental-failover/age-key.txt
#
#   ./restore-dental-from-minio.sh          # restore both
#   ./restore-dental-from-minio.sh clinic   # or just one
#   ./restore-dental-from-minio.sh n8n
set -euo pipefail
BASE=/mnt/user/appdata/dental-failover
. "$BASE/.env"

# SAFETY: never overwrite a LIVE failover. If clinic-api is running we're failed over
# and serving real traffic — refuse to restore over it.
if docker ps --format '{{.Names}}' | grep -qx clinic-api; then
  echo "$(date '+%F %T'): clinic-api is RUNNING (failover active) — skipping warm-restore to protect live data."
  # still ping Kuma UP — failover is healthy behaviour, not a restore failure
  [ -n "${KUMA_PUSH_URL:-}" ] && curl -fsS --max-time 10 "${KUMA_PUSH_URL}?status=up&msg=failover-active-skip" >/dev/null 2>&1 || true
  exit 0
fi
MC="docker run --rm -e MC_HOST_dr=http://${MINIO_DR_USER}:${MINIO_DR_PASSWORD}@100.85.129.88:9100 minio/mc"
AGE="docker run --rm -i --user 0:0 --entrypoint age -v ${BASE}/age-key.txt:/k:ro ghcr.io/steficzko/dental-backup:v0.15.0"  # --user 0:0: read the root-owned 600 key
API_IMG=ghcr.io/steficzko/dental-api:v0.15.0
what="${1:-all}"

restore_clinic() {
  echo "==> clinic-postgres: finding latest age-encrypted dump ..."
  local f; f=$($MC ls dr/clinic-backups/clinic-postgres/ | awk '{print $NF}' | sort | tail -1)
  [ -n "$f" ] || { echo "no clinic dump found"; return 1; }
  echo "    restoring $f  (age-decrypt -> pg_restore)"
  # NOTE: GRANT ... TO clinic_app errors are EXPECTED here — pg_dump carries no roles, so
  # clinic_app doesn't exist until the migrate below creates it. Tolerate them (|| true) so
  # pipefail doesn't abort before the migrate runs.
  $MC cat "dr/clinic-backups/clinic-postgres/$f" \
    | $AGE -d -i /k \
    | docker exec -i clinic-postgres pg_restore -U "$CLINIC_POSTGRES_USER" -d "$CLINIC_POSTGRES_DB" --clean --if-exists --no-owner \
    || echo "    (pg_restore GRANT-to-clinic_app warnings expected pre-migrate)"
  echo "    data restored; running idempotent migrate (recreates clinic_app role + confirms schema) ..."
  # pg_dump does NOT carry roles; the app connects as clinic_app, so re-run the migrate
  # that Prague runs as a PreSync hook. Idempotent against already-migrated data.
  docker run --rm --network dental-failover \
    -e DATABASE_URL_SUPERUSER="$CLINIC_DATABASE_URL_SUPERUSER" \
    -e CLINIC_APP_DB_PASSWORD="$CLINIC_APP_DB_PASSWORD" \
    "$API_IMG" python -m app.migrate
  echo "    clinic-postgres restored + migrated."
}

restore_n8n() {
  echo "==> gompha n8n: finding latest export ..."
  local f; f=$($MC ls dr/app-backups/gompha-n8n/ | awk '{print $NF}' | sort | tail -1)
  [ -n "$f" ] || { echo "no gompha n8n export found"; return 1; }
  echo "    restoring $f"
  rm -rf /tmp/gn8nrestore && mkdir -p /tmp/gn8nrestore
  $MC cat "dr/app-backups/gompha-n8n/$f" | tar xzf - -C /tmp/gn8nrestore
  install -d -o 1000 -g 1000 "$BASE/n8n"
  local run="docker run --rm --user 1000:1000 -e N8N_ENCRYPTION_KEY=$GOMPHA_N8N_ENCRYPTION_KEY -v $BASE/n8n:/home/node/.n8n -v /tmp/gn8nrestore:/restore:ro n8nio/n8n:2.27.0"
  # tolerate an empty export (fresh product n8n has no workflows/credentials yet)
  $run import:workflow --separate --input=/restore/workflows || echo "    (no workflows to import yet)"
  $run import:credentials --input=/restore/credentials.json  || echo "    (no credentials to import yet)"
  rm -rf /tmp/gn8nrestore
  echo "    gompha n8n restored."
}

case "$what" in
  clinic)  restore_clinic ;;
  n8n)     restore_n8n ;;
  all)     restore_clinic; restore_n8n ;;
  *) echo "usage: $0 [all|clinic|n8n]"; exit 1 ;;
esac
# ping Kuma dead-man's-switch — only reached on a successful restore
[ -n "${KUMA_PUSH_URL:-}" ] && curl -fsS --max-time 10 "${KUMA_PUSH_URL}?status=up&msg=restore-ok" >/dev/null 2>&1 || true
echo "==> Done."
