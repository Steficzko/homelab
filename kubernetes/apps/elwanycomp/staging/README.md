# ElwanyComp staging: the owner's hand steps

Hosts: `comp-test.teamelwany.com` (public) and `comp-test-staff.teamelwany.com` (staff: sign-in and
every signed-in screen; added by "Second hostname" below). Production later:
`competitions.teamelwany.com` and `comp-staff.teamelwany.com`. Namespace:
`elwanycomp-staging`. ArgoCD Application: `kubernetes/bootstrap/apps/elwanycomp-staging.yaml`
(excludes `*.sops.yaml`, so Argo never applies secrets; `prune: false`). The app repo is
Steficzko/elwanycomp; its `docs/DEPLOY-NOTES.md` has the background.

**Who runs what.** These steps touch credentials, Cloudflare and DNS, so they are the owner's. The
homelab session (homelab-7f) may carry out steps 1, 2, 3 and 5 for the owner, on his go in that
session. Step 4 (Cloudflare dashboard) is done by the owner by hand.

**Order:** secrets first, then the tunnel hostname, then Cloudflare settings, DNS last.
**If a step fails, stop there.** Do not go on to the next step. Every block that changes something
runs in a `( set -euo pipefail ... )` subshell, so a failed command ends the block and nothing after
it runs. No secret value is written anywhere: values are generated or typed at run time, travel
through stdin (never a command-line argument, so not in `ps` or the shell history) and only the
SOPS-encrypted file is written.

Run from the homelab checkout root, on `main`, after the staging PR is merged. Argo has then created
the namespace; the pod waits in `CreateContainerConfigError` / `ImagePullBackOff` until steps 1
and 2 are done, which is expected.

1. **PIN pepper.** 32 random bytes, base64, in a SOPS file labelled so it never goes to Velero's
   MinIO. The guard stops if the file already exists: re-running this step would silently replace
   the pepper and **invalidate every PIN**.
   ```bash
   F=kubernetes/apps/elwanycomp/staging/pepper-secret.sops.yaml
   ( set -euo pipefail
     kubectl get ns elwanycomp-staging >/dev/null
     [ ! -e "$F" ] || { echo "STOP: $F exists. Do not recreate it (every PIN would stop working). To re-apply it: sops -d $F | kubectl apply --server-side -f -"; exit 1; }
     trap 'rm -f "$F.tmp"' EXIT
     openssl rand -base64 32 \
       | kubectl create secret generic elwanycomp-pepper -n elwanycomp-staging \
           --from-file=pepper=/dev/stdin --dry-run=client -o yaml \
       | kubectl label --local -f - velero.io/exclude-from-backup=true -o yaml \
       | sops encrypt --filename-override "$F" > "$F.tmp"
     grep -q 'ENC\[AES256_GCM' "$F.tmp" && mv "$F.tmp" "$F" \
       && sops -d "$F" | kubectl apply --server-side -f - \
       && git add "$F" && git commit -m "elwanycomp staging: PIN pepper (SOPS)" -- "$F"
   )
   ```
   The app strips the trailing newline. Losing the pepper means every PIN must be reissued; no
   competition data is lost. The commit stays local until the owner says to push: pushing to
   homelab `main` is the owner's word.

2. **`ghcr-pull`** (the image package is private). A GitHub classic token with only `read:packages`,
   typed at a hidden prompt. Same guard, same chain:
   ```bash
   F=kubernetes/apps/elwanycomp/staging/ghcr-pull.sops.yaml
   ( set -euo pipefail
     [ ! -e "$F" ] || { echo "STOP: $F exists. To re-apply it: sops -d $F | kubectl apply --server-side -f -"; exit 1; }
     trap 'rm -f "$F.tmp"' EXIT
     read -rs -p "GHCR token (read:packages): " GHCR_PAT; echo
     [ -n "$GHCR_PAT" ] || { echo "STOP: empty token"; exit 1; }
     printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'Steficzko:%s' "$GHCR_PAT" | base64 -w0)" \
       | kubectl create secret generic ghcr-pull -n elwanycomp-staging \
           --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
           --dry-run=client -o yaml \
       | sops encrypt --filename-override "$F" > "$F.tmp"
     unset GHCR_PAT
     grep -q 'ENC\[AES256_GCM' "$F.tmp" && mv "$F.tmp" "$F" \
       && sops -d "$F" | kubectl apply --server-side -f - \
       && git add "$F" && git commit -m "elwanycomp staging: ghcr-pull (SOPS)" -- "$F"
   )
   ```
   Then replace the waiting pod (deleting the pod is enough; the Deployment recreates it) and check
   it is healthy:
   ```bash
   ( set -euo pipefail
     kubectl -n elwanycomp-staging delete pod -l app=elwanycomp --wait=true
     kubectl -n elwanycomp-staging rollout status deploy/elwanycomp --timeout=300s
     kubectl -n elwanycomp-staging exec deploy/elwanycomp -- python -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/healthz').read().decode())"
   )
   ```
   The last line must print `"status":"ok"`. If the pod is not Ready, stop. The commit stays local
   until the owner says to push: pushing to homelab `main` is the owner's word.

3. **Tunnel public hostname** on the team-elwany tunnel (id `98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd`,
   connector `kubernetes/networking/cloudflared/deployment-elwany.yaml`, token-based, so the route
   lives on the Cloudflare side). The existing teamelwany.com hosts (`link.teamelwany.com`,
   `link-admin.teamelwany.com`, `gallery.teamelwany.com`) go to
   `http://traefik.traefik.svc.cluster.local:80` (ADR-044: every tunnel rule points there since
   2026-10-16), which lands on Traefik's `web` entrypoint, the only one this app's Ingress uses. Use
   the API, not the dashboard's "Add public hostname" form: the form also creates the DNS record at
   once, which would break the DNS-last order.

   Set up the work folder and helpers (nothing changes yet). `$W` is a 700 folder in the home
   directory, not `/tmp`, because `before.json` is the rollback: **keep `$W` until step 7 passes.**
   The token goes to curl as a header file, never in its argv.
   ```bash
   W=~/.local/share/elwanycomp-staging-cf; install -d -m 700 "$W"
   ACC=90e7dc337477819281ed982a7f6afe32; TUN=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd
   URL=https://api.cloudflare.com/client/v4/accounts/$ACC/cfd_tunnel/$TUN/configurations
   ZT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token_zt)"; }
   ```
   3a. Read the current config, check it, build and check the new one, show the diff (nothing is
   written to Cloudflare here):
   ```bash
   ( set -euo pipefail
     [ ! -e "$W/before.json" ] || { echo "STOP: $W/before.json exists from an earlier run. Keep it, it is the rollback."; exit 1; }
     trap 'rm -f "$W/before.json.tmp"' EXIT
     curl -sf -H @<(ZT) "$URL" > "$W/before.json.tmp"
     jq -e '.success and (.result.config.ingress|length>=2) and (.result.config.ingress[-1].hostname==null) and ([.result.config.ingress[].hostname]|index("comp-test.teamelwany.com")==null)' "$W/before.json.tmp" >/dev/null \
       || { echo "STOP: the tunnel config is not as expected. Nothing was changed."; exit 1; }
     mv "$W/before.json.tmp" "$W/before.json"
     jq -r '.result.config.ingress[] | "\(.hostname // "(catch-all)") -> \(.service)"' "$W/before.json"
     jq '{config: (.result.config | .ingress |= ([{hostname: "comp-test.teamelwany.com", service: "http://traefik.traefik.svc.cluster.local:80"}] + .))}' "$W/before.json" > "$W/after.json"
     jq -e --slurpfile b "$W/before.json" '(.config.ingress[0] == {hostname: "comp-test.teamelwany.com", service: "http://traefik.traefik.svc.cluster.local:80"}) and (.config.ingress[1:] == $b[0].result.config.ingress) and ((.config|del(.ingress)) == ($b[0].result.config|del(.ingress)))' "$W/after.json" >/dev/null \
       || { echo "STOP: after.json is not before.json plus one rule. Nothing was changed."; exit 1; }
     diff <(jq .result.config "$W/before.json") <(jq .config "$W/after.json") || true
   )
   ```
   Read the output. The listed teamelwany.com hosts must point at
   `http://traefik.traefik.svc.cluster.local:80` and the last line must be the catch-all; the diff
   must add exactly the one `comp-test.teamelwany.com` rule. If not, stop.

   3b. Only after reading 3a, write the new config and confirm it took:
   ```bash
   ( set -euo pipefail
     curl -sf -H @<(ZT) "$URL" | jq -e --slurpfile b "$W/before.json" '.result.config == $b[0].result.config' >/dev/null \
       || { echo "STOP: the tunnel config changed since 3a. Nothing was changed. Move before.json and after.json aside and redo 3a."; exit 1; }
     curl -sf -X PUT -H @<(ZT) -H "Content-Type: application/json" --data @"$W/after.json" "$URL" | jq -e '.success' >/dev/null
     trap 'rm -f "$W/put.json.tmp"' EXIT
     curl -sf -H @<(ZT) "$URL" > "$W/put.json.tmp"
     jq -e '.result.config.ingress[0].hostname == "comp-test.teamelwany.com"' "$W/put.json.tmp" \
       && mv "$W/put.json.tmp" "$W/put.json"
   )
   ```
   `put.json` is the live config as Cloudflare stored it after the PUT; the rollback compares
   against it.

   Rollback (puts the saved config back exactly; works from a fresh terminal; stops if anyone has
   changed the tunnel since 3b):
   ```bash
   W=~/.local/share/elwanycomp-staging-cf
   ACC=90e7dc337477819281ed982a7f6afe32; TUN=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd
   URL=https://api.cloudflare.com/client/v4/accounts/$ACC/cfd_tunnel/$TUN/configurations
   ZT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token_zt)"; }
   ( set -euo pipefail
     [ -s "$W/before.json" ] || { echo "STOP: $W/before.json is missing or empty. Restore by hand."; exit 1; }
     [ -s "$W/put.json" ] || { echo "STOP: $W/put.json is missing; 3b did not finish. Compare the live config with before.json by hand."; exit 1; }
     curl -sf -H @<(ZT) "$URL" | jq -e --slurpfile p "$W/put.json" '.result.config == $p[0].result.config' >/dev/null \
       || { echo "STOP: the live tunnel config is not the one 3b wrote. Nothing was changed. Restore by hand."; exit 1; }
     jq '{config: .result.config}' "$W/before.json" \
       | curl -sf -X PUT -H @<(ZT) -H "Content-Type: application/json" --data @- "$URL" | jq -e '.success'
   )
   ```

4. **Cloudflare settings before any traffic** (owner, by hand, dashboard, zone teamelwany.com).
   Both hosts are in every expression so production is covered from day one. If the rule editor
   refuses a field on this plan, stop and report; do not widen a rule to the whole zone.
   - **D1, no injected scripts.** Rules > Configuration Rules > Create rule, name
     `elwanycomp no injection`, expression
     `(http.host in {"comp-test.teamelwany.com" "competitions.teamelwany.com"})`, settings: Rocket
     Loader Off, Email Obfuscation Off, Disable Zaraz, Disable RUM (Web Analytics). Also check
     Analytics & Logs > Web Analytics has no automatic setup for teamelwany.com. An injected script
     could read the PIN from the address.
   - **D2.** `/login` is never behind Cloudflare Access and never redirects to another origin (a
     redirect carries the QR `#pin=` fragment to its target). No Page Rule or Redirect Rule may
     match these hosts. See "Cloudflare Access" below.
   - **Rate limit.** First open Security > WAF > Rate limiting rules. The Free plan allows one rule:
     **if the zone already has a rate-limiting rule, stop and report; do not replace it.** If there is
     none, create one rule, name `elwanycomp login and public posts`, expression
     `(http.request.method eq "POST" and (http.request.uri.path eq "/api/login" or starts_with(http.request.uri.path, "/api/public/")) and http.host in {"comp-test.teamelwany.com" "competitions.teamelwany.com"})`,
     counting by IP, 10 requests per 10 seconds, action Block for 10 seconds.
     The app spec asks for 10 per minute with a 10-minute block on `/api/public/`; use the closest
     the plan's editor allows and report what you set.
   - **Tor.** Security > WAF > Custom rules > Create, name `elwanycomp login no tor`, expression
     `(ip.src.country eq "T1" and http.request.uri.path eq "/api/login" and http.host in {"comp-test.teamelwany.com" "competitions.teamelwany.com"})`,
     action Block.

5. **DNS, last.** Work folder and helpers again, so a fresh terminal works (nothing changes yet):
   ```bash
   W=~/.local/share/elwanycomp-staging-cf; install -d -m 700 "$W"
   Z=bf7cb7f1d5d83b3416647fddee20b82c
   DT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token)"; }
   ```
   5a. Check:
   ```bash
   ( set -euo pipefail
     curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?type=CNAME&per_page=100" \
       | jq -r '.result[] | select(.content | endswith("cfargotunnel.com")) | "\(.name) -> \(.content)"'
     curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?name=comp-test.teamelwany.com" | jq '.result | length'
   )
   ```
   5b. Run only when 5a's last line printed `0` **and** `link.teamelwany.com`,
   `link-admin.teamelwany.com` and `gallery.teamelwany.com` point at
   `98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd.cfargotunnel.com`. Otherwise stop.
   ```bash
   ( set -euo pipefail
     [ ! -e "$W/dns.json" ] || { echo "STOP: $W/dns.json exists; the record was already created."; exit 1; }
     [ "$(curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?name=comp-test.teamelwany.com" | jq '.result|length')" = 0 ] \
       || { echo "STOP: name in use (or the check failed). Nothing was changed."; exit 1; }
     trap 'rm -f "$W/dns.json.tmp"' EXIT
     curl -sf -X POST -H @<(DT) -H "Content-Type: application/json" \
         "https://api.cloudflare.com/client/v4/zones/$Z/dns_records" \
         --data '{"type":"CNAME","name":"comp-test.teamelwany.com","content":"98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd.cfargotunnel.com","proxied":true,"comment":"ElwanyComp staging, homelab kubernetes/apps/elwanycomp/staging"}' \
       > "$W/dns.json.tmp"
     jq -e '.success' "$W/dns.json.tmp" >/dev/null && mv "$W/dns.json.tmp" "$W/dns.json" \
       && jq -r '.result.id' "$W/dns.json"
   )
   ```
   5c. Check through the tunnel. It must print `"status":"ok"`. If it fails right after 5b, wait 1 to
   2 minutes and retry before rolling back.
   ```bash
   curl -sf https://comp-test.teamelwany.com/healthz
   ```
   Rollback (deletes only the record created in 5b; works from a fresh terminal):
   ```bash
   W=~/.local/share/elwanycomp-staging-cf; install -d -m 700 "$W"
   Z=bf7cb7f1d5d83b3416647fddee20b82c
   DT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token)"; }
   ( set -euo pipefail
     [ -s "$W/dns.json" ] || { echo "STOP: $W/dns.json is missing or empty. Nothing was changed."; exit 1; }
     ID=$(jq -er '.result.id' "$W/dns.json")
     curl -sf -X DELETE -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records/$ID" | jq -e '.success'
   )
   ```

6. **First admin.** Prints the admin's PIN once, to your terminal only:
   ```bash
   kubectl -n elwanycomp-staging exec deploy/elwanycomp -- python -m app.cli create-admin "<name>"
   ```

7. **Check D1 and D3 before anyone else uses it.**
   ```bash
   curl -sI https://comp-test.teamelwany.com/login | grep -i '^content-security-policy'
   curl -s https://comp-test.teamelwany.com/login | grep -o '<script[^>]*>'
   curl -s https://comp-test.teamelwany.com/login | grep -c '/cdn-cgi/' || true
   ```
   The first must print the CSP header. The second must print exactly the app's own three tags
   (`/static/js/login.js`, `/static/js/i18n.js`, `/static/js/api.js`) and nothing else. The third
   must print `0`: a `/cdn-cgi/challenge-platform/` script is Bot Fight Mode (Security > Bots >
   Bot Fight Mode; it is zone-wide on this plan, so report before turning it off), any other
   `/cdn-cgi/` script is one of the D1 settings. Any extra script means D1 is not done: stop.

   Then D3: from the admin screen make a staging QR, scan it on a real phone with the stock camera,
   and confirm the address bar no longer shows `#pin=`. Then confirm the app log has only `/login`
   and no PIN:
   ```bash
   kubectl -n elwanycomp-staging logs deploy/elwanycomp --since=15m | grep -c 'pin=' || true
   kubectl -n elwanycomp-staging logs deploy/elwanycomp --since=15m | grep -o '"path": *"[^"]*login[^"]*"' | sort | uniq -c
   ```
   The first must print `0`. In Cloudflare, Security > Events (host `comp-test.teamelwany.com`)
   must show only `/login` for that visit. Traefik has no access log in this cluster.

   When step 7 has passed, `$W` (`~/.local/share/elwanycomp-staging-cf`) may be removed.

## Second hostname: comp-test-staff.teamelwany.com (before the two-hostname image)

From app commit 5179f2f the app answers on two hostnames (app repo `docs/specs/hosts.md`): the
public one keeps the live page, results and sign-up; sign-in, `/admin`, `/mat/`, `/team`,
`/healthz` and `/livez` move to the staff one. **S1 to S3 run before the pull request that carries
this section and the new image is merged** (read them from that PR's branch, or from the app repo's
`docs/RUNBOOK-test-site.md`, Update B). If the image lands first, sign-in is unreachable until the
staff hostname works. Same rules as above: owner's steps, stop at the first failure, the homelab
session may run S1 and S3 on the owner's go, S2 is the owner's by hand.

S1. **Tunnel public hostname** for `comp-test-staff.teamelwany.com`, same tunnel, same service, same
   read / diff / separate PUT as step 3. Its own work folder, so step 3's rollback files stay
   untouched. **Keep `$W` until S4 passes.**
   ```bash
   W=~/.local/share/elwanycomp-staging-cf-staff; install -d -m 700 "$W"
   ACC=90e7dc337477819281ed982a7f6afe32; TUN=98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd
   URL=https://api.cloudflare.com/client/v4/accounts/$ACC/cfd_tunnel/$TUN/configurations
   ZT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token_zt)"; }
   H=comp-test-staff.teamelwany.com; SVC=http://traefik.traefik.svc.cluster.local:80
   ```
   S1a. Read, check, build, diff (nothing is written to Cloudflare here):
   ```bash
   ( set -euo pipefail
     [ ! -e "$W/before.json" ] || { echo "STOP: $W/before.json exists from an earlier run. Keep it, it is the rollback."; exit 1; }
     trap 'rm -f "$W/before.json.tmp"' EXIT
     curl -sf -H @<(ZT) "$URL" > "$W/before.json.tmp"
     jq -e --arg h "$H" --arg s "$SVC" '.success and (.result.config.ingress[-1].hostname==null)
         and ([.result.config.ingress[] | select(.hostname=="comp-test.teamelwany.com" and .service==$s)] | length==1)
         and ([.result.config.ingress[].hostname] | index($h)==null)' "$W/before.json.tmp" >/dev/null \
       || { echo "STOP: the tunnel config is not as expected (comp-test missing, or the staff host already there). Nothing was changed."; exit 1; }
     mv "$W/before.json.tmp" "$W/before.json"
     jq -r '.result.config.ingress[] | "\(.hostname // "(catch-all)") -> \(.service)"' "$W/before.json"
     jq --arg h "$H" --arg s "$SVC" '{config: (.result.config | .ingress |= ([{hostname: $h, service: $s}] + .))}' "$W/before.json" > "$W/after.json"
     jq -e --arg h "$H" --arg s "$SVC" --slurpfile b "$W/before.json" '(.config.ingress[0] == {hostname: $h, service: $s}) and (.config.ingress[1:] == $b[0].result.config.ingress) and ((.config|del(.ingress)) == ($b[0].result.config|del(.ingress)))' "$W/after.json" >/dev/null \
       || { echo "STOP: after.json is not before.json plus one rule. Nothing was changed."; exit 1; }
     diff <(jq .result.config "$W/before.json") <(jq .config "$W/after.json") || true
   )
   ```
   The diff must add exactly the one `comp-test-staff.teamelwany.com` rule. If not, stop.

   S1b. Only after reading S1a, write and confirm:
   ```bash
   ( set -euo pipefail
     curl -sf -H @<(ZT) "$URL" | jq -e --slurpfile b "$W/before.json" '.result.config == $b[0].result.config' >/dev/null \
       || { echo "STOP: the tunnel config changed since S1a. Nothing was changed. Move before.json and after.json aside and redo S1a."; exit 1; }
     curl -sf -X PUT -H @<(ZT) -H "Content-Type: application/json" --data @"$W/after.json" "$URL" | jq -e '.success' >/dev/null
     trap 'rm -f "$W/put.json.tmp"' EXIT
     curl -sf -H @<(ZT) "$URL" > "$W/put.json.tmp"
     jq -e --arg h "$H" '.result.config.ingress[0].hostname == $h' "$W/put.json.tmp" \
       && mv "$W/put.json.tmp" "$W/put.json"
   )
   ```
   Rollback: step 3's rollback block with `W=~/.local/share/elwanycomp-staging-cf-staff`.

S2. **Cloudflare rules extended to the staff hostname** (owner, by hand, dashboard, zone
   teamelwany.com). Edit the existing rules from step 4; do not create second copies. Add both staff
   hostnames so production is covered too. If the editor refuses a field, stop and report.
   - `elwanycomp no injection` (Configuration Rule, D1): expression
     `(http.host in {"comp-test.teamelwany.com" "competitions.teamelwany.com" "comp-test-staff.teamelwany.com" "comp-staff.teamelwany.com"})`,
     settings unchanged.
   - `elwanycomp login and public posts` (the one rate-limiting rule): expression
     `(http.request.method eq "POST" and (http.request.uri.path eq "/api/login" or starts_with(http.request.uri.path, "/api/public/")) and http.host in {"comp-test.teamelwany.com" "competitions.teamelwany.com" "comp-test-staff.teamelwany.com" "comp-staff.teamelwany.com"})`,
     counting and action unchanged.
   - `elwanycomp login no tor` (custom rule): expression
     `(ip.src.country eq "T1" and http.request.uri.path eq "/api/login" and http.host in {"comp-test.teamelwany.com" "competitions.teamelwany.com" "comp-test-staff.teamelwany.com" "comp-staff.teamelwany.com"})`,
     action Block.
   - No challenge, "Under Attack" mode, Bot Fight Mode or edge cache rule may match the staff
     hostnames (D9; hosts.md 5). No Cloudflare Access on the staff host unless the owner decides it
     (then never on `/login`, `/api/login`, `/team`, `/mat/`, `/api/img/*`).

S3. **DNS, last.** Same helpers as step 5, with the staff name and its own folder:
   ```bash
   W=~/.local/share/elwanycomp-staging-cf-staff; install -d -m 700 "$W"
   Z=bf7cb7f1d5d83b3416647fddee20b82c; H=comp-test-staff.teamelwany.com
   DT() { printf 'Authorization: Bearer %s\n' "$(cat ~/.cloudflare_token)"; }
   ```
   S3a. Check (as 5a): the tunnel CNAMEs, then the count for `$H`.
   ```bash
   ( set -euo pipefail
     curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?type=CNAME&per_page=100" \
       | jq -r '.result[] | select(.content | endswith("cfargotunnel.com")) | "\(.name) -> \(.content)"'
     curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?name=$H" | jq '.result | length'
   )
   ```
   S3b. Only when S3a's last line printed `0` and `comp-test.teamelwany.com` points at
   `98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd.cfargotunnel.com`:
   ```bash
   ( set -euo pipefail
     [ ! -e "$W/dns.json" ] || { echo "STOP: $W/dns.json exists; the record was already created."; exit 1; }
     [ "$(curl -sf -H @<(DT) "https://api.cloudflare.com/client/v4/zones/$Z/dns_records?name=$H" | jq '.result|length')" = 0 ] \
       || { echo "STOP: name in use (or the check failed). Nothing was changed."; exit 1; }
     trap 'rm -f "$W/dns.json.tmp"' EXIT
     jq -n --arg h "$H" '{type:"CNAME", name:$h, content:"98ea5620-3e6b-42cb-ad1f-e18c0c9c96dd.cfargotunnel.com", proxied:true, comment:"ElwanyComp staging staff host, homelab kubernetes/apps/elwanycomp/staging"}' \
       | curl -sf -X POST -H @<(DT) -H "Content-Type: application/json" \
           "https://api.cloudflare.com/client/v4/zones/$Z/dns_records" --data @- > "$W/dns.json.tmp"
     jq -e '.success' "$W/dns.json.tmp" >/dev/null && mv "$W/dns.json.tmp" "$W/dns.json" \
       && jq -r '.result.id' "$W/dns.json"
   )
   ```
   S3c. Check, read-only, before the image switch. The Ingress rule for the staff host only arrives
   with the pull request, so the right answer today is **Traefik's own 404**: status `404` and the
   body `404 page not found`. A Cloudflare error page (530, 1033, 1016) or a tunnel error means the
   path is broken: stop. Wait 1 to 2 minutes after S3b before deciding.
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' https://comp-test-staff.teamelwany.com/livez
   curl -s https://comp-test-staff.teamelwany.com/livez
   curl -s https://comp-test.teamelwany.com/healthz
   ```
   The third line (the public host, still the old image) must still print `"status":"ok"`.
   Rollback: step 5's rollback block with the staff folder.

S4. **Only then** the pull request with the new image, both Ingress hosts and the two variables
   merges (staging: the orchestrator merges after manifest-reviewer passes). After Argo syncs:
   ```bash
   kubectl -n elwanycomp-staging rollout status deploy/elwanycomp --timeout=300s
   curl -s https://comp-test-staff.teamelwany.com/healthz
   curl -s -o /dev/null -w '%{http_code}\n' https://comp-test.teamelwany.com/healthz
   curl -s -o /dev/null -w '%{http_code}\n' https://comp-test.teamelwany.com/login
   curl -s -o /dev/null -w '%{http_code}\n' https://comp-test.teamelwany.com/
   ```
   Expected, in order: `"status":"ok"` with the new schema number; `404`; `404`; `200`. Then step 7's
   D1 and D3 checks with `comp-test-staff.teamelwany.com` in place of `comp-test.teamelwany.com`
   (`/login` now lives on the staff host), and a sign-in there. From now on `/healthz` through the
   tunnel is checked on the staff host only (it answers 404 on the public host by design).

## Cloudflare Access: the owner's decision, not part of these steps yet

Pick one later; none is configured by the steps above.
- **A.** The whole host behind Access (email one-time code), with bypass apps for `/login`, `/api/login`, `/api/me`, `/static/*` and `/healthz`.
- **B.** Access only on `/admin*` and `/api/admin/*`.
- **C.** No Access on the test version.

Whatever is chosen, `/login` is never behind Access and never redirects to another origin
(DEPLOY-NOTES D2).
