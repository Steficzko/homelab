---
date: 2026-05-24
tags: [storage, longhorn, helm, kubectl, gitops, configmap, upgrades, cka]
---

# Longhorn: kubectl apply vs helm install, upgrade procedure, and imperative GitOps docs

## Goal

Understand how Longhorn is actually installed (kubectl apply, not helm install),
what that means for tracking and upgrades, how Longhorn replicates data across
nodes, and how to document imperative installs in a GitOps repo without ArgoCD.

## Problem

Four things clicked today as a connected pattern:

1. I didn't know how to tell at runtime whether a workload was installed via
   `helm install` or `kubectl apply` — the commands look the same in the running cluster.
2. Longhorn's upgrade path is non-obvious: re-applying the base manifest silently
   resets the custom settings ConfigMap every time.
3. The resilience model wasn't clear — specifically, what "3 replicas" means for
   failure tolerance vs. what it doesn't protect against.
4. No mental model for keeping imperative installs reproducible in a GitOps repo
   when ArgoCD isn't managing them.

## Solution

### 1. Detecting install method at runtime

Helm stores a `helm.sh/release.v1` Secret in the target namespace, labelled
`owner=helm`, every time `helm install` or `helm upgrade` runs.

```bash
# If this returns results: Helm owns it
kubectl get secret -n longhorn-system -l owner=helm

# If output is empty: it was kubectl apply (or kustomize, or raw manifest)
```

Longhorn ships as `longhorn.yaml` — an all-in-one manifest designed for
`kubectl apply`. This cluster uses the manifest path; no Helm release Secret
exists for Longhorn.

The only footprint `kubectl apply` leaves on objects is the
`kubectl.kubernetes.io/last-applied-configuration` annotation. It records the last
applied body, not who ran it or when.

```bash
# Inspect the last-applied body on any object
kubectl get configmap longhorn-default-setting -n longhorn-system \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
  | jq .
```

### 2. Longhorn upgrade procedure

```bash
# 1. Apply the new base manifest
#    Rolling upgrade — manager pods restart one node at a time, volumes stay online
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/vX.Y.Z/deploy/longhorn.yaml

# 2. Re-apply custom settings immediately after
#    The base manifest resets longhorn-default-setting to empty
kubectl apply -f kubernetes/infrastructure/longhorn/default-setting.yaml

# 3. Watch rollout
kubectl rollout status daemonset/longhorn-manager -n longhorn-system

# 4. Verify PVCs stayed healthy
kubectl get pvc -A | grep -v Bound
```

Always read the Longhorn release notes for the target version before applying —
some upgrades have mandatory pre-flight steps.

### 3. The ConfigMap key name trap

`kubernetes/infrastructure/longhorn/default-setting.yaml` — the key inside
`data:` MUST be named `default-setting.yaml` exactly:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: longhorn-default-setting
  namespace: longhorn-system
data:
  default-setting.yaml: |-       # <-- this key name is mandatory
    priority-class: longhorn-critical
    disable-revision-counter: true
```

Longhorn manager fetches this specific key by name. Any other key name — `config`,
`settings`, `data` — causes the manager to silently fall back to defaults. No
error, no warning.

### 4. Longhorn resilience model

`numberOfReplicas: 3` set in the custom ConfigMap.

| Scenario | Result |
|---|---|
| 1 node fails | Volume degrades to 2/3, stays online; auto-rebuild when node returns |
| 2 nodes fail | Volume degrades to 1/3, stays online |
| All 3 nodes gone simultaneously | Data inaccessible; risk of data loss without external backup |
| Node returns | Longhorn auto-rebuilds the missing replica |

What replicas protect: individual node hardware failure.

What replicas do NOT protect: accidental `kubectl delete pvc`, namespace deletion,
or a bad upgrade corrupting all replicas simultaneously. External backup (Velero)
is required for those scenarios — not yet set up in this cluster.

The ConfigMap in git documents install reproducibility, not data backup. Those are
different concerns.

### 5. GitOps documentation pattern for imperative installs

```
kubernetes/infrastructure/<app>/
  README.md               # exact install command, version, pre/post steps
  default-setting.yaml    # custom settings — committed, re-applied after upgrades
  # no ArgoCD Application object
```

The README captures the exact `kubectl apply -f <url>` command and version. ArgoCD
does not watch this directory. It is install documentation so a cluster rebuild
doesn't require reconstructing from shell history.

## Why it works

`kubectl apply` pushes manifests through the API server with no surrounding
lifecycle context. Helm wraps the same YAML in a release record (Secrets) so it
can track history, upgrade with context, and roll back. Longhorn's manifest path
skips that layer — simpler, but `helm rollback` is unavailable and overrides must
be re-applied manually after each upgrade because the base manifest has no
knowledge of them.

The ConfigMap key-name constraint is standard Kubernetes consumer behavior: the
manager reads a specific key, not the whole map. It's analogous to a process
reading a specific filename — wrong name, finds nothing.

## CKA angle

Exam domains: Storage, Application Lifecycle Management, Cluster Maintenance.

Key commands:

```bash
# Verify Helm owns a namespace
kubectl get secret -n <ns> -l owner=helm

# Monitor a DaemonSet rolling update
kubectl rollout status daemonset/<name> -n <ns>
kubectl rollout history daemonset/<name> -n <ns>
kubectl rollout undo daemonset/<name> -n <ns>

# Create ConfigMap with explicit key name (exam speed)
kubectl create configmap my-cm --from-file=default-setting.yaml=./local-settings.yaml

# Check PVC health cluster-wide
kubectl get pvc -A | grep -v Bound
```

On the exam: if a ConfigMap consumer silently ignores your config, verify the key
name before anything else. The value may be correct but the key name wrong.

DaemonSet rollout commands follow the same pattern as Deployments — `rollout
status`, `rollout history`, `rollout undo` all work on DaemonSets.

## Revision prompts

1. You `kubectl apply` a new Longhorn base manifest for an upgrade. Your custom
   priority class and replica count disappear from the UI five minutes later. What
   happened and how do you fix it without touching the UI?

2. A colleague says "Longhorn has 3 replicas, so we don't need backups." Name one
   failure scenario replicas do not protect against.

3. You need to determine whether `monitoring-stack` was deployed via `helm install`
   or `kubectl apply`. What single command answers this?
