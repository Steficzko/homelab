#!/usr/bin/env bash
# Backs up the Greece stack TO the Greece MinIO under the greece-live/ prefix,
# but ONLY while Greece is failed over and serving (n8n container running).
# On standby it's a no-op (Prague is primary; nothing new here to protect).
# Runs hourly via cron. This protects the new data Greece accepts during an outage
# (which the Prague->Greece replication can't capture, since Prague is down).
set -euo pipefail
BASE=/mnt/user/appdata/bjj-failover
. "$BASE/.env"

# Only act when failed over (n8n running). On standby, exit quietly.
docker ps --format '{{.Names}}' | grep -qx n8n || exit 0

TS=$(date '+%Y%m%d-%H%M%S')
MCPIPE="docker run --rm -i -e MC_HOST_dr=http://${MINIO_DR_USER}:${MINIO_DR_PASSWORD}@100.85.129.88:9100 minio/mc"
MC="docker run --rm    -e MC_HOST_dr=http://${MINIO_DR_USER}:${MINIO_DR_PASSWORD}@100.85.129.88:9100 minio/mc"

echo "$(date '+%F %T'): greece-live backup (failover active) ..."

# Postgres: stream pg_dump straight into the object
docker exec bjj-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z6 \
  | $MCPIPE pipe "dr/app-backups/greece-live/bjj-postgres/${POSTGRES_DB}-${TS}.dump"

# n8n: export inside the running container, then stream the tarball out
docker exec n8n sh -c '
  rm -rf /tmp/glb && mkdir -p /tmp/glb/workflows
  n8n export:workflow --all --separate --output=/tmp/glb/workflows >/dev/null
  n8n export:credentials --all --output=/tmp/glb/credentials.json >/dev/null
  tar czf - -C /tmp/glb .
' | $MCPIPE pipe "dr/app-backups/greece-live/n8n/n8n-${TS}.tgz"
docker exec n8n rm -rf /tmp/glb 2>/dev/null || true

# keep 14 days of greece-live history
$MC rm --recursive --force --older-than 14d "dr/app-backups/greece-live/" || true
echo "$(date '+%F %T'): greece-live backup done -> greece-live/{bjj-postgres,n8n}/...-${TS}"
