# ADR-030 Amendment — 16 GiB Workers, Tier-A to Preferred, Longhorn Rebalance Enacted

**Status:** Accepted
**Date:** 2026-06-27

> This amends ADR-030 (Dedicated Worker Nodes: Topology Split). It does **not** reverse the
> topology split — control-plane/worker separation, agents-not-members, and the soft taint all
> stand. It corrects a load-bearing hardware assumption (workers are 16 GiB, not 32 GiB),
> downgrades tier-A placement from required to preferred, and records the Longhorn rebalance as
> **executed** (2026-06-27) — including that the originally-planned mechanism turned out to be a
> no-op and what was used instead.

## Context

ADR-030 was written against an assumed worker spec of **32 GiB**. During the W1 deployment
(2026-06-26) the actual hardware was confirmed: **Lenovo ThinkCentre M920q, i5-9500T (6c/6t),
16 GiB RAM, 256 GB NVMe** — each worker has **half the RAM ADR-030 planned for**.

This invalidates the survivability arithmetic in ADR-030 §5 ("RAM asymmetry rationale") and the
related Bad/Risks bullet. The whole "~18 GiB app working-set fits on a single 32 GiB worker, so
losing a worker is survivable" claim assumed 32 GiB headroom. At 16 GiB — roughly **14 GiB usable**
after `k3s-agent` plus system overhead — a single surviving worker **cannot** absorb the ~18 GiB
cluster app working-set. The arithmetic no longer closes.

Both workers are now live (W1 `k3s-prg-w1`/.204 joined 2026-06-26; W2 `k3s-prg-w2`/.205 joined
2026-06-27), all 5 nodes kernel-aligned at 6.12.94+deb13 / k8s v1.35.4, and the Longhorn rebalance
has been run. This amendment records the enacted state.

## Decision

### 1. Worker RAM correction — single-worker-failover survivability is now explicitly unsupported

Workers are 16 GiB each, not 32 GiB. ADR-030's single-worker-failover survivability clause is
**withdrawn**. It is no longer a design property; it is an explicitly-unsupported state.

At 16 GiB (~14 GiB usable), one worker cannot hold the ~18 GiB app working-set. So if a worker is
lost, the only thing keeping workloads scheduled is the soft-taint overflow back onto the
control-plane nodes — and that **re-introduces the exact pressure on etcd members the topology
split existed to remove.** Stated plainly: a worker failure trades the survivability guarantee for
a temporary return to the pre-ADR-030 problem (app spikes landing on quorum members) until the
worker is restored. That is the accepted failure mode, not a guarantee, and not a property to
design other decisions on top of.

This does not change the topology decision. The split still decouples etcd from app spikes in the
**healthy** (both-workers-present) steady state, which is where the cluster runs the overwhelming
majority of the time. It removes a false claim about the **degraded** state.

### 2. Tier-A placement: required worker affinity → preferred

ADR-030 §3 hard-pins tier-A (`immich-ml`, whisper CPU fallback) to workers with **required**
affinity. With a single 16 GiB worker that recreates a SPOF: if the one worker is full or down,
tier-A pods go `Pending` with no control-plane fallback — the precise cliff the soft taint was
chosen to avoid elsewhere.

**Tier-A is amended from required to preferred worker affinity.** This keeps the scheduling
steering (tier-A still prefers workers, still gets off the etcd nodes in the healthy case) without
the `Pending`-on-failure cliff. Restore required affinity only once **both** conditions hold:

1. There are **two healthy workers** (so required affinity still has a fallback target) — **now
   satisfied** (W1 + W2 live as of 2026-06-27), **and**
2. Tier-A requests have been **validated honest on the workers** (per the ADR-030 §5 / ADR-021
   caveat that requests were historically dishonest-low) — **still pending**.

With condition 1 met, restoring required affinity is now gated only on the requests-honesty
validation. Until that is done, tier-A stays preferred, matching tier-B.

> **Reality check (2026-06-27):** the `preferred` affinity described here is **not yet in the
> manifests** — `immich-ml`, `whisper`, `litellm`, and `ollama` have empty
> `affinity`/`nodeSelector`/`tolerations`, so placement is soft-taint-only and `immich-ml` is
> currently on `b3` (an etcd node). This section describes the **intended** placement, not deployed
> state. Open action: add the `preferred` worker affinity to those four deploys, or accept
> soft-taint-only steering and drop the affinity language.

### 3. Longhorn rebalance — EXECUTED 2026-06-27 (planned mechanism was a no-op)

ADR-030 §4 said add the worker NVMe and rebalance. Both worker disks onboarded (each a ~216 GiB
disk at `/var/lib/longhorn`, schedulable). The rebalance was run **once, after both workers were
present**, as a single off-hours event — but **not by the mechanism this amendment originally
planned.**

**What was planned (and why it failed):** flip `replica-auto-balance` `least-effort` →
`best-effort` and let Longhorn spread replicas onto the workers. This was run and **moved zero
replicas in 37 minutes.** Longhorn's `replica-auto-balance` (both `least-effort` and `best-effort`)
balances **each volume's own replicas across distinct nodes** — it does **not** level aggregate
replica *count* across nodes. Every volume already had its 3 replicas on 3 distinct control-plane
nodes, so from each volume's view nothing was unbalanced; the empty workers were invisible to it.
Confirmed against longhorn-manager logs. Two other "safe" mechanisms were also ruled out
empirically and **must not be retried** on Longhorn 1.7:

- Patching `replica.spec.evictionRequested=true` directly → the controller silently reverts it to
  `false`; no migration.
- Scaling a volume `numberOfReplicas` `3→4→3` → Longhorn culls the **new worker** replica on the
  way back down, keeping the 3 control-plane copies. Safe, but a no-op for migration.

**What was actually used — delete-and-rebuild, throttled and serialized:** for each of the 21
volumes, delete one replica off the **fullest** control-plane node; Longhorn rebuilds the third
copy on the **emptiest worker**. Guarded by:

- `concurrent-replica-rebuild-per-node-limit` set `5 → 1` for the duration (restored to 5 after),
  so only one rebuild runs per node at a time — the memory/network-spike hedge on the 16 GiB
  workers.
- Serialized one volume at a time, waiting for `robustness=healthy` (3 replicas) before the next.
  Each volume held **≥2 copies throughout** — single-node-failure-safe the entire run; never 1.

~70 GiB of replica data moved over ~30 min. **Final distribution: b3=13, g2=14, r1=13, w1=15,
w2=8** (was 21/19/21/0/2), all 21 volumes healthy. Longhorn returned to `least-effort`.

**Rationale and honest caveat:** the driver was pulling Longhorn replica I/O off the
etcd-member disks (etcd fsync is latency-sensitive; co-locating heavy replica I/O on a single
consumer SSD is a known anti-pattern) and using worker disk capacity. That mechanism is real but
was **not empirically demonstrated** on this cluster (k3s does not expose etcd metrics by default;
no measured fsync regression drove it). The move is low-risk and banks the capacity regardless;
the etcd-offload benefit is taken on principle, not on a measured number. Longhorn placement
favored w1 over w2, leaving a count skew (w1=15 vs w2=8); accepted — both workers carry data and
flattening further is histogram-polishing.

### 4. Implementation notes — W1 and W2 joins (factual, not new decisions)

**W1** joined 2026-06-26 as a **k3s agent** (etcd quorum unchanged at 3, per ADR-030 §1). It was
pointed at a control-plane **node IP** rather than the VIP, because the kube-vip VIP
`192.168.1.200:6443` was found **broken cluster-wide**: `b3` and `g2` had `--bind-address=<node IP>`,
so the apiserver was not listening on the floating VIP. Fixed the same session
(`--bind-address=0.0.0.0`, hardened into `config.yaml`); the agent was then repointed to the VIP.
The kube-vip DaemonSet was also pinned to control-plane nodes — it had no `nodeSelector` and
crashlooped on the worker. The soft taint (`node-role.kubernetes.io/control-plane:PreferNoSchedule`)
is applied to all three control-plane nodes.

**W2** joined 2026-06-27, same agent pattern, via the (now-working) VIP `192.168.1.200`. It came up
on DHCP `.211`/`eno1`, was moved to static `.205`/`eno2`, and both workers carry a MAC→`eno2`
`systemd .link` pin so the predictable-interface-name flip (eno1↔eno2 with BIOS WiFi state) cannot
recur. All five nodes were then kernel-aligned at `6.12.94+deb13` (k8s `v1.35.4`). Both workers are
on the Tailscale tailnet (host-level `tailscaled`).

The `immich-lightroom` `r1` `nodeSelector` unpin (the ADR-030 ↔ ADR-021 amendment) is tracked
separately under ADR-021.

## Consequences

- **The most honest line in the updated design:** single-worker failover is unsupported, and the
  fallback (soft-taint overflow to control-plane) reverses the split under failure. This is a
  resilience downgrade versus what ADR-030 claimed — but ADR-030's claim rested on RAM that does
  not exist. The amendment trades a comforting fiction for an accurate failure model. With W2 now
  live, real degraded-state survivability returns **only if** tier-A requests prove honest and a
  surviving node can hold the working-set — which at 16 GiB it cannot for a *single* survivor.
- **Tier-A as preferred removes the worker `Pending` cliff** at the cost of weaker steering: under
  contention the scheduler *may* leave a tier-A pod on a control-plane node. Required affinity can
  be restored now that two workers exist, once requests are validated honest.
- **Longhorn is rebalanced** (b3=13/g2=14/r1=13/w1=15/w2=8, all healthy); heavy replica I/O is off
  the etcd disks and worker disk capacity is in use. The reduced-redundancy window was bounded to
  one volume at a time at ≥2 copies; it is now closed.
- **The VIP fix is a latent-bug payoff, not scope creep.** The broken `bind-address` would have
  bitten any VIP-dependent client (DR failback, new joins); W1 surfaced it. Hardened into
  `config.yaml` so it survives reboots, and proven by W2 joining through the VIP.
- **Cost note from ADR-030 (+20–40 W always-on) stands** — unaffected by the RAM correction; the
  9500T T-series draw is independent of DIMM capacity.

## Alternatives Considered

**Buy 32 GiB DIMMs to match the original ADR-030 spec:** Rejected for now — re-opens a
hardware-spend decision and blocks onboarding behind a parts order. The split's steady-state
benefit (etcd decoupled from app spikes when both workers are healthy) is real at 16 GiB; only the
degraded-state survivability is lost. If single-worker failover survivability later becomes a hard
requirement, a worker RAM upgrade is the clean path and can be decided then.

**Keep tier-A required and accept `Pending` on worker loss:** Rejected. That strands the exact
contention-heavy AI workloads with no fallback — strictly worse than preferred.

**Longhorn node/disk eviction instead of delete-and-rebuild:** Considered. Node/disk eviction does
build-before-delete (never drops redundancy), but only at whole-node/disk granularity — it would
have drained an entire control-plane node, over-correcting. Delete-and-rebuild gave per-volume
control at the cost of a bounded, serialized ≥2-copy window. Accepted that trade.

---

*Amends: ADR-030 (Dedicated Worker Nodes: Topology Split). Relates to: ADR-021 (Cluster Memory
Management via Pod Placement — the `immich-lightroom` `r1` unpin), ADR-007 (Proxmox ML Node
Architecture).*
