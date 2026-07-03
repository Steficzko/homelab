# Disaster Recovery — Greece warm standby

Cross-site DR for the cluster's critical public service. Prague (the K3s cluster)
is primary; **Greece** (a SuperMicro/ZFS box that's been running since the FreeNAS
days) is a **warm standby** that can take over `auto.kostikidis.net` (n8n) when
Prague is unavailable — and hand it back cleanly.

Designed in [ADR-005](../docs/adr/ADR-005-multi-site-dr-architecture.md), reshaped
into a Docker/Portainer stack in [ADR-012](../docs/adr/ADR-012-greece-warm-standby-docker-stack.md),
and fed by the backup layer in [ADR-011](../docs/adr/ADR-011-application-logical-backups-and-offsite-replication.md).

## How it works

```
Prague (primary)                         Greece (warm standby)
  n8n on K3s  ──hourly──► on-site MinIO ──replicate──► Greece MinIO
      ▲                                                     │
      │                                          restore-from-minio.sh
  auto.kostikidis.net                                       ▼
  (Cloudflare DNS)  ◄────── failover.sh flips DNS ──► Greece failover stack
                                                      (n8n + cloudflared tunnel)
```

A cutover: bring up the Greece stack (seeded from the latest MinIO backup) → wait
until its tunnel + n8n are healthy → flip `auto.kostikidis.net` DNS to the Greece
tunnel → verify Greece is serving → (on a drill) **automatically fail back** to
Prague and tear the standby down.

## Scripts

| Script | Does |
|---|---|
| `failover.sh` | Flip public DNS Prague → Greece failover tunnel (sticky). |
| `failback.sh` | Revert DNS Greece → Prague. |
| `restore-from-minio.sh` | Seed the Greece failover stack from the latest local Greece MinIO backups. |
| `cutover-test.sh` | **Full drill:** start standby → failover → verify → *always* fail back. Guarded by an `EXIT` trap so failback runs on success, error, or kill. |
| `cutover-safety.sh` | Independent `at`-scheduled safety net — guarantees the site is back on Prague even if the drill process is killed. |
| `cutover-drill-extended.sh` | Extended drill: a 30-minute hold on Greece with repeated verification + data-parity checks. |
| `downtime-probe.sh` | Measures **user-facing** availability across a cutover (worst consecutive-failed run = worst-case downtime). |
| `greece-standby-probe.sh` | DR-readiness monitor for the standby (is it seedable and healthy *before* you need it?). |
| `greece-live-backup.sh` | Backs the Greece stack up to Greece MinIO under `greece-live/`. |

Stacks: `failover-stack.yml` (n8n + cloudflared), `minio-stack.yml`, `socket-proxy-stack.yml`.
Runbooks: [`FAILOVER.md`](greece/FAILOVER.md), [`FAILBACK.md`](greece/FAILBACK.md).

## Safety design

The drill can **never** leave production pointed at Greece:
1. `cutover-test.sh` runs failback in an `EXIT` trap — it fires on success, on error, and on signal.
2. `cutover-safety.sh` is a second, **independent** `at` job — even if the drill process is killed mid-run, DNS gets reverted.

## Drilled + measured

Not theoretical — the cutover is exercised and benchmarked:
- **Cutover works and fails back clean** — DNS returns to Prague, the standby is torn down, and Prague's n8n is never disrupted.
- **User-facing downtime measured at ~0 s** — every probe sample across the DNS flip hit a live origin (Cloudflare's proxied DNS flip is near-instant, and both origins were healthy through the transition).

**Honest scope:** the ~0 s figure is the cutover *mechanism* with Prague still up. In a real Prague outage, expect **RTO ≈ 1-2 min** (warm-standby startup) and **RPO ≈ 1 h** (hourly backup). Coverage is `auto.kostikidis.net` (n8n); the standby is warm, not hot.
