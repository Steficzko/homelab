# ADR-016 — Immich Postgres Migration: Filtered pg_restore Over Fresh Deploy

**Status:** Accepted — **SHIPPED** (corrected 2026-08-31; this said "deferred" for three months after it was done)

> Verified live: `immich-lightroom` and `redis-lightroom` both 1/1 and 88 days old, serving
> `lightroom.kostikidis.net`. The 298,843-photo professional archive — the highest-stakes data
> move in the fleet — completed and this document went on describing it as an open commitment.
> Same failure as ADR-030 §55: the work shipped and the status line did not follow, so the repo
> under-claimed what its author had actually delivered.

## Context

The Lightroom Immich instance runs in Docker Compose on Unraid. It is being migrated
to Kubernetes as part of the broader service migration to the k3s cluster
(ADR-008). The instance holds 298,843 photos and is the primary professional client
photo archive. Its Postgres database contains:

| Data type | Count |
|-----------|-------|
| Photos and videos | 298,843 |
| Face embeddings (HNSW index) | 574,017 |
| CLIP embeddings (HNSW index) | 274,608 |

The face embeddings are tagged with client names. This metadata is the product of
sustained manual labelling work and cannot be reconstructed programmatically — it
would require manually identifying 574,017 faces from scratch.

**The failed first attempt:**

A naive `pg_restore` into the new Kubernetes Postgres pod succeeded for all tables
except two: `face_search` (face embeddings) and `smart_search` (CLIP embeddings).
Both use `pgvector`'s HNSW index type. During index reconstruction, Postgres loads
all vectors into memory simultaneously to build the HNSW graph. With 574k + 274k
vectors, this exhausted the 12Gi memory limit on the Postgres pod and triggered an
OOMKill from the Kubernetes node. The partial write left the WAL in a corrupt state,
causing Immich to crash-loop on startup.

**Why HNSW index construction OOMKills:**

HNSW (Hierarchical Navigable Small World) graph construction is not a streaming
operation. The algorithm must hold the full vector set in RAM at once while building
the graph edges. There is no batching option in the index build path. At 768
dimensions per CLIP vector and 512 dimensions per face vector, the combined peak
memory exceeds 12 GB. The embeddings themselves — the raw vector data — live in
ordinary table rows in the `COPY` data section of the dump, not in the index. The
index is a lookup structure over data that already exists. It can be dropped and
rebuilt without any data loss.

The fix procedure is documented in `cases/immich-pg-restore-oomkill.md`.

## Decision

**Restore schema and data using a filtered `pg_restore` that skips the HNSW index
creation lines, then let Immich's job queue rebuild the indexes under a controlled
`maintenance_work_mem` budget.**

The specific filter: before restoring, extract `restore.list` from the dump and
remove every entry matching `face_search` or `smart_search` index definitions
(`grep -v "face_search\|smart_search"` applied to the list). Run `pg_restore` with
`--use-list` pointing at the filtered list. All schema, all table data — including
all embedding vectors — restore cleanly. Only the two HNSW indexes are absent.

On first startup, Immich detects the missing indexes and enqueues Smart Search and
Face Detection jobs. These rebuild the HNSW indexes incrementally via Immich's own
job worker, which uses `maintenance_work_mem=256MB`. At 256 MB, Postgres degrades
from the fast single-pass HNSW construction to a slower multi-pass algorithm but
never spikes above the pod's memory limit. Rebuild completes in the background over
several hours; the instance is usable (browseable, uploadable) the entire time.
Smart search and face search return degraded results during the rebuild window.

Kubernetes manifests for the Lightroom instance are committed. The migration is
deferred to after the Prague departure deadline (week of 2026-05-29).

## Alternatives Considered

**Option A — Fresh deploy: empty database, rescan library, re-run all ML jobs.**

Point Immich at the existing NFS library path with a blank Postgres database. Immich
scans the library and rebuilds all metadata from scratch. No OOMKill risk because
the HNSW indexes are built fresh by the job worker with `maintenance_work_mem=256MB`
from the start.

Rejected. This approach loses all data that does not live in image files or their
EXIF metadata:

- Albums and album structure
- Favorites, archived status, custom metadata
- All face assignments — 574,017 embeddings with client names attached

The face name associations are the blocking factor. Client names cannot be
reconstructed from files. The curatorial work is the data. Re-doing it is not a
realistic option.

**Option B — Increase Postgres memory limit to allow full pg_restore.**

Set the Postgres pod's memory limit to 32Gi or higher to give HNSW graph
construction enough headroom to complete in a single pass.

Not adopted as the primary path. The k3s cluster nodes have 32 GB RAM each and
run multiple workloads. Allocating 32Gi to a single Postgres pod during a one-time
migration operation would starve adjacent pods and risk cascading OOMKills across
the node. The filtered restore achieves the same outcome without the cluster-wide
risk. A temporary bump could serve as a fallback if the filtered restore path
encounters an unexpected issue.

## Consequences

**Wins:**

- All user-generated metadata is preserved: albums, favorites, face names, archived
  status. No manual re-labelling.
- The migration is idempotent. If the filtered restore fails, the Postgres PVC can
  be wiped and the procedure repeated without data loss — the source dump is not
  modified.
- The cluster is not destabilised during the migration. Peak memory demand is bounded
  by `maintenance_work_mem=256MB` per index build pass.
- The insight generalises: any `pgvector` HNSW index can be skipped in a restore and
  rebuilt via application-layer jobs, provided the embedding data rows are intact.
  This pattern applies to all four Immich instances (ADR-008) if they are migrated.

**Costs and risks:**

- **Rebuild window degradation.** Smart search and face search return no results or
  incomplete results while the job queue rebuilds indexes. Duration depends on worker
  concurrency and pod CPU allocation; estimate 4–12 hours for 574k + 274k vectors on
  the k3s CPU tier. The instance is fully usable for upload, browse, and share
  during this window.

- **Deferred until after Prague departure.** The manifests are committed; the
  migration has not run. The Docker Compose instance on Unraid remains the live
  system until the procedure executes. Two sources of truth exist for the duration
  of the deferral.

- **Dump currency.** The `pg_dump` used as the restore source was taken at the time
  of the first failed attempt. Photos added after that point are on the NFS volume
  (Immich stores files independently of Postgres) but will not appear in the database
  until Immich's library sync runs post-migration. This is expected and handled by
  the normal startup scan, but the gap should be noted before running the restore so
  new additions are not assumed lost.

- **`cases/immich-pg-restore-oomkill.md` is the runbook.** The step-by-step
  procedure lives there, not here. This ADR records the decision; that file records
  the execution steps.
