---
date: 2026-05-24
tags: [gitops, helm, argocd, flux, storage, deployments, cka]
---

# GitOps-managed Helm installs (HelmRelease) vs imperative helm install

## Goal

Understand the difference between an imperative `helm install` and a GitOps-managed
`HelmRelease`, and learn what "putting Longhorn into git" actually means and why it
requires care when live PVCs are involved.

## Problem

Longhorn was installed imperatively. The desired state lives only in shell history —
not in git. The question "what is Longhorn into git?" exposed the gap: I knew GitOps
in concept but hadn't applied it to a stateful, storage-layer workload before, and
hadn't thought through the reconciliation risk.

## Solution

### Imperative install (what we have now)

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
helm install longhorn longhorn/longhorn \
  -n longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultReplicaCount=2 \
  --set persistence.defaultClassAnnotation="storageclass.kubernetes.io/is-default-class=true"
```

This works. But the intended state is not stored anywhere reproducible. A cluster
rebuild requires you to find that command (or reconstruct it from `helm get values`).

Inspect what's running now before you write the HelmRelease:

```bash
# See every value that differs from the chart's defaults
helm get values longhorn -n longhorn-system

# Full resolved values (defaults + overrides)
helm get values longhorn -n longhorn-system --all

# What chart version is actually installed?
helm list -n longhorn-system
```

### GitOps / HelmRelease (what "into git" means)

There is no native Kubernetes object for "install this Helm chart." The two common
CRDs that provide this are:

| Tool  | CRD         | API group                      |
|-------|-------------|--------------------------------|
| Flux  | HelmRelease | helm.toolkit.fluxcd.io/v2beta1 |
| ArgoCD | Application | argoproj.io/v1alpha1          |

Neither ships with a vanilla cluster. You install the controller first; it watches
the repo and drives reconciliation.

**Flux HelmRelease example:**

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: longhorn
  namespace: longhorn-system
spec:
  interval: 10m
  chart:
    spec:
      chart: longhorn
      version: "1.6.x"          # pin a minor series
      sourceRef:
        kind: HelmRepository
        name: longhorn
        namespace: flux-system
  values:
    defaultSettings:
      defaultReplicaCount: 2
    persistence:
      defaultClassAnnotation: "storageclass.kubernetes.io/is-default-class=true"
```

**ArgoCD Application (helm source) example:**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.longhorn.io
    chart: longhorn
    targetRevision: 1.6.2
    helm:
      values: |
        defaultSettings:
          defaultReplicaCount: 2
        persistence:
          defaultClassAnnotation: "storageclass.kubernetes.io/is-default-class=true"
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system
  syncPolicy:
    automated:
      selfHeal: true
      prune: true
    syncOptions:
      - CreateNamespace=true
```

Commit either file, push, and the controller owns it from that point on.

### The migration risk (why this is deferred pre-Prague)

The moment the controller takes ownership it will try to make the cluster match
the declared state. If values in the YAML don't exactly match what Helm has
deployed, it re-runs the release — which for Longhorn means touching `StorageClass`,
`Daemonset` on every node, and potentially triggering a rolling restart of the
manager pods while PVCs (Nextcloud, CouchDB, etc.) are in use.

Safe migration checklist:

```bash
# 1. Capture the exact live values
helm get values longhorn -n longhorn-system > longhorn-live-values.yaml

# 2. Snapshot the chart version
helm list -n longhorn-system

# 3. Write the HelmRelease with values that match longhorn-live-values.yaml exactly

# 4. Before handing control over, verify with a dry-run diff
# (ArgoCD: sync with --dry-run flag in the UI or CLI)
argocd app diff longhorn

# Flux equivalent:
helm template longhorn longhorn/longhorn \
  -n longhorn-system \
  -f longhorn-live-values.yaml \
  --version <current-version> | kubectl diff -f -

# 5. If diff is clean, commit and let the controller sync
# 6. Watch rollout immediately:
kubectl rollout status daemonset/longhorn-manager -n longhorn-system
kubectl get pvc -A | grep -v Bound      # anything not Bound is a problem
```

## Why it works

Helm tracks installed releases in Secrets in the target namespace (type
`helm.sh/release.v1`). The GitOps controller uses these same records under the hood —
it calls `helm upgrade` against the existing release, not a fresh `helm install`. That
means it inherits all existing state including PVCs. The risk is not data loss from
the move itself; it's the rolling restart that happens if any value or chart version
diverges from what's installed.

The `helm.sh/release.v1` Secrets are the ground truth for what Helm thinks is
installed:

```bash
kubectl get secret -n longhorn-system -l owner=helm
```

## CKA angle

The CKA exam does not test Flux or ArgoCD directly (those are CKAD/platform
engineering territory), but it tests the underlying primitives heavily:

- **Custom Resource Definitions** — HelmRelease and Application are CRDs. Know how
  to inspect them: `kubectl get crd`, `kubectl explain helmrelease.spec`.
- **Helm imperative commands** — `helm install`, `helm upgrade`, `helm get values`,
  `helm list`, `helm rollback` are all fair game. Know `--dry-run` and `-f values.yaml`.
- **StorageClass and PVC lifecycle** — understanding why a Longhorn upgrade touches
  the storage layer requires knowing that the SC and the PVCs are independent objects;
  deleting/modifying an SC doesn't delete existing PVCs.
- **Reconciliation mental model** — exam questions about "desired state vs actual
  state" are fundamentally this pattern. The controller (whether it's a Deployment
  controller, a HelmRelease controller, or ArgoCD) always drives toward declared
  state. That's the whole model.

Exam shortcut — inspect a Helm release without `helm` installed on the node:

```bash
# The release data is base64-encoded gzip inside the Secret
kubectl get secret -n <ns> -l owner=helm -o jsonpath='{.items[0].data.release}' \
  | base64 -d | base64 -d | gunzip | jq .
```

This surfaces the full rendered manifest even from a node with no `helm` binary.

## Why it matters for storage specifically

Stateless apps (web servers, APIs) can be re-installed from scratch with zero
consequence — the controller just re-deploys. Storage operators are different:
- The operator manages the lifecycle of PVCs it did not create
- A chart upgrade can update CRDs, which are cluster-scoped and affect all namespaces
- A rolling restart of the storage daemonset affects every node simultaneously

This is why "GitOps-ify storage last, after you've done it with stateless apps and
understand exactly how your controller handles drift."

## Revision prompts

1. A colleague says "just run `helm install` on the new cluster — it'll be fine."
   What information is missing, and how do you recover it from the live cluster before
   you can reproduce the install reliably?
2. You've written a HelmRelease for Longhorn and committed it. ArgoCD immediately
   starts a sync. What's the first thing you check to know whether the sync is safe
   vs. about to restart storage pods?
3. What Kubernetes object type stores Helm release state in-cluster, and what
   command lists them?

## Anki

What command shows only the user-supplied overrides for a live Helm release? | helm get values <release> -n <namespace>
What command shows ALL values (defaults + overrides) for a live Helm release? | helm get values <release> -n <namespace> --all
What Secret label does Helm use to store release state in-cluster? | owner=helm (type helm.sh/release.v1)
What kubectl command lists all Helm release Secrets in a namespace? | kubectl get secret -n <ns> -l owner=helm
Kubernetes has no native "install this chart" object — what CRD does Flux use? | HelmRelease (helm.toolkit.fluxcd.io/v2beta1)
Kubernetes has no native "install this chart" object — what CRD does ArgoCD use? | Application (argoproj.io/v1alpha1)
What helm flag previews what would change without actually running the install/upgrade? | --dry-run
Why is migrating a storage operator (e.g. Longhorn) to GitOps riskier than migrating a stateless app? | A chart upgrade can roll the daemonset on every node simultaneously and update cluster-scoped CRDs, affecting all PVCs while they're in use
What helm subcommand rolls back a release to a previous revision? | helm rollback <release> <revision> -n <namespace>
How do you diff what ArgoCD would change before letting it sync? | argocd app diff <app-name>
