# ADR-044 amendment (2026-10-22): a LAN path for apps with their own login

- **Status:** Draft, 2026-10-22 (owner direction: "as long as I am home I get the direct link", Immich first).
  Extended 2026-10-23: Nextcloud and Vaultwarden joined (owner), k3s nodes excluded from the rewrite.
- **Amends:** ADR-044 "ClusterIP only"
- **Related:** ADR-046 (AdGuard on every VLAN), ADR-045 amendment (VLANs)

## Context

Cloudflare caps a single request at 100 MB, and the Immich mobile app uploads each file in one request.
Videos above that fail through the tunnel. A bulk upload (Marianna, five months of backlog) at home should
not leave the house and come back through Cloudflare at all.

ADR-044 retired the LAN LoadBalancer because nothing on the LAN used it and it exposed every host
(F-001). A blanket split horizon would also skip Cloudflare Access for apps that have no login of their own.

## Decision

1. **One LAN VIP, `192.168.1.210:443`**, announced by kube-vip (`svc_enable`, `lb_class_only`): only
   Services with `loadBalancerClass: kube-vip.io/kube-vip-class` get a VIP; k3s ServiceLB keeps the others.
2. **A separate Traefik entrypoint `lan`** (8444, TLS) behind that VIP. `web`/`websecure` are `asDefault`,
   so a router joins `lan` only when its Ingress lists it in `router.entrypoints`. Sending another host's
   Host/SNI to the VIP finds no router: Access-gated apps are not reachable this way.
3. **Members: hosts with their own login only.** The 4 Immich hosts (`stefanosmobiles`, `mariannamobiles`,
   `lightroom` .kostikidis.net, `gallery.teamelwany.com`) since 2026-10-22; `nextcloud.kostikidis.net`
   (large files) and `vault.kostikidis.net` (works at home when the internet is down) since 2026-10-23.
   Each has its own cert-manager certificate (DNS-01), so `https://` is valid on the LAN. Apps with no login
   of their own (homepage, Grafana, Longhorn, …) never join: the LAN path skips Cloudflare Access.
4. **Split horizon in the router's DNS, for those names only**, on every VLAN regardless of AdGuard
   filtering: AdGuard sends `[/host/]` to dnsmasq, dnsmasq answers `192.168.1.210`, and dnsmasq is local
   for the name (`server=/host/`) so AAAA is never forwarded. Without that, a member that publishes
   Cloudflare AAAA records (Nextcloud and Vaultwarden do) would send IPv6 clients out through Cloudflare.
   Names not physically served from Prague (Greece, gym laptop, DreamHost, Vercel) are never rewritten.
5. **The k3s nodes are not clients of the split horizon.** Cluster DNS forwards to the router, and pods
   cannot reach `.210` (egress NetworkPolicies), so a rewrite there breaks in-cluster calls to members by
   their public name. An AdGuard persistent client for `.201–.205` uses the public upstreams; pods keep
   going through Cloudflare.
6. **Router firewall:** the VLANs that should use it may reach `192.168.1.210` tcp/443 only
   (rules `trusted-to-LAN-VIP`, `family-to-LAN-VIP`).

## Consequences

- Uploads at home run at LAN speed with no size cap; away from home nothing changes (same URL, Cloudflare).
- A device with its own DoH/Private Relay skips the router DNS and simply uses Cloudflare: degrades, never breaks.
- If Prague is down, home clients get an IP that does not answer, the same as the public path today.
- Adding a host = four edits that must stay together: the `lan` entrypoint on its Ingress, dnsmasq `address=`
  and `server=` for the name, and the name in AdGuard's `[/…/]127.0.0.1:5354` upstream. A missed one fails
  silently. Hosts without their own login stay off.
- A new k3s node IP must be added to the AdGuard nodes client, or its pods get `.210` and are refused.
- At home, Kuma (on Unraid, behind the router's DNS redirect) resolves members to `.210`, so its monitors test
  the LAN path; the Cloudflare path for members is watched from outside by UptimeRobot.
- ArgoCD's Service health check (argocd-cm) treats a LoadBalancer with `externalIPs` as Healthy, so Argo no
  longer says whether kube-vip announces `.210`; the Kuma monitors above do.
- k3s ServiceLB's status loop ignores `loadBalancerClass` and blanks kube-vip's status, so the Service also
  carries `externalIPs: [192.168.1.210]` (kube-proxy programs it from spec) and
  `allocateLoadBalancerNodePorts: false` (no per-node port, F-001). Live 2026-10-22 (f89ecdb, 8315ac6).
- The VIP lives on the kube-vip leader (a control-plane node); failover follows the API VIP's lease.
