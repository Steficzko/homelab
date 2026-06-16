# ADR-010 Amendment — Cross-Tenant Cloudflare Access on studioconcreteluka.com /wp-admin

**Status:** Proposed (amendment to ADR-010, also touches ADR-025)
**Date:** 2026-06-15
**Trigger:** Security audit finding F-003 (2026-06-15, `/home/stefanos/AUDIT_May/audit.md`)

## Context

ADR-010 records that `studioconcreteluka.com/wp-admin` is gated by Cloudflare Access
(email OTP). ADR-025 builds on that, stating the site's security "rests entirely on
Cloudflare Zero Trust," with the renamed login path (`/zadni_vratka`) being cosmetic.

Both ADRs implicitly assumed the Access policy lived in the owner's own Cloudflare
tenant (`kostikidis.cloudflareaccess.com`). The 2026-06-15 audit found otherwise:

> **F-003** — the `/wp-admin` Access gate is enforced by
> **`martuniawork.cloudflareaccess.com`**, a *different* Cloudflare tenant than the
> owner's. The control exists and is working, but it is owned and configured by a
> third party.

This is **intentional**: the Studio Concrete Luka site is co-managed with a
collaborator/agency, and that collaborator's Cloudflare tenant fronts the admin gate.
This amendment records that dependency explicitly rather than leaving it implicit.

## Decision

Accept the cross-tenant Access gate as the deliberate arrangement for this one client
domain. The owner's wildcard deny-by-default (ADR-010) governs `*.kostikidis.net`;
`studioconcreteluka.com` is a separate domain whose admin gate is delegated to the
`martuniawork` tenant by design.

Because the control now sits outside the owner's span of control, two hardening
requirements attach to it:

1. **MFA must be enforced on the `martuniawork` tenant account.** If the gate's
   identity provider allows single-factor login, a compromise of that one account
   grants `/wp-admin` access to the live client site. The owner must confirm with the
   collaborator that MFA is enforced on every identity that can administer the
   `martuniawork` Zero Trust org.
2. **The gate's continued enforcement must be re-verified periodically.** Because the
   policy is editable by a third party, the owner cannot assume it stays in place.
   Re-confirm during each audit cycle that an unauthenticated `/wp-admin` request is
   still rejected at the edge.

## Consequences

**Accepted risk:** The owner does not control the `/wp-admin` gate's policy or its MFA
posture. If the `martuniawork` tenant is lost, disabled, or compromised, the admin
gate is lost with it and the owner cannot restore it without that tenant's cooperation
(or re-fronting the domain through their own tenant — the migration path, deliberately
not taken here).

**Compensating control (F-002, fixed 2026-06-15):** Even if the gate were to fail open,
the WordPress hardening mu-plugin now suppresses version/fingerprint disclosure
(WordPress/Elementor/Site Kit generators, `?ver=` strings) and `readme.html`/
`license.txt` are reliably removed. This reduces what an attacker learns about the
target before reaching the (still-gated) admin path. It is defense-in-depth, not a
replacement for the gate.

**Break-glass / exit path:** If the collaborator relationship ends or the tenant
becomes untrusted, recreate the Access application under
`kostikidis.cloudflareaccess.com` (email OTP per ADR-010) and remove the `martuniawork`
application. This is a Cloudflare Zero Trust dashboard operation, not a repo change.

---

*Relates to: ADR-010 (Cloudflare Zero Trust), ADR-025 (WordPress security model),
audit finding F-003.*
