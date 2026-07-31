# namo-apps — Namo's application stack (Stefanos's cluster, Namo's domain)

| Host | App | Auth | Notes |
|---|---|---|---|
| `automation.namosocks.com` | **n8n** 2.27.0 | n8n's own owner account — **set it on first visit, immediately** | SQLite on a 5Gi longhorn PVC. Timezone Asia/Baghdad. |
| `go.namosocks.com` | **Shlink** 4.4.6 | none (public by design — short links must resolve for everyone); admin REST API needs the API key | SQLite on a 2Gi PVC. |

Both are published through the CLIENT's Cloudflare tunnel (`ca867f1b`, account e46015da):
k8s Ingress + one proxied CNAME per host -> `<tunnel-uuid>.cfargotunnel.com`. TLS ends at
Cloudflare; the in-cluster hop is plain HTTP, so these Ingresses deliberately have no TLS block.

Secrets: `secrets.sops.yaml` (SOPS/age). ArgoCD does NOT decrypt — apply out-of-band:
    sops -d kubernetes/apps/namo-apps/secrets.sops.yaml | kubectl apply -f -

**Open security item:** neither host sits behind Cloudflare Access yet (that needs Zero Trust
access to the client's account). n8n is protected only by its own login — create the owner account
the moment it comes up, before anyone else finds the URL.
