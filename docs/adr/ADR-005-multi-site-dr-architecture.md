# ADR-005 — Multi-Site DR Architecture: Active-Passive Cluster Replication

## Status
Accepted — pending implementation (after all apps stable + Talos migration)

## Context

The primary cluster runs in Prague. A second Unraid server in Greece already receives
backups from the Prague Unraid. The goal is to extend this into a full cluster-level
DR site: if Prague loses internet connectivity, the Greece cluster takes over serving
all family apps with minimal data loss and no manual DNS changes.

Constraints:
- Greece hardware mirrors Prague (3 nodes, same specs) — minus the ML machine
- Both sites are home networks on identical private subnets (`192.168.1.0/24`)
- The solution must not require per-app changes when failing over
- The solution must not add operational complexity to the primary site

## Decision

**Deploy an identical passive cluster in Greece using the same IPs, the same GitHub
repo, and the same Cloudflare Tunnel.**

### Same IP strategy

Both sites use identical addressing:

| Component | IP |
|-----------|----|
| kube-vip VIP | 192.168.1.200 |
| Node 1 | 192.168.1.201 |
| Node 2 | 192.168.1.202 |
| Node 3 | 192.168.1.203 |
| Unraid | 192.168.1.100 |

All NFS mount paths (`192.168.1.100:/mnt/user/*`) are identical on both sites.
All Kubernetes manifests apply to either cluster without modification.

### GitOps

Both clusters point to the same GitHub repo (`github.com/Steficzko/homelab`).
ArgoCD syncs the same manifests. SOPS Age key is the same — encrypted secrets
decrypt identically on either cluster.

### Cloudflare Tunnel failover

`cloudflared` supports running multiple replicas across independent machines pointing
to the same tunnel. Prague runs 2 replicas; Greece runs 2 more replicas of the
**same tunnel**.

Cloudflare automatically routes incoming traffic to whichever replicas are healthy.
If Prague internet goes down, Cloudflare detects the Prague replicas as unhealthy
and routes all traffic to Greece within seconds. No DNS changes, no manual
intervention required.

### Data replication

User data lives on Unraid NFS, not Longhorn PVCs, wherever the application allows.
The existing Unraid-to-Unraid backup already replicates this data to Greece
continuously. Failover data loss is bounded by the backup interval.

| Data type | Storage | Replicated to Greece |
|-----------|---------|---------------------|
| Nextcloud files | Unraid NFS | ✅ via Unraid backup |
| Immich photo originals | Unraid NFS | ✅ via Unraid backup |
| Paperless documents | Unraid NFS | ✅ via Unraid backup |
| Postgres databases | Longhorn PVC + Velero → NFS | ✅ via Velero backups on NFS |
| CouchDB (Obsidian) | Longhorn PVC + native replication | ✅ CouchDB-to-CouchDB sync |
| App code/config layer | Longhorn PVC | Rebuilt from ArgoCD on failover |

### ML machine

The Proxmox/5950X ML machine is Prague-only. Open WebUI is already configured to
fall back from GPU Ollama to CPU Ollama automatically. Greece cluster runs CPU
inference only — acceptable degradation.

## Design Rules (apply to every future app deployment)

1. **NFS-first for user data.** If an app stores files users care about, mount them
   from Unraid NFS. Longhorn is for app code, caches, and ephemeral state only.

2. **Velero for all databases.** Any Postgres or stateful PVC gets a Velero backup
   job writing to Unraid NFS. This makes database state part of the Unraid replication
   chain automatically.

3. **No Prague-specific values in manifests.** IPs are identical across sites so this
   is automatic. Avoid any hostname or path that only exists in Prague.

4. **No Tailscale subnet router on either site.** Both sites share `192.168.1.0/24`.
   Tailscale routes to individual machine IPs (100.x.x.x) — this works correctly.
   Adding a subnet router for either site creates a routing conflict. Do not do this.

## Consequences

- New app deployments take slightly longer: must decide NFS vs Longhorn consciously
- Velero must be installed and configured (future session)
- CouchDB replication between sites must be configured (future session)
- Greece cluster rebuild is the disaster recovery drill — validates `ROADMAP_restore.md`
- App layer PVCs (code, not data) are rebuilt from ArgoCD on failover — acceptable,
  takes ~10 minutes for all apps to sync and start

## Alternatives Considered

- **Different IPs per site** — rejected. Would require per-site manifest variants or
  Kustomize overlays, adding complexity with no benefit given identical hardware.

- **Longhorn cross-site replication** — rejected. Longhorn supports stretched clusters
  but requires low-latency links between nodes. A Prague-to-Greece WAN link has too
  much latency and is the exact failure mode we're protecting against.

- **Single cluster stretched across both sites** — rejected. Same latency problem.
  A stretched etcd cluster over WAN is an operational hazard, not a safety net.

- **Velero-only (no passive cluster)** — rejected. Restore time from Velero alone
  would be 30–60 minutes. A warm passive cluster with ArgoCD already synced reduces
  this to ~10 minutes for app layer, near-zero for data.
