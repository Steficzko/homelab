# Secrets Bootstrap Guide

All real secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [Age](https://github.com/FiloSottile/age) and committed to this repo as `*.sops.yaml` files. ArgoCD ignores these files — you must apply them manually after bootstrapping a fresh cluster.

---

## Age key location

The private Age key lives **only on the operator's machine** (never in git):

```
~/.config/sops/age/keys.txt
```

Public key: `age1v9pqv93dtdg7zuk2uc423rdtapu9p0fqucd2s9p6curt2c0y2vuq4yzw9n`

Back this file up to a password manager (Bitwarden, 1Password, etc.).

---

## Encrypted secret files

| File | Secret applied to cluster |
|------|--------------------------|
| `kubernetes/networking/cert-manager/secret.sops.yaml` | `cloudflare-api-token` in `cert-manager` |
| `kubernetes/networking/cloudflared/secret.sops.yaml` | `cloudflare-tunnel-token` in `cloudflare-tunnel` |
| `kubernetes/apps/nextcloud/nextcloud-secret.sops.yaml` | `nextcloud-secret` in `nextcloud` |
| `kubernetes/apps/nextcloud/postgres-secret.sops.yaml` | `postgres-secret` in `nextcloud` |
| `kubernetes/apps/obsidian-livesync/secret.sops.yaml` | `couchdb-secret` in `obsidian-livesync` |

---

## How to decrypt and apply a secret

```bash
sops --decrypt kubernetes/networking/cert-manager/secret.sops.yaml | kubectl apply -f -
```

## How to apply all secrets at once (fresh cluster bootstrap)

```bash
for f in \
  kubernetes/networking/cert-manager/secret.sops.yaml \
  kubernetes/networking/cloudflared/secret.sops.yaml \
  kubernetes/apps/nextcloud/nextcloud-secret.sops.yaml \
  kubernetes/apps/nextcloud/postgres-secret.sops.yaml \
  kubernetes/apps/obsidian-livesync/secret.sops.yaml; do
  sops --decrypt "$f" | kubectl apply -f -
done
```

---

## How to encrypt a new secret

1. Write a plain Kubernetes Secret manifest to a temp file (outside the repo):

```yaml
# /tmp/my-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: my-namespace
type: Opaque
stringData:
  key: value
```

2. Encrypt and save to the repo:

```bash
SOPS_AGE_RECIPIENTS=age1v9pqv93dtdg7zuk2uc423rdtapu9p0fqucd2s9p6curt2c0y2vuq4yzw9n \
  sops --encrypt \
  --encrypted-regex '^(data|stringData)$' \
  --input-type yaml --output-type yaml \
  /tmp/my-secret.yaml > kubernetes/apps/my-app/secret.sops.yaml

rm /tmp/my-secret.yaml
```

3. Commit `secret.sops.yaml` to git — it is safe to push.

---

## How to rotate the Age key

1. Generate a new key: `age-keygen -o ~/.config/sops/age/keys.txt`
2. Re-encrypt all `.sops.yaml` files with both old and new keys during the transition
3. Once confirmed working, remove the old key recipient from all files
4. Delete the old key from your machine
