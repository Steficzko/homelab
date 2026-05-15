# ADR-003: Cluster Networking Stack

**Status:** Accepted  
**Date:** 2026-05-15

## Context

K3s ships with Traefik as the default ingress and has no built-in load balancer IP management. The cluster needs a VIP for the control plane API and an ingress controller for HTTP/HTTPS traffic.

## Decision

- **VIP / LoadBalancer:** kube-vip in ARP mode — floats 192.168.1.200 between nodes. Handles both control-plane HA and `LoadBalancer` service IPs.
- **Ingress controller:** ingress-nginx (not Traefik). Installed via Helm.
- **Public traffic:** Cloudflare Tunnel (`cloudflared`) — wildcard route `*.kostikidis.net` → ingress-nginx. No ports open on the router.
- **TLS:** cert-manager with `letsencrypt-prod` ClusterIssuer, Cloudflare DNS-01 challenge. All public ingresses get automatic TLS.
- **CNI:** Flannel (k3s default) — no change needed at this scale.
- **Private/admin access:** Tailscale. Admin tools are never exposed via the Cloudflare Tunnel.

## Consequences

**Not used:**
- Traefik — removed in favour of ingress-nginx for wider ecosystem familiarity and CKA relevance
- MetalLB — kube-vip covers both control-plane HA and LoadBalancer IPs, no need for a separate component

**Ingress conventions:**
- All public ingresses: `cert-manager.io/cluster-issuer: letsencrypt-prod`
- Add `nginx.ingress.kubernetes.io/ssl-redirect: "false"` to avoid redirect loops with Cloudflare
- Add `nginx.ingress.kubernetes.io/proxy-body-size: "0"` for file upload apps (Immich, Nextcloud)
- Private apps: no Ingress resource = not reachable from internet even through wildcard tunnel
