# ADR-025 — WordPress Security Model: Cloudflare Tunnel + ZT, Not Obscurity

**Status:** Accepted  
**Date:** 2026-06-07

> **Update (2026-06-16, verified live):** The WPS-Hide-Login rename has since been
> **removed**. The login is now `/wp-login.php` (and `/wp-admin`), gated by Cloudflare
> Access (`martuniawork.cloudflareaccess.com`, the owner's own ZT org); `/zadni_vratka`
> now 404s. This *confirms* the decision below rather than contradicting it — the
> obscurity layer was dropped once ZT was the verified control. Read every `/zadni_vratka`
> reference below as historical context, not current state.

## Context

The Studio Concrete Luka WordPress site has its admin login path renamed from the
default `/wp-admin` and `/wp-login.php` to a custom slug (`/zadni_vratka`). An external
reviewer flagged this as "security-by-obscurity — renaming the door doesn't help if
the lock is the same."

This critique is technically correct in isolation. This ADR documents why the path
rename is cosmetic, and what the actual security model is.

## Decision

The security of the Studio Concrete Luka WordPress admin interface rests entirely on
**Cloudflare Zero Trust** and **Cloudflare Tunnel**, not on the renamed login path.

### The actual security stack

1. **No inbound ports.** The WordPress pod is not exposed via NodePort, LoadBalancer,
   or any port binding on the host. It is reachable exclusively through a Cloudflare
   Tunnel (`cloudflared` sidecar, two replicas). There is no IP address or port on the
   public internet to connect to directly.

2. **Cloudflare Tunnel terminates all ingress.** Every request to
   `studioconcreteluka.com` flows through Cloudflare's network before reaching the
   tunnel. Cloudflare's WAF, bot protection, and DDoS mitigation apply at the edge.

3. **Cloudflare Zero Trust Access gates the admin paths.** The `/zadni_vratka` and any
   admin-adjacent paths are behind a Zero Trust Access policy requiring authentication
   before the request is proxied to the WordPress pod. An unauthenticated request to
   the admin path is rejected at the Cloudflare edge — it never reaches the cluster.

4. **WordPress credentials are SOPS-encrypted** in the repository. The database
   password is a strong, unique credential sealed with Age. The plaintext `wordpress`
   value visible in the manifest is the *database username*, not a password.

### Role of the renamed login path

`/zadni_vratka` serves one purpose: reducing noise in WordPress logs. Automated
scanners probe `/wp-login.php` and `/wp-admin` constantly. The rename means those
probes return 404 at the WordPress layer (they are already rejected at the Cloudflare
edge, but the rename keeps the app logs clean). It is a log hygiene choice, not a
security control.

If the Zero Trust policy were removed, the renamed path would provide no real
protection — a determined attacker would find it. ZT is the control; the rename is
cosmetic.

## Consequences

The security posture is: Cloudflare edge (WAF + bot protection) → ZT Access policy
(authentication required) → Cloudflare Tunnel (no public IP exposure) → WordPress pod.
An attacker who does not pass ZT never reaches the WordPress process, regardless of
whether they know the admin path name.

**What would change this decision:** Moving off Cloudflare Tunnel to direct ingress
(e.g. opening port 443 to the internet). In that case, the renamed login path provides
zero protection and rate-limiting + fail2ban would become mandatory compensating controls.

---

*Relates to: ADR-003 (networking), ADR-010 (Cloudflare Zero Trust).*
