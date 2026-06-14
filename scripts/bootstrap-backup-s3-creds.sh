#!/usr/bin/env bash
# Generates the SOPS-encrypted backup secrets by copying the MinIO credentials
# VERBATIM (base64 .data, no decode/re-encode) from longhorn-backup-secret, plus
# the Greece minio-dr creds for replication. Run LOCALLY.
#
#   export MINIO_DR_USER=...  MINIO_DR_PASSWORD=...
#   ./scripts/bootstrap-backup-s3-creds.sh
#
# Apply (ArgoCD excludes *.sops.yaml, so out-of-band). The backup-* Applications
# carry ignoreDifferences on /data so selfHeal won't strip these:
#   for ns in bjj n8n; do sops -d kubernetes/apps/$ns/backup-s3-secret.sops.yaml | kubectl apply -f -; done
#   sops -d kubernetes/apps/backup-replication/minio-replication-secret.sops.yaml | kubectl apply -f -
set -euo pipefail
REPO="$(git rev-parse --show-toplevel)"
lh() { kubectl get secret longhorn-backup-secret -n longhorn-system -o jsonpath="{.data.$1}"; }

emit() { # $1=name $2=ns $3=file ; reads "  key: b64" lines on stdin
  { printf 'apiVersion: v1\nkind: Secret\ntype: Opaque\nmetadata:\n  name: %s\n  namespace: %s\ndata:\n' "$1" "$2"; cat; } > "$3"
  sops -e -i "$3"; echo "encrypted -> $3"
}

AKID=$(lh AWS_ACCESS_KEY_ID); SAK=$(lh AWS_SECRET_ACCESS_KEY); EP=$(lh AWS_ENDPOINTS)

for ns in bjj n8n; do
  printf '  AWS_ACCESS_KEY_ID: %s\n  AWS_SECRET_ACCESS_KEY: %s\n  AWS_ENDPOINTS: %s\n' "$AKID" "$SAK" "$EP" \
    | emit backup-s3-secret "$ns" "$REPO/kubernetes/apps/$ns/backup-s3-secret.sops.yaml"
done

if [ -n "${MINIO_DR_USER:-}" ] && [ -n "${MINIO_DR_PASSWORD:-}" ]; then
  printf '  SRC_ACCESS_KEY: %s\n  SRC_SECRET_KEY: %s\n  DST_ACCESS_KEY: %s\n  DST_SECRET_KEY: %s\n' \
    "$AKID" "$SAK" "$(printf %s "$MINIO_DR_USER" | base64 -w0)" "$(printf %s "$MINIO_DR_PASSWORD" | base64 -w0)" \
    | emit minio-replication-secret backup "$REPO/kubernetes/apps/backup-replication/minio-replication-secret.sops.yaml"
else
  echo "SKIP replication secret: export MINIO_DR_USER and MINIO_DR_PASSWORD, then re-run."
fi
