# Cloudflare Tunnel

Tunnel name: **k3s-cluster**

## What it does

The tunnel creates an outbound-only encrypted connection from the cluster to Cloudflare's edge.
No ports are opened on the router or firewall — the cluster initiates the connection.

Traffic flow: `Cloudflare edge → tunnel → cloudflared pods → ingress-nginx → apps`

## Kubernetes side

- Namespace: `cloudflare-tunnel`
- Deployment: `cloudflared` (2 replicas for HA — one per node, avoids single point of failure)
- Credential: `cloudflare-tunnel-token` secret (encrypted in git as `kubernetes/networking/cloudflared/secret.sops.yaml`)
- Manifests: `kubernetes/networking/cloudflared/deployment.yaml`

## Route configuration

Single route covering all apps:

| Route | Service |
|-------|---------|
| `*.kostikidis.net` | `http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80` |

The route is configured in the Cloudflare dashboard under Zero Trust → Networks → Tunnels → k3s-cluster → Public Hostnames.

## Recreating the tunnel from scratch

1. Go to Cloudflare Zero Trust → Networks → Tunnels → Create tunnel
2. Name it `k3s-cluster`, select Cloudflared connector
3. Copy the tunnel token
4. Decrypt the existing secret, update the token value, re-encrypt:
   ```bash
   sops --decrypt kubernetes/networking/cloudflared/secret.sops.yaml > /tmp/tunnel.yaml
   # edit /tmp/tunnel.yaml with new token
   SOPS_AGE_RECIPIENTS=age1v9pqv93dtdg7zuk2uc423rdtapu9p0fqucd2s9p6curt2c0y2vuq4yzw9n \
     sops --encrypt --encrypted-regex '^(data|stringData)$' \
     --input-type yaml --output-type yaml /tmp/tunnel.yaml \
     > kubernetes/networking/cloudflared/secret.sops.yaml
   rm /tmp/tunnel.yaml
   ```
5. Apply: `sops --decrypt kubernetes/networking/cloudflared/secret.sops.yaml | kubectl apply -f -`
6. Restart: `kubectl rollout restart deployment/cloudflared -n cloudflare-tunnel`
7. Add the wildcard route in the dashboard
