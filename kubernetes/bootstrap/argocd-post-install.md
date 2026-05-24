# ArgoCD post-install steps

Steps to run after deploying ArgoCD — not managed by ArgoCD itself.

## 1. ApplicationSet CRD (required)

The ApplicationSet CRD is missing from the default ArgoCD install manifest and
must be applied manually. Without it, `argocd-applicationset-controller` crashes
on startup.

```bash
# --server-side required: CRD is too large for the kubectl.kubernetes.io/last-applied-configuration annotation limit
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.2/manifests/crds/applicationset-crd.yaml
```

Verify the controller is healthy:

```bash
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller
kubectl rollout status deployment/argocd-applicationset-controller -n argocd
```

> Update the version tag to match the installed ArgoCD version when upgrading.

## 2. Rotate admin password

The initial `argocd-initial-admin-secret` is auto-generated and must be replaced.

Wait for argocd-server to be fully up first:

```bash
kubectl rollout status deployment/argocd-server -n argocd
```

Then login and rotate. If the ingress is not yet live, use port-forward:

```bash
# via ingress (normal)
argocd login <argocd-host> --username admin --password $(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)

# via port-forward (fallback if ingress not ready)
kubectl port-forward svc/argocd-server -n argocd 8080:443
argocd login localhost:8080 --insecure --username admin --password $(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)
```

```bash
argocd account update-password
kubectl delete secret argocd-initial-admin-secret -n argocd --ignore-not-found
```
