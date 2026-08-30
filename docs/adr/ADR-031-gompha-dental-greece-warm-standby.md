# ADR-031 — Gompha (Dental) Greece Warm Standby with In-Region Decryption Key (extends ADR-012)

**Status:** Accepted — verified running 2026-08-31 (published from draft)

> Verified before publishing: all six DR containers up on Greece Unraid
> (`clinic-spa`, `clinic-api`, `clinic-postgres`, `bjj-postgres`, `gompha-n8n`, `minio-dr`).
> This ADR sat as a draft for eight weeks while the system it describes ran in production.
**Date:** 2026-07-06
**Extends:** ADR-012 (Greece warm standby as a Docker/Portainer stack), ADR-011 (backups + offsite replication)

## Context

The Gompha dental product (`dental-clinic` namespace: `clinic-postgres` + `clinic-api` + `clinic-spa`, plus a product n8n) is now semi-production, serving real tenants (`demo`, `blanca`) at `*.gompha.com`. It needs the same disaster-recovery posture as the gym app: an offsite copy of the data and the ability to fail over.

Two facts shaped the design:
1. The gym DR pattern (ADR-012) already exists on `unraid-ptolemaida` (Greece, `100.85.129.88`): stock container images run as a Portainer compose stack, seeded from a Greece MinIO that mirrors Prague hourly.
2. **The dental DB dumps are age-encrypted at rest** (REQ-17), and the age *private* key was, by design, kept off the cluster. A cold offsite copy therefore could not be restored without a manual key-bearing step — which defeats a *warm* standby (instant cutover).

## Decision

Extend the Greece warm-standby pattern to the dental product, and **place the age private key in Greece** (`/mnt/user/appdata/dental-failover/age-key.txt`) so Greece can decrypt and continuously restore.

- **`dental-failover-stack.yml`** — `clinic-postgres` always-on (holds the restored DB); `clinic-api` / `clinic-spa` / product-n8n / `cloudflared` in a `failover` profile (start only on cutover). Network aliases reproduce the Prague k8s short service names so restored data works unedited.
- **`restore-dental-from-minio.sh`** — hourly: pull latest `clinic-backups` dump from Greece MinIO → age-decrypt → `pg_restore` → re-run the idempotent migrate (recreates the `clinic_app` role, which `pg_dump` does not carry). Skips if failover is live; pings a Kuma dead-man's-switch.
- **`gompha-GR`** — a dedicated Cloudflare tunnel in the gompha account for the Greece connector; cutover is a DNS flip of `demo`/`blanca`/`auto.gompha.com` to it.

Both files live in `disaster-recovery/greece/` and mirror the committed gym DR scripts; every secret is a `${ENV}` placeholder (real values in the Greece `.env`, never in git).

## Options considered

- **A — Warm standby, key in Greece (chosen).** Instant-ish cutover (drilled: ~9s DNS-propagation-to-serve; real-outage RTO ≈ 1–2 min, RPO ≈ 1h). Cost: the dental decryption key now exists in a second location. Accepted because (a) Greece already holds the gym's data in plaintext, so this is not a new *class* of exposure, and (b) the user confirmed this will be standard practice for the rest of the apps.
- **B — Cold copy, key stays offline.** Encrypted dumps sit in Greece; restore is a manual DR step requiring the operator to bring the key. Key never leaves the operator, but no instant cutover. Rejected: "live in standby" was the explicit requirement.

## Consequences

- Dental `demo` + `blanca` are restorable and serve from Greece; drilled 2026-07-06.
- The age key now lives in Greece — its compromise exposes clinic data at rest there. Treated as acceptable given the site already holds plaintext family/gym data and is on the tailnet only.
- Same RTO/RPO caveats as ADR-012: hourly mirror = up to ~1h of writes not yet in Greece; cutover is currently manual (no `gompha-failover.sh` yet — a follow-up).
- Source-of-truth note: `postgres.yaml` (and the migrate) are mirrored from the `saas.dental` repo; the DR restore depends on the migrate image staying idempotent.
