# ADR-012 — Greece Warm Standby as a Docker/Portainer Stack (amends ADR-005)

**Status:** Accepted
**Date:** 2026-06-14
**Amends:** ADR-005 (for the `bjj` + `n8n` application tier)

## Context

ADR-005 specified the Greece DR site as an **identical 3-node k3s cluster** — same IPs, same GitHub repo, ArgoCD syncing the same manifests, with `cloudflared` multi-replica same-tunnel auto-failover. That design assumes Greece runs Kubernetes.

It does not. The Greece site (`unraid-ptolemaida`, `100.85.129.88`) is a **single Unraid server running Docker via Portainer** — no k8s, no ArgoCD, no kube-vip. So ADR-005's "apply the same manifests to an identical passive cluster" mechanism cannot be used for the apps that matter most for the gym/automation (Postgres, n8n, the BJJ site, gotenberg).

What *is* true: the apps are stock container images, and ADR-011 now lands their backups in a Greece MinIO. So Greece can run the same images as a compose stack and restore the same data.

## Decision

Run the BJJ/n8n application tier in Greece as a **docker-compose stack deployed via Portainer** (`bjj-failover`), seeded from the replicated Greece MinIO backups. Active/passive warm standby.

### Image + config parity
Same image tags as Prague (`postgres:16-alpine`, `n8nio/n8n:2.25.1`, `gotenberg/gotenberg:8.21`, `nginx:alpine`). Same `N8N_ENCRYPTION_KEY` and DB credentials (in `/mnt/user/appdata/bjj-failover/.env`, chmod 600) — without the matching key, restored n8n credentials are unreadable.

### Network-alias trick (the load-bearing decision)
The restored n8n credentials/workflows and the nginx `/api` proxy reference **Prague's k8s service FQDNs** (`postgres.bjj.svc.cluster.local`, `n8n-web.n8n.svc.cluster.local`, `gotenberg.n8n.svc.cluster.local`). Each Greece container is given those FQDNs as **Docker network aliases**, so restored data resolves **unchanged** — no rewriting of credentials or workflow JSON. Verified resolving on the `bjj-failover` network.

### Standby posture
`n8n` and `bjj-app` sit in a compose `failover` **profile** → defined but **not started** on standby. This prevents n8n from double-firing schedules/webhooks against shared external state while Prague is live. `restore-from-minio.sh` re-seeds Postgres (`pg_restore`) and n8n (`import:workflow`/`import:credentials`) from the Greece MinIO to keep the standby warm.

### Failover
Run the restore, set Portainer env `COMPOSE_PROFILES=failover` and redeploy (starts n8n + bjj), reactivate workflows, then point Cloudflare at the Greece tunnel. RPO ≈ 1h, RTO ≈ minutes. Documented in `disaster-recovery/greece/FAILOVER.md`.

## Consequences

- A working, validated warm standby exists today (DB restored — 75 members; 49 workflows + 7 credentials imported and decrypting; n8n boots healthy) — far ahead of ADR-005's "pending implementation" passive cluster.
- **Divergence from single-source GitOps (accepted day-2 cost):** Greece is *not* driven by ArgoCD. The compose file lives in the repo (`disaster-recovery/greece/`) and must be **kept version-matched by hand** — bump an image tag or change wiring in Prague and you must mirror it here. Drift is the standing risk.
- **Secret blast radius widened (accepted):** DB creds + `N8N_ENCRYPTION_KEY` now also sit in plaintext in a `.env` on the Greece Unraid. Necessary for failover; it is a second copy of the crown-jewel key in another country. Keep the box patched and access-controlled.
- **ADR-005's auto-failover assumption no longer holds.** Both tunnels are **token/remotely-managed**, so public-hostname routing lives in the Cloudflare Zero Trust dashboard, not in git — and Greece's tunnel currently has no public hostnames pointing at this stack. Failover routing is therefore a deliberate Cloudflare step (dashboard once + optional API automation), not the "Cloudflare routes to healthy replicas within seconds" of ADR-005. Tracked as the next DR task.
- **Workflows import deactivated** → must be reactivated at failover (`n8n update:workflow --all --active=true`). Correct for a standby, but a manual step in the runbook.

## Alternatives Considered

- **Full k3s on the Greece Unraid (honour ADR-005 literally)** — rejected. Heavier to run/operate on a single box; the apps don't need k8s to serve; compose restores the same data faster to stand up.
- **Cold standby (restore only at failover, nothing running)** — rejected. Higher RTO and an untested restore path. Keeping Postgres running + periodically re-seeded makes the restore path continuously exercised.
- **Mirror the whole k8s NetworkPolicy/topology** — rejected. Docker isolates by network membership; the k3s NetworkPolicies (and their kube-router cross-node bug) do not and should not transfer.
