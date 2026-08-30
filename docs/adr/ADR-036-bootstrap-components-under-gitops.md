# ADR-036 — The Bootstrap Layer Manages Itself: ArgoCD and Longhorn Under GitOps

**Status:** Proposed
**Date:** 2026-08-30
**Related:** ADR-001 (GitOps toolchain), ADR-019 (storage evolution), ADR-035 (scheduling)

## Context

This repository is a GitOps portfolio. Its premise is that the cluster's desired state lives in
git and ArgoCD reconciles it. Two components were exceptions, and they were the two that matter
most:

- **ArgoCD** deployed everything except ArgoCD. It was applied by hand from upstream
  `install.yaml`. There was no Application pointing at it, and its StatefulSet carried only a
  `kubectl.kubernetes.io/last-applied-configuration` annotation.
- **Longhorn** holds every PersistentVolumeClaim in the cluster. It was installed the same way
  and upgraded by hand — v1.7.0 to v1.12.1 across five rungs on 2026-08-27. The only way to
  learn which version was deployed was to read a running pod.

This is a normal bootstrap pattern and not, by itself, a mistake: something has to install the
installer. The problem is what it costs over time.

**The concrete failure that prompted this.** On 2026-08-30 the ArgoCD application controller —
at ~1.35Gi the largest movable pod in the cluster — was moved off `r1`, an etcd member sitting at
85% memory (ADR-035). Because ArgoCD was not in git, that change was a live `kubectl patch`. It
existed in exactly one place: the running cluster. A reinstall or upgrade from upstream manifests
would have silently reverted it, the controller would have returned to an etcd node, and nothing
in the repo would have recorded that it ever moved or why.

The same argument applies with more force to Longhorn. A hand-managed storage layer means the
component whose failure loses *data* — rather than merely reconciliation — is the one with no
change history, no reviewable upgrade, and no record of intent.

## Decision

**Bootstrap components are managed by ArgoCD like everything else, using a kustomize remote base
pinned to the version already running, with automated pruning disabled.**

```
kubernetes/bootstrap/argocd/kustomization.yaml    -> upstream install.yaml @ v3.4.2  + affinity patch
kubernetes/bootstrap/longhorn/kustomization.yaml  -> upstream longhorn.yaml @ v1.12.1
kubernetes/bootstrap/apps/{argocd,longhorn}.yaml  -> the Applications, picked up by the root app
```

Three properties make this safe, and each was chosen deliberately.

### 1. Pin the base to the version already running

The base is upstream's manifest at the exact deployed tag, so the **first sync is a no-op rather
than a rewrite**. A self-managing component that adopts a *different* version on its first
reconcile is rewriting its own deployment while serving — for ArgoCD that means it may restart
mid-sync; for Longhorn it means the storage layer changes underneath attached volumes.

This was verified before committing, not after, with `kubectl kustomize . | kubectl diff -f -`:

- **ArgoCD:** six RoleBindings gaining an explicit subject `namespace`. Semantically identical;
  settles after one sync.
- **Longhorn:** one ConfigMap, six lines — quote style, the v1.12.1 format for
  `disable-revision-counter`, and a stale `app.kubernetes.io/version: v1.7.0` label that the
  manual upgrade had left behind. That stale label is itself the argument for this ADR: a
  hand-run upgrade updated the workloads and forgot the metadata, and nothing could have shown it.

### 2. `prune: false` — against the convention everywhere else in this repo

Every other Application here prunes. These two must not, for different reasons:

- **ArgoCD** would be able to delete its own controller and its CRDs. The CRDs going takes all 53
  Applications with it, and it cannot recover itself afterwards.
- **Longhorn** is worse. Everything in `longhorn-system` that is *not* in the upstream manifest is
  runtime state: 49 `Volume` CRs with their `Replica`s and `Engine`s, the `Setting`s (this cluster
  customises engine-upgrade concurrency, replica-auto-balance and overprovisioning), and the
  ServiceMonitor NetworkPolicy owned by `monitoring/extras`. Pruning would not merely remove
  config — it would delete the storage layer's own bookkeeping, which is the map to the data on
  disk.

Removing a component of either system is rare and deserves a deliberate manual step.

### 3. `selfHeal: true`

This is what makes the exercise worth anything. It is the mechanism that keeps the ArgoCD
controller's node affinity from decaying back into an undocumented live patch. Verified safe for
Longhorn: the upstream manifest contains **no `Setting` CRs**, so runtime settings are never
reconciled against it.

`ServerSideApply=true` is required for both — the CRDs in each manifest exceed the client-side
`last-applied-configuration` annotation limit.

## Consequences

**Wins**

- The deployed version of both components is now a line in git with a commit message explaining
  it, rather than a fact you learn by reading a pod.
- Upgrades become a tag bump with a reviewable diff and a revert path, instead of an undocumented
  `kubectl apply` against a URL.
- Changes to bootstrap components survive reinstalls. The specific change that motivated this —
  keeping the ArgoCD controller off an etcd node — is now durable.
- Verified non-disruptive: after both syncs, 53/53 Applications Healthy, all 7 ArgoCD pods
  Running with 0 restarts, and all 49 Longhorn volumes `attached`/`healthy`.

**Costs and risks**

- **Self-management deadlock is real.** ArgoCD cannot fix ArgoCD, and Longhorn cannot fix
  Longhorn. If a bad version wedges either, recovery is a manual apply of a known-good tag. That
  command is written into a comment in both the kustomization and the Application, because the
  moment you need it is the moment you cannot look it up in the UI.
- **Longhorn does not support skipping minor versions.** The tag must be bumped one rung at a
  time with volume health confirmed between each. This is recorded in the file; automation must
  not treat it as an ordinary image bump. Renovate should be kept away from that tag.
- **A remote base means the build depends on GitHub reachability** from the repo-server. An
  outage makes the app unsyncable, though not unhealthy.
- Two Applications now deviate from the repo's prune convention. That inconsistency is
  deliberate and documented, but it is a thing a reader must be told rather than infer.

**Deliberately not done**

- `k3s` itself remains outside GitOps and should. It is the substrate ArgoCD runs on; there is no
  coherent way for a workload to own its own kubelet. Its configuration lives in
  `/etc/rancher/k3s/config.yaml` on each node and in `kubernetes/bootstrap/k3s-server-config.yaml`
  as reference.

## Alternatives Considered

- **Leave both hand-managed.** Rejected — this is the status quo whose cost is documented above:
  a live patch that only the cluster knows about, and a storage layer whose version is
  undiscoverable from the repo.
- **Use the official Helm charts instead of the upstream manifests.** Rejected for both. Neither
  component was installed by Helm (`helm list` is empty in both namespaces), so a chart-based
  Application would show large drift against the running install and could destroy and recreate
  components on first sync. The manifest base matches what is actually deployed, byte for byte.
- **Vendor the upstream manifests into this repo** rather than referencing them remotely.
  Rejected for now: it removes the GitHub dependency but adds ~3,000 lines of vendored YAML per
  component and makes the diff of an upgrade unreadable. Worth revisiting if remote-base fetches
  ever become a reliability problem.
- **`prune: true` with `ignoreDifferences` covering the runtime CRs.** Rejected. It relies on an
  exclusion list being exhaustive forever; the failure mode if it is not is deleting Volume CRs.
  The asymmetry of that bet is unacceptable for storage.

## Follow-ups

1. `argocd-application-controller` still declares **no resource requests** (BestEffort QoS). It is
   the cluster's reconciler and is first in line for eviction under node pressure. Now that the
   StatefulSet is in git, this is a one-line fix — see ADR-035 follow-up 3.
2. ~~Consider the same treatment for `cert-manager` and `ingress-nginx`.~~ **Checked 2026-08-30:
   both already have ArgoCD Applications backed by their official Helm charts and both report
   Synced.** ArgoCD and Longhorn were the only two bootstrap components outside GitOps, and the
   gap is now closed. Recorded because "we should check the others" is the kind of follow-up that
   quietly becomes a permanent open item when nobody writes down that it was checked.
