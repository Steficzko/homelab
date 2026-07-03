# ADR-019 — Storage Evolution: Longhorn Now, Ceph + TrueNAS Scale Long-Term, Unraid to Archival Role

**Status:** Accepted — pending implementation (Phases 2 and 3)

## Context

This ADR records a multi-phase storage strategy, not a single point-in-time decision.
It captures the current state, the rationale for treating that state as transitional,
and the target architecture. Each phase is a distinct decision gate; later phases depend
on hardware availability and cluster growth.

### Current state (Phase 1 — active)

Storage is split across two tiers:

| Tier | System | What it holds |
|------|--------|---------------|
| Block (in-cluster) | Longhorn v1.7.0 on k3s, 3× Lenovo M910q NVMe | App state, databases, caches — 3 replicas per volume |
| File (NFS) | Unraid Prague (`192.168.1.100`) | Immich photo library, Paperless consume, media shares |

Longhorn was installed via `kubectl apply`, not Helm. Each M910q contributes local NVMe
at `/var/lib/longhorn/`. A second Unraid server (a Beelink mini PC running Unraid with
2TB HDDs and an M.2-to-SATA adapter) is currently held at another location and is not
in active use.

### Why the current state is transitional

Longhorn on NVMe is the right fit for the current cluster size and budget. It is not
the right fit for large media volumes or a mixed-disk future:

- NVMe capacity per node is small. Photo libraries and media archives cannot move off
  NFS onto Longhorn without hitting capacity limits.
- NVMe storage is tied to node lifecycle. There is no independent capacity tier.
- The 2TB HDDs in the Beelink represent a natural capacity tier that Longhorn cannot
  serve — Longhorn is a performance tier, not a capacity tier.
- Unraid Prague is always-on to serve active NFS. A full Unraid tower at idle is a
  poor fit for persistent, low-load roles once better-suited hardware is available.

## Decision

Adopt a three-phase storage evolution:

### Phase 1 — Current (Longhorn + Unraid Prague NFS)

No change. Longhorn handles in-cluster block storage. Unraid Prague serves NFS.
This phase ends when the Beelink returns and is repurposed.

### Phase 2 — Near-term (Beelink becomes dedicated media storage node; Unraid steps back)

Triggered by: Beelink mini PC returns from Iraq.

1. **Beelink repurposed as TrueNAS Scale node for photos and home media.** ZFS pool
   on M.2 drives. TrueNAS Scale provides NFS exports specifically for the Immich photo
   libraries (all instances) and the home media stack. This is a scoped role — not a
   general-purpose NFS replacement for all cluster workloads.

2. **Unraid Prague steps back to replication and archival.** No longer always-on.
   Runs on a scheduled power-on window for replication jobs and archival access.
   Receives replicated data from MinIO Prague and other sources. Cold storage for
   documents and data not in active cluster use.

3. **2TB HDDs from Beelink move into k3s cluster nodes.** Staged as future Ceph OSDs.
   Phase 2 ends with the HDDs physically installed; Ceph deployment is Phase 3.

4. **MinIO backup target migrates to TrueNAS Scale.** Velero and Longhorn backup
   targets currently point to MinIO on Unraid Prague (see ADR-011). This migration
   must complete before Unraid Prague changes to scheduled operation. It is a hard
   sequencing gate — see Consequences.

### Phase 3 — Medium-term (Ceph on cluster; new worker nodes)

Triggered by: stronger worker nodes added to the cluster, HDDs in place from Phase 2.

1. **Rook-Ceph deployed on k3s cluster.** 2TB HDDs serve as Ceph OSDs. Ceph becomes
   the capacity tier for large persistent volumes — media archives, Paperless, any
   workload too large for NVMe Longhorn.

2. **Longhorn retained for NVMe-backed volumes.** Databases, caches, and
   latency-sensitive workloads stay on Longhorn. The two systems coexist:
   Longhorn = performance tier, Ceph = capacity tier.

3. **New stronger worker nodes added.** Dedicated to homehosting workloads (Coolify
   or Dokku — self-hosted Vercel/Netlify alternative). Ceph storage shared across
   the full cluster including these nodes.

4. **Beelink TrueNAS Scale remains as the photo and home media NFS tier.** Does not
   replace Ceph; serves a different access pattern (NFS mounts for media stack).

### Storage tier map (Phase 3 target)

| Tier | System | Use |
|------|--------|-----|
| Performance block | Longhorn (NVMe) | Databases, caches, app state |
| Capacity block | Rook-Ceph (HDD OSDs) | Large PVCs, archives |
| Media / photo NFS | TrueNAS Scale Beelink (M.2 ZFS) | Immich libraries, home media stack |
| Archival / replication | Unraid Prague (HDD) | Cold storage, DR replication, on/off schedule |

## Consequences

**Wins:**

- Phase 2 eliminates always-on Unraid Prague idle power cost for active storage.
  A full tower serving active NFS is replaced by a low-power Beelink with ZFS.
- ZFS checksums protect the photo archive (15 years of Nikon D850 RAWs) from silent
  bit-rot on every read — a step up from Unraid's parity-only model.
- Photo libraries and home media get their own dedicated I/O surface — no contention
  with cluster databases or app workloads.
- Rook-Ceph fits the GitOps model. Its configuration lives in the repo as a
  Kubernetes operator alongside everything else.
- Longhorn and Ceph coexistence means no single storage system is forced to serve
  both latency-sensitive and capacity-heavy use cases.
- Unraid Prague does not disappear — it shifts to a role better matched to its
  hardware profile: cold storage and replication.

**Costs and open risks:**

- **MinIO migration is a hard sequencing gate.** Velero and Longhorn backup targets
  point to MinIO on Unraid Prague. If Unraid Prague goes to scheduled operation
  before MinIO is live on TrueNAS Scale and Velero is reconfigured and tested, backup
  jobs fail silently during every off-window. Phase 2 is not complete until this
  migration is verified end-to-end.
- **NFS path convention must be preserved.** ADR-005 relies on consistent NFS mount
  paths. TrueNAS Scale must export at the same paths as Unraid, or every manifest
  referencing NFS mounts requires a coordinated update.
- **Rook-Ceph operational complexity.** Ceph is significantly more complex to operate
  than Longhorn. OSD management, CRUSH maps, and failure recovery require Ceph
  familiarity. Appropriate at Phase 3 scale; premature at current cluster size.
- **HDD tier is slower than NVMe.** Only appropriate for media libraries and archives
  — not databases or caches.
- **Phase 3 depends on hardware not yet procured.** Ceph topology depends on new
  worker node specs. Cannot be finalised until those nodes are known.
- **Beelink M.2-to-SATA adapter is non-standard.** Validate drive health and adapter
  stability before treating it as production photo storage.
- **DR gap on photo originals.** ADR-005's Unraid-to-Unraid replication currently
  covers Immich photo originals. Once they move to TrueNAS Scale, a TrueNAS
  replication job to the Greece site must be configured before the Beelink node
  is treated as production-ready for the Lightroom instance.

## Alternatives Considered

**Longhorn only (no Ceph, no TrueNAS Scale):** Rejected for Phase 3. Longhorn cannot
efficiently serve a mixed NVMe + HDD cluster. No meaningful capacity tier without Ceph.

**Keep Unraid Prague always-on permanently:** Rejected. Power cost of a full tower at
idle is not justified once a low-power TrueNAS Scale node is available. Unraid's
strengths map better to cold storage and replication than always-on active NFS.

**TrueNAS Scale for everything:** Rejected. TrueNAS Scale is not a Kubernetes-native
storage operator. It does not provide PVC lifecycle management, CSI driver behaviour,
or snapshot integration that Longhorn and Rook-Ceph provide natively.

**GlusterFS instead of Ceph:** Rejected. No maintained Kubernetes operator comparable
to Rook-Ceph. Rook-Ceph is the standard and integrates with the GitOps model.

**Migrate to Talos + Rook-Ceph immediately:** Rejected as premature. Ceph deployment
should follow a Talos migration, not precede it — doing both simultaneously on live
nodes increases blast radius unnecessarily.

---

*Relates to: ADR-002 (infrastructure split), ADR-005 (DR architecture and NFS-first
design rules), ADR-007 (ML node — separate from cluster storage), ADR-011 (backup
strategy — MinIO target migration is a Phase 2 gate)*
