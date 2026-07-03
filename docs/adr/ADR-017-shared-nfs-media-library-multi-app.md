# ADR-017 — Shared NFS Media Library: Read-Only Mount with Per-App Type Filtering

**Status:** Accepted

## Context

A single NFS share on Unraid (`192.168.1.100`) holds a mixed dump of personal media
accumulated over time: PDFs, office documents, ebooks (EPUB/MOBI/AZW), and
audiobooks (MP3/M4B/FLAC). Three applications need to serve subsets of this data:

| App | Supported types |
|-----|----------------|
| Paperless-ngx | PDF, common document formats |
| Calibre-Web | EPUB, MOBI, AZW, PDF |
| Audiobookshelf | MP3, M4B, FLAC, OGG |

File types overlap: PDFs are consumed by both Paperless-ngx and Calibre-Web.
Files have accumulated organically over years; the directory structure does not
separate by type. Reorganising thousands of files carries a real risk of loss
and requires a one-time migration window that does not exist.

All three apps are deployed (or will be deployed) on the k3s cluster. NFS mounts
to Unraid at `192.168.1.100` are standard practice in this cluster (ADR-005).
Audiobookshelf is new and not yet committed to the repo.

Constraints:
- Source files must never be moved or deleted by any app
- No one-time migration window is available before the Prague departure deadline
  (week of 2026-05-29)
- Each app must maintain its own metadata, progress, and index state independently
- The pattern must extend cleanly to future apps without data migration

## Decision

**Mount the same NFS share read-only to all three apps. Each app indexes and
serves only its supported file types in-place. Source files are never moved.
Each app's metadata, index, and progress state lives on a dedicated Longhorn PVC.**

### Mount strategy

The NFS share is mounted read-only into each app's pod at a conventional path
(e.g. `/media/library`). Apps that support configurable library paths are pointed
at this mount. Type filtering happens at the application layer — each app ignores
file formats it does not understand.

### Per-app behaviour

**Calibre-Web**
Reads EPUB/MOBI/AZW/PDF directly from the NFS mount. No file movement. Calibre
metadata (`metadata.db`) is stored in a dedicated Longhorn PVC. Calibre-Web
operates in read-only library mode — it browses and serves; it does not import
or reorganise.

**Audiobookshelf**
Reads MP3/M4B/FLAC/OGG directly from the NFS mount. Identifies audiobooks by
directory structure and file metadata. Progress tracking, bookmarks, and the
internal SQLite database are stored on a dedicated Longhorn PVC. Audiobookshelf
is a new addition to the cluster; its Kubernetes manifests are to be committed.

**Paperless-ngx (special case)**
Paperless-ngx's consume pipeline moves files out of its consume folder after
processing. Pointing it directly at the NFS share would cause it to attempt to
delete or relocate source files — this is incompatible with the read-only source
contract.

Workaround: a Kubernetes CronJob copies (not moves) PDFs from the NFS mount to
Paperless's consume PVC at a scheduled interval. Paperless processes from the
consume PVC and stores its own processed copies in its media PVC (on Longhorn).
The NFS originals are never touched. This introduces a scheduled copy step and
a storage duplicate for every PDF, both of which are accepted trade-offs
(see Consequences).

### Storage layout

| App | Source (read-only) | App state (read/write) |
|-----|--------------------|------------------------|
| Calibre-Web | NFS share | Longhorn PVC (`calibre-metadata`) |
| Audiobookshelf | NFS share | Longhorn PVC (`audiobookshelf-data`) |
| Paperless-ngx consume | Longhorn PVC (`paperless-consume`) | — |
| Paperless-ngx media | — | Longhorn PVC (`paperless-media`) |

NFS is the source of truth for raw files. Longhorn PVCs hold app-specific derived
state only.

## Alternatives Considered

**Option A — Reorganise source files into per-app folders before ingestion.**

Move all EPUBs into an `ebooks/` subfolder, all audiobooks into `audiobooks/`,
all documents into `documents/`. Each app gets its own NFS subpath.

Rejected. Reorganising thousands of files is a one-time migration with real risk
of data loss (misidentified types, interrupted transfers, files silently dropped).
There is no migration window before the departure deadline. The upside — cleaner
folder structure — does not justify the risk given that per-app type filtering
achieves the same isolation at zero migration cost.

**Option B (chosen) — Read-only shared mount with per-app type filtering.**

Described in the Decision section above.

## Consequences

**Wins:**

- Source files are never at risk. No app can modify, move, or delete originals.
- Zero migration cost. The existing NFS structure is consumed as-is.
- Adding a new app that serves the same files requires only a new read-only
  `PersistentVolume` / `PersistentVolumeClaim` pointing at the same NFS share — no
  data migration, no coordination with other apps.
- App metadata is independently isolated on per-app Longhorn PVCs. One app's index
  being wiped or rebuilt does not affect the others.
- Consistent with the NFS-first data placement rule established in ADR-005:
  user files live on NFS; Longhorn is for app-layer state.

**Costs and risks:**

- **PDF duplication.** PDFs exist on NFS (original) and on the Paperless media PVC
  (Paperless's processed copy). This is expected and accepted. The NFS copy is the
  canonical original; the Paperless copy is a processed derivative. They serve
  different purposes.

- **CronJob lag.** New PDFs dropped on the NFS share are not available in Paperless
  until the next CronJob run. The copy interval determines the ingestion lag. This
  is acceptable for a personal document archive where near-real-time ingestion is
  not required.

- **Audiobookshelf manifests are not yet committed.** The app is new to the cluster.
  NFS volume, Longhorn PVC, Deployment, and Service manifests need to be written and
  synced via ArgoCD before Audiobookshelf can be used.

- **NFS single point of failure.** All three apps lose their source library if the
  Unraid NFS server is unavailable. App-layer metadata on Longhorn PVCs remains
  intact, but browsing and serving content is degraded until NFS is restored.
  This is an existing cluster-wide constraint (ADR-005), not introduced by this
  decision.
