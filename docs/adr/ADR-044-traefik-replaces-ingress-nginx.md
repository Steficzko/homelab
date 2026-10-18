# ADR-044: Traefik replaces ingress-nginx as the only ingress controller

**Status:** Accepted (2026-10-17) — supersedes the ingress-controller part of ADR-003
**Date:** 2026-10-16
**Tracking:** Plane CLSTR-29

## Context

ADR-003 chose ingress-nginx over K3s's bundled Traefik for ecosystem familiarity and CKA
relevance. The Kubernetes project has retired ingress-nginx (statement of 2026-01-29):
best-effort maintenance ended in March 2026, and there are no further releases, bug fixes
or security patches. The cluster's whole public surface (5 Cloudflare tunnels, 53 Ingresses, including
a client's SaaS staging and two client WordPress sites) sat behind a controller that would
stop receiving CVE fixes. Forks such as Chainguard's EmeritOSS are stopgaps, not a home.

Facts measured before deciding the shape of the replacement:

- Every request to nginx in a 24 h window came from the cloudflared pods or the two
  wp-cron Jobs. Nothing on the LAN used the `.201-.205:80/443` LoadBalancer.
- The ClusterIssuer is DNS-01 (Cloudflare), so certificates do not depend on the controller.
  One namespaced Issuer (namo-apps `letsencrypt-http01`) did, through its solver class.

## Decision

- **Traefik v3 (Helm chart, Argo-managed) is the only ingress controller and the default
  IngressClass.** Standard `networking.k8s.io/v1` Ingress objects stay the API; Traefik
  CRDs are used only where an Ingress cannot express the behaviour.
- **ClusterIP only.** Traffic arrives exclusively through the Cloudflare tunnels
  (`http://traefik.traefik.svc.cluster.local:80`, or `:443` with `originServerName` for
  hosts that keep a TLS origin: faktury, warehouse). The LAN LoadBalancer is retired, which
  also closes the F-001 NodePort surface. Ingress status is published as the in-cluster
  hostname (`ingressEndpoint.hostname`) so Argo sees Ingresses as Healthy.
- **No http->https redirect and no upstream timeouts at the origin.** TLS terminates at
  Cloudflare; entrypoint `readTimeout: 0`; HSTS is added globally on `websecure`.
- **nginx annotation equivalents** (only where the behaviour mattered):

  | ingress-nginx | Traefik |
  |---|---|
  | `ssl-redirect: "false"` | default (Traefik never redirects on its own) |
  | `proxy-body-size: "0"`, read/send timeouts, `proxy-buffering: off` | defaults |
  | `proxy-body-size` on **public** APIs (64k, 1m, 25m) | `buffering.maxRequestBodyBytes` Middleware |
  | `proxy-body-size` on Access-gated apps (25m-100m) | dropped: Cloudflare caps a request at 100 MB |
  | `auth-type: basic` + `auth-secret` | `basicAuth` Middleware on the same htpasswd secret |
  | `custom-headers` | `headers.customResponseHeaders` Middleware |
  | `permanent-redirect` | `redirectRegex` Middleware |
  | `backend-protocol: HTTPS` | Service annotations `serversscheme` + `ServersTransport` |
  | `proxy-redirect-from/to` (Plane `/god-mode`) | exact-path IngressRoute + `redirectRegex` |

- **Wildcard priority is explicit.** Traefik ranks routers by rule length, not
  "exact host first". The `*.gompha.com` tenant wildcard carries `router.priority: 10`,
  the landing's `/manual` carve-out `20`; exact hosts keep their length-based priority (>=36).

## Consequences

- One controller with active upstream maintenance; the same Ingress objects carry over to
  the Talos + Flux target (Future Stack), since Traefik is not K3s-specific.
- The CKA trade-off ADR-003 optimised for is given up: ingress-nginx annotations are no
  longer exercised here. The exam tests the Ingress API, which is unchanged.
- Body limits are no longer a blanket convention. Public, unauthenticated surfaces keep a
  Buffering Middleware; Buffering also holds the response, so it must never sit on a
  streaming route (Open WebUI, MCP SSE, Plane live).
- Charts that special-case Traefik need checking: plane-ce renders IngressRoutes for a
  `traefik*` class and derives entrypoints from `ssl.*`; with TLS at Cloudflare it needs
  `ssl.externalTermination: true` and no `tls_secret_name` (a 6-minute Plane outage on
  2026-10-16 came from missing this).
- Migration evidence: a 52-path golden diff (status, Location, auth and security headers)
  plus 21 gompha routing and body-limit checks, recorded through nginx before the move and
  replayed through Traefik after it, matched; load test 31.5k rps (nginx 23.7k) on a static
  backend; 1 GB and slow 100 s uploads passed; TraefikBackendErrors reached Telegram.

## Verification (2026-10-16/17)

What makes "everything is on Traefik" a checked fact rather than a belief:

| Check | Result |
|---|---|
| Ingress objects | 52/52 `ingressClassName: traefik`, none carries an `nginx.ingress.kubernetes.io/*` annotation (Traefik would silently ignore an auth or allow-list one) |
| Cloudflare tunnels, read via API (11 tunnels, both accounts) | 0 rules to ingress-nginx or a node IP; `*.kostikidis.net` wildcard → Traefik |
| NetworkPolicies | every policy that admits `ingress-nginx` also admits `traefik` |
| LAN exposure | `.201`/`.203`/`.205` answer nothing on 80/443; SEC-9 bypass gone |
| Alert rules | none reference nginx metrics; TraefikBackendErrors proven to reach Telegram |
| Public sweep through Cloudflare | 64 hosts, 0 × 5xx/timeout (before and after load) |
| Block-wise load test, 59 hosts via Traefik | ~3.9 M requests, 0 × 5xx, 0 restarts, no node below 5.3 GB free |

The load tests surfaced faults that were not Traefik's but were hidden behind the old edge:
Grafana with no memory limit froze w2 and w1 (fixed 3a2b526), and the client WordPress sites
dropped to 503 at 5 concurrent visitors because a 1-core CPU limit throttled PHP 85-90% behind
a 1 s readiness timeout (fixed acad330, d55b71b).

## Soak, then removal

ingress-nginx is deactivated, not deleted: controller at 0 replicas, LoadBalancer Service and
admission webhooks removed, Argo app kept (0c61563, 2026-10-16). Rollback is reverting that
commit plus re-pointing a tunnel rule — never casually, since it reopens the LAN bypass.

Delete it no earlier than **2026-10-20**, and only when, since 0c61563:
- no TraefikBackendErrors / TraefikHigh5xxRatio alert has fired that traces to routing;
- a fresh public sweep is clean and the tunnel audit still shows 0 nginx rules;
- no app owner has reported a broken path.

Then the follow-ups below go in one change.

## Follow-ups

- Remove `ingress-nginx` namespaceSelectors from the 42 NetworkPolicies, the `nginx` IngressClass, the
  `landing-security-headers` ConfigMap, the nginx Grafana dashboard and the
  `infrastructure/ingress-nginx/` values once the Argo app is deleted.
- ADRs that name ingress-nginx and need a note: 002, 004, 010, 026, 036 (and ADR-003's
  ingress conventions section).
