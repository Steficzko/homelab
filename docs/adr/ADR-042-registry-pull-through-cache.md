# ADR-042 — Registry pull-through cache for the cluster

**Status:** PARKED (2026-10-03) — draft kept for later, not to be built now

> **Why parked (same day it was drafted):** both premises were resolved by other means before
> anything was built. Disk pressure → kubelet image GC 70/60 live on all five nodes (CLSTR-23,
> 42c53ee), disks 47–66% free. w1 unable to start plane-minio → its stale kubelet pull record was
> removed (CLSTR-26). What remains is upstream availability for MinIO only, and MinIO is slated for
> replacement. Revisit if a second gated/deleted upstream image appears, or with STOR-32 / the
> Talos+Flux rebuild. If an offline-pull story is wanted, compare option B (Spegel, one k3s flag, no
> Unraid dependency) first. Tracked as CLSTR-27.

**Relates to:** CLSTR-23 (image GC 70/60), CLSTR-26 (w1 pull record), STOR-32 / ADR-041 (dedicated Longhorn disk), STOR-29 (MinIO images gated), ADR-022 (Unraid shared service layer)

## Context

Every node keeps its own containerd image cache on the root disk it shares with Longhorn
(`/var/lib/rancher/k3s/agent/containerd` next to `/var/lib/longhorn`). On 2026-10-02 w2 had 118G of
cached images against 41G of Longhorn data and fired `LonghornNodeDiskNearlyUnschedulable`; on
2026-10-03, after the w1 freeze, g2 crossed the 25% floor. A manual `crictl rmi --prune` freed
~20–35G per node, every time.

Two separate problems share this root:

1. **Cache size.** Kubelet GC at 85/80 never fires before Longhorn's 25%-free floor. CLSTR-23 fixes
   the thresholds, but aggressive GC is only safe if a deleted image can always come back.
2. **Upstream availability.** MinIO gated anonymous pulls on Docker Hub (2026-09-11) and quay.io
   (2026-09-24/10-01). The stopgap — a tar in `agent/images` on all five nodes, pinned — then broke
   on k8s 1.35's kubelet pull records (plane-minio down 5h on 2026-10-02; w1 still cannot start it,
   CLSTR-26). Any image whose upstream disappears is today a one-way delete for GC.

The image cache **cannot** move to an Unraid NFS share: containerd's overlayfs snapshotter needs a
local filesystem for its upper/work dirs, and it would make every container start depend on Unraid.

## Options

| | A. Pull-through cache on Unraid (zot) | B. k3s embedded registry mirror (Spegel) | C. Status quo + GC 70/60 only |
|---|---|---|---|
| Where images come from | Unraid, populated on first pull | other nodes' caches, peer-to-peer | internet |
| Survives upstream deletion/gating | **yes** — copy persists on Unraid | only while some node still has it (GC erodes this) | no |
| New dependency | Unraid for *new pulls* (fallback to upstream if down) | none | none |
| Makes aggressive GC safe | yes | partly | no |
| Effort | one container + `registries.yaml` on 5 nodes | one k3s flag + `registries.yaml` | none beyond CLSTR-23 |

## Decision (proposed)

**A — a zot pull-through cache on Prague Unraid**, plus CLSTR-23's 70/60 thresholds.

- zot rather than `registry:2`: `registry:2` proxies exactly one upstream per instance; zot's `sync`
  extension serves docker.io, ghcr.io, quay.io and others from one instance, on demand.
- Nodes get `/etc/rancher/k3s/registries.yaml` with a `mirrors:` entry per upstream pointing at the
  Unraid zot. k3s keeps the upstream as a fallback endpoint by default, so **Unraid down = pulls go to
  the internet as today; running containers are unaffected** (images already on the node stay).
- Gated images (MinIO server + mc at the pinned digests) are **pushed into zot once** from a node's
  cache — pull-through cannot fetch them any more. This retires the per-node `agent/images` tar.
- Image names in manifests do **not** change (mirrors are transparent), so kubelet pull records and
  digest pins are unaffected.
- Private ghcr images (`ghcr-pull` secrets in dental-clinic, padle, saas-gompha-*, travel) are
  **excluded from the mirror** or served with auth — a cache must not hand private images to anyone
  on the LAN. Default: exclude, pull those direct.

## Consequences

- Each image is downloaded from the internet once for the whole cluster, not once per node.
- GC can be aggressive; a deleted image returns at LAN speed.
- Prague Unraid gains one more role (it already hosts xyOps, Kuma, MinIO) — it is a soft dependency
  only (fallback exists), but zot's storage needs a backup decision (it is a cache: no backup, except
  the hand-pushed gated images, which must be re-creatable — keep their digests here).
- `registries.yaml` is a host file like `k3s-server-config.yaml`: not GitOps-reconciled. Record it in
  `kubernetes/bootstrap/` next to that file. Needs a k3s restart per node — do it in the same window
  as CLSTR-23.
- Network: nodes → Unraid zot port must be allowed (no netpol involved; host-level pulls).

## Open questions

1. Unraid path for zot storage (cache share, not array?) and expected size (~100–150G).
2. TLS: zot on plain HTTP needs `insecure`-style endpoint config in `registries.yaml`, or a cert.
3. Does Greece DR want the same (separate zot there), or pull direct?
4. Revisit once STOR-32 lands — the dedicated Longhorn disk removes the disk-pressure half of the
   problem, but not the upstream-availability half.
