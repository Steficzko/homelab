# ADR-023 — NFS PV Capacity Labels are Documentation, Not Enforcement

**Status:** Accepted  
**Date:** 2026-06-07

## Context

All NFS-backed PersistentVolumes in this cluster declare `storage: 100Ti`:

```yaml
capacity:
  storage: 100Ti
```

An external reviewer flagged this as "a beautiful lie — Kubernetes doesn't enforce it,
you just typed a big number to feel safe."

This is technically accurate and intentionally chosen.

## Decision

Use `100Ti` as the NFS PV capacity label for all NFS-backed volumes. Manage actual
capacity at the Unraid share level, not at the Kubernetes PV layer.

**Why `100Ti`:**

NFS PersistentVolume capacity in Kubernetes is a metadata field. For NFS-backed
volumes, Kubernetes does not enforce it — there is no quota, no admission block, no
alert when the underlying filesystem approaches the declared size. The label exists
for the scheduler's benefit (PVC requests must be ≤ PV capacity) and for human
readability in `kubectl get pv`.

The actual capacity constraint for each NFS share is set at the Unraid level via
Unraid's share settings. Unraid enforces real disk quotas and can be configured to
alert on space pressure. The Kubernetes label and the Unraid share limit are two
separate mechanisms operating on two separate layers.

`100Ti` is chosen because:
1. It is larger than any realistic data volume for this homelab (current NAS capacity
   is under 30 TB).
2. It ensures no PVC binding fails due to a capacity mismatch — any valid `storageClass:
   ""` (static) PVC will bind to the correct PV by name.
3. It honestly communicates that capacity is not managed at the Kubernetes layer.

A "realistic" label (e.g. `10Ti` for a 10 TB share) would be misleading in a different
way — it implies Kubernetes enforces the limit, which it does not for NFS.

## Consequences

**Operational reality:** Disk space monitoring for NFS-backed workloads must be done
at the Unraid layer (disk usage alerts, share quotas), not via Kubernetes
`PersistentVolumeClaim` metrics. Prometheus's `kubelet_volume_stats_capacity_bytes`
will report `100Ti` for these volumes, which is meaningless. Exclude NFS volumes from
Kubernetes-based capacity alerts and rely on Unraid-side monitoring instead.

**No change needed** when the Unraid share grows or shrinks — the PV label does not
need to be updated. The `100Ti` label is a permanent placeholder, not a measured value.

## Alternatives Considered

**Label with actual share size (e.g. `8Ti`):** Rejected. Creates a false impression
that Kubernetes enforces the limit. Also requires updating the PV manifest every time
the underlying share is resized, which adds operational overhead with no enforcement
benefit.

**Use dynamic NFS provisioning (e.g. nfs-subdir-external-provisioner) with real
quotas:** Out of scope for this homelab. Static NFS PVs with Unraid-managed shares are
correct at this scale.

---

*Relates to: ADR-022 (Unraid as shared service layer), ADR-002 (storage placement).*
