# Greece → Prague FAILBACK Runbook

Use this **after** a real failover where Greece served live traffic (so Greece holds
new data Prague never saw). There is **no automatic merge** — this is single-writer
DR: the side that was live (Greece) is authoritative, and you copy it back to Prague
wholesale. Relational databases cannot be safely auto-merged (PK collisions), so don't try.

## ⛔ The golden rule
**The side that was serving traffic wins. Never let Prague resume serving with its
stale pre-outage data** — that throws away everything Greece accepted during the outage
and splits your data. Failback is always deliberate.

## Before you start
- Confirm Greece is the authoritative copy (it served the outage).
- Confirm the **greece-live backup** ran during the outage (`greece-live/` prefix in the
  Greece MinIO) — that's your safety copy of the new data.

## Steps
1. **Keep Prague's app tier from serving.** When Prague comes back, leave Cloudflare
   pointed at Greece (it already is, from failover). Prague's pods may run, but **no
   traffic must reach them** until step 5. Do NOT flip Cloudflare back yet.

2. **Snapshot Greece (authoritative) — fresh:**
   ```bash
   # on the Greece Unraid
   docker exec bjj-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z6 -f /tmp/failback.dump
   docker exec n8n n8n export:workflow --all --separate --output=/tmp/fb/workflows
   docker exec n8n n8n export:credentials --all --output=/tmp/fb/credentials.json
   ```
   (Or just grab the latest `greece-live/` objects from the Greece MinIO.)

3. **Restore Greece's data into Prague (overwrite the stale DB):**
   ```bash
   # bjj postgres (Prague)
   kubectl exec -i -n bjj deploy/postgres -- pg_restore -U <user> -d <db> --clean --if-exists < failback.dump
   # n8n (Prague)
   kubectl exec -n n8n deploy/n8n -- n8n import:workflow --separate --input=/restore/workflows
   kubectl exec -n n8n deploy/n8n -- n8n import:credentials --input=/restore/credentials.json
   ```
   Verify Prague row counts now match Greece.

4. **Freeze Greece** — stop its app tier so it accepts no more writes:
   Portainer → `bjj-failover` → remove `COMPOSE_PROFILES=failover` env → redeploy
   (n8n + bjj-app stop). Greece is back to warm standby.

5. **Cut traffic back to Prague** — point Cloudflare (the Greece tunnel hostnames) back
   to Prague. Verify Prague serves correctly with the merged-forward data.

6. **Resume normal direction** — Prague→Greece replication + the 6h warm-restore continue
   as before. Confirm a fresh Prague backup lands and replicates.

## Why not auto-failback?
A health-check Load Balancer would route back to Prague the moment it looks healthy —
**before** you've copied Greece's new data into it → instant split-brain. For
single-writer DR, **failover may be automatic but failback must be manual.** If you use a
Cloudflare Load Balancer, configure the Prague pool for **manual re-enable**, not
automatic. The DNS-flip approach is sticky by default (stays on Greece until you flip
back), which is the safer fit here.
