# ADR-012 Amendment — Drop `app.teamelwany.com` from the Greece Warm Standby

**Status:** Proposed (amendment to committed ADR-012)
**Date:** 2026-06-17

> This amends ADR-012 (Greece Warm-Standby Docker Stack). It does not reverse that decision —
> the warm-standby architecture stands. It narrows the **scope** of what the standby protects.

## Context

ADR-012 built the Greece warm standby to fail over two cluster apps: the n8n automation
(`auto.kostikidis.net`) and the BJJ coach app (`app.teamelwany.com`), the latter via a
`bjj-app` nginx container fronting a restored Postgres + n8n.

Verified 2026-06-17, `app.teamelwany.com` is **not a live product** — it serves only a
placeholder shell (title "Elwany Staff", an `<h1>TEAM ELWANY</h1>`, literal "placeholder" in
the markup), and the n8n workflows behind its `/api/` were never built. The **real coaches
application lives on Dreamhost at `teamelwany.com/coach`** (a ~157 KB WordPress page), entirely
outside the cluster and outside this DR design. The cluster `app.teamelwany.com` was a
work-in-progress that has not become the product.

Standing up and DNS-flipping a placeholder during failover adds risk and moving parts for zero
recovery value. It also caused a near-miss: the failback path carried a stale Prague tunnel id
and a dead hardcoded DNS record id for `app.teamelwany.com`, either of which could have written
bad DNS for a hostname we don't actually need to protect.

## Decision

**Remove `app.teamelwany.com` from the Greece DR entirely.** The warm standby now protects only
`auto.kostikidis.net` (n8n).

Concretely (commit `f54ad13`):
- `failover.sh` / `failback.sh` — dropped the `app.teamelwany.com` DNS flip and the
  `teamelwany.com` zone handling. They now flip only `auto.kostikidis.net`.
- `cutover-test.sh` — dropped the app verify, the Greece `bjj:8088` origin check, and the
  dryrun/cleanup references. Verify now checks `auto.kostikidis.net` + the Greece n8n origin.
- `failover-stack.yml` — removed the `bjj-app` nginx container and its tunnel ingress. The
  Greece stack now runs postgres + gotenberg + n8n + cloudflared.

Note: `bjj` Postgres remains in the failover stack (n8n depends on it); this amendment does not
re-decide whether the BJJ ledger data itself is worth replicating — only that the
`app.teamelwany.com` *frontend/hostname* is out of DR.

## Consequences

- DR has fewer moving parts and no placeholder in the failover path; the cutover drill is
  simpler and verifies only something real.
- If/when a real coaches app is built **in-cluster** (rather than on Dreamhost), it must be
  explicitly re-added to the DR scope — it will not be covered by default.
- The Dreamhost coaches site (`teamelwany.com/coach`) is covered by Dreamhost's own hosting, not
  this DR. That is an accepted external dependency, not a gap this design owns.

---

*Amends: ADR-012 (Greece warm-standby Docker stack). Relates to: ADR-005 (multi-site DR), ADR-011 (backup & off-site replication).*
