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
3. **Re-activate workflows.** They import deactivated **and unpublished**; on n8n 2.27 a
   workflow's triggers/webhooks register only when it is BOTH active and published.
   `update:workflow --active=true` is DEPRECATED here and does NOT publish — using it leaves
   every webhook returning 404. Use `publish:workflow`, which sets a workflow active **and**
   published in one step (verified: `unpublish` clears both, `publish` restores both):
   ```bash
   # publish (= activate + publish) every restored workflow, then restart so triggers register
   docker exec n8n sh -c 'for id in $(n8n list:workflow --onlyId); do n8n publish:workflow --id="$id"; done'
   docker restart n8n
   ```
   Publishing ~100 workflows this way takes a few minutes (each CLI call cold-starts n8n) —
   it's the sanctioned path. Then verify a key webhook is live:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://auto.kostikidis.net/webhook/ledger-login
   # 200/401 = registered & healthy; 404 = not registered yet
   ```
   (Or publish only the ones you need with `n8n publish:workflow --id=<id>` / the n8n UI.)
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
- RPO ≈ 1 hour (hourly replication). RTO ≈ minutes for steps 1–2 + 4; add a few minutes
  for step 3 (publishing ~100 workflows on 2.27 is sequential). Execution history is NOT
  replicated — only workflows + credentials — so past run logs don't survive failover.
