# ADR-024 — PVC Lifecycle: Size Once with Headroom, Treat as Immutable

**Status:** Accepted  
**Date:** 2026-06-07

## Context

During the cluster's early operation, the ollama PVC was provisioned at 20Gi, then a
commit attempted to rightsize it to 12Gi (`34b4d6a fix(ai): rightsize ollama PVC
20Gi→12Gi`). The result: ArgoCD entered `SyncError` because Kubernetes does not allow
PVC capacity to decrease. The live PVC remained at 20Gi; the manifest said 12Gi;
ArgoCD retried five times and gave up. The cluster and git disagreed silently.

This incident established a hard operational rule for all future PVC provisioning.

## Decision

**Provision PVCs once, with headroom, and treat the initial size as permanent.**

Rules derived from this incident:

1. **Size at provisioning with 40–60% headroom above current usage.** If the workload
   needs 8 GB today, provision 15–20 GB. Storage is cheap relative to the operational
   cost of a PVC resize/migrate procedure.

2. **Never commit a PVC reduction.** Kubernetes will refuse it. ArgoCD will enter
   permanent `SyncError`. The only path out is delete + recreate, which requires
   draining the PVC data first.

3. **PVC expansion is one-directional.** Growing a Longhorn PVC is supported and safe
   (Longhorn CSI supports volume expansion). Shrinking is not. Treat the provisioned
   size as a floor, not a target.

4. **If a PVC must be resized down**, the procedure is: export data → delete PVC and
   dependent pod → recreate PVC at new size → restore data. This is a maintenance
   window, not a one-line fix. Plan it explicitly.

5. **Longhorn snapshot before any storage operation.** Before any PVC delete/recreate,
   take a manual Longhorn snapshot and verify it completes successfully.

## What Triggered This

The `gemma4` model at 9.6 GB was not comfortable in a 12Gi PVC after Ollama's working
files and model metadata are accounted for. The 20Gi provisioned size was correct.
The attempt to reclaim the difference created more operational debt (a stuck ArgoCD
application) than the 8 Gi of "wasted" storage was worth. The storage cost of 8 Gi on
a homelab Longhorn pool is effectively zero.

## Consequences

PVCs in this cluster are provisioned generously and not touched after initial
deployment. Observed usage is monitored via Grafana (`kubelet_volume_stats_used_bytes`)
and the response to approaching the limit is to grow the PVC (Longhorn supports online
expansion), not to investigate whether a smaller PVC would suffice.

**What changes this decision:** A cluster running on severely constrained storage where
every gigabyte counts. At current scale (three nodes, Longhorn pool well under 50%
utilization) this is not the situation.

---

*Relates to: ADR-002 (storage placement), ADR-011 (backup strategy — Longhorn snapshot before PVC operations).*
