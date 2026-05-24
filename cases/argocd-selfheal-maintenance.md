---
date: 2026-05-22
tags: [argocd, gitops, sync, maintenance, deployments, cka]
---

# ArgoCD selfHeal defeating kubectl apply during maintenance

## Goal

Scale down the Immich deployment to zero replicas for a database restore, and keep it at zero long enough to complete the maintenance window.

## Problem

Every `kubectl scale deployment immich-server --replicas=0` was reverted by ArgoCD within ~3 minutes. The Application has `selfHeal: true`, so any drift from the git state triggers an automatic sync that puts the replica count back to whatever the manifest says. Attempts to patch the Application resource directly also failed — the Application itself is managed by the parent App of Apps (bootstrap app), which immediately reverted those patches too.

This is the correct behaviour of ArgoCD. The problem is knowing what layer to operate at.

---

## Solution

### Correct approach for maintenance windows

The only layer ArgoCD cannot override is git. The fix:

1. In the bootstrap Application manifest (the App of Apps), temporarily disable automated sync for the child Application:

```yaml
# In the bootstrap/app-of-apps Application spec, find the child app entry
# or directly in the child Application manifest in git:
spec:
  syncPolicy:
    automated:
      selfHeal: false   # was true
      prune: false      # disable prune too during maintenance
```

2. Commit and push to the git repo.

3. ArgoCD detects the change to its own Application spec, applies it, and disables selfHeal.

4. Now `kubectl scale` changes stick.

5. Perform the maintenance.

6. Re-enable in git:

```yaml
spec:
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
```

7. Commit and push. Sync resumes.

### Wrong approaches and why they fail

| Attempt | Why it fails |
|---|---|
| `kubectl scale deployment immich-server --replicas=0` | ArgoCD detects drift from git within ~3 min, reverts |
| `kubectl patch application immich -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'` | The Application object itself is owned by the App of Apps, which reverts any direct patch |
| Suspending the ArgoCD Application via the UI | The App of Apps will re-enable it if its manifest says otherwise |

### Faster alternative: ArgoCD CLI

If git round-trip is too slow, the ArgoCD CLI can suspend sync directly (but only works if the App of Apps doesn't immediately override it — use with caution in nested setups):

```bash
argocd app set immich --sync-policy none
# do maintenance
argocd app set immich --sync-policy automated
```

For a proper App of Apps setup, always go through git.

---

## Why it works

ArgoCD's control loop continuously compares live cluster state against the desired state in git. `selfHeal: true` means any deviation — regardless of cause — triggers an immediate sync to restore git state. The Application CR itself is a Kubernetes object. If that CR is also managed by a parent ArgoCD Application (App of Apps pattern), then patching it directly is itself a deviation from the parent's desired state, and the parent reverts it.

The only authoritative source is git. Changing git changes what ArgoCD considers desired state — which is the one change ArgoCD will apply rather than revert.

**App of Apps pattern:** A single "bootstrap" ArgoCD Application watches a directory of other Application manifests in git. It manages the child Applications as if they were any other Kubernetes resource. This gives you a declarative, git-driven way to manage all your applications — but it means you must go through git to change any application's configuration.

---

## CKA angle

**Exam domain:** Cluster Maintenance, Workloads & Scheduling.

The CKA exam itself doesn't test ArgoCD directly, but this incident maps to several exam concepts:

- Understanding declarative vs. imperative management — the exam heavily favours `kubectl apply -f` over imperative commands where state matters long-term
- `kubectl scale` for quick replica changes during maintenance
- Knowing when `kubectl edit` / `kubectl patch` is appropriate vs. when a controller will override it (Deployments, ReplicaSets — same principle: a higher-level controller reconciles back)
- Disabling a controller's reconciliation temporarily (analogous to pausing a HorizontalPodAutoscaler or putting a node into maintenance with `kubectl cordon`)

**Relevant exam patterns:**

```bash
# Cordon a node so no new pods schedule there (maintenance without changing git)
kubectl cordon <node>
kubectl uncordon <node>

# Pause a HPA (exam equivalent of "stop the controller from fighting you")
kubectl patch hpa <name> -n <ns> -p '{"spec":{"minReplicas":0,"maxReplicas":0}}'

# Check what's managing a pod (if you scale a deployment and it bounces back,
# something is reconciling it — find the owner)
kubectl get pod <pod> -n <ns> -o jsonpath='{.metadata.ownerReferences}'
```

**Key mental model:** In Kubernetes, any resource managed by a controller will be reconciled back to the controller's desired state. Always identify the top-level controller before trying to make a manual change stick.

---

## Revision prompts

1. You `kubectl scale deployment foo --replicas=0` and 3 minutes later the pod is back. Name two possible causes (one K8s-native, one ArgoCD-specific).
2. In an App of Apps ArgoCD setup, why does patching a child Application directly not work when selfHeal is enabled?
3. What is the one layer in a GitOps setup that ArgoCD cannot override, and why?

---

## Anki

What ArgoCD sync policy field causes it to revert any manual kubectl change within minutes? | syncPolicy.automated.selfHeal: true
In an App of Apps ArgoCD setup, why does patching a child Application directly fail when selfHeal is on? | The parent App of Apps also has selfHeal on and immediately reverts the child Application to its git state
What is the correct way to disable ArgoCD selfHeal for a maintenance window in an App of Apps setup? | Edit the Application manifest in git to set selfHeal: false, commit and push — ArgoCD applies the change to itself
What kubectl command temporarily stops a node from receiving new pod scheduling? | kubectl cordon <node>
What kubectl command re-enables scheduling on a previously cordoned node? | kubectl uncordon <node>
How do you identify what controller owns a pod (so you know what to stop before manual changes stick)? | kubectl get pod <pod> -o jsonpath='{.metadata.ownerReferences}'
What exit code signals SIGKILL from the Linux OOM killer? | 137 (128 + signal 9)
