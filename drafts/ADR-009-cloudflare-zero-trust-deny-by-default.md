# ADR-009 — Cloudflare Zero Trust: Deny-by-Default Access Strategy

## Status
Accepted — pending implementation

## Context

All homelab applications are currently reachable via the Cloudflare Tunnel wildcard
route (`*.kostikidis.net → ingress-nginx`) with no authentication layer. Anyone who
discovers a subdomain can reach the application directly. There is no 2FA, no identity
check, and no rate limiting at the edge.

This covers a mix of app types:

| App | Audience | Sensitivity |
|-----|----------|-------------|
| ArgoCD | Owner only | High — cluster write access |
| Open WebUI | Owner only | Medium — LLM, private prompts |
| Grafana | Owner only | Medium — cluster internals visible |
| Paperless | Owner only | High — personal documents |
| Nextcloud | Owner + family | Medium — personal files |
| Immich (elwany) | Iraq gym team | Low — upload/view only |
| Obsidian LiveSync | Owner only (background sync) | High — private notes |

The cluster has no in-cluster authentication middleware. The only access control today
is that private apps (e.g. ArgoCD internal services) have no Ingress resource — they
are unreachable from the internet but unprotected if one were ever added by mistake.

Cloudflare Zero Trust Access sits in front of the tunnel and can enforce identity
before a request reaches the cluster. It supports email OTP (no Cloudflare account
required for recipients), Service Tokens for non-browser clients, and path-level
bypass rules for public share URLs.

## Decision

**Enable Cloudflare Zero Trust Access with a deny-by-default posture: all applications
under `*.kostikidis.net` are protected unless an explicit policy allows access.**

The implementation uses four policy types:

### 1. Email OTP — admin tools (owner only)

| Application | URL |
|-------------|-----|
| ArgoCD | `argocd.kostikidis.net` |
| Open WebUI | `chat.kostikidis.net` |
| Grafana | `grafana.kostikidis.net` |
| Paperless | `paperless.kostikidis.net` |

Policy: allow `kostikidis@gmail.com`, deny all others. Cloudflare sends a one-time
code to the email address on each new browser session.

### 2. Email OTP — family apps

| Application | URL |
|-------------|-----|
| Nextcloud | `nextcloud.kostikidis.net` |

Policy: allow `kostikidis@gmail.com` plus explicitly listed family email addresses.
Nextcloud public share links (`/s/*`) are added as a bypass rule so recipients can
open shares without a Cloudflare account.

### 3. Service Token — Obsidian LiveSync

Obsidian's LiveSync plugin runs as a background sync process with no browser context.
A Cloudflare Service Token (Client ID + Secret) is created under Access → Service Auth.
The token credentials are injected into the plugin settings on each device and stored
encrypted in the repo as `cloudflare/service-token.sops.yaml` (SOPS, age-encrypted).

### 4. Bypass — Immich Iraq team (elwany)

`elwany.kostikidis.net` is shared with the Iraq gym team for photo uploads and viewing.
The team does not have Cloudflare accounts. The Access policy for this subdomain
includes bypass rules for:

- `/share/*` — Immich shared album UI
- `/api/shared-link/*` — Immich shared-link API calls

All other paths on `elwany.kostikidis.net` require email OTP (owner access only).

### Deny-by-default enforcement

Cloudflare Zero Trust enforces access at the edge. Any request to `*.kostikidis.net`
that does not match a configured Access application is blocked before it reaches the
tunnel. This covers subdomains that may be added to DNS or the tunnel in the future
without a corresponding Access policy.

## Consequences

**Wins:**

- All admin tools gain email-based 2FA with no code changes and no in-cluster auth
  middleware
- A misconfigured or accidentally added Ingress is blocked at the edge before it
  reaches the cluster
- Obsidian sync continues uninterrupted via Service Token — no browser interaction
  required for background processes
- Family members can access Nextcloud and Immich shares without Cloudflare accounts

**Costs and open risks:**

- **Immich /share/* bypass requires manual path verification before go-live** —
  The bypass rules for `elwany.kostikidis.net` cover `/share/*` and
  `/api/shared-link/*`. These paths are correct for the Immich shared album UI and
  its API calls. However, Immich's internal routing must be verified: if clicking
  into a shared album or opening an individual image causes the browser to redirect
  to a path outside those prefixes (e.g. `/photos/<asset-id>`, `/assets/*`, or any
  other top-level route), that request will hit the Access wall and fail — the Iraq
  team's upload and viewing workflow breaks silently from their perspective. This
  must be manually confirmed by walking the full share flow (open shared link,
  browse album, open individual image, download) before the Access policy is enabled
  on `elwany.kostikidis.net`. Do not go live on this subdomain until verified.

- **Obsidian Service Token has no expiry by default** — Cloudflare Service Tokens
  do not expire unless an expiry date is set at creation time. A lost or compromised
  device retains permanent access to `obsidian.kostikidis.net` until the token is
  manually revoked in the Zero Trust dashboard. There is no automatic rotation, no
  audit trail per-device, and no way to revoke access for one device without
  revoking all devices using the same token. Mitigation: set a calendar reminder to
  rotate the token every 90 days (revoke + create new + update plugin settings on
  all devices). This is an accepted operational burden; the alternative (per-device
  tokens) requires separate plugin configurations per device and the same rotation
  discipline.

- **Deny-by-default is enforced at Cloudflare, not in-cluster** — the block
  catch-all lives entirely in Cloudflare's Access layer. No equivalent enforcement
  exists inside the cluster. If `cloudflared` is ever reconfigured to bypass Access
  (e.g. a tunnel route pointing directly to an internal service without an Access
  application associated), deny-by-default silently collapses — traffic reaches
  the cluster with no auth check and no alerting. There is no in-cluster policy
  (NetworkPolicy, admission webhook, or otherwise) that enforces the same deny
  posture as a fallback. This is a known single point of trust. Mitigations are
  limited: keep tunnel route configuration under GitOps review, and treat any
  change to `cloudflared` deployment or tunnel routes as a security-relevant change.

## Alternatives Considered

- **In-cluster auth middleware (e.g. oauth2-proxy, Vouch)** — rejected. Adds a
  pod per app or a shared proxy with complex routing rules. Cloudflare Zero Trust
  achieves the same result at the edge with zero cluster changes. In-cluster
  middleware would also not protect against a misconfigured tunnel.

- **IP allowlist only** — rejected. Dynamic home IPs and travel use cases make a
  static IP allowlist unworkable. The Iraq team is on a different continent.
  Email OTP provides identity assurance that an IP allowlist cannot.

- **Tailscale for all access** — rejected for family and Iraq team use cases.
  Requiring non-technical family members or the Iraq gym team to install and
  authenticate Tailscale on their devices is not viable. Email OTP has no client
  requirement beyond a browser.

- **Per-device Service Tokens for Obsidian** — not adopted. Would allow per-device
  revocation but requires maintaining separate plugin configurations per device and
  identical rotation discipline. Complexity not justified for a single-user note
  sync service.
