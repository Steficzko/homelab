# ElwanyComp production: the owner's one sitting

Hosts (owner, 2026-11-23): public `competitions.teamelwany.com` (live page, results, sign-up) and
staff `comp-staff.teamelwany.com` (sign-in and every signed-in screen). Namespace `elwanycomp`.
ArgoCD Application `kubernetes/bootstrap/apps/elwanycomp.yaml` (excludes `*.sops.yaml`, so Argo
never applies secrets; `prune: false`; Namespace and PVC also carry `Prune=false,Delete=false`).
Image: the one the test site runs (app commit f70d641: 9ceab3a plus the rules at a glance on the sign-up form, team page and live page, and the walkthrough fixes: phone required on the public form, send limit 6 a minute per address, `/staff` and the `/signup` and `/live` redirects; schema 5, no migration; rolling back to 9ceab3a needs only the image line). Routes on Traefik's
dedicated `comp` entrypoint, as staging, including the upload routes (`upload-routes.yaml`, see
"Photos stage 1" below). This folder is the staging folder with only these changes:
namespace, the two hostnames (Ingress, upload routes and the two `ORIGIN` variables), CPU 500m and memory 768Mi
request = limit, a 5Gi volume, plus a PodDisruptionBudget (`pdb.yaml`), critical alerts
(`alerts.yaml`) and a Renovate rule in the repo's `renovate.json` that leaves this folder alone. Background: the app repo's `docs/DEPLOY-NOTES.md`.

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
  grep -q 'ENC\[AES256_GCM' "$F.tmp" \
    || { rm -f "$F.tmp"; echo "STOP: the file is not encrypted. Nothing was applied or committed."; exit 1; }
  mv "$F.tmp" "$F"
  sops -d "$F" | kubectl apply --server-side -f -
  git add "$F" && git commit -m "elwanycomp production: PIN pepper (SOPS)" -- "$F"
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
  grep -q 'ENC\[AES256_GCM' "$F.tmp" \
    || { rm -f "$F.tmp"; echo "STOP: the file is not encrypted. Nothing was applied or committed."; exit 1; }
  mv "$F.tmp" "$F"
  sops -d "$F" | kubectl apply --server-side -f -
  git add "$F" && git commit -m "elwanycomp production: ghcr-pull (SOPS)" -- "$F"
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
Cloudflare side). Both new hosts go to `http://traefik.traefik.svc.cluster.local:8081`, Traefik's
dedicated `comp` entrypoint, the only one this Ingress uses. Only ElwanyComp hostnames use `:8081`.
The other teamelwany.com hosts (link, link-admin, gallery, app) stay on
`http://traefik.traefik.svc.cluster.local:80`, the shared `web` entrypoint: do not change them.
API, not the dashboard form: the form also creates the DNS record at once and breaks the DNS-last
order. Today (2026-11-23) the config is **version 8**: comp-test-staff and comp-test on `:8081`,
gallery, link, link-admin and app on `:80`, then the catch-all. Both production hosts are added
in one write; nothing else moves.

Work folder and helpers (nothing changes yet). `$W` is the rollback: **keep it until P7 passes.**
```bash
W=~/.local/share/elwanycomp-production-cf; install -d -m 700 "$W"
ACC=90e7dc337477819281ed982a7f6afe32; TUN=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd
URL=https://api.cloudflare.com/client/v4/accounts/$ACC/cfd_tunnel/$TUN/configurations
ZT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token_zt)"; }
HS=comp-staff.teamelwany.com; HP=competitions.teamelwany.com
SVC=http://traefik.traefik.svc.cluster.local:8081   # ElwanyComp hosts only
OTHER=http://traefik.traefik.svc.cluster.local:80   # every other teamelwany.com host stays here
```
P2a. Read, check, build, diff (nothing is written to Cloudflare here):
```bash
( set -euo pipefail
  [ ! -e "$W/before.json" ] || { echo "STOP: $W/before.json exists from an earlier run. Keep it, it is the rollback."; exit 1; }
  trap 'rm -f "$W/before.json.tmp"' EXIT
  curl -sf -H @<(ZT) "$URL" > "$W/before.json.tmp"
  # Exact: version 8, 7 rules, the catch-all last, exactly these six hostnames, the two test hosts
  # on :8081 and the four others on :80.
  jq -e --arg s "$SVC" --arg o "$OTHER" '.success and (.result.version == 8)
      and (.result.config.ingress | length == 7)
      and (.result.config.ingress[6].hostname == null)
      and ([.result.config.ingress[0:6][].hostname] | sort == ["app.teamelwany.com","comp-test-staff.teamelwany.com","comp-test.teamelwany.com","gallery.teamelwany.com","link-admin.teamelwany.com","link.teamelwany.com"])
      and ([.result.config.ingress[0:6][] | select(.hostname == "comp-test.teamelwany.com" or .hostname == "comp-test-staff.teamelwany.com") | .service] == [$s, $s])
      and ([.result.config.ingress[0:6][] | select(.hostname != "comp-test.teamelwany.com" and .hostname != "comp-test-staff.teamelwany.com") | .service] | length == 4 and all(. == $o))' "$W/before.json.tmp" >/dev/null \
    || { echo "STOP: the tunnel config is not the expected version 8 (found below). Nothing was changed.";
         jq -r '"version \(.result.version)", (.result.config.ingress[]? | "\(.hostname // "(no hostname)") -> \(.service)")' "$W/before.json.tmp" || true
         exit 1; }
  mv "$W/before.json.tmp" "$W/before.json"
  jq -r '"version \(.result.version)", (.result.config.ingress[] | "\(.hostname // "(catch-all)") -> \(.service)")' "$W/before.json"
  jq --arg hs "$HS" --arg hp "$HP" --arg s "$SVC" '{config: (.result.config | .ingress |= ([{hostname: $hs, service: $s}, {hostname: $hp, service: $s}] + .))}' "$W/before.json" > "$W/after.json"
  jq -e --arg hs "$HS" --arg hp "$HP" --arg s "$SVC" --slurpfile b "$W/before.json" '(.config.ingress[0:2] == [{hostname: $hs, service: $s}, {hostname: $hp, service: $s}]) and (.config.ingress[2:] == $b[0].result.config.ingress) and ((.config|del(.ingress)) == ($b[0].result.config|del(.ingress)))' "$W/after.json" >/dev/null \
    || { echo "STOP: after.json is not before.json plus two rules. Nothing was changed."; exit 1; }
  diff <(jq .result.config "$W/before.json") <(jq .config "$W/after.json") || true
)
```
Check: `version 8`; comp-test-staff and comp-test on `:8081`; gallery, link, link-admin and app
on `:80` (do not change them); the catch-all last; and a diff that adds exactly the two production
rules, both on `http://traefik.traefik.svc.cluster.local:8081`. If not, stop.

P2b. Only after reading P2a, write and confirm:
```bash
( set -euo pipefail
  curl -sf -H @<(ZT) "$URL" | jq -e --slurpfile b "$W/before.json" '.result.config == $b[0].result.config' >/dev/null \
    || { echo "STOP: the tunnel config changed since P2a. Nothing was changed. Move before.json and after.json aside and redo P2a."; exit 1; }
  curl -sf -X PUT -H @<(ZT) -H "Content-Type: application/json" --data @"$W/after.json" "$URL" | jq -e '.success' >/dev/null
  trap 'rm -f "$W/put.json.tmp"' EXIT
  curl -sf -H @<(ZT) "$URL" > "$W/put.json.tmp"
  mv "$W/put.json.tmp" "$W/put.json"
  # The whole config read back must equal after.json. `originRequest: {}` (an empty default
  # Cloudflare may add to a rule) is ignored on both sides; nothing else is.
  jq -e --slurpfile a "$W/after.json" 'def norm: .ingress |= map(if .originRequest == {} then del(.originRequest) else . end);
      .success and ((.result.config | norm) == ($a[0].config | norm))' "$W/put.json" >/dev/null \
    || { echo "STOP: the config Cloudflare holds now is not after.json (difference below). Run the P2 rollback.";
         diff <(jq .config "$W/after.json") <(jq .result.config "$W/put.json") || true
         exit 1; }
  jq -r '"version \(.result.version)"' "$W/put.json"
)
```
Check: it prints `version 9` and no STOP. `put.json` is the live config after the write (kept even
on a STOP, so the rollback can compare against it).

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

Done on 2026-11-23: the three zone rules and the one redirect rule already list the four hostnames. **Change nothing here**; only
confirm, in the dashboard of zone teamelwany.com:
- Rules > Configuration Rules: `elwanycomp no injection`, expression lists
  `comp-test.teamelwany.com`, `competitions.teamelwany.com`, `comp-test-staff.teamelwany.com` and
  `comp-staff.teamelwany.com`; Rocket Loader Off, Email Obfuscation Off, Zaraz off, RUM off.
- Security > WAF > Rate limiting rules: `elwanycomp login and public posts`, same four hostnames.
- Security > WAF > Custom rules: `elwanycomp login no tor`, same four hostnames, action Block,
  covering sign-in and public posts: `ip.src.country eq "T1"` and the four hosts and
  (path eq `/api/login` or (method `POST` and path starts with `/api/public/`)).
- Rules > Redirect Rules: exactly ONE rule for these hosts, `elwanycomp https`: not ssl and the
  four hosts, 301 to `https` with the same host and path, query string kept. It never sends to
  another host (D2: `/login#pin=` stays on its own host).
- No other Redirect Rule, no Page Rule, Cloudflare Access app, challenge or "Cache Everything" rule
  matches either production host.

Stop condition: a rule is missing, lacks `competitions.teamelwany.com` or
`comp-staff.teamelwany.com`, the Tor rule lacks the `/api/public/` part, or a second redirect
matches. Then stop the sitting and report; the fix is a separate edit.

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
TV=$(curl -s https://comp-test.teamelwany.com/ | grep -o '/static/v/[0-9a-f]*/js/api.js' | head -1); echo "test site: $TV"
curl -sI "$P$V" | grep -iE 'cache-control|cf-cache-status'
curl -s -o /dev/null -w 'made-up version %{http_code}\n' $P/static/v/000000000000/js/api.js
for H in competitions.teamelwany.com comp-staff.teamelwany.com; do
  curl -s -o /dev/null -w "http $H %{http_code} -> %{redirect_url}\n" "http://$H/live?x=1"
done
```
Expected, in order:
1. `{"status":"ok","schema":5}` on the staff host.
2. `404` for every staff path on the public host.
3. `/ 200` (public home page).
4. A `content-security-policy` line.
5. Exactly three tags on `/login`: `/static/v/<version>/js/login.js`, `.../js/i18n.js`,
   `.../js/api.js`; exactly three on `/`: `.../js/i18n.js`, `.../js/api.js`, `.../js/index.js`. The
   `<version>` is the one the test site shows (the `test site:` line printed by the block above, read from
   https://comp-test.teamelwany.com/ while it runs the same image). Any other script means D1 is
   not done: stop.
6. `0` for `/cdn-cgi/` (a `/cdn-cgi/challenge-platform/` script is Bot Fight Mode; report before
   changing it, it is zone-wide).
7. A versioned path equal to the `test site:` line (if the test site has moved to a newer image
   since, compare by hand with the version that image showed), `cache-control` with
   `max-age=31536000`, and `made-up version 404`.
8. `http competitions.teamelwany.com 301 -> https://competitions.teamelwany.com/live?x=1` and the
   same for `comp-staff.teamelwany.com` (the `elwanycomp https` redirect rule). Any other code or
   target: stop.

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

## Photos stage 1: upload routes (upload-routes.yaml) and image 9ceab3a

App repo `docs/specs/teams.md` 5.4 and `docs/DEPLOY-NOTES.md` D16 to D24 are the source; the manifests
are the test site's (`../staging/upload-routes.yaml`), which passed the manifest review, the
pentester's review and, with the earlier image 68d3a16, the release checks there. Only the namespace
and the two hosts differ. Memory
is already request = limit = 768Mi here (D19), so `app.yaml` changes only the image. No migration:
the schema stays 5 (D20), so no pre-release snapshot is needed.

**Precondition, before merging:** both production hostnames' tunnel rules point at
`http://traefik.traefik.svc.cluster.local:8081` (P2) and the Ingress names `comp` only (`ingress.yaml`).
Read-only check with the P2 helpers:
`curl -sf -H @<(ZT) "$URL" | jq -r '.result.config.ingress[] | "\(.hostname // "(catch-all)") -> \(.service)"'`
must show `comp-staff.teamelwany.com` and `competitions.teamelwany.com` on `:8081`. If not, do not merge.

**The two routes** (IngressRoutes on the `comp` entrypoint only, explicit `priority: 1000`, above the
Ingress rules, which get their rule length, about 50 to 60):

| Host | Method and path | Chain, in order |
|---|---|---|
| `competitions.teamelwany.com` | `POST /api/public/events/<number>/entries` (the public sign-up) | InFlightReq 4 per `CF-Connecting-IP`; InFlightReq 20 per cloudflared pod (TCP peer; 2 tunnel replicas, so 40 per Traefik pod); Buffering max 2,162,688 bytes, 524,288 in memory (the rest in Traefik's /tmp) |
| `comp-staff.teamelwany.com` | `PUT` on `/api/team/entries/<n>/photo`, `/api/team/logo`, `/api/org/entries/<n>/photo`, `/api/org/clubs/<n>/logo`, `/api/admin/events/<n>/entries/<n>/photo`, `/api/admin/events/<n>/clubs/<n>/logo` | InFlightReq 4 per `CF-Connecting-IP`; InFlightReq 5 per cloudflared pod (TCP peer; 2 tunnel replicas, so 10 per Traefik pod); Buffering max 352,256 bytes, all in memory |
| both | everything else (`/api/login`, the live and form GETs, the picture DELETEs, these paths with another method or on the other host) | the Ingress, `body-64k` (65,536 bytes), unchanged |

Over an InFlightReq Traefik answers 429 before buffering a byte; over a Buffering limit, its own
plain-text 413. The app's caps sit 64 KiB lower (2 MiB and 280 KiB), so a body between the two gets the
app's JSON 413 `ERR-REF-006`. A middleware added to the Ingress later must be added to both routes in the
same change. If the team-elwany tunnel's cloudflared replica count changes, the two total caps change
with it (comment in `upload-routes.yaml`).

**Check from outside, after Argo syncs.** Only probes that send no valid data and cannot write anything:
every body is a run of `a` characters (not JSON), there is no session cookie and no `Idempotency-Key`, so
the app refuses each one before any write; only the size decides who answers. `traefik` means Traefik's
own answer (the body never reached the app), `app` means the body passed Traefik and the app answered
with an `ERR-REF` (413 `ERR-REF-006` above its cap; below it some other refusal, 400, 401, 403, 404 or
429, which is fine). The sign-up probes debit the prober's own address in the app's send bucket (6 a
minute per address, 30 a minute overall) and count against the Cloudflare rate rule (10 per 10 s),
hence the pauses; run it when sign-ups are quiet, never on the event day.
```bash
( set -euo pipefail
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  probe() {  # host method path bytes [extra curl arguments]
    local h=$1 m=$2 u=$3 n=$4; shift 4
    head -c "$n" /dev/zero | tr '\0' 'a' > "$T/body"
    : > "$T/out"
    code=$(curl -s --max-time 60 -o "$T/out" -w '%{http_code}' -X "$m" -H 'Content-Type: application/json' \
      --data-binary @"$T/body" "$@" "https://$h$u" || true)
    if grep -q 'ERR-REF' "$T/out"; then who=app; else who=traefik; fi
    printf '%-34s %-7s %-40s %8s %-34s -> %s %s\n' "$h" "$m" "$u" "$n" "$*" "$code" "$who"; sleep 2; }
  P=competitions.teamelwany.com; S=comp-staff.teamelwany.com
  # A. Limits on the plain routes
  probe $S POST /api/login                      66560    # 65 KiB, not an upload path
  probe $P PUT  /api/public/events/1/entries    66560    # upload path, wrong method
  probe $S POST /api/public/events/1/entries    66560    # upload path, wrong host
  probe $P PUT  /api/team/entries/1/photo       66560    # picture path, wrong host
  probe $P POST /api/public/events/1/entries    2162000  # just under the sign-up limit
  probe $P POST /api/public/events/1/entries    2163000  # just over
  probe $S PUT  /api/org/clubs/1/logo           352000   # just under the picture limit
  probe $S PUT  /api/org/clubs/1/logo           353000   # just over
  probe $S PUT  /api/team/logo                  352000
  probe $S PUT  /api/team/logo                  353000
  # B. Path and method variants of the sign-up, 65 KiB each (pentester L2)
  probe $P POST //api/public/events/1/entries           66560 --path-as-is
  probe $P POST /api/public/events/1/entries/           66560
  probe $P POST /api/public/events/1/entries%2F         66560 --path-as-is
  probe $P POST /api/public/events/1/x/../entries       66560 --path-as-is
  probe $P HEAD /api/public/events/1/entries            66560
  probe $P OPTIONS /api/public/events/1/entries         66560
  probe $P post /api/public/events/1/entries            66560
  # C. Host variants of the sign-up (pentester H1)
  probe $P POST /api/public/events/1/entries    2162000  -H "Host: COMPETITIONS.teamelwany.com"
  probe $P POST /api/public/events/1/entries    2163000  -H "Host: COMPETITIONS.teamelwany.com"
  probe $P. POST /api/public/events/1/entries   2162000
  probe $P. POST /api/public/events/1/entries   2163000
)
```
Expected:
- A: the first four `413 traefik`; then `app`, `413 traefik`, `app`, `413 traefik`, `app`, `413 traefik`.
- B: each line is a Traefik refusal (`413`, or `400` for the encoded slash) or an `app` answer (a 4xx with
  `ERR-REF`). An `app` line means Traefik cleaned the path to the real sign-up path and the app refused
  it, which is fine. Anything else (a `2xx`, a `5xx`, a timeout other than on HEAD): stop and report.
- C: the upper-case Host exactly as the plain host in A, `app` then `413 traefik`; the trailing-dot host
  gets Traefik's own `404` (no route matches it), which is fine. If Cloudflare refuses a variant itself (a
  4xx that is not 413, no `ERR-REF`), note it; that is not a failure.
Any other pattern in A: roll back (below).

**Not on production:** the release checks (D18 trickle check, D19 parallel cap-sized bodies and the
`{},` body, D21 picture checks) ran on the test site on 2026-11-23 against these same manifests and the
earlier image 68d3a16. They were not rerun in full on 9ceab3a nor on f70d641; 9ceab3a has had only the outside probes
since its rollout there on 2026-11-24. The D24 load test with photos ran on a local copy of the app, not
on the test site and not on the image; its result is a conditional pass that waits for the owner, and its
hammer variant has not been run. All of these send real or cap-sized data, hold connections and fill the
send bucket: do not run them against production.

**Rollback.** Revert this pull request (a new pull request, merged by the owner like P5). The
Application has `prune: false` (`kubernetes/bootstrap/apps/elwanycomp.yaml`), so the revert puts the old
image back but leaves the two IngressRoutes and six Middlewares in the cluster. After Argo has synced the
revert (not before: with `selfHeal` it re-creates anything still in git), delete them by hand:
```bash
kubectl -n elwanycomp delete ingressroute elwanycomp-signup-upload elwanycomp-picture-upload
kubectl -n elwanycomp delete middleware signup-inflight-addr signup-inflight-total signup-body \
  picture-inflight-addr picture-inflight-total picture-body
```
Without the routes every path is back on the Ingress at 64 KiB (uploads fail with Traefik's 413, nothing
is exposed). The image can also be rolled back alone (revert only the `image:` line); the routes are
harmless in front of the older image, which caps every body at 64 KiB itself.

Rolling the image back while pictures exist is safe. Both images are schema 5 (no migration between
dac2d1f and 9ceab3a), so the older image starts on the same database. Pictures are rows in the `image`
table (created empty by migration 005); dac2d1f never reads or writes it, so its pages show no pictures
and it has no picture routes. One difference while it runs: foreign keys are on and `image.entry_id` and
`image.club_id` are `ON DELETE CASCADE`, so deleting an entry or a club, merging clubs or rejecting a
pending sending still removes that picture, exactly as 9ceab3a does, but dac2d1f's audit row does not
record it (9ceab3a writes `had_photo` / `logos_deleted`). Nothing else is lost; rolling forward again
shows every picture that is still there.

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
