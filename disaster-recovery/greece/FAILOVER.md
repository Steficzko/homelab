# Greece Failover Runbook (unraid-ptolemaida)

Warm standby for the Prague `bjj` + `n8n` apps. Data arrives via the hourly
Prague→Greece MinIO replication; this stack restores from it and can take over.

## Steady state (standby)
- `bjj-postgres` + `gotenberg`: **running** (Portainer stack `bjj-failover`).
- `n8n` + `bjj-app`: **defined but stopped** (compose `failover` profile) — keeps n8n
  from double-firing schedules/webhooks while Prague is live.
- Secrets live in `/mnt/user/appdata/bjj-failover/.env` (same DB creds +
  `N8N_ENCRYPTION_KEY` as Prague). Site HTML/nginx in `.../html` + `.../nginx`.

## Keep it warm (optional, periodic)
Re-seed from the latest replicated backups any time:
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
3. **Re-activate workflows** (they import deactivated):
   ```bash
   docker exec n8n n8n update:workflow --all --active=true   # then restart n8n
   docker restart n8n
   ```
   (Or activate only the ones you need in the n8n UI.)
4. **Send traffic to Greece** via Cloudflare — point `auto.kostikidis.net` (and the
   bjj site host) at the Greece `cloudflared` tunnel / flip the Cloudflare LB origin.

## FAIL BACK (Prague restored)
1. Stop Greece app tier: remove `COMPOSE_PROFILES` env → update stack (n8n + bjj-app stop).
2. Make sure Prague has the authoritative data (restore Greece's deltas into Prague if
   Greece served writes), then point Cloudflare back to Prague.

## Notes
- `n8n` runs as uid 1000; `/mnt/user/appdata/bjj-failover/n8n` is chowned 1000:1000.
- Postgres data persists at `/mnt/user/appdata/bjj-failover/postgres` (subPath `pgdata`).
- RPO ≈ 1 hour (hourly replication). RTO ≈ minutes once you run steps 1–4.
