#!/usr/bin/env bash
# Generates the SOPS-encrypted backup-s3-secret for the bjj and n8n namespaces
# by copying the MinIO credentials from the existing longhorn-backup-secret.
#
# Run this LOCALLY (it reads live cluster secrets and writes encrypted files).
# Credentials are piped straight into sops and never printed.
#
#   ./scripts/bootstrap-backup-secrets.sh
#
# Then apply the encrypted secrets to the cluster (out-of-band; ArgoCD excludes
# *.sops.yaml from sync):
#
#   for ns in bjj n8n; do
#     sops -d kubernetes/apps/$ns/backup-s3-secret.sops.yaml | kubectl apply -f -
#   done
set -euo pipefail

REPO="$(git rev-parse --show-toplevel)"
SRC_NS="longhorn-system"
SRC_SECRET="longhorn-backup-secret"

get() { kubectl get secret "$SRC_SECRET" -n "$SRC_NS" -o jsonpath="{.data.$1}" | base64 -d; }

AKID="$(get AWS_ACCESS_KEY_ID)"
SAK="$(get AWS_SECRET_ACCESS_KEY)"
ENDPOINT="$(get AWS_ENDPOINTS)"

for NS in bjj n8n; do
  F="$REPO/kubernetes/apps/$NS/backup-s3-secret.sops.yaml"
  cat > "$F" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: backup-s3-secret
  namespace: $NS
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "$AKID"
  AWS_SECRET_ACCESS_KEY: "$SAK"
  AWS_ENDPOINTS: "$ENDPOINT"
EOF
  sops --encrypt --in-place "$F"
  echo "encrypted -> $F"
done

# --- replication secret (Prague SRC -> Greece DST) -------------------------
# DST creds = the Greece minio-dr root user/password. Export them first:
#   export MINIO_DR_USER=...  MINIO_DR_PASSWORD=...
if [ -n "${MINIO_DR_USER:-}" ] && [ -n "${MINIO_DR_PASSWORD:-}" ]; then
  R="$REPO/kubernetes/apps/backup-replication/minio-replication-secret.sops.yaml"
  cat > "$R" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-replication-secret
  namespace: backup
type: Opaque
stringData:
  SRC_ACCESS_KEY: "$AKID"
  SRC_SECRET_KEY: "$SAK"
  DST_ACCESS_KEY: "$MINIO_DR_USER"
  DST_SECRET_KEY: "$MINIO_DR_PASSWORD"
EOF
  sops --encrypt --in-place "$R"
  echo "encrypted -> $R"
else
  echo "SKIP replication secret: export MINIO_DR_USER and MINIO_DR_PASSWORD, then re-run."
fi

echo "Done. Now apply them:"
echo "  for ns in bjj n8n; do sops -d kubernetes/apps/\$ns/backup-s3-secret.sops.yaml | kubectl apply -f -; done"
echo "  sops -d kubernetes/apps/backup-replication/minio-replication-secret.sops.yaml | kubectl apply -f -"
