---
date: 2026-05-23
tags: [argocd, gitops, networking, services, endpoints, configmap, debugging, cka]
---

# ArgoCD remote tracking, manual Endpoints, debug pods, ConfigMap restarts

## Goal

Wire up a service to an external host, verify connectivity from inside the cluster, and push a config change — all inside a GitOps-managed namespace.

## Problem

Four separate friction points hit in the same session:

1. `kubectl apply` changes were silently overwritten by ArgoCD sync because ArgoCD tracks the **remote** git ref, not the local working tree.
2. Needed to route a ClusterIP Service to an off-cluster IP (`192.168.1.225`) with no pod backing it.
3. No easy way to test whether a URL was reachable from inside the target namespace without deploying a real pod.
4. Updated a ConfigMap but the app kept reading stale values — no restart happened automatically.

## Solution

### 1. GitOps: commit AND push before ArgoCD sees the change

ArgoCD polls (or receives a webhook from) the **remote** repository. A local `git commit` that hasn't been pushed does nothing. The cycle is:

```bash
# 1. Edit the manifest
vim k8s/apps/myapp/deployment.yaml

# 2. Commit locally
git add k8s/apps/myapp/deployment.yaml
git commit -m "chore: update myapp config"

# 3. Push — this is when ArgoCD can act
git push origin main

# 4. Force an immediate sync instead of waiting for the poll interval
kubectl annotate application -n argocd <app-name> \
  argocd.argoproj.io/refresh=hard
```

The annotation triggers a hard refresh: ArgoCD re-fetches from the remote and queues a sync. Without the push, the annotation does nothing useful — there's nothing new on the remote to fetch.

Any `kubectl apply` or `kubectl patch` to a resource in an ArgoCD-managed namespace will be overwritten on the next sync cycle. See also: `argocd-selfheal-maintenance.md` for the case where selfHeal is fighting you.

### 2. Service with no pod selector (manual Endpoints)

To route cluster traffic to an external host, create a headless-style ClusterIP Service with **no selector**, then create a matching Endpoints object manually:

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-external-svc
  namespace: myapp
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: 8080
  # no selector field — Kubernetes will not auto-populate Endpoints
---
# endpoints.yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: my-external-svc   # must match Service name exactly
  namespace: myapp
subsets:
  - addresses:
      - ip: 192.168.1.225  # external host
    ports:
      - port: 8080
```

Verify the Service is actually routing to the right address:

```bash
kubectl get endpoints my-external-svc -n myapp
# NAME               ENDPOINTS           AGE
# my-external-svc    192.168.1.225:8080  2m
```

If the Endpoints object is missing or empty, the Service will return `connection refused` — all traffic silently dropped.

### 3. Ephemeral debug pod for in-cluster connectivity testing

```bash
kubectl run test-curl \
  --image=curlimages/curl \
  --rm -it \
  --restart=Never \
  -n myapp \
  -- curl http://my-external-svc:8080/health
```

Flags:
- `--rm` — deletes the pod on exit
- `-it` — interactive TTY so you see the response inline
- `--restart=Never` — makes it a bare Pod, not a Deployment
- `-n myapp` — runs in the same namespace so DNS resolution uses the same search domain

For a quick shell instead:

```bash
kubectl run debug \
  --image=busybox \
  --rm -it \
  --restart=Never \
  -n myapp \
  -- sh
```

Exam shortcut: `curlimages/curl` for HTTP probes, `busybox` for DNS/TCP, `nicolaka/netshoot` for full network tooling.

### 4. ConfigMap change requires explicit rollout restart

If an app reads a ConfigMap at **startup** (env vars or files loaded once at init time), updating the ConfigMap has zero effect on running pods. The pods must be restarted:

```bash
# Update the ConfigMap (in git, commit+push for GitOps)
kubectl edit configmap myapp-config -n myapp   # or apply from file

# Force a rolling restart — new pods pick up the new ConfigMap values
kubectl rollout restart deployment/myapp -n myapp

# Watch the rollout complete
kubectl rollout status deployment/myapp -n myapp
```

ConfigMaps mounted as volumes **can** update live (kubelet syncs them), but there is a lag (default sync period ~1 min) and the app must re-read the file — most apps do not. Treat an explicit restart as always required unless you know the app watches for file changes.

## Why it works

**ArgoCD remote tracking:** ArgoCD's Application spec contains a `repoURL` + `targetRevision`. It resolves that revision against the remote, not the local clone. The local working tree is irrelevant to ArgoCD — it never sees it.

**Manual Endpoints:** Kubernetes Services normally auto-create Endpoints by selecting pods via `spec.selector`. With no selector, the auto-population is skipped, and the Endpoints object becomes a static routing table you control. The Service name and Endpoints name must match; kube-proxy reads both together to build its iptables/IPVS rules.

**Ephemeral pods:** Running a pod in the same namespace as the target service means the pod uses that namespace's DNS search domain (`svc.cluster.local`). It also sees the same NetworkPolicy rules, so a successful curl from there is real evidence the path is open.

**ConfigMap volume vs. env:** Env vars and `envFrom` are set at container start and never re-read. Volume-mounted ConfigMaps are synced by the kubelet but the app still has to re-read the file. Neither is guaranteed to update a live pod without a restart.

## CKA angle

**Exam domains:** Services & Networking, Workloads & Scheduling, Application Lifecycle Management.

Key exam tasks this maps to:

- Creating Services of different types and verifying Endpoints (`kubectl get ep`)
- Troubleshooting connectivity by spinning up a test pod
- Performing rolling restarts and checking rollout status
- Understanding when a ConfigMap change requires a pod restart

**Imperative shortcuts for the exam:**

```bash
# Create a ConfigMap from literal values quickly
kubectl create configmap myapp-config \
  --from-literal=DB_HOST=postgres \
  --from-literal=LOG_LEVEL=info \
  -n myapp

# Check rollout history
kubectl rollout history deployment/myapp -n myapp

# Undo a rollout if the new config was wrong
kubectl rollout undo deployment/myapp -n myapp

# Get endpoints for any service
kubectl get endpoints -n myapp
# or short form
kubectl get ep -n myapp

# One-liner connectivity test (no TTY needed for scripted checks)
kubectl run test-curl --image=curlimages/curl --rm --restart=Never -n myapp \
  -- curl -s http://my-external-svc:8080/health
```

**Declarative pattern for manual Endpoints:** Always commit both `Service` and `Endpoints` objects together. If only the Service exists without a matching Endpoints, `kubectl get ep` shows `<none>` and all traffic drops silently — easy exam trap.

## Revision prompts

1. You push a manifest change to git but ArgoCD still shows the old version 10 minutes later. What are two possible causes, and what command forces a re-fetch?
2. You create a ClusterIP Service but `kubectl get endpoints` shows `<none>`. Name two reasons this happens and one is specific to the no-selector pattern.
3. You update a ConfigMap that supplies env vars to a Deployment. What must you do for the running pods to use the new values, and why doesn't an edit alone suffice?

## Anki

ArgoCD tracks remote git, not local — what does this mean for a commit that hasn't been pushed? | ArgoCD never sees it; the change has no effect until pushed to the remote branch
What annotation forces ArgoCD to immediately re-fetch from remote git and re-sync? | kubectl annotate application -n argocd <app> argocd.argoproj.io/refresh=hard
How do you route a Kubernetes ClusterIP Service to an external IP with no backing pods? | Create the Service with no selector field, then create a matching Endpoints object with the external IP
What must match exactly between a manually-created Endpoints object and its Service? | The metadata.name and namespace — kube-proxy joins them by name
What kubectl command verifies a Service is actually routing to the expected IPs? | kubectl get endpoints -n <ns> (or kubectl get ep -n <ns>)
How do you spin up a throwaway curl pod in a specific namespace? | kubectl run test-curl --image=curlimages/curl --rm -it --restart=Never -n <ns> -- curl <url>
Why must you run a debug pod in the same namespace as the target Service? | To use the correct DNS search domain and face the same NetworkPolicy rules — otherwise the test doesn't reflect real conditions
After updating a ConfigMap used as env vars, what must you do for running pods to see the change? | kubectl rollout restart deployment/<name> -n <ns>
Why don't ConfigMap changes propagate automatically to pods using envFrom? | Env vars are resolved once at container start; the kubelet never re-injects them into a running process
What kubectl command checks the status of a rolling restart in progress? | kubectl rollout status deployment/<name> -n <ns>
