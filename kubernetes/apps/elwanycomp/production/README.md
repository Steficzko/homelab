# ElwanyComp production: the owner's one sitting

Hosts (owner, 2026-11-23): public `competitions.teamelwany.com` (live page, results, sign-up) and
staff `comp-staff.teamelwany.com` (sign-in and every signed-in screen). Namespace `elwanycomp`.
ArgoCD Application `kubernetes/bootstrap/apps/elwanycomp.yaml` (excludes `*.sops.yaml`, so Argo
never applies secrets; `prune: false`; Namespace and PVC also carry `Prune=false,Delete=false`).
Image: the one the test site runs since 2026-11-23 (app commit e562a94, schema 5). This folder is
the staging folder with only these changes: namespace, the two hostnames (Ingress and the two
`ORIGIN` variables), CPU 500m and memory 768Mi request = limit, a 5Gi volume, plus a
PodDisruptionBudget (`pdb.yaml`), critical alerts (`alerts.yaml`) and a Renovate rule in the repo's
`renovate.json` that leaves this folder alone. Background: the app repo's `docs/DEPLOY-NOTES.md`.

**Who runs what.**

| Step | Who |
|---|---|
| P1 namespace and the two secrets | **owner only** (types the GitHub token; holds the SOPS key) |
| P2 tunnel hostnames | owner, or the homelab session (homelab-7f) on his go |
| P3 zone rules, a look | **owner only** (dashboard) |
| P4 DNS records | owner, or the homelab session on his go |
| P5 merge of the production pull request | **owner only** (he merges, or says "merge") |
| P6 first admin | **owner only, in his own terminal, never through a Claude session** (it prints the PIN) |
| P7 checks | owner; the read-only lines may be run by the homelab session; the phone check is the owner's |

**Rules for the sitting.** Do the steps in order. **If a step's check fails, stop there** and do not
go on. Every block that changes something runs in a `( set -euo pipefail ... )` subshell, so a
failed command ends the block and nothing after it runs. No secret value is written anywhere:
values are generated or typed at run time, travel through stdin (never a command-line argument)
and only the SOPS-encrypted file is written. Tokens go to curl as a header file, never in argv.

Run from the root of the homelab worktree that holds the production branch:
```bash
cd /home/stefanos/.local/share/elwanycomp-review/homelab-wt && git switch elwanycomp/production
```

## P1. Namespace, PIN pepper and ghcr-pull [owner]

Production has its **own** pepper. Never copy staging's: the two sites must not share PINs.

P1a. Create the namespace from this folder's file (Argo adopts it at P5; same labels, so the pod
security level applies from the start):
```bash
( set -euo pipefail
  kubectl get ns elwanycomp >/dev/null 2>&1 && { echo "STOP: namespace elwanycomp already exists. Report before going on."; exit 1; }
  kubectl apply -f kubernetes/apps/elwanycomp/production/namespace.yaml
  kubectl get ns elwanycomp --show-labels
)
```
Check: the last line shows `pod-security.kubernetes.io/enforce=restricted`.

P1b. **PIN pepper.** 32 random bytes, base64, labelled so it never goes to Velero's MinIO. The
guards stop if the file or the Secret already exists: replacing the pepper **invalidates every PIN**.
```bash
F=kubernetes/apps/elwanycomp/production/pepper-secret.sops.yaml
( set -euo pipefail
  kubectl get ns elwanycomp >/dev/null
  [ ! -e "$F" ] || { echo "STOP: $F exists. Do not recreate it (every PIN would stop working). To re-apply it: sops -d $F | kubectl apply --server-side -f -"; exit 1; }
  ! kubectl -n elwanycomp get secret elwanycomp-pepper >/dev/null 2>&1 || { echo "STOP: the Secret elwanycomp-pepper already exists in the cluster. Report."; exit 1; }
  trap 'rm -f "$F.tmp"' EXIT
  openssl rand -base64 32 \
    | kubectl create secret generic elwanycomp-pepper -n elwanycomp \
        --from-file=pepper=/dev/stdin --dry-run=client -o yaml \
    | kubectl label --local -f - velero.io/exclude-from-backup=true -o yaml \
    | sops encrypt --filename-override "$F" > "$F.tmp"
  grep -q 'ENC\[AES256_GCM' "$F.tmp" && mv "$F.tmp" "$F" \
    && sops -d "$F" | kubectl apply --server-side -f - \
    && git add "$F" && git commit -m "elwanycomp production: PIN pepper (SOPS)" -- "$F"
)
```

P1c. **`ghcr-pull`** (the image package is private). A GitHub classic token with only
`read:packages`, typed at a hidden prompt (the staging token may be reused; it is the same package):
```bash
F=kubernetes/apps/elwanycomp/production/ghcr-pull.sops.yaml
( set -euo pipefail
  [ ! -e "$F" ] || { echo "STOP: $F exists. To re-apply it: sops -d $F | kubectl apply --server-side -f -"; exit 1; }
  trap 'rm -f "$F.tmp"' EXIT
  read -rs -p "GHCR token (read:packages): " GHCR_PAT; echo
  [ -n "$GHCR_PAT" ] || { echo "STOP: empty token"; exit 1; }
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'Steficzko:%s' "$GHCR_PAT" | base64 -w0)" \
    | kubectl create secret generic ghcr-pull -n elwanycomp \
        --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
        --dry-run=client -o yaml \
    | sops encrypt --filename-override "$F" > "$F.tmp"
  unset GHCR_PAT
  grep -q 'ENC\[AES256_GCM' "$F.tmp" && mv "$F.tmp" "$F" \
    && sops -d "$F" | kubectl apply --server-side -f - \
    && git add "$F" && git commit -m "elwanycomp production: ghcr-pull (SOPS)" -- "$F"
)
```

P1 check (prints no secret value; the last line compares fingerprints only):
```bash
( set -euo pipefail
  kubectl -n elwanycomp get secret elwanycomp-pepper ghcr-pull
  kubectl -n elwanycomp get secret elwanycomp-pepper -o jsonpath='{.metadata.labels.velero\.io/exclude-from-backup}{"\n"}'
  a=$(kubectl -n elwanycomp get secret elwanycomp-pepper -o jsonpath='{.data.pepper}' | sha256sum)
  b=$(kubectl -n elwanycomp-staging get secret elwanycomp-pepper -o jsonpath='{.data.pepper}' | sha256sum)
  [ "$a" != "$b" ] && echo "pepper differs from staging: ok" || { echo "STOP: production pepper equals staging's"; exit 1; }
)
```
Expected: both Secrets listed, `true`, `pepper differs from staging: ok`. Both commits sit on the
production branch and go with the production pull request (Argo never applies them). Pushing is the
owner's word.

## P2. Tunnel public hostnames (owner, or homelab session on his go)

Team-elwany tunnel `98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd` (connector
`kubernetes/networking/cloudflared/deployment-elwany.yaml`, token-based, so routes live on the
Cloudflare side). Both new hosts go to `http://traefik.traefik.svc.cluster.local:80` (Traefik's
`web` entrypoint, the only one this Ingress uses). API, not the dashboard form: the form also
creates the DNS record at once and breaks the DNS-last order. Today (2026-11-23) the config is
**version 7** and holds comp-test-staff, comp-test, gallery, link, link-admin, app, then the
catch-all. Both production hosts are added in one write.

Work folder and helpers (nothing changes yet). `$W` is the rollback: **keep it until P7 passes.**
```bash
W=~/.local/share/elwanycomp-production-cf; install -d -m 700 "$W"
ACC=90e7dc337477819281ed982a7f6afe32; TUN=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd
URL=https://api.cloudflare.com/client/v4/accounts/$ACC/cfd_tunnel/$TUN/configurations
ZT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token_zt)"; }
HS=comp-staff.teamelwany.com; HP=competitions.teamelwany.com; SVC=http://traefik.traefik.svc.cluster.local:80
```
P2a. Read, check, build, diff (nothing is written to Cloudflare here):
```bash
( set -euo pipefail
  [ ! -e "$W/before.json" ] || { echo "STOP: $W/before.json exists from an earlier run. Keep it, it is the rollback."; exit 1; }
  trap 'rm -f "$W/before.json.tmp"' EXIT
  curl -sf -H @<(ZT) "$URL" > "$W/before.json.tmp"
  jq -e --arg hs "$HS" --arg hp "$HP" --arg s "$SVC" '.success and (.result.version == 7)
      and (.result.config.ingress[-1].hostname == null)
      and ([.result.config.ingress[] | select((.hostname=="comp-test.teamelwany.com" or .hostname=="comp-test-staff.teamelwany.com") and .service==$s)] | length == 2)
      and ([.result.config.ingress[].hostname] | (index($hs) == null and index($hp) == null))' "$W/before.json.tmp" >/dev/null \
    || { echo "STOP: the tunnel config is not as expected (version not 7, test hosts missing, or a production host already there). Nothing was changed."; exit 1; }
  mv "$W/before.json.tmp" "$W/before.json"
  jq -r '"version \(.result.version)", (.result.config.ingress[] | "\(.hostname // "(catch-all)") -> \(.service)")' "$W/before.json"
  jq --arg hs "$HS" --arg hp "$HP" --arg s "$SVC" '{config: (.result.config | .ingress |= ([{hostname: $hs, service: $s}, {hostname: $hp, service: $s}] + .))}' "$W/before.json" > "$W/after.json"
  jq -e --arg hs "$HS" --arg hp "$HP" --arg s "$SVC" --slurpfile b "$W/before.json" '(.config.ingress[0:2] == [{hostname: $hs, service: $s}, {hostname: $hp, service: $s}]) and (.config.ingress[2:] == $b[0].result.config.ingress) and ((.config|del(.ingress)) == ($b[0].result.config|del(.ingress)))' "$W/after.json" >/dev/null \
    || { echo "STOP: after.json is not before.json plus two rules. Nothing was changed."; exit 1; }
  diff <(jq .result.config "$W/before.json") <(jq .config "$W/after.json") || true
)
```
Check: `version 7`, the seven lines above, and a diff that adds exactly the two production rules.
If not, stop.

P2b. Only after reading P2a, write and confirm:
```bash
( set -euo pipefail
  curl -sf -H @<(ZT) "$URL" | jq -e --slurpfile b "$W/before.json" '.result.config == $b[0].result.config' >/dev/null \
    || { echo "STOP: the tunnel config changed since P2a. Nothing was changed. Move before.json and after.json aside and redo P2a."; exit 1; }
  curl -sf -X PUT -H @<(ZT) -H "Content-Type: application/json" --data @"$W/after.json" "$URL" | jq -e '.success' >/dev/null
  trap 'rm -f "$W/put.json.tmp"' EXIT
  curl -sf -H @<(ZT) "$URL" > "$W/put.json.tmp"
  jq -e --arg hs "$HS" --arg hp "$HP" '.result.config.ingress[0].hostname == $hs and .result.config.ingress[1].hostname == $hp' "$W/put.json.tmp" >/dev/null \
    && mv "$W/put.json.tmp" "$W/put.json" && jq -r '"version \(.result.version)"' "$W/put.json"
)
```
Check: it prints `version 8`. `put.json` is the live config after the write; the rollback compares
against it.

P2 rollback (puts the saved config back exactly; works from a fresh terminal; stops if anyone has
changed the tunnel since P2b):
```bash
W=~/.local/share/elwanycomp-production-cf
ACC=90e7dc337477819281ed982a7f6afe32; TUN=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd
URL=https://api.cloudflare.com/client/v4/accounts/$ACC/cfd_tunnel/$TUN/configurations
ZT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token_zt)"; }
( set -euo pipefail
  [ -s "$W/before.json" ] || { echo "STOP: $W/before.json is missing or empty. Restore by hand."; exit 1; }
  [ -s "$W/put.json" ] || { echo "STOP: $W/put.json is missing; P2b did not finish. Compare the live config with before.json by hand."; exit 1; }
  curl -sf -H @<(ZT) "$URL" | jq -e --slurpfile p "$W/put.json" '.result.config == $p[0].result.config' >/dev/null \
    || { echo "STOP: the live tunnel config is not the one P2b wrote. Nothing was changed. Restore by hand."; exit 1; }
  jq '{config: .result.config}' "$W/before.json" \
    | curl -sf -X PUT -H @<(ZT) -H "Content-Type: application/json" --data @- "$URL" | jq -e '.success'
)
```

## P3. Cloudflare zone rules: a look only [owner]

Done on 2026-11-23: all three rules already list the four hostnames. **Change nothing here**; only
confirm, in the dashboard of zone teamelwany.com:
- Rules > Configuration Rules: `elwanycomp no injection`, expression lists
  `comp-test.teamelwany.com`, `competitions.teamelwany.com`, `comp-test-staff.teamelwany.com` and
  `comp-staff.teamelwany.com`; Rocket Loader Off, Email Obfuscation Off, Zaraz off, RUM off.
- Security > WAF > Rate limiting rules: `elwanycomp login and public posts`, same four hostnames.
- Security > WAF > Custom rules: `elwanycomp login no tor`, same four hostnames, action Block.
- No Page Rule, Redirect Rule, Cloudflare Access app, challenge or "Cache Everything" rule matches
  either production host.

Stop condition: a rule is missing, or lacks `competitions.teamelwany.com` or
`comp-staff.teamelwany.com`. Then stop the sitting and report; the fix is a separate edit.

## P4. DNS, last (owner, or homelab session on his go)

Helpers again, so a fresh terminal works (nothing changes yet):
```bash
W=~/.local/share/elwanycomp-production-cf; install -d -m 700 "$W"
Z=bf7cb7f1d5d83b3416647fddee20b82c; T=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd.cfargotunnel.com
DT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token)"; }
```
P4a. Check:
```bash
( set -euo pipefail
  curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?type=CNAME&per_page=100" \
    | jq -r '.result[] | select(.content | endswith("cfargotunnel.com")) | "\(.name) -> \(.content)"'
  for H in comp-staff.teamelwany.com competitions.teamelwany.com; do
    printf '%s %s\n' "$H" "$(curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?name=$H" | jq '.result | length')"
  done
)
```
P4b. Run only when both last lines end in `0` **and** `comp-test.teamelwany.com` and
`comp-test-staff.teamelwany.com` point at `98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd.cfargotunnel.com`.
Otherwise stop. Staff host first, then public; each has its own record file for the rollback.
```bash
( set -euo pipefail
  for H in comp-staff.teamelwany.com competitions.teamelwany.com; do
    R="$W/dns-$H.json"
    [ ! -e "$R" ] || { echo "STOP: $R exists; the record for $H was already created."; exit 1; }
    [ "$(curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?name=$H" | jq '.result|length')" = 0 ] \
      || { echo "STOP: $H in use (or the check failed)."; exit 1; }
    jq -n --arg h "$H" --arg t "$T" '{type:"CNAME", name:$h, content:$t, proxied:true, comment:"ElwanyComp production, homelab kubernetes/apps/elwanycomp/production"}' \
      | curl -sf -X POST -H @<(DT) -H "Content-Type: application/json" \
          "https://api.cloudflare.com/client/v4/zones/$Z/dns_records" --data @- > "$R.tmp"
    jq -e '.success' "$R.tmp" >/dev/null || { rm -f "$R.tmp"; echo "STOP: creating $H failed."; exit 1; }
    mv "$R.tmp" "$R"; echo "$H $(jq -r '.result.id' "$R")"
  done
)
```
P4c. Check through the tunnel, read-only. The Ingress only arrives with P5, so the right answer now
is **Traefik's own 404** on both hosts: `404` and the body `404 page not found`. A Cloudflare error
page (530, 1033, 1016) or a tunnel error means the path is broken: stop. Wait 1 to 2 minutes after
P4b before deciding.
```bash
for H in comp-staff.teamelwany.com competitions.teamelwany.com; do
  echo "$H $(curl -s -o /dev/null -w '%{http_code}' https://$H/livez) $(curl -s https://$H/livez)"
done
```

P4 rollback (deletes only the records P4b created; works from a fresh terminal):
```bash
W=~/.local/share/elwanycomp-production-cf
Z=bf7cb7f1d5d83b3416647fddee20b82c
DT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token)"; }
( set -euo pipefail
  for H in competitions.teamelwany.com comp-staff.teamelwany.com; do
    R="$W/dns-$H.json"
    [ -s "$R" ] || { echo "skip $H: no record file"; continue; }
    ID=$(jq -er '.result.id' "$R")
    curl -sf -X DELETE -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records/$ID" | jq -e '.success'
  done
)
```

## P5. Merge the production pull request [owner]

The owner merges it himself, or says "merge" in the session. Argo then creates everything in this
folder. Check (read-only):
```bash
( set -euo pipefail
  kubectl -n elwanycomp rollout status deploy/elwanycomp --timeout=300s
  kubectl -n elwanycomp exec deploy/elwanycomp -- python -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/healthz').read().decode())"
  kubectl -n argocd get application elwanycomp -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
  kubectl -n elwanycomp get pvc,pdb,prometheusrule
)
```
Expected: rolled out; `"status":"ok"` with `"schema":5`; `Synced Healthy`; the PVC `Bound` at 5Gi,
the PDB with `ALLOWED DISRUPTIONS 0`, the rule `elwanycomp-alerts`. If the pod is not Ready within
5 minutes (`ImagePullBackOff`: P1c; `CreateContainerConfigError`: P1b), stop.

## P6. First admin [owner, own terminal only]

Prints the admin's PIN once. Run it **in your own terminal, never through a Claude session** and
never paste the output anywhere:
```bash
kubectl -n elwanycomp exec deploy/elwanycomp -- python -m app.cli create-admin "<name>"
```

## P7. Checks after the rollout

Read-only; the homelab session may run all but the phone check.
```bash
P=https://competitions.teamelwany.com; S=https://comp-staff.teamelwany.com
curl -s $S/healthz; echo
for p in /healthz /livez /login /admin /mat/ /team /api/me; do echo "$p $(curl -s -o /dev/null -w '%{http_code}' $P$p)"; done
curl -s -o /dev/null -w '/ %{http_code}\n' $P/
curl -sI $S/login | grep -i '^content-security-policy' | cut -c1-60
curl -s $S/login | grep -o '<script[^>]*>'
curl -s $P/ | grep -o '<script[^>]*>'
curl -s $S/login $P/ | grep -c '/cdn-cgi/' || true
V=$(curl -s $P/ | grep -o '/static/v/[0-9a-f]*/js/api.js' | head -1); echo "$V"
curl -sI "$P$V" | grep -iE 'cache-control|cf-cache-status'
curl -s -o /dev/null -w 'made-up version %{http_code}\n' $P/static/v/000000000000/js/api.js
```
Expected, in order:
1. `{"status":"ok","schema":5}` on the staff host.
2. `404` for every staff path on the public host.
3. `/ 200` (public home page).
4. A `content-security-policy` line.
5. Exactly three tags on `/login`: `/static/v/<version>/js/login.js`, `.../js/i18n.js`,
   `.../js/api.js`; exactly three on `/`: `.../js/i18n.js`, `.../js/api.js`, `.../js/index.js`. With
   this image the version is `cb903a7939d5`. Any other script means D1 is not done: stop.
6. `0` for `/cdn-cgi/` (a `/cdn-cgi/challenge-platform/` script is Bot Fight Mode; report before
   changing it, it is zone-wide).
7. A versioned path, `cache-control` with `max-age=31536000`, and `made-up version 404`.

Phone check [owner]: from the admin screen make a QR for a test official, scan it with a phone's
stock camera, confirm the address bar no longer shows `#pin=`, then:
```bash
kubectl -n elwanycomp logs deploy/elwanycomp --since=15m | grep -c 'pin=' || true
```
must print `0`. Then switch that test official off in People.

Backup check (the data is NOT backed up without it):
```bash
PV=$(kubectl -n elwanycomp get pvc elwanycomp-data -o jsonpath='{.spec.volumeName}'); echo "$PV"
kubectl -n longhorn-system get volumes.longhorn.io -l recurring-job.longhorn.io/daily-backup=enabled | grep -E "NAME|$PV"
```
The volume must be listed. After the next 03:00 run (Prague), confirm a backup exists:
`kubectl -n longhorn-system get backups.longhorn.io | grep "$PV"`.

When P7 has passed, `~/.local/share/elwanycomp-production-cf` may be removed.

Not part of this sitting, still open: the uptime check from outside the cluster on
`https://comp-staff.teamelwany.com/healthz` plus the public home page (DEPLOY-NOTES), and the
pre-release list in the app repo's `docs/CHECKS.md`.

## Rollback

- **Manifests:** revert the production pull request (a new pull request, merged like P5). Argo has
  `prune: false`, so the Namespace, the PVC (with the data) and the Secrets stay; a revert of the
  first production pull request leaves the old objects in place and they must be removed by hand if
  wanted. A later image bump is rolled back by reverting that bump.
- **Data:** a newer schema refuses an older image, so reverting an image after a migration needs the
  database copy as well. Method: the app repo's `docs/RUNBOOK-test-site.md`, section 0 (copy tools,
  `backup.py` streamed off the pod before every release with a migration) and section 3 (pause Argo
  for the Application, scale to 0, helper pod with the old image, `restore.py`, revert, unpause),
  with namespace `elwanycomp`, Application `elwanycomp` and the hosts above. A Longhorn snapshot
  is taken before any release that carries a migration.
- **Cloudflare:** the P2 and P4 rollback blocks above (DNS first, then the tunnel).
