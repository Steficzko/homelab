# ADR-041 — Longhorn HDD tier for secondary data; databases stay on the SSD tier

- **Status:** Draft (2026-10-02) — decided, not yet built (disks go in during the rack migration)
- **Deciders:** Stefanos
- **Supersedes (in part):** ADR-019 Phase 2 step 3 / Phase 3 — "HDDs in cluster nodes become
  Ceph OSDs" and the rejection of a Longhorn-only mixed NVMe+HDD cluster
- **Relates to:** ADR-030 + amendment (worker topology; its 2026-10-02 update says the 2 TB disk is
  for W1 only — corrected here: all five nodes), ADR-005 (NFS-first for user data)
- **Tracked in:** Plane STOR-32 (prerequisites), STOR-33 (Nextcloud/Paperless offsite gap)

## Context

Five 2.5" Seagate Barracuda 2 TB drives, one per k3s node, go into the empty 2.5" SATA bay of each
ThinkCentre M920q during the rack migration (full cluster shutdown, 10" 9U rack, 3D-printed
mounts). Today every node has exactly one 238.5 GB NVMe shared by the OS, containerd, logs and all
Longhorn data, and that tier is over-committed (1.08 TB scheduled against 0.84 TB schedulable;
`LonghornNodeSchedulingCeiling` has fired on r1/g2/b3).

ADR-019 planned HDDs in cluster nodes as Rook-Ceph OSDs after a Talos migration. These five drives
are a separate purchase that ADR-019 never mentions, and Ceph is not on the near-term path.

The drives are **SMR**: fine for sequential writes and archival reads, bad at sustained random
writes. A Longhorn replica rebuild is a sustained write.

## Decision

**Longhorn, not Ceph, manages the HDDs — as a secondary-data tier only.**

1. **SSD (NVMe) Longhorn tier keeps everything write-heavy:** every database (Postgres, MariaDB,
   SQLite-backed apps), Prometheus/Loki, queues, caches, and anything latency-sensitive.
2. **HDD Longhorn tier takes secondary data only:** documents, notes, archives, media-like bulk —
   write-once / read-mostly volumes.
3. **Enforced by tags, not convention** (from STOR-32), all before the first HDD becomes a Longhorn disk:
   - tag the existing NVMe disks `ssd` and the new disks `hdd` — an untagged disk accepts every replica;
   - add `diskSelector: ssd` to the existing `longhorn` StorageClass so no current volume can land on HDD;
   - add a second StorageClass (`longhorn-hdd`, `diskSelector: hdd`, `numberOfReplicas: 2`);
     only volumes explicitly created on it use the HDDs.
4. **2 replicas on the HDD tier**, 3 stays the default on SSD. Offsite backup covers the third copy;
   2 replicas halves SMR rebuild traffic.

## Consequences

- Databases stay on SSD by **rule**, not by "it's the only disk there is".
- The NVMe tier gets room back only if existing bulk volumes are *moved* to the HDD class — new
  volumes alone don't relieve it. Which volumes move is a follow-up, volume by volume.
- An HDD-tier node reboot means slow, SMR-bound rebuilds; volumes there stay degraded longer.
  Acceptable for secondary data, unacceptable for databases — which is why the split exists.
- Ceph stays a possible Phase-3 future (ADR-019) on different hardware; nothing here blocks it,
  but these disks are not reserved for it.
- STOR-33 (Nextcloud/Paperless files have no offsite copy) is independent and should not wait.

## Alternatives considered

- **Ceph on these disks (ADR-019 as written):** rejected for now — needs Talos first per ADR-019
  itself, far heavier to operate, and 5 SMR HDDs are a poor OSD set.
- **Untagged HDDs added to the default pool:** rejected — replicas of Postgres would land on SMR.
- **3 replicas on HDD:** rejected — triples SMR rebuild load for data that is offsite-backed.
