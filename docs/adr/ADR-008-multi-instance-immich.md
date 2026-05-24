# ADR-008: Multiple Immich Instances With Per-Instance Access Policies

**Status:** Accepted  
**Date:** 2026-05-20

## Context

The homelab runs four Immich photo library instances for different users and purposes. The question was whether to consolidate these into a single shared Immich deployment or keep them as separate instances with separate namespaces, databases, and ingress routes.

The four instances and their audiences:

| Instance | Users | Content |
|----------|-------|---------|
| Lightroom | Stefanos (professional) | Client work, Nikon D850 RAW archive — 15 years |
| Steficzko | Stefanos (personal) | Personal phone backup |
| Marianna | Marianna | Personal phone backup |
| Elwany | BJJ team | Training photos and videos, collaborative archive |

## Decision

Run four independent Immich instances, each in its own Kubernetes namespace, with its own database, storage path, and ingress hostname. Each instance has a different Cloudflare Access policy.

Access model per instance:

- **Lightroom** — Cloudflare Zero Trust Access required (email OTP or SSO). No exceptions.
- **Steficzko / Marianna** — Cloudflare Zero Trust Access required; mobile app uses Immich's own token-based auth which passes through Access.
- **Elwany** — Cloudflare Zero Trust Access protects the instance. Specific bypass paths are configured for the team upload workflow (see below).

## Reasoning

**The primary driver is data classification, not convenience.**

The Lightroom instance holds professional client work. Under GDPR, this data requires a higher standard of protection than a personal photo album. Putting client photos in the same database as a team instance, or behind the same login, would create a data leakage risk. Separate instance = separate database = clear data boundary. If one instance is ever compromised, the others are not affected.

**Domain is also a functional requirement, not just organisation.**

Mobile apps pin to a specific server URL. Marianna's phone points to `marianna.kostikidis.net`. Stefanos's personal phone points to `steficzko.kostikidis.net`. Sharing a single Immich instance would require all users to share one account or use Immich's multi-user mode, which still shares one ML model cache, one upload storage namespace, and one face recognition corpus. Keeping separate instances keeps libraries clean and prevents cross-contamination of face data and CLIP embeddings.

**The Elwany instance: locked down, with a deliberate upload path.**

The Elwany instance is locked behind Cloudflare Zero Trust Access — the same as every other instance. Nobody reaches Immich without passing through Access first. However, the BJJ team's workflow requires teammates to upload training photos without each person having a full Immich account.

Immich supports this natively through shared album links with upload permission. A shared link is generated for the team album and distributed to teammates. Cloudflare Access is configured with a bypass rule on Immich's shared-link and upload API paths (`/share/*` and `/api/shared-link/*`), so teammates can upload directly from their phones without going through interactive browser-based authentication.

The access model is intentional and layered:

- Teammates can **upload** to the shared album — they contribute to the library
- Teammates cannot **delete**, rename, or modify anything — the shared link grants upload-only rights by design, which is how Immich implements it
- The shared link itself is not password-protected — the friction of a password defeats the purpose for a group of people uploading after training
- Full account access (admin, browsing the full library, managing albums) still requires Zero Trust login

This is a considered trade-off: the upload path is open to anyone with the link, which is acceptable for training photos. The library itself is protected.

## Consequences

**Accepted tradeoffs:**
- Four sets of manifests instead of one — mitigated by GitOps: the pattern is in git and adding an instance is copying a directory and changing a few values
- Four separate Postgres databases on Longhorn — storage cost is acceptable, each DB is a few GB
- Each instance runs its own ML container for now — shared ML across instances is planned once the dedicated GPU machine (Ryzen 9 5950X + RX 6700 XT) comes online via LXC passthrough (see ml-machine/RUNBOOK-lxc-build.md)

**Not used:**
- Single shared Immich with multi-user mode — does not provide data isolation at the database level; GDPR compliance requires clear data boundaries for professional client work
- Single shared Immich with separate libraries — libraries in Immich share the same ML corpus and the same database; not an adequate separation boundary
