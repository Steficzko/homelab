# ADR-021 — Cluster Memory Management via Pod Placement Instead of Hardware Upgrade

**Status:** Accepted
**Date:** 2026-06-04

## Context

The cluster runs three Lenovo M910q nodes (`k3s-prg-b3`, `k3s-prg-g2`, `k3s-prg-r1`), each with 16 GiB RAM. The problem surfaced during the four-instance Immich migration (ADR-008).

`immich-lightroom` requires a 12 GiB memory limit to rebuild its HNSW vector index (574K face + CLIP vectors). During the migration, `b3` was simultaneously running all four Immich server pods. The 12 GiB spike caused OOMKills on `b3`.

A separate but compounding issue: Loki was deployed via its upstream Helm chart with default values. That chart provisions `chunksCache` and `resultsCache` — Memcached sidecars that exist for Loki's microservices mode. The cluster runs Loki in `SingleBinary` mode, where both caches are no-ops. The Helm defaults committed them anyway. `chunksCache` had a 9.8 GiB *request* sitting on `r1`, blocking all pod scheduling on that node. `resultsCache` held an additional 1.2 GiB request on `g2`. Together, these phantom requests left `g2` appearing 70% allocated at idle and made `r1` nearly unschedulable.

**Forces:**

- The heaviest Immich workload (`lightroom` + ML inference) needs predictable headroom, not best-effort scheduling.
- Pod placement in K3s is free and immediate — `nodeSelector` on the pod spec, committed to git, applied on next sync.
- A RAM upgrade is a physical intervention requiring node downtime, procurement, and cost — not a one-way door, but a non-trivial step that should only be taken once software-side options are exhausted.
- The Loki cache bloat was misdiagnosed capacity — real available RAM was higher than `kubectl top` suggested.

## Decision

Manage cluster memory through explicit pod placement and correct Helm values rather than a hardware upgrade.

**1. Pin `immich-lightroom` to `r1`.**

```yaml
nodeSelector:
  kubernetes.io/hostname: k3s-prg-r1
```

Isolates the heaviest Immich instance (12 GiB limit) to a single node that can be reasoned about independently. No other Immich server pod runs on `r1`.

**2. Pin `immich-ml` to `r1`.**

The ML container idles at ~400 MiB and spikes to ~3.5 GiB only during active inference. `MACHINE_LEARNING_WORKER_TIMEOUT=120` unloads models after 2 minutes of inactivity. Co-locating ML with `lightroom` makes the `r1` spike profile predictable: index rebuild and ML inference do not happen simultaneously, so the 12 GiB and 3.5 GiB peaks do not overlap.

**3. Disable `chunksCache` and `resultsCache` in the Loki Helm values.**

Both caches are microservices-mode features. In `SingleBinary` mode Loki does not use them. Disabling them frees 9.8 GiB of request from `r1` and 1.2 GiB from `g2`, and removes two pods that were consuming scheduler capacity for zero operational benefit.

**4. No RAM upgrade.**

With the above changes the workload fits within current hardware. The decision is deferred until a real capacity ceiling is hit under correct scheduling.

## Node balance after changes

| Node | Utilisation | Key workloads |
|------|-------------|---------------|
| `b3` | ~42% | immich-marianna, immich-stefanos, immich-elwany, ollama |
| `g2` | ~69% | immich-postgres (12 GiB limit), nextcloud, paperless-drali, n8n, litellm, argocd, monitoring |
| `r1` | ~36% | immich-lightroom, immich-ml, whisper, open-webui, loki (SingleBinary) |

## Consequences

**Wins:**

- `r1` went from nearly unschedulable to 36% utilised after removing the phantom Loki cache requests — a capacity gain that cost nothing.
- `lightroom`'s 12 GiB spike is now isolated to `r1`. OOMKills on `b3` are resolved without touching the `b3` workload set.
- Pod placement is expressed in git as `nodeSelector` on the relevant deployments. The intent is auditable, reversible, and applied automatically by ArgoCD.
- No hardware procurement, no downtime.

**Costs and risks:**

- **`nodeSelector` creates scheduling rigidity.** `r1` is now the only node that can run `immich-lightroom` and `immich-ml`. If `r1` goes offline (kernel panic, failed Longhorn PVC, NIC failure), those two pods do not reschedule elsewhere — they stay `Pending` until `r1` recovers or the selector is manually removed. Accepted: `lightroom` is low-urgency (professional archive, not a real-time service), and the 12 GiB requirement means no other node has free headroom to absorb it anyway.
- **`g2` is the high-water node.** At 69% utilisation, `g2` carries immich-postgres with a 12 GiB limit. If all four Immich instances run heavy migrations or face-clustering jobs simultaneously, `g2` could spike toward that limit. Normal operation stays well under 12 GiB — the postgres pod's actual RSS in steady state is 2–4 GiB. Accepted: the risk is bounded by Immich's own concurrency model and is not triggered by routine use.
- **Helm default auditing is now a recurring concern.** `chunksCache` and `resultsCache` were present in the cluster for an unknown period before the memory investigation. Any future Helm chart upgrade could re-enable them silently if the values override is not explicit. Mitigate by keeping `chunksCache.enabled: false` and `resultsCache.enabled: false` explicit in the committed `values.yaml`, not relying on omission.

## Alternatives Considered

**RAM upgrade to 32 GiB per node:** Would eliminate the need for `nodeSelector` constraints and give headroom for future workloads. Rejected at this time — the Loki cache bloat was masking real available capacity. Revisit if `g2` sustains high utilisation after a few weeks of observation.

**Spread Immich instances across nodes with no pinning:** The scheduler would distribute pods, but cannot know that `lightroom`'s 12 GiB limit must not land on `b3` alongside the other three Immich servers. Uncontrolled scheduling is what caused the original OOMKill. Rejected.

**Move immich-postgres off `g2`:** Would reduce `g2` pressure but introduces cross-node database traffic and complicates the backup job. The current utilisation on `g2` is acceptable. Rejected unless `g2` becomes a consistent bottleneck.
