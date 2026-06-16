# ADR-026 — BJJ Gym Management: PostgreSQL + n8n + nginx Proxy Stack

**Status:** Accepted
**Date:** 2026-06-09

## Context

Team Elwany needed a web app for coaches to track class attendance and manage a gym
ledger. The app is accessed from coaches' phones — small-screen browsers, no dedicated
client installation, no technical admin on-site.

The cluster already had several components relevant to this decision:

- PostgreSQL running in multiple namespaces (`immich`, `nextcloud`, `paperless-drali`),
  establishing it as the standard on-cluster database engine.
- n8n running at `auto.kostikidis.net` with a native PostgreSQL node and built-in
  webhook endpoints — a ready API substrate that required no new code.
- Longhorn providing block storage with daily backup labels already in use across the
  cluster.
- Cloudflare Tunnel providing the public ingress path without open router ports (ADR-003).

The core access problem: browser clients running on coaches' phones cannot reach
in-cluster services directly. n8n webhooks listen on an internal service. Some routing
layer was needed between the public internet and the n8n internal service.

## Decision

Deploy a dedicated stack in a new `bjj` namespace:

1. **PostgreSQL** — dedicated instance with a Longhorn PVC labelled for daily backup.
   Stores attendance records and the gym ledger.
2. **n8n webhooks as the API layer** — attendance writes, ledger entries, and reads are
   implemented as n8n webhook workflows that query or write to Postgres directly via
   the native Postgres node. No separate API server is written.
3. **nginx pod as reverse proxy and static host** — serves the static HTML/JS frontend
   and proxies `/api/*` requests to the n8n internal service. This is the only component
   reachable from the public ingress path.
4. **Cloudflare Tunnel → ingress-nginx → nginx pod** — exposes `app.teamelwany.com`
   via the existing tunnel. The n8n service is never exposed publicly; all external
   traffic enters through the nginx pod.

### Traffic path

```
Coach's phone (browser)
  → app.teamelwany.com (Cloudflare Tunnel)
    → ingress-nginx (K3s cluster)
      → nginx pod (static files + /api/* proxy)
        → n8n internal service (webhook handlers)
          → PostgreSQL (bjj namespace)
```

### Why PostgreSQL, not PocketBase or MySQL

PostgreSQL is already the cluster standard. Introducing PocketBase would add a second
database engine with its own backup tooling, upgrade path, and operational model.
PocketBase also has no native n8n integration; bridging it would require HTTP nodes
and custom auth handling that the native Postgres node avoids entirely.

MySQL was not considered. There is no existing MySQL instance on the cluster, no
tooling calibrated for it, and no capability gap that would justify introducing it.

### Why n8n as the API layer

n8n is already running and authenticated. The native PostgreSQL node executes
parameterised queries without writing any server code. Webhook endpoints are versioned
and can be updated through the n8n UI without a code deploy. For a small internal app
serving a handful of coaches, a purpose-built API server would introduce build, test,
and deployment overhead that n8n eliminates.

### Why the nginx proxy pattern

n8n's webhook service is internal to the cluster. Exposing it directly via ingress
would put the n8n UI and all other workflows behind the same public hostname as the BJJ
app — a blast radius problem. The nginx pod creates a clean separation: it is the only
surface exposed to the internet, it serves only the BJJ frontend and proxies only
`/api/*`, and n8n stays internal. This also means no API auth headers need to be
managed at the client — the nginx pod is the sole caller of the internal service.

### Why a dedicated namespace

The existing Postgres instances (`immich-db`, `nextcloud-db`, `paperless-db-drali`)
each run in isolation per app. Sharing one of those instances with the BJJ app would
couple backup schedules, upgrade windows, and failure domains across unrelated
applications. A dedicated `bjj` namespace keeps BJJ data and operations independent of
personal-use apps.

## Consequences

**Wins:**

- Zero new components introduced to the cluster. PostgreSQL, n8n, nginx, Longhorn, and
  Cloudflare Tunnel are all already in production. Operational familiarity is immediate.
- n8n handles the API without a custom server. Coaches' workflows can be modified
  through the n8n UI — no code deployment required for logic changes.
- Backup is handled by the existing Longhorn daily backup policy. No new backup
  tooling or schedule to manage.
- The nginx pod is the only publicly reachable surface. n8n's full workflow and UI
  surface stays internal, consistent with the principle that n8n is not a public API
  server.
- Namespace isolation means a BJJ data incident (corrupt PVC, failed migration) cannot
  affect Immich, Nextcloud, or any other app's database.

**Costs and risks:**

- **n8n is now load-bearing for two separate purposes.** It was previously a personal
  automation tool; it is now also the API layer for a third-party-facing application.
  An n8n crash or misconfiguration takes down the BJJ app's write path, not just
  personal workflows. No replica is configured. Mitigate by keeping n8n updated and
  monitoring via Uptime Kuma.
- **nginx proxy config is a hidden coupling point.** If n8n's internal service name
  or port changes, the nginx proxy config breaks silently until someone notices 502s.
  Document the dependency; add an Uptime Kuma check on `app.teamelwany.com/api/health`.
- **No authentication on the BJJ app itself.** If `app.teamelwany.com` is outside the
  Cloudflare Zero Trust wildcard deny scope, attendance and ledger endpoints are open
  to anyone with the URL. Must be resolved before coaches use it with real data.
- **PostgreSQL instance is unmonitored.** A silent storage failure or PVC exhaustion
  would go undetected until queries start failing. Add a Longhorn capacity alert and
  an Uptime Kuma probe.

## Alternatives Considered

**PocketBase as the full stack (DB + API + UI):** Rejected. PocketBase is a
self-contained tool with its own auth, API, and admin UI. Here, n8n and PostgreSQL are
already present and operational. Adopting PocketBase would add a second runtime, second
backup target, and a tool with no other presence in the cluster for marginal gain.

**MySQL:** Rejected. No existing MySQL footprint on the cluster. No capability that
PostgreSQL lacks for this workload.

**Expose n8n webhooks directly via ingress (no nginx proxy):** Rejected. n8n's ingress
hostname hosts personal automation workflows. The nginx proxy keeps concerns cleanly
separated and limits the public attack surface to a static file server and a single
`/api/*` proxy path.

**Shared PostgreSQL instance (reuse an existing app's DB):** Rejected. Sharing a
database instance across applications with different audiences and failure tolerances
creates hidden operational coupling. The cost of an additional PostgreSQL pod is low;
the cost of a coupled failure is high.

---

*Relates to: ADR-003 (Cloudflare Tunnel), ADR-008 (namespace isolation pattern),
ADR-010 (Cloudflare Zero Trust — BJJ app must be addressed in a ZT carve-out session)*
