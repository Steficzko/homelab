# ADR-022 — Unraid as Intentional Shared Service Layer: DNS, NFS, and Backup Target

**Status:** Accepted  
**Date:** 2026-06-07

## Context

The homelab runs a three-node HA K3s cluster alongside a single Unraid CWWK N305 NAS.
A recurring external critique is that Unraid represents a single point of failure: it
serves NFS to four cluster apps, hosts AdGuard Home (split DNS), and runs MinIO (backup
target). If Unraid goes offline, several cluster workloads are affected.

This ADR documents why this is a deliberate, budget-constrained architectural decision
and not an oversight.

**The constraints in force:**

- **One-person homelab, no SLA, no budget for redundant NAS hardware.** A second
  always-on NAS or a replicated DNS cluster is a real cost with no justification at
  this scale.
- **The data that matters is already off-site.** Photo originals (the primary asset)
  live on Unraid Prague and replicate to a second Unraid in Greece via the
  mechanism documented in ADR-005. A Prague Unraid failure is a service interruption,
  not a data loss event.
- **DNS on Unraid is the bootstrap chicken-and-egg.** AdGuard Home handles split DNS
  for `*.kostikidis.net → 192.168.1.200` (the K3s VIP). Moving it into the cluster
  creates a circular dependency: pods need DNS to resolve cluster-internal names, and
  DNS needs the cluster to be healthy to run. Unraid is the correct location for
  the resolver precisely because it is not part of the cluster.
- **MinIO on Unraid is the backup target, not the source of truth.** Backup failure
  when Unraid is offline is acceptable — no live data is lost, and the off-site
  Greece copy provides the DR copy. See ADR-011 for the full backup architecture.

## Decision

Accept Unraid Prague as the shared service layer for DNS, NFS mounts, and backup
target. Treat Unraid availability as a best-effort dependency, not a hard SLA.

### AdGuard Home (DNS)

AdGuard Home runs on Unraid at port 5300 (DNS) and 3080 (web UI). It provides:

- Split-horizon DNS: `*.kostikidis.net → 192.168.1.200` (K3s VIP)
- LAN-wide ad and tracker filtering

**Why it stays on Unraid:** The bootstrap problem is real and unsolvable within the
cluster itself. A CoreDNS override inside K3s would not help clients outside the
cluster (phones, laptops, TV). A second DNS resolver (e.g. a Raspberry Pi or the
router itself) is the correct redundancy mechanism when physical redundancy matters —
deferred until it becomes a real operational problem.

**Accepted risk:** If Unraid goes offline, split DNS fails. Cluster services are
still reachable by IP; external services via Cloudflare Tunnel are unaffected (they
resolve through Cloudflare's public DNS). LAN clients lose the `*.kostikidis.net`
shortcut until Unraid is back.

### NFS for cluster workloads

Four cluster namespaces mount NFS shares from Unraid:

| Namespace | Share | Content |
|-----------|-------|---------|
| immich | /mnt/user/ImmichPhotos | Photo originals (read-only) |
| paperless | /mnt/user/PaperlessData | Document consume paths |
| nextcloud | /mnt/user/NextcloudData | Nextcloud files |
| obsidian-livesync | /mnt/user/ObsidianVault | Obsidian vault |

NFS-mounted volumes are explicitly excluded from the cluster backup scope (ADR-011).
They are protected by Unraid's own replication to Greece (ADR-005).

**Accepted risk:** If Unraid NFS becomes unavailable, pods with NFS mounts will hang
on volume attach. Pods not backed by NFS (databases, cluster-native stateful apps)
continue running unaffected. Recovery is automatic when Unraid NFS comes back — no
manual pod restart required if the NFS mount is configured with `hard` and `nfsvers=4.1`.

### MinIO as backup target

MinIO runs on Unraid at port 9100 and serves as the S3-compatible target for both
Velero (K8s resources) and Longhorn (volume data). Both buckets replicate to the
Greece Unraid, providing an off-site copy.

If Unraid is offline during a scheduled backup window, that backup run is skipped.
The previous successful backup remains the recovery point. This is acceptable given
daily backup frequency and the Greece copy providing a second copy of each snapshot.

## Consequences

**Why this works for a homelab:**

- Unraid CWWK N305 has been consistently reliable. The SPOF risk is theoretical, not
  observed. Uptime across the cluster's lifetime has not featured a Unraid-caused
  incident.
- The assets that cannot be recreated (photo originals, personal documents) are
  protected by off-site replication, not by Unraid's availability.
- The assets that can be recreated (cluster state, manifests) are in Git (ArgoCD)
  and would survive a total Unraid loss.

**What would change this decision:**

- Unraid reliability degrades (multiple unplanned outages per quarter)
- A second always-on node is available at zero incremental cost (e.g. a Raspberry Pi
  for DNS only)
- Budget allows a second NAS for replicated NFS and a HA DNS pair

**What does NOT change this decision:**

- External reviewers pointing out the SPOF. The risk is understood, documented, and
  accepted. The alternative costs money this homelab does not have.

## Alternatives Considered

**Move AdGuard into K3s cluster:** Rejected. Creates a bootstrap DNS dependency that
makes the cluster unable to resolve its own services during startup, and does not serve
LAN clients before the cluster is healthy.

**Longhorn for photo storage:** Rejected. Photo originals are 2–8 TB of append-only
files with no block-storage benefit. NFS from Unraid is the correct tier for large,
infrequently-changing files. Longhorn is for structured, cluster-native stateful data
(databases, app state).

**Secondary NAS for NFS redundancy:** Not yet justified. Would require purchasing and
maintaining additional hardware for a failure mode that has not occurred.

---

*Relates to: ADR-002 (infrastructure split), ADR-005 (Greece DR and Unraid replication), ADR-011 (backup strategy and MinIO architecture).*
