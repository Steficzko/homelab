# ADR-030 — Dedicated Worker Nodes: Topology Split Instead of Per-Node RAM Upgrade

**Status:** Accepted (enacted 2026-06-26/27 — see ADR-030-amendment-16gib-workers)
**Date:** 2026-06-22

## Context

The cluster runs three Lenovo M910q nodes (`k3s-prg-b3`, `k3s-prg-g2`, `k3s-prg-r1`), each with 16 GiB RAM, all three serving as control-plane members of a K3s HA cluster with embedded etcd (3-member quorum). ADR-021 deferred a hardware upgrade and managed memory through pod placement and Helm-default cleanup. That bought real headroom, but the underlying topology problem remains: every node carries both control-plane duties and the full application working set.

**Verified live state:**

- All three nodes are control-plane. There is no worker tier.
- CPU is not the constraint — nodes idle at 10–12%.
- RAM is the constraint, but not in the way a naive `kubectl top` reading suggests. Memory-limit overcommit (sum of pod limits ÷ node allocatable) is **189% on `r1`** and **172% on `b3`** (re-measured 2026-06-22 after a round of limit right-sizing trimmed it down from 253%/182% — still well over 100%). `r1` is an etcd member, so a memory event there is also a quorum-availability event.
- The 16 GiB-per-node ceiling is **not** the binding limit. The control-plane stack itself (k3s server + etcd + system) is only ~3–6 GiB per node. What pressures these nodes is co-located applications plus historically dishonest-low requests (see ADR-021: phantom 9.8 GiB Loki cache request, 12 GiB limits against 2–4 GiB real RSS).

The problem is structural: control-plane and application workloads share the same three boxes, so application spikes land on etcd members. ADR-021 mitigated this with `nodeSelector` pinning; it did not separate the tiers.

**Forces:**

- The constraint is aggregate packing on shared control-plane/app nodes, not raw per-node RAM and not CPU.
- etcd quorum must stay clean. Application memory spikes should not be able to threaten an etcd member.
- No single application needs more than 16 GiB (max configured limit is 12 GiB on `ai/ollama`, the in-cluster CPU LLM fallback; max observed live RSS is ~2.5 GiB; total app working-set is ~18 GiB of requests).
- Power is a managed cost (PVE already tuned 230 W → 170 W); any always-on hardware addition must justify its draw.
- Longhorn is at zero rebuild headroom: 3 replicas on 3 nodes, all ~70% full. A single disk loss has nowhere to rebuild.

## Decision

Add **two dedicated worker nodes** to the cluster as agents and split the topology into a control-plane tier and a worker tier. Do **not** raise per-node RAM on the control-plane nodes.

**Target topology:** 3 control-plane (M910q, 16 GiB) + 2 workers (i5-9500T, 6c/6t, 256 GB NVMe, **32 GiB**).

### 1. Workers join as agents, not control-plane

The two 9500T nodes join as K3s agents. **etcd quorum stays at 3.** The workers are never made control-plane members — adding etcd members on a 1 GbE fabric buys nothing for a 3-member-sufficient quorum and only widens the consensus blast radius.

### 2. Soft taint on the control-plane

```yaml
node-role.kubernetes.io/control-plane:PreferNoSchedule
```

`PreferNoSchedule`, **not** `NoSchedule`. With only two workers, a hard taint makes the worker tier a single point of failure for all non-control-plane workloads: lose one worker and the survivor must absorb everything or pods go `Pending`. The soft taint keeps the control-plane nodes available as overflow capacity while still steering normal scheduling onto the workers.

### 3. Placement tiers

| Tier | Workloads | Placement |
|------|-----------|-----------|
| A | Contention-heavy AI: whisper CPU fallback, `immich-ml` | **Required** worker affinity |
| B | Always-up gateways: `litellm`, ingress | **Preferred** worker affinity |
| C | Everything else | Rides the soft taint (prefers workers, tolerates control-plane) |

Tier A is hard-pinned to workers because that is the workload whose spikes were threatening etcd members. Tier B prefers workers but must stay schedulable if both workers are down. Tier C is left to the scheduler under the soft-taint gradient.

> **Implementation status (2026-06-27):** the per-pod affinity in this table was **never applied to the manifests.** `immich-ml`, `whisper`, `litellm`, and `ollama` all have empty `affinity`/`nodeSelector`/`tolerations` — placement is steered by the **soft taint alone**, and `immich-ml` currently sits on `b3` (an etcd node). The ADR-030-amendment downgraded Tier A from *required* to *preferred*; neither is deployed. The decision is recorded; **implementation is an open item** — add `preferred` worker affinity to those four deploys, or formally accept soft-taint-only steering. See `ADR-030-amendment-16gib-workers` §2.

### 4. Longhorn: add the worker NVMe as replica targets

Add the 256 GB NVMe on each worker as a Longhorn disk. Set replica placement to soft anti-affinity so the 3 replicas of each volume spread across the 5 available nodes. This converts today's zero-headroom state (3 replicas on 3 full nodes) into a topology where a disk loss has somewhere to rebuild.

### 5. RAM asymmetry rationale

The control-plane nodes stay at 16 GiB; the workers get 32 GiB. The reasoning is that control-plane nodes are pressured by **co-located applications**, not by control-plane duties (k3s server + etcd + system ≈ 3–6 GiB). Once applications move to the workers, 16 GiB is comfortable on the control-plane. Put the 32 GiB where the work actually runs. No single app needs >16 GiB (max limit 12 GiB, max live ~2.5 GiB), and the full app working-set is ~18 GiB of requests — which fits on a single 32 GiB worker, the basis for single-worker-failure survivability (see Bad/Risks).

## Consequences

**Good:**

- **etcd members are decoupled from application spikes.** Application workloads — including `immich-lightroom`, currently `nodeSelector`-pinned to the `r1` etcd member and contributing to its ~189% limit overcommit — move off the control-plane onto dedicated workers. An index rebuild or whisper batch can no longer pressure a quorum member.
- **The actual constraint is fixed, not relabelled.** The binding limit was aggregate packing on shared nodes, and the topology split addresses exactly that. 32 GiB on the workers gives real headroom where work runs.
- **Longhorn gains rebuild headroom.** Spreading 3 replicas across 5 nodes means a disk failure has a healthy target to rebuild onto — impossible in the current 3-on-3, all-~70%-full layout.
- **CPU was never the issue, so the lateral CPU profile of the 9500T is irrelevant to the win** — the value is the tier split and RAM-on-workers, both delivered.
- **Control-plane stays at 16 GiB, no per-node upgrade, no control-plane downtime for memory swaps.**

**Bad / Risks:**

- **Longhorn rebalance onto the new NVMe is a scheduled-maintenance event, not a casual click.** Moving replicas onto the worker disks is a network-saturating, multi-hour, degraded-replica operation over 1 GbE. It is a real benefit but it must be **scheduled** — run it deliberately (off-hours, with the cluster otherwise quiet), never triggered mid-week. During the rebalance, volumes run with reduced replica redundancy until rebuilds complete.

- **This ADR amends ADR-021 and the amendment is load-bearing.** Live state (verified 2026-06-22): **only `immich-lightroom` carries the `r1` pin** (`nodeSelector: kubernetes.io/hostname: k3s-prg-r1`, now a 6 GiB limit) — **`immich-ml` has no nodeSelector** and is already free to ride tier-A affinity to a worker. So the action is narrower than first drafted: **remove `immich-lightroom`'s `r1` `nodeSelector`** so it can follow the soft-taint gradient off the etcd node onto a worker (it is the real 6 GiB pod pinned to a quorum member). Until that pin is lifted, ADR-021 ("stay on `r1`") and this ADR ("move off the control-plane") contradict each other for that pod. **This ADR supersedes the `immich-lightroom` pinning clause of ADR-021.** Update both the manifest and ADR-021 when this lands. **✓ DONE 2026-06-27: the `r1` `nodeSelector` was removed — `immich-lightroom` now runs on `w1` unpinned, and ADR-021's header is annotated as superseded.**

- **Single-worker-failure survivability rests on requests being honest — and ADR-021 documents that they historically were not.** The "~18 GiB of requests fits on one 32 GiB worker, so losing a worker is survivable" claim is only true if requests reflect reality. ADR-021 records the opposite history: a phantom 9.8 GiB Loki cache request, and 12 GiB limits against 2–4 GiB real RSS. If tier-A AI and tier-B gateways converge on the lone surviving worker and one of them spikes (e.g. an `immich-server` instance or `ollama` driving toward its limit), 32 GiB gets tight. The soft-taint overflow to the control-plane is the explicit backstop for this case. Recorded as the assumption it is — not a proven property. Re-validate request accuracy on the workers before relying on single-worker failover.

- **+20–40 W always-on draw** for two added nodes. Accepted: power is a managed cost (PVE already tuned 230 W → 170 W), and the topology benefit justifies it. The 9500T is a low-TDP T-series part, keeping the addition modest.

## Alternatives Considered

**Per-node RAM upgrade to 32 GiB on all three M910q (ADR-021's deferred option):** Would add headroom but leaves control-plane and application workloads co-located on the same etcd members. The constraint is the shared topology, not raw RAM. Rejected — it spends money without separating the tiers, and application spikes would still land on quorum members.

**16 GiB workers instead of 32 GiB:** The 9500T's per-core performance is roughly equal to the existing 8400T, so 16 GiB workers would be a **lateral CPU move** — and CPU was never the constraint (10–12% idle). The value of the whole exercise is the topology split plus putting RAM where the work runs. 16 GiB workers deliver the split but not the headroom; 32 GiB is what actually fixes the binding constraint. Rejected.

**Add 1× M910q i7-7700T worker after upgrading all three nodes to 32 GiB (earlier plan):** This was the prior direction. Superseded by this ADR. It coupled a full per-node RAM upgrade (cost on three boxes) with a single worker (still a SPOF for the worker tier) and a weaker CPU part. Two 32 GiB workers + unchanged 16 GiB control-plane is cheaper on RAM, removes the single-worker SPOF, and keeps the constraint-fixing RAM on the worker tier where it belongs.

**Hard `NoSchedule` taint on the control-plane:** Rejected. With only two workers, a hard taint makes the worker tier a SPOF — losing one worker forces the survivor to carry everything or strands pods as `Pending`. The soft `PreferNoSchedule` taint keeps the control-plane as overflow while still steering normal scheduling onto workers.

**Make the workers control-plane members (5-member etcd):** Rejected. A 3-member quorum is sufficient and healthy. Adding etcd members over 1 GbE adds consensus traffic and widens the failure blast radius for zero availability gain.

## Related

- **ADR-007** — Proxmox ML Node Architecture. The off-cluster GPU/CPU inference tier; this ADR concerns the always-on in-cluster CPU tier that complements it.
- **ADR-021** — Cluster Memory Management via Pod Placement. **Amended/superseded** by this ADR: the `immich-lightroom` `nodeSelector` pinning to `r1` is lifted so it can move to a worker (`immich-ml` is already unpinned). The Loki Helm-default cleanup from ADR-021 stands unchanged.
