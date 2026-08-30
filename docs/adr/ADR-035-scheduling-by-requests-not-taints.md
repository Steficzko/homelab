# ADR-035 — Scheduling Is Governed by Requests, Not by Taints

**Status:** Proposed
**Date:** 2026-08-30
**Supersedes:** the soft-taint mechanism in ADR-030 §37, §51, §53, §93; ADR-030-amendment §7, §140; and the placement clause in ADR-021's status header.

## Context

ADR-030 split the cluster into control-plane and worker tiers and made a soft
`node-role.kubernetes.io/control-plane:PreferNoSchedule` taint the mechanism that steered
workloads onto the workers. Three ADRs then reasoned about that taint across eleven separate
passages: tier C "rides the soft taint", tier A/B fall back through "soft-taint overflow",
and ADR-021 explicitly handed its pod-placement authority to it ("placement is now steered by
ADR-030's soft taint, not these pins").

**The taint was removed on 2026-08-20 and nothing was written down.**

It was removed for a real reason. `PreferNoSchedule` is binary in practice: with `w1` cordoned
during maintenance, `w2` became the only untainted node in the cluster and absorbed roughly
ninety pods. A mechanism meant to spread load had concentrated it. The taint was replaced by
raising `system-reserved` from 1Gi to 2560Mi on `r1`, `b3` and `g2`, the reasoning being that
workers would then show ~3.6Gi more allocatable memory and `LeastAllocated` scoring would
prefer them — a soft gradient rather than a binary switch.

That reasoning was sound and the outcome was still wrong. Ten days later:

| Node | Memory used | Pods |
|---|---|---|
| `r1` (etcd) | **85%** | 61 |
| `g2` (etcd) | 79% | 46 |
| `b3` (etcd) | 76% | 49 |
| `w1` | 38% | 34 |
| `w2` | 42% | 35 |

The three etcd members carried 156 pods and were the three fullest nodes in the cluster, while
the two machines bought specifically to carry that load sat at under half capacity. A
descheduler had been installed to correct exactly this and had evicted nothing in months.

## Decision

**Placement is governed by resource requests and explicit affinity. Taints are not used to
steer normal workload scheduling.**

Three findings drove this, each verified against the live cluster on 2026-08-30.

### 1. Over-stated CPU requests silently disabled the whole rebalancing mechanism

`whisper` and `ollama` each declared `cpu: "2"`. Measured actual usage: **7m and 1m**. With two
Longhorn instance-managers at 720m each, both workers showed **75% of CPU requested against
9–11% actually used**.

The descheduler's `LowNodeUtilization` strategy only evicts *toward* a node that is under
threshold on **every** resource. At 75% CPU the workers could never qualify, so the descheduler
logged `"No node is underutilized, nothing to do here, you might tune your thresholds further"`
and did nothing — correctly, by its own rules. The scheduler read the same picture and kept
placing new work on the control planes.

Two numbers in two manifests had quietly frozen the cluster's balance. Both are now `250m`.

**CPU requests are floor reservations, not caps.** CPU is compressible: a low request still
bursts to the limit under real load. A request sized for peak usage is a permanent reservation
of capacity nobody is using.

**Memory requests are deliberately left at 4Gi** for both. Those are sized for a loaded model
(`large-v3`, `gemma3:4b`), not for idle, and trimming them to observed idle would invite
OOM-kills under precisely the load they exist to serve. Memory is not compressible; the
asymmetry is intentional.

### 2. A workload with no requests is scheduled by fiction

`argocd-application-controller` — at ~1.35Gi the largest movable pod in the cluster — declares
**no resource requests at all** (BestEffort QoS). The scheduler therefore places it by comparing
*requested* utilisation, where `r1` looked like the emptiest node (42% memory requested) while
actually running at 85%. Restarting it would have returned it to `r1` indefinitely.

A pod with no requests cannot be steered by scoring. It needs explicit affinity, or requests
that tell the truth. It also sits first in line for eviction under node pressure, which is a
poor property for the component that reconciles the entire cluster.

### 3. Preferred affinity is applied at scheduling time only

`preferredDuringSchedulingIgnoredDuringExecution` is evaluated when a pod is *scheduled*. Adding
it to a running workload changes nothing until that pod is replaced, and updating affinity alone
does not always trigger a new ReplicaSet. Adding affinity is **two steps** — the manifest change
and a rollout — and the first step looks like success on its own.

### What was done

- `whisper`, `ollama`: `cpu` request `2` → `250m`.
- ADR-030's `preferred` anti-control-plane affinity added to the workloads that had none:
  all four Immich instances, `grafana`, and (as a live patch, see ADR-036) the ArgoCD
  application controller.

| Node | Before | After |
|---|---|---|
| `r1` (etcd) | 85% | **67%** |
| `g2` | 79% | **66%** |
| `b3` | 76% | **66%** |
| `w1` | 38% | 50% |
| `w2` | 42% | 59% |

## Consequences

**Wins**

- The three etcd members no longer lead the cluster in memory pressure. `r1` fell 18 points.
- Every node now sits in a 50–67% band rather than 38–85%.
- Workers dropped below the descheduler's CPU threshold, so automated rebalancing can function
  for the first time since it was installed.
- The mechanism is now the same one Kubernetes itself reasons with. Requests and affinity are
  visible in `kubectl describe node`; a taint's *absence* is not visible anywhere except as
  behaviour nobody can explain months later.

**Costs and risks**

- Preferred affinity is a hint. Under real pressure pods still land on control planes — which is
  deliberate, and the same fallback property the soft taint was chosen for in ADR-030 §93.
- This depends on requests being honest. ADR-021 documented that they historically were not
  (a phantom 9.8Gi Loki cache request; 12Gi limits against 2–4Gi real usage), and this ADR adds
  two more instances. **Request accuracy is a recurring failure mode in this cluster, not a
  one-off.** It should be audited when a node looks unbalanced, before any other theory.
- `grafana` and the Immich instances now carry affinity in git; the ArgoCD controller's
  equivalent lives in the kustomization introduced by ADR-036. Nothing steers the remaining
  long tail of small pods, which is acceptable — they are not what fills a node.

**Deliberately not done**

- `prometheus` (2.9Gi, the largest single object on `g2`) and `cal` (1Gi on `b3`) hold RWO
  Longhorn volumes, so moving them is a detach/reattach rather than a restart. Moving prometheus
  would take `g2` to roughly 43%, and should be its own maintenance window rather than folded
  into a rebalance — detaching the storage of the thing that watches the cluster deserves
  deliberate scheduling.

## Alternatives Considered

- **Re-add the soft taint.** Rejected. It caused the ninety-pod pile-on that got it removed, and
  it is invisible in the manifests — three ADRs described a mechanism that had not existed for
  ten days, and nothing in the repo could have revealed that.
- **Hard `NoSchedule` taint on the control plane.** Rejected for ADR-030's original reason: with
  two workers it makes the worker tier a single point of failure.
- **Tune the descheduler's thresholds** so the workers qualify as underutilised. Rejected — it
  treats the symptom. The thresholds were reasonable; the requests were lies.
- **Required rather than preferred affinity.** Rejected, consistent with the ADR-030 amendment:
  with two workers, required affinity strands pods as `Pending` when a worker is lost.

## Follow-ups

1. Amend ADR-030, ADR-030-amendment and ADR-021 to reference this ADR instead of the taint.
   ADR-021's header currently delegates placement authority to a mechanism that does not exist,
   which means pod placement has been governed by no accepted decision since 2026-08-20.
2. Correct ADR-030 §55, which still states the tier-A affinity was "never applied to the
   manifests". It was applied, it is in git, and all four tier-A pods run on workers.
3. Give `argocd-application-controller` real resource requests. BestEffort is the wrong QoS class
   for the cluster's reconciler.
