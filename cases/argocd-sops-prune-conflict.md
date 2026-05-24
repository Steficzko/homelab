# ArgoCD + SOPS: Secret Prune Conflict

**Date:** 2026-05-24  
**Cluster:** k3s homelab (k3s-prg)  
**Apps affected:** paperless-ngx, n8n

---

## What happened

Two apps went down simultaneously. paperless-ngx: postgres auth failed. n8n: encryption key mismatch. Both pointed to corrupted or missing Kubernetes Secrets.

Root cause was a three-step chain:

**Step 1 — Secret created with wrong values**

A `secret.example.yaml` file existed in each app directory as documentation — showing secret structure with placeholder values like `changeme`. ArgoCD syncs all `.yaml` files recursively, so it applied these as real Secrets. On first deploy, ArgoCD's apply ran before the manual SOPS apply, so apps that restarted picked up `changeme` passwords.

Result: postgres initialized its data directory with password `changeme`. n8n initialized its SQLite DB with encryption key `REPLACE_ME_32_CHAR_RANDOM_STRING`.

**Step 2 — Manual SOPS apply fought ArgoCD self-heal**

Applying the real secrets with `sops --decrypt ... | kubectl apply -f -` would work briefly. ArgoCD self-heal would then re-apply the example file, overwriting the real values back to placeholders. Each pod restart picked up whichever version was current — creating a race condition.

**Step 3 — Rename triggered prune**

Renamed `secret.example.yaml` → `secret.example` to stop ArgoCD from applying it. ArgoCD with `prune: true` saw that `postgres-secret` and `paperless-secret` now had the `app.kubernetes.io/instance: paperless` label (set when ArgoCD first applied the example) but were no longer present in git. ArgoCD deleted them on the next sync.

pods → crashloop.

---

## The fixes applied (in order)

```bash
# 1. Rename all example files to remove .yaml extension
git mv kubernetes/apps/n8n/secret.example.yaml kubernetes/apps/n8n/secret.example
git mv kubernetes/apps/paperless/secret.example.yaml kubernetes/apps/paperless/secret.example
git mv kubernetes/apps/obsidian-livesync/secret.example.yaml kubernetes/apps/obsidian-livesync/secret.example

# 2. Reapply all SOPS secrets (they now have no ArgoCD ownership label)
sops --decrypt kubernetes/apps/paperless/secret.sops.yaml | kubectl apply -f -
sops --decrypt kubernetes/apps/n8n/secret.sops.yaml | kubectl apply -f -

# 3. Reset postgres role password to match SOPS value
# (DB was initialized with "changeme" from the example secret)
DBPASS=$(kubectl get secret paperless-secret -n paperless \
  -o jsonpath='{.data.PAPERLESS_DBPASS}' | base64 -d)
kubectl exec -n paperless deploy/postgres -- \
  psql -U paperless -c "ALTER ROLE paperless PASSWORD '$DBPASS';"

# 4. Wipe n8n data PVC (no credentials stored yet; DB encrypted with wrong key)
kubectl scale deploy n8n -n n8n --replicas=0
kubectl run --rm -i config-fix --image=alpine:3 --restart=Never -n n8n \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"n8n-data-pvc"}}],"containers":[{"name":"config-fix","image":"alpine:3","command":["sh","-c","rm -rf /data/*"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}]}}'
kubectl scale deploy n8n -n n8n --replicas=1
```

---

## Permanent fix: secret-placeholder.yaml

ArgoCD prunes secrets it "owns" (resources it applied — they carry the `app.kubernetes.io/instance` label). The SOPS secrets are excluded from ArgoCD sync (`exclude: '*.sops.yaml'`), so ArgoCD never applies them and never owns them. Without ownership, ArgoCD won't prune them.

To make this robust, add a `secret-placeholder.yaml` per app that:
- Declares the Secret resource (so ArgoCD tracks it and won't prune it)
- Has **no `data:` field** (client-side apply won't touch data fields absent from git)
- Carries two annotations that prevent self-heal conflicts

```yaml
# kubernetes/apps/<app>/secret-placeholder.yaml
apiVersion: v1
kind: Secret
metadata:
  name: <secret-name>
  namespace: <namespace>
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous  # don't flag SOPS-added data as drift
    argocd.argoproj.io/sync-options: Prune=false          # never prune even if removed from git
type: Opaque
```

**Why this works:**
- `IgnoreExtraneous`: when ArgoCD compares git (no `data:`) vs live (real secret values), the extra data fields in live are treated as extraneous and ignored. ArgoCD marks the resource as Synced without overwriting.
- `Prune=false`: even if the placeholder is ever removed from git, ArgoCD will not delete the live secret.
- No `data:` in placeholder: kubectl client-side apply only manages fields present in last-applied-configuration. A placeholder with no `data:` field means ArgoCD's apply never touches the data, preserving SOPS-applied values.

---

## Bootstrap sequence for new deploys

Order matters:

```bash
# 1. Apply namespace (ArgoCD needs it for the app)
kubectl apply -f kubernetes/apps/<app>/namespace.yaml

# 2. Apply SOPS secret BEFORE ArgoCD first syncs
sops --decrypt kubernetes/apps/<app>/secret.sops.yaml | kubectl apply -f -

# 3. Apply ArgoCD Application (triggers first sync)
kubectl apply -f kubernetes/bootstrap/apps/<app>.yaml
```

If ArgoCD syncs before step 2, the placeholder secret is created empty. Apply SOPS immediately after — it will patch the empty secret with real values. ArgoCD self-heal won't revert because of `IgnoreExtraneous`.

---

## What NOT to do

- **Do not** name example files `secret.example.yaml` or any `.yaml`/`.yml` extension inside ArgoCD-synced paths. ArgoCD applies all YAML files it finds.
- **Do not** rely on apply ordering to avoid the race — ArgoCD self-heal runs continuously.
- **Do not** use `stringData:` in placeholders. kubectl normalises `stringData` to `data` and the empty map will be written into last-applied-configuration, causing future applies to remove real keys.

---

## Affected repos pattern

Every app with a SOPS secret needs:
```
kubernetes/apps/<app>/
├── secret-placeholder.yaml   ← ArgoCD tracks, never overwrites data
├── secret.sops.yaml          ← excluded from ArgoCD, applied manually
└── secret.example            ← documentation only, no .yaml extension
```
