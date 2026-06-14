# ADR-011 — Application-Level Logical Backups + Off-Site MinIO Replication

**Status:** Accepted
**Date:** 2026-06-14

## Context

ADR-005 framed database DR as "Velero for all databases → Unraid NFS → Unraid-to-Unraid replication to Greece." That covers *disaster* recovery, but it left two real gaps once heavy day-to-day development started on the BJJ stack (the `bjj` Postgres schema and the n8n automation platform are edited constantly):

1. **No granular / frequent rollback.** Velero and Longhorn are block/namespace-level and run **daily**. They cannot answer "undo what I broke ~5 hours ago in the database or a workflow." Logical, portable, per-object backups are needed for that, and for migration across Postgres/n8n versions.
2. **The off-site copy did not actually exist.** Velero and Longhorn both wrote only to the **Prague Unraid MinIO** (`192.168.1.100:9100`) — on the Prague LAN. A power/ransomware/theft event on that one LAN loses the live data *and* every backup. ADR-005 *assumed* Unraid-to-Unraid replication; in practice the MinIO buckets were not being mirrored to Greece.

Constraint discovered mid-implementation: the k3s **kube-router** NetworkPolicy controller reliably drops cross-node *source* pods (the VXLAN overlay itself is healthy — proven 8/8 with no NP). So a backup pod scheduled on a different node than its database is blocked. See ADR-012 and the deferred fix.

## Decision

Add a **logical backup layer** on top of the existing block-level backups, and **replicate every backup bucket off-site to Greece over Tailscale.**

### Logical backups (hourly, to Prague MinIO `app-backups`)
- **Postgres:** `pg_dump -Fc -Z6` → `app-backups/bjj-postgres/`. `-Fc` restores selectively and across versions.
- **n8n:** `n8n export:workflow --all --separate` + `export:credentials` (encrypted) via `kubectl exec` into the live pod (n8n is SQLite on an RWO Longhorn PVC — a second pod cannot mount it).
- **Retention 7 days** = 168 hourly restore points. On-demand snapshots via `kubectl create job --from=cronjob/...` before risky changes.
- Credentials export stays **encrypted**; it is only restorable with `N8N_ENCRYPTION_KEY`, which lives in `n8n-secret` (SOPS) — so the key is escrowed in git, gated by the Age key.

### Off-site replication (hourly, Prague → Greece)
A single `hostNetwork` `mc mirror` CronJob in namespace `backup` runs on a Prague node (so it reaches both the Prague-LAN MinIO and the Greece tailnet IP) and mirrors:
- `app-backups` — accumulate + 30-day cap (keeps Greece deeper than Prague's 7d).
- `velerok3s` and `longhornk3s` — **faithful versioned mirrors** (`--overwrite --remove`, destination versioning on).

This puts the Velero (k8s objects + PVC data) and Longhorn (raw volume) backups in Greece too, not just our logical dumps.

### Reliability workaround
Backup jobs use `podAffinity` to co-locate with their workload (same node, where NP enforcement is reliable) **and** an in-pod `pg_isready` retry loop (~90s) to wait out the kube-router NP-programming delay. This makes backups reliable **without** depending on the deferred kube-router fix.

## Consequences

- "Roll back ~5 hours" is satisfied for both the database and n8n, independent of the daily Velero/Longhorn cadence.
- True 3-2-1: live data → Prague Unraid MinIO → Greece Unraid MinIO (different country). Verified sizes on Greece: app-backups 846 KiB, velerok3s 64 MiB, longhornk3s 664 MiB.
- **Day-2 risk — deletion propagation:** the `--remove` mirror means a deletion (or wipe) on Prague propagates to Greece. Mitigated by **object versioning** on the Greece buckets (deletes become recoverable delete-markers), but versions grow unbounded without a future lifecycle policy — a known follow-up.
- **Secret smell (accepted):** the replication needs MinIO credentials in-cluster (`minio-replication-secret`, SOPS). The credentials were the same MinIO user as Longhorn; reused deliberately rather than minting a scoped user. A scoped read-only key for replication would be tighter.
- The kube-router cross-node NP defect remains latent (see ADR-012). Backups are insulated from it; other cross-node traffic is not.

## Alternatives Considered

- **Velero/Longhorn only (no logical layer)** — rejected. Daily cadence and block-level granularity cannot do "undo the last few hours" or cross-version migration.
- **MinIO server-side bucket replication** (configured on the Prague MinIO) — rejected for now. Cleaner long-term, but needs MinIO admin access and remote-target config; the `mc mirror` CronJob reuses the existing GitOps + tailnet path with no MinIO admin changes.
- **Push backups straight to Greece from each job** — rejected. Keeps the tailnet-egress concern (hostNetwork) isolated to one replication job instead of every backup pod.
