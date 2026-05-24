---
date: 2026-05-22
tags: [storage, postgres, oomkill, pvc, resources, debugging, cka]
---

# Immich pg_restore OOMKill — Vector Index Memory Trap

## Goal

Migrate Immich (298,843 photos, 574,017 face embeddings, 274,608 CLIP embeddings) from Docker Compose to Kubernetes by restoring a pg_dump archive into the K8s Postgres pod.

## Problem

The `pg_restore --section=post-data` phase OOMKills the Postgres container. The post-data section builds indexes after data is loaded. Immich uses pgvecto-rs with HNSW (Hierarchical Navigable Small World) indexes on `face_search` and `smart_search`. HNSW index building loads **all** vectors into memory at once:

- 574,000 face embeddings × 512 dimensions × 4 bytes ≈ 1.1 GB raw vectors
- HNSW graph structure needs several times that working memory
- 12 Gi container limit → OOMKill mid-build

The OOMKill during index building corrupts the Postgres WAL. On restart, Postgres replays WAL → hits the same memory spike → OOMKill again → crash loop. The only escape from the crash loop is wiping the PVC and starting over.

---

## Solution

### The right restore sequence

```bash
# 1. Extract the table of contents from the dump
pg_restore --list dump.pgc > restore.list

# 2. Filter out the HNSW vector index lines (face_search, smart_search)
grep -v "face_search\|smart_search" restore.list > restore-filtered.list

# 3. Restore schema + data only, skipping the vector indexes
pg_restore -d mydb -L restore-filtered.list dump.pgc

# 4. Start Immich — let it run its own DB migrations (it will recreate index DDL)

# 5. Build the vector indexes separately, with reduced maintenance_work_mem
#    so Postgres builds in smaller batches instead of loading everything into RAM
psql -d mydb -c "SET maintenance_work_mem = '256MB';"
# Then trigger index creation via Immich's migration or manually per Immich docs
```

### Key distinction: data vs. index

The face embeddings and CLIP embeddings themselves live in `COPY` statements in the **data section** of the dump — not in the index. The index is a lookup structure over that data. You can always drop and rebuild the index. You cannot rebuild the embeddings without re-running ML inference across every photo (days of GPU time).

When a restore is at risk of OOMKilling, always:
1. Restore schema + data first
2. Skip or defer expensive index builds
3. Let the application rebuild indexes under controlled memory settings

### Identifying the OOMKill

```bash
# Check why the pod restarted
kubectl describe pod <postgres-pod> -n <ns>
# Look for: Last State: Terminated, Reason: OOMKilled, Exit Code: 137

# Check current memory limits
kubectl get pod <postgres-pod> -n <ns> -o jsonpath='{.spec.containers[*].resources}'

# Check node-level OOM killer evidence
kubectl get events -n <ns> --sort-by='.lastTimestamp'
```

Exit code 137 = SIGKILL from the OOM killer (128 + 9).

### Escaping the WAL corruption crash loop

If already in the crash loop:

```bash
# Scale the statefulset to 0 to stop Postgres
kubectl scale statefulset <postgres-sts> -n <ns> --replicas=0

# Delete the PVC (destructive — you lose all data, start restore from scratch)
kubectl delete pvc <postgres-pvc> -n <ns>

# Recreate PVC and restore using the filtered list above
```

There is no recovery from a WAL-corrupted Postgres without the original data files. The filtered restore approach is the only way to avoid reaching this state.

---

## Why it works

HNSW builds its navigable graph by computing distances between all vector pairs. The algorithm needs the full vector set in memory simultaneously to construct the graph layers. PostgreSQL's `maintenance_work_mem` setting controls how much RAM an index build can use. If you build the index in a separate session with a low `maintenance_work_mem`, Postgres falls back to an on-disk merge strategy (slower, but doesn't blow the container limit). The `pg_restore -L` flag lets you pass a filtered TOC (table of contents), which is the clean way to skip specific objects without patching the binary dump.

---

## CKA angle

**Exam domain:** Workloads & Scheduling (resource limits), Storage (PVCs), Troubleshooting.

Key things the exam tests that this incident exercises:

- Reading OOMKill signals: `kubectl describe pod` → `Reason: OOMKilled`, exit code 137
- Understanding container resource limits and requests in pod specs
- PVC lifecycle: creating, deleting, rebinding
- Recovering from a crash-looping pod (identify root cause before restarting blindly)
- `kubectl scale statefulset` for maintenance

**Resource limit snippet (exam pattern):**

```yaml
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "12Gi"
    cpu: "4"
```

**Imperative shortcuts:**

```bash
# Check OOM reason
kubectl describe pod <pod> -n <ns> | grep -A5 "Last State"

# Scale statefulset to 0 for maintenance
kubectl scale statefulset <name> -n <ns> --replicas=0

# Delete a PVC
kubectl delete pvc <name> -n <ns>

# Watch pod restarts live
kubectl get pod <pod> -n <ns> -w
```

---

## Revision prompts

1. A Postgres pod keeps crash-looping with exit code 137. What does that exit code mean, and what kubectl command gives you the clearest signal of an OOMKill?
2. You need to restore a pg_dump but want to skip specific indexes. What two pg_restore flags let you do this cleanly?
3. Why is it safe to skip HNSW vector indexes during a pg_restore, and what do you have to do after the restore to get them back?

---

## Anki

What exit code indicates an OOMKill in a Kubernetes container? | 137 (SIGKILL = 128 + 9, sent by the kernel OOM killer)
What kubectl command shows why a pod's previous container instance was terminated? | kubectl describe pod <pod> — look at "Last State: Terminated, Reason: OOMKilled"
What pg_restore flag lets you supply a filtered table-of-contents file to skip specific objects? | -L <toc-file> (e.g. pg_restore -d mydb -L restore-filtered.list dump.pgc)
What pg_restore flag dumps the TOC of an archive so you can inspect or filter it? | --list (pg_restore --list dump.pgc > restore.list)
What Postgres session setting limits per-index-build RAM so HNSW construction doesn't OOMKill the container? | SET maintenance_work_mem = '256MB';
What is the only escape from a WAL-corrupted Postgres crash loop in Kubernetes? | Scale the StatefulSet to 0, delete the PVC, recreate it, and restore from the original dump
Why is it safe to skip vector indexes during pg_restore? | The embedding data lives in COPY statements (data section); the index is a rebuild-able lookup structure — you lose query performance, not the data
