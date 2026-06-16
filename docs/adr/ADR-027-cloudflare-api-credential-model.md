# ADR-027 — Cloudflare API Token Model: Scoped, Single-Purpose Tokens per Consumer

**Status:** Accepted
**Date:** 2026-06-16

## Context

The homelab depends on the Cloudflare API from more than one place:

- **cert-manager** solves ACME DNS-01 challenges (writes `_acme-challenge` TXT records)
  to issue Let's Encrypt certs for cluster ingress hostnames.
- **Disaster-recovery automation** (the Greece warm-standby failover/failback scripts,
  ADR-005 / ADR-012) rewrites DNS records to cut traffic over to the standby site.

Both need `Zone → DNS → Edit`. The question was whether to issue **one shared token**
for everything, or **one token per consumer**. Two related facts had to be pinned down
first, because earlier assumptions about them were wrong:

1. **Account topology.** `kostikidis.net` and `teamelwany.com` are **both in the same
   Cloudflare account** (`Kostikidis.network@gmail.com's Account`). The `martuniawork`
   org is the **Zero-Trust / Access** org (ADR-010) — a *separate* construct from the DNS
   account. A token issued in the kostikidis account can be scoped to either or both zones;
   it does **not** need a second account.

2. **Permission naming trap.** Cloudflare's token editor lists both **`DNS`** and
   **`DNS Settings`** under the Zone group. Only the bare **`DNS`** permission grants access
   to DNS *records*. `DNS Settings` controls zone-level toggles (DNSSEC etc.) and silently
   does **not** authorize the records API — a token built with it returns
   `Authentication error (10000)` on `/dns_records`.

A third event forced the issue: the DR token had been created **with an expiry**, and it
lapsed on 2026-06-15, silently disabling DR until noticed.

## Decision

**One scoped, single-purpose API token per consumer. Tokens are never shared across
consumers, and automation tokens carry no expiry.**

### Token inventory

| Consumer | Token name / location | Token ID (suffix) | Permissions | Zone scope | Expiry |
|---|---|---|---|---|---|
| cert-manager | secret `cloudflare-api-token` (ns `cert-manager`) | `…484bc796…d31bf3` | Zone:DNS:Edit + Zone:Zone:Read | `kostikidis.net`, `teamelwany.com` | none |
| DR / failover | file `~/.cloudflare_token` (`600`), name `devseat` | `…c0aaf846…b3a0ab6` | Zone:DNS:Edit + Zone:Zone:Read | `kostikidis.net`, `teamelwany.com` | none |

### Rules

1. **Per-consumer isolation.** Each automated consumer gets its own token. A compromised
   or mis-scoped token affects only that consumer, and can be rotated without disturbing
   the others.
2. **Least privilege, explicit zones.** Tokens use `Zone Resources → Include → Specific
   zone`, listing each zone by name — never "All zones". Adding a new domain is a
   deliberate edit to each token that should reach it.
3. **`DNS`, not `DNS Settings`.** Records access requires the bare `DNS` permission under
   the `Zone` scope group. `DNS Settings` is not a substitute.
4. **No expiry on unattended automation tokens.** DR and cert-manager run without a human;
   a token TTL is a scheduled outage. Expiry is acceptable only for interactive/human
   tokens where lapse is self-evident.
5. **Storage.** cert-manager's token lives in a Kubernetes secret; the DR token lives in
   `~/.cloudflare_token` (`600`, raw token, no newline) on the operator workstation. Token
   IDs (not the secret strings) are recorded so each can be matched in the dashboard.

## Consequences

- **Adding a zone is a per-token chore.** When a new domain needs certs *and* DR, both
  tokens' Zone Resources must be edited. Accepted as the cost of least privilege — it
  surfaced exactly once here (adding `teamelwany.com` to the cert-manager token cleared two
  shlink certs that had been `Ready=False` for ~4h on DNS-01).
- **Independent blast radius and rotation.** Leaking the DR token cannot touch
  cert-manager's issuance path and vice-versa.
- **More tokens to track.** Mitigated by recording token IDs (above) so the right one is
  edited in the dashboard.
- **Rejected alternative — one shared token.** Fewer objects, but a single point of
  compromise, no independent rotation, and a scope change for one consumer silently widens
  another's authority. Rejected.

**What would change this decision:** moving to Cloudflare *account-scoped* API tokens, or
introducing a secrets manager / short-lived dynamic credentials — at which point the
per-consumer-static-token model would be revisited.

---

*Relates to: ADR-005 (multi-site DR), ADR-010 (Cloudflare Zero Trust), ADR-012 (Greece warm standby).*
