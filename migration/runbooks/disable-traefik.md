# Runbook: Disable Traefik on K3s

**Why:** K3s ships with Traefik as a default ingress controller. We use ingress-nginx instead (ADR-003). Having both running causes svclb-ingress-nginx pods to stay Pending permanently because Traefik's svclb pods already hold ports 80 and 443 on every node.

**When to run:** Once, during initial cluster setup, before deploying ingress-nginx.

---

## Steps

Run on each node **one at a time**. Wait for all nodes to show `Ready` before moving to the next.

### On each node (as root via SSH)

```bash
# Write the K3s config file
cat > /etc/rancher/k3s/config.yaml << 'EOF'
disable:
  - traefik
EOF

# Restart K3s to apply
systemctl restart k3s
```

### Verify between each node restart

```bash
# From your local machine — all 3 should be Ready
kubectl get nodes

# Traefik pods should disappear within ~60s after the last node restarts
kubectl get pods -n kube-system | grep traefik
```

### Final verification

```bash
# svclb-ingress-nginx pods should now be Running (not Pending)
kubectl get pods -n kube-system | grep svclb-ingress-nginx

# Traefik HelmChart should be gone
kubectl get helmchart -n kube-system
```

---

## Notes

- The config file at `/etc/rancher/k3s/config.yaml` is the canonical way to configure K3s. Prefer it over editing the systemd unit so config is easier to track and redeploy.
- For Talos migration: Talos has no K3s, so this runbook is K3s-specific. The equivalent in Talos is simply not installing Traefik in the first place.
