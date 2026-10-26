# Greece Failover Runbook (unraid-ptolemaida)

Warm standby for the Prague `bjj` + `n8n` apps. Data arrives via the hourly
Prague→Greece MinIO replication; this stack restores from it and can take over.

## Steady state (standby)
- `bjj-postgres` + `gotenberg`: **running** (Portainer stack `bjj-failover`).
- `n8n` + `bjj-app`: **defined but stopped** (compose `failover` profile) — keeps n8n
  from double-firing schedules/webhooks while Prague is live.
- Secrets live in `/mnt/user/appdata/bjj-failover/.env` (same DB creds +
  `N8N_ENCRYPTION_KEY` as Prague). Site HTML/nginx in `.../html` + `.../nginx`.

## Keep it warm (SCHEDULED — every 6h)
A cron on the Greece Unraid re-seeds the standby from the latest replicated backups
every 6 hours, so it never drifts far:
- cron source (persisted on flash): `/boot/config/plugins/dynamix/bjj-failover-restore.cron`
  → loaded into `/etc/cron.d/root` by `update_cron`
- log: `/mnt/user/appdata/bjj-failover/restore.log`
- **safety guard:** the script aborts if the `n8n` container is running (i.e. we're
  already failed over) so the periodic restore never clobbers live data.

Run it manually any time (e.g. right before failover, for the freshest data):
```bash
cd /mnt/user/appdata/bjj-failover && ./restore-from-minio.sh        # both
./restore-from-minio.sh postgres        # or just one
```

## FAIL OVER (Prague is down)
1. **Pull the freshest data:**
   ```bash
   cd /mnt/user/appdata/bjj-failover && ./restore-from-minio.sh
   ```
2. **Start the app tier.** Portainer → Stacks → `bjj-failover` → add env var
   `COMPOSE_PROFILES=failover` → **Update the stack**. (CLI equivalent:
   `docker compose --profile failover up -d` in the stack dir.)
   This starts `n8n` + `bjj-app`.
3. **Workflows are already published.** Since 2026-10-26 `restore-from-minio.sh`
   publishes exactly the workflows active in Prague (sets `active` + `activeVersionId`,
   the same write `n8n publish:workflow` makes) on every run, so step 1 leaves Greece
   failover-ready. The stack's `N8N_USE_WORKFLOW_PUBLICATION_SERVICE=false` is what makes
   n8n 2.44 honour that on startup. **Never remove it without re-drilling:** without it
   every webhook 404s while `/healthz` stays green. Verify a key webhook is live:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://auto.kostikidis.net/webhook/ledger-login
   # 200/401 = registered & healthy; 404 = not registered
   ```
   **Drilling while Prague is up:** use `drill-webhooks.sh`. It unpublishes everything
   except webhook-only workflows (schedules would double-fire, Telegram triggers would
   re-register the bots), and its cleanup re-runs the n8n restore to go back to ready.

4. **Send traffic to Greece** — run the sticky DNS flip:
   ```bash
   ./disaster-recovery/greece/failover.sh    # needs CF API token in ~/.cloudflare_token
   ```
   Flips `app.teamelwany.com` + `auto.kostikidis.net` to the `TeamElwany GR` tunnel; it
   REFUSES to flip if that tunnel isn't connected (i.e. you skipped step 2). Sticky: Prague
   recovering does NOT reclaim traffic — failback is deliberate (`failback.sh`).

## FAIL BACK (Prague restored)
1. Stop Greece app tier: remove `COMPOSE_PROFILES` env → update stack (n8n + bjj-app stop).
2. Make sure Prague has the authoritative data (restore Greece's deltas into Prague if
   Greece served writes), then point Cloudflare back to Prague.

## Notes
- `n8n` runs as uid 1000; `/mnt/user/appdata/bjj-failover/n8n` is chowned 1000:1000.
- Postgres data persists at `/mnt/user/appdata/bjj-failover/postgres` (subPath `pgdata`).
- RPO ≈ 1 hour (hourly replication). RTO measured 2026-10-26: restore ~35 s + stack start to
  webhooks live ~25 s + Cloudflare edge picking up the DNS flip ~1 min, so about 2 min. Execution history is NOT
  replicated — only workflows + credentials — so past run logs don't survive failover.
