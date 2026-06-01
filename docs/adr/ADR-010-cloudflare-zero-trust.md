# ADR-010 — Cloudflare Zero Trust: Wildcard Deny-by-Default with Per-App Policy Carve-Outs

**Status:** Accepted  
**Date:** 2026-06-01

## Context

ADR-003 established `cloudflared` as the public ingress path: a wildcard tunnel route `*.kostikidis.net` → ingress-nginx with no ports open on the router. That was the right transport decision. It left one layer unaddressed: authentication. Until this decision, every subdomain on `*.kostikidis.net` was reachable by anyone on the internet with no authentication gate.

The cluster runs apps across a wide range of sensitivity: professional photo archives (Lightroom Immich), personal documents (Paperless-ngx), a client portfolio site (studioconcreteluka.com), and operational tooling (ArgoCD, Grafana, Longhorn). A flat open posture is not appropriate for this mix.

Two constraints shaped the approach:

1. **Timing.** The wildcard deny had to land before live data migration and before NFS shares went live. Once real data is in, the cost of a gap is higher.
2. **Gap avoidance.** Applying Access policies piecemeal — one app at a time over days — creates windows where some apps are protected and others are not. An inconsistent policy surface is worse than a momentarily restrictive one.

The infrastructure anchor is `cloudflared` running as a Deployment in `kubernetes/networking/cloudflared/`. The tunnel terminates at Cloudflare's edge. Cloudflare Access policies sit in front of the tunnel at Cloudflare's layer and are independent of in-cluster configuration.

## Decision

Flip `*.kostikidis.net` to **wildcard deny-by-default** via Cloudflare Access, then carve out each app with an explicit policy in a single batch session. No app is carved out before the session begins; no app is left without a policy after it ends.

### Per-app policy patterns

| App | Policy type | Rationale |
|-----|-------------|-----------|
| ArgoCD, Grafana, Paperless (personal), Paperless-drali, n8n, Nextcloud, Open WebUI, Longhorn | Cloudflare Access — email OTP to `kostikidis@gmail.com` | Browser apps; interactive login flow is viable |
| Immich (all instances) | Tailscale bypass | Mobile app cannot complete Cloudflare's browser redirect; Tailscale provides equivalent network-layer auth |
| Obsidian LiveSync (CouchDB backend) | Cloudflare Access — Service Token | Plugin runs a background sync process with no browser context; static service token injected into plugin config |
| studioconcreteluka.com `/wp-admin` | Cloudflare Access — email OTP | Admin path only; rest of the site is public (client portfolio, not a personal service) |

No app on `kostikidis.net` is fully public. The Obsidian service token has a rotation reminder set at 90 days.

### Why one batch session

Applying the wildcard deny first, then carving out apps in sequence in a single session, means there is never a gap. An app is either still blocked by the wildcard deny (not yet reached in the sequence) or fully covered by its own policy. Piecemeal rollout across multiple days would leave some apps open while others were protected, which is a worse posture than the pre-ZT state because it creates a false sense of partial coverage.

## Consequences

**Wins:**
- Every app on `*.kostikidis.net` is behind authentication. No subdomain is reachable without passing Cloudflare Access or Tailscale.
- Audit log: Cloudflare Access logs every authentication event. This is the first time the homelab has an auth audit trail.
- No router firewall rules required. Access policy enforcement happens at Cloudflare's edge, not in-cluster.
- The mobile app constraint (Immich) is addressed cleanly: Tailscale already covers those devices at the network layer.

**Costs and risks:**

- **Service Token is a one-way credential.** The Obsidian plugin stores the service token in its config. If that config is synced to an untrusted device or leaked, the token grants permanent tunnel access until manually rotated. 90-day rotation is the mitigation; it requires a manual config update in the plugin on every device.
- **No in-cluster deny fallback.** Access policies live in Cloudflare's control plane, not in Kubernetes. If `cloudflared` is reconfigured to route around Access (e.g., a misconfigured tunnel split), the cluster has no secondary enforcement layer. Network policies (see in-cluster NetworkPolicy manifests) partially mitigate this but do not cover all paths.
- **Immich `/share/*` bypass paths (Elwany instance).** The Elwany Immich instance requires Cloudflare Access bypass rules on `/share/*` and `/api/shared-link/*` to support team upload workflows (see ADR-008). These bypass paths must be walked through manually during the ZT cohort session, not pre-configured. A misconfigured bypass could expose the full Immich API.
- **Email OTP is single-factor.** OTP to a single Gmail address means compromise of that inbox grants Access to all OTP-protected apps simultaneously. Acceptable for a personal homelab; would not be acceptable in a multi-user or commercial context.
- **studioconcreteluka.com admin path only.** The rest of that domain is intentionally public. This is a deliberate carve-out, not an oversight. Any future page added under a protected path needs an explicit Access policy or it inherits the wildcard deny.

## Alternatives Considered

**VPN-only (Tailscale everywhere):** Rejected. Browser-based apps (ArgoCD, Grafana, Nextcloud) do not work reliably behind Tailscale on all devices, particularly on mobile browsers where Tailscale's split DNS interacts poorly with some network configurations. Tailscale is kept for mobile apps that cannot do browser redirect flows.

**Per-app firewall rules at the router or ingress level:** Rejected. IP allowlist rules are fragile (dynamic IPs on mobile), do not scale as apps are added, and produce no audit log. They also do not solve the authentication problem — they limit source, not identity.

**Always-open with strong per-app passwords:** Rejected. No MFA, no audit log, no central revocation. A password compromise on any single app is undetected until damage is done.

**Piecemeal per-app ZT rollout (app by app over time):** Rejected as the implementation strategy. See the batch session rationale above.

---

*Relates to: ADR-002 (infrastructure split), ADR-003 (networking stack), ADR-008 (multi-instance Immich and per-instance access policies)*
