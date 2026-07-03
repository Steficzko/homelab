# Architecture Decision Records

Every non-trivial decision in this cluster is written down here — *what* was
decided, *why*, what was rejected, and what it cost. I keep them current: when a
decision is superseded or an assumption breaks, the ADR gets amended rather than
quietly overwritten. The ones I got wrong are still here on purpose.

> Numbering skips **ADR-018** — it was folded into [ADR-011](ADR-011-application-logical-backups-and-offsite-replication.md).

## Start here (if you only read five)

- **[ADR-030](ADR-030-dedicated-worker-nodes-topology-split.md) + [its amendment](ADR-030-amendment-16gib-workers.md)** — dedicated worker tier instead of a per-node RAM upgrade. The amendment is the one to read: I planned for 32 GB workers, the hardware was 16 GB, so I amended my own decision and documented exactly what that invalidated.
- **[ADR-011](ADR-011-application-logical-backups-and-offsite-replication.md)** — the backup & off-site replication strategy (block + logical layers).
- **[ADR-005](ADR-005-multi-site-dr-architecture.md)** — multi-site DR, active-passive replication to Greece (drilled, ~0 s cutover).
- **[ADR-021](ADR-021-cluster-memory-management-via-pod-placement.md)** — managing memory with pod placement instead of buying hardware (and honestly noting where ADR-030 later superseded it).
- **[ADR-001](ADR-001-gitops-toolchain.md)** — the GitOps toolchain the whole repo rests on.

## Foundations
| ADR | Decision | Status |
|---|---|---|
| [001](ADR-001-gitops-toolchain.md) | GitOps toolchain | Accepted |
| [002](ADR-002-infrastructure-split.md) | Infrastructure split (K3s / Unraid / ML machine) | Accepted |
| [003](ADR-003-networking.md) | Cluster networking stack | Accepted |
| [004](ADR-004-internal-dns.md) | Internal DNS: AdGuard over Pi-hole | Accepted (pending deploy) |
| [006](ADR-006-dev-environment.md) | Dev environment: Debian VM on Unraid + Syncthing | Accepted |

## Networking & security
| ADR | Decision | Status |
|---|---|---|
| [010](ADR-010-cloudflare-zero-trust.md) | Cloudflare Zero Trust: wildcard deny + per-app carve-outs | Accepted |
| [010-amend](ADR-010-amendment-cross-tenant-wpadmin.md) | Cross-tenant CF Access on studioconcreteluka `/wp-admin` | Proposed |
| [025](ADR-025-wordpress-security-model.md) | WordPress security: Tunnel + ZT, not obscurity | Accepted |
| [027](ADR-027-cloudflare-api-credential-model.md) | Scoped, single-purpose Cloudflare API tokens per consumer | Accepted |
| [029](ADR-029-deploy-paperless-n8n-before-zero-trust.md) | Deploy paperless/n8n before ZT: acceptable risk window | Accepted |

## Storage
| ADR | Decision | Status |
|---|---|---|
| [017](ADR-017-shared-nfs-media-library-multi-app.md) | Shared NFS media library, read-only per-app filtering | Accepted |
| [019](ADR-019-storage-evolution.md) | Storage evolution: Longhorn now, Ceph + TrueNAS long-term | Accepted (phases 2-3 pending) |
| [022](ADR-022-unraid-shared-service-layer.md) | Unraid as intentional shared service layer (DNS/NFS/backup) | Accepted |
| [023](ADR-023-nfs-pv-capacity-labels.md) | NFS PV capacity labels are documentation, not enforcement | Accepted |
| [024](ADR-024-pvc-lifecycle-size-once.md) | PVC lifecycle: size once with headroom, treat as immutable | Accepted |

## Immich & media
| ADR | Decision | Status |
|---|---|---|
| [008](ADR-008-multi-instance-immich.md) | Multiple Immich instances, per-instance Access policies | Accepted |
| [016](ADR-016-immich-postgres-filtered-restore.md) | Immich Postgres migration: filtered `pg_restore` | Accepted (deferred) |
| [020](ADR-020-shared-postgres-multi-immich.md) | Shared PostgreSQL pod for all four Immich instances | Accepted |

## AI / ML
| ADR | Decision | Status |
|---|---|---|
| [007](ADR-007-proxmox-ml-node-architecture.md) | Proxmox ML node: GPU inference + CPU transcription split | Accepted |
| [009](ADR-009-litellm-inference-gateway.md) | LiteLLM as unified inference gateway with tiered fallback | Accepted |
| [014](ADR-014-litellm-resilience-gpu-fallback.md) | LiteLLM resilience: circuit-breaker cooldown + GPU fallback | Proposed |
| [015](ADR-015-open-webui-embedding-engine-builtin.md) | Open WebUI embedding engine: switch to built-in | Accepted |
| [028](ADR-028-whisper-stt-litellm-routing.md) | Whisper STT routing via LiteLLM | Draft (unstable) |

## Applications
| ADR | Decision | Status |
|---|---|---|
| [026](ADR-026-bjj-gym-database-architecture.md) | BJJ gym management: PostgreSQL + n8n + nginx proxy | Accepted |
| [013](ADR-013-paperless-drali-isolated-exam-instance.md) | Isolated Paperless-ngx for a client's exam KB | Decommissioned |

## Backups & disaster recovery
| ADR | Decision | Status |
|---|---|---|
| [005](ADR-005-multi-site-dr-architecture.md) | Multi-site DR: active-passive cluster replication | Implemented (amended form) |
| [011](ADR-011-application-logical-backups-and-offsite-replication.md) | Backup & off-site replication (block + logical) | Accepted |
| [012](ADR-012-greece-warm-standby-docker-stack.md) | Greece warm standby as a Docker/Portainer stack | Accepted |
| [012-amend](ADR-012-amendment-drop-app-teamelwany-from-dr.md) | Drop `app.teamelwany.com` from the Greece standby | Proposed |

## Topology & resource management
| ADR | Decision | Status |
|---|---|---|
| [021](ADR-021-cluster-memory-management-via-pod-placement.md) | Memory management via pod placement, not hardware | Accepted (partially superseded by 030) |
| [030](ADR-030-dedicated-worker-nodes-topology-split.md) | Dedicated worker nodes: topology split, not RAM upgrade | Accepted (enacted) |
| [030-amend](ADR-030-amendment-16gib-workers.md) | 16 GiB workers, tier-A → preferred, rebalance enacted | Accepted |
