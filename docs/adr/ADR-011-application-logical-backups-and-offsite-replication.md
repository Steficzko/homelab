# ADR-011 — Backup & Off-Site Replication Strategy (Block + Logical Layers)

**Status:** Accepted
**Date:** 2026-06-14

> **Consolidation note (2026-06-16):** This ADR now documents the **full** backup
> architecture end to end. The block-level layer (Velero for K8s resources, Longhorn for
> volume data) was previously drafted separately as ADR-018; it has been folded in here so
> there is a single canonical backup record. ADR-018 is superseded by this ADR. One stale
> claim from ADR-018 is corrected below: off-site replication is **not** merely ADR-005's
> Unraid-to-Unraid copy — that copy did not actually exist; the hourly `mc mirror` CronJob
> in this ADR is what implements it.

## Context

ADR-005 framed database DR as "Velero for all databases → Unraid NFS → Unraid-to-Unraid replication to Greece." That covers *disaster* recovery, but it left two real gaps once heavy day-to-day development started on the BJJ stack (the `bjj` Postgres schema and the n8n automation platform are edited constantly):

1. **No granular / frequent rollback.** Velero and Longhorn are block/namespace-level and run **daily**. They cannot answer "undo what I broke ~5 hours ago in the database or a workflow." Logical, portable, per-object backups are needed for that, and for migration across Postgres/n8n versions.
2. **The off-site copy did not actually exist.** Velero and Longhorn both wrote only to the **Prague Unraid MinIO** (`192.168.1.100:9100`) — on the Prague LAN. A power/ransomware/theft event on that one LAN loses the live data *and* every backup. ADR-005 *assumed* Unraid-to-Unraid replication; in practice the MinIO buckets were not being mirrored to Greece.

The cluster runs stateful applications — Immich, Nextcloud, Paperless, n8n, CouchDB, and multiple Postgres instances — producing two distinct data categories that need different recovery approaches: **K8s resource definitions** (recreatable from Git via ArgoCD, but not all runtime-generated state) and **persistent volume data** (the bytes inside Longhorn PVCs, which ArgoCD cannot restore). A single tool cannot cover both efficiently, so the design uses purpose-built layers.

Constraint discovered mid-implementation: the k3s **kube-router** NetworkPolicy controller reliably drops cross-node *source* pods (the VXLAN overlay itself is healthy — proven 8/8 with no NP). So a backup pod scheduled on a different node than its database is blocked. See ADR-012 and the deferred fix.

## Decision

Run a **block-level layer** (Velero + Longhorn) as the foundation, add a **logical backup layer** on top for granular/portable recovery, and **replicate every backup bucket off-site to Greece over Tailscale.**

### Block-level layer — the foundation

Two independent tools, each covering the layer it owns, both targeting MinIO on Unraid Prague (`192.168.1.100:9100`) in separate buckets.

**Layer 1 — Velero (K8s resource backup)**

| Parameter | Value |
|-----------|-------|
| Schedule | Daily at 02:00 |
| TTL | 30 days |
| Scope | All namespaces |
| PVC data included | No (`defaultVolumesToFsBackup: false`) |
| Target | MinIO `192.168.1.100:9100`, bucket `velerok3s` |
| Uploader | kopia |
| Plugin | `velero-plugin-for-aws` v1.10.0 (S3-compatible) |
| Exclusions | Resources labelled `velero.io/exclude-from-backup` |

Velero captures cluster-wide resource state (Deployments, StatefulSets, Services, Ingresses, Secrets, ConfigMaps, PVC *definitions*, CRDs). In a full restore it brings the cluster back to its last-known resource state; ArgoCD then reconciles drift from Git. PVC data is excluded — that is Layer 2.

**Layer 2 — Longhorn volume backup**

| Parameter | Value |
|-----------|-------|
| Schedule | Daily at 03:00 (1 hour after Velero) |
| Retain | 30 snapshots |
| Concurrency | 2 volumes simultaneously |
| Job name | `daily-backup` (RecurringJob, task: backup) |
| Target | MinIO `192.168.1.100:9100`, bucket `longhornk3s` |
| Scope | All Longhorn volumes carrying the `daily-backup` label (18 currently) |

The 1-hour offset from Velero avoids competing I/O peaks on the MinIO target and node storage during the backup window. Longhorn incrementals keep the 30-snapshot retention from multiplying storage cost linearly.

### Logical backups (hourly, to Prague MinIO `app-backups`)
- **Postgres:** `pg_dump -Fc -Z6` → `app-backups/bjj-postgres/`. `-Fc` restores selectively and across versions.
- **n8n:** `n8n export:workflow --all --separate` + `export:credentials` (encrypted) via `kubectl exec` into the live pod (n8n is SQLite on an RWO Longhorn PVC — a second pod cannot mount it).
- **Retention 7 days** = 168 hourly restore points. On-demand snapshots via `kubectl create job --from=cronjob/...` before risky changes.
- Credentials export stays **encrypted**; it is only restorable with `N8N_ENCRYPTION_KEY`, which lives in `n8n-secret` (SOPS) — so the key is escrowed in git, gated by the Age key.

### Off-site replication (hourly, Prague → Greece)
A single `hostNetwork` `mc mirror` CronJob in namespace `backup` runs on a Prague node (so it reaches both the Prague-LAN MinIO and the Greece tailnet IP) and mirrors:
- `app-backups` — accumulate + 30-day cap (keeps Greece deeper than Prague's 7d).
- `velerok3s` and `longhornk3s` — **faithful versioned mirrors** (`--overwrite --remove`, destination versioning on).

This puts the Velero (k8s objects + PVC definitions) and Longhorn (raw volume) backups in Greece too, not just our logical dumps. **This CronJob is the real off-site mechanism** — superseding ADR-005's assumed-but-absent Unraid-to-Unraid copy.

### Reliability workaround
Backup jobs use `podAffinity` to co-locate with their workload (same node, where NP enforcement is reliable) **and** an in-pod `pg_isready` retry loop (~90s) to wait out the kube-router NP-programming delay. This makes backups reliable **without** depending on the deferred kube-router fix.

### What this does NOT protect

| Data | Protected by |
|------|-------------|
| NFS-mounted volumes (Immich library, Paperless consume, Nextcloud files) | Unraid host-level backup + ADR-005 replication |
| etcd cluster state | k3s embedded etcd snapshots |
| Longhorn volumes not labelled `daily-backup` at job run time | **Not protected** — operator must ensure the label is on new volumes |

## Consequences

- "Roll back ~5 hours" is satisfied for both the database and n8n, independent of the daily Velero/Longhorn cadence.
- Resource and data recovery paths are independent: a PVC corruption does not prevent manifest restore, and vice-versa. Recovery is testable in isolation (Velero restore and Longhorn restore are separate operations).
- True 3-2-1: live data → Prague Unraid MinIO → Greece Unraid MinIO (different country). Verified sizes on Greece: app-backups 846 KiB, velerok3s 64 MiB, longhornk3s 664 MiB.
- **Restore sequencing:** Velero does not capture Longhorn volume data (intentional). A Velero restore without a matching Longhorn restore leaves PVCs empty — runbooks must sequence Longhorn restore *before* app startup.
- **New Longhorn volumes must be labelled.** Any PVC created without the `daily-backup` RecurringJob label is silently unprotected; no alerting exists today. A Prometheus alert on unlabelled Longhorn volumes would close this gap.
- **Day-2 risk — deletion propagation:** the `--remove` mirror means a deletion (or wipe) on Prague propagates to Greece. Mitigated by **object versioning** on the Greece buckets (deletes become recoverable delete-markers), but versions grow unbounded without a future lifecycle policy — a known follow-up.
- **Single backup target:** if Unraid Prague is offline, both block layers stop writing simultaneously; the Greece copy is a recovery copy, not a live target, and may lag up to one replication interval. **Open dependency:** if Unraid Prague moves from always-on to on-demand scheduling, MinIO will not be available at 02:00/03:00 unless the machine is woken for the backup window — requiring a scheduled wake+backup window or a target migration to TrueNAS Scale (storage evolution plan, ADR-019).
- **Secret smell (accepted):** the replication needs MinIO credentials in-cluster (`minio-replication-secret`, SOPS). The credentials were the same MinIO user as Longhorn; reused deliberately rather than minting a scoped user. A scoped read-only key for replication would be tighter.
- **Concurrency of 2:** with 18 volumes the Longhorn window may run up to 9 sequential pairs; monitor `longhorn_backup_state` for jobs that do not reach `Completed`.
- The kube-router cross-node NP defect remains latent (see ADR-012). Backups are insulated from it; other cross-node traffic is not.

## Alternatives Considered

- **Velero/Longhorn only (no logical layer)** — rejected. Daily cadence and block-level granularity cannot do "undo the last few hours" or cross-version migration.
- **Single tool for both layers (Velero with `defaultVolumesToFsBackup: true`)** — rejected. Velero filesystem backup treats PVC contents as opaque byte streams; for running database pods this is only safe with per-StatefulSet app-quiescing hooks — operational overhead Longhorn's built-in backup avoids.
- **MinIO server-side bucket replication** (configured on the Prague MinIO) — rejected for now. Cleaner long-term, but needs MinIO admin access and remote-target config; the `mc mirror` CronJob reuses the existing GitOps + tailnet path with no MinIO admin changes.
- **Push backups straight to Greece from each job** — rejected. Keeps the tailnet-egress concern (hostNetwork) isolated to one replication job instead of every backup pod.
- **Cloud backup target (S3, B2, Wasabi)** — rejected. Data sovereignty is a hard constraint; photo archives and personal documents must not leave self-managed infrastructure.
- **Longhorn cross-site (stretched) replication as the backup mechanism** — rejected. Requires low-latency node-to-node links unsuitable over the Prague–Greece WAN, and provides no point-in-time recovery.

---

*Relates to: ADR-005 (DR architecture and Unraid-to-Unraid replication), ADR-002 (cluster split and storage placement), ADR-007 (ML node — separate from cluster storage), ADR-019 (storage evolution — MinIO target migration when Unraid Prague moves to on-demand). Consolidates and supersedes the former ADR-018 (block-level backup strategy).*
