# ADR-020 — Shared PostgreSQL Pod for All Four Immich Instances

**Status:** Accepted
**Date:** 2026-06-03

## Context

Four Immich instances are being deployed on the cluster: `lightroom`, `marianna`, `stefanos`, and `team-elwany`. Each instance requires PostgreSQL with the `pgvecto-rs` extension (`tensorchord/pgvecto-rs:pg16-v0.3.0`) for face recognition and CLIP embedding storage via HNSW vector search.

`pgvecto-rs` requires `shared_preload_libraries=vectors.so`. This is a server-level PostgreSQL setting — it is not configurable per-database. Every Postgres instance that runs any Immich database must load this extension at startup.

The cluster runs on three Lenovo M910q nodes with limited RAM. Longhorn provides the storage layer. All four instances share a single Immich ML container for inference.

The question was whether to run one shared Postgres pod with four databases, or four separate Postgres pods each serving one Immich instance.

## Decision

Run a single PostgreSQL pod (`tensorchord/pgvecto-rs:pg16-v0.3.0`) with four databases:

| Database | Immich instance |
|---|---|
| `immich_lightroom` | lightroom |
| `immich_marianna` | marianna |
| `immich_stefanos` | stefanos |
| `immich_elwany` | team-elwany |

Each Immich deployment connects to its own database via a dedicated Kubernetes Secret. The databases share no schemas, no tables, and no connection pools. Migrations, failures, and backups are independent at the database level.

One Longhorn PVC backs the pod. One backup job covers all four databases. Each database can be extracted independently with `pg_dump -d <dbname>` and migrated to a dedicated pod without touching the others.

## Consequences

**Wins:**

- `pgvecto-rs` loaded once at the server level covers all four instances with no duplication.
- 1 pod, 1 PVC, 1 readiness probe, 1 backup job instead of 4× each. Simpler ArgoCD Application graph and fewer Longhorn volumes to track for backup.
- Database-level isolation is preserved — Immich migrations run per-database, a corrupt or locked DB does not block other instances.
- Clean escape hatch: `pg_dump -d immich_<name>` produces a self-contained dump. Any single instance can be moved to its own pod at any time without touching the others.
- RAM savings are meaningful on M910q hardware. Four separate Postgres pods each carry `shared_buffers`, WAL writer, background workers, and `pgvecto-rs` worker overhead.

**Costs and risks:**

- **Shared fate point.** A bad upgrade, OOMKill, or node eviction takes all four Immich instances offline simultaneously. Risk is accepted: the same event would hit all four separate pods too (same image, same upgrade window). Blast-radius difference is minimal in practice.
- **Single Longhorn PVC.** If the volume is lost or corrupted, all four databases are affected. Mitigation: daily Longhorn backup to MinIO with off-site replication.
- **No process-level isolation.** A runaway query can consume shared Postgres resources. Acceptable: four trusted users, low concurrency, not a multi-tenant workload.
- **Superuser access grants access to all four databases.** Acceptable under the homelab threat model.

## Alternatives Considered

**Four separate PostgreSQL pods:** Rejected. `pgvecto-rs` must load at the server level regardless — no isolation benefit specific to the extension. Four pods means 4× RAM, 4× PVCs, 4× ArgoCD resources, 4× backup jobs, with no meaningful blast-radius reduction. A Postgres version upgrade touches all four pods simultaneously in either architecture.
