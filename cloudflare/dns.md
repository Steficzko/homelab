# Cloudflare DNS Records

Zone: **kostikidis.net**

## Active records

| Type | Name | Target | Proxied | Purpose |
|------|------|--------|---------|---------|
| CNAME | `*` | `<tunnel-id>.cfargotunnel.com` | Yes | Wildcard → K3s cluster via tunnel |

> The wildcard CNAME is created automatically by `cloudflared` when the tunnel is provisioned.
> All subdomains (`nextcloud.*`, `argocd.*`, etc.) resolve through it — no individual DNS records needed.

## How routing works

```
Browser → *.kostikidis.net
  → Cloudflare CDN (proxied, TLS terminated)
  → Cloudflare Tunnel (k3s-cluster)
  → cloudflared pods (cloudflare-tunnel namespace, 2 replicas)
  → ingress-nginx service (ingress-nginx namespace)
  → app Ingress → app Service → app Pod
```

TLS between the browser and Cloudflare is managed by Cloudflare.
TLS between Cloudflare and the tunnel uses the tunnel credential (cloudflare-tunnel-token secret).
TLS between ingress-nginx and apps is terminated at nginx (cert-manager issues the certs but they're used for nginx→pod, not exposed externally).

## Adding a new subdomain

No DNS change needed. Just create a Kubernetes Ingress with `host: <name>.kostikidis.net` and the wildcard picks it up automatically.
