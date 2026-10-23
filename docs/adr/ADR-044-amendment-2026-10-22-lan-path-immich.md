# ADR-044 amendment (2026-10-22): a LAN path for Immich only

- **Status:** Draft, 2026-10-22 (owner direction: "as long as I am home I get the direct link", Immich first)
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
3. **Members: the 4 Immich hosts** (`stefanosmobiles`, `mariannamobiles`, `lightroom` .kostikidis.net,
   `gallery.teamelwany.com`). Each has its own cert-manager certificate (DNS-01), so `https://` is valid
   on the LAN. Every member has its own login.
4. **Split horizon in the router's DNS, for those names only**, on every VLAN regardless of AdGuard
   filtering: AdGuard sends `[/host/]` to dnsmasq, dnsmasq answers `192.168.1.210`. Names not physically
   served from Prague (Greece, gym laptop, DreamHost, Vercel) are never rewritten.
5. **Router firewall:** the VLANs that should use it may reach `192.168.1.210` tcp/443 only.

## Consequences

- Uploads at home run at LAN speed with no size cap; away from home nothing changes (same URL, Cloudflare).
- A device with its own DoH/Private Relay skips the router DNS and simply uses Cloudflare: degrades, never breaks.
- If Prague is down, home clients get an IP that does not answer, the same as the public path today.
- Adding a host later = the annotation on its Ingress + its DNS entry. Hosts without their own login stay off.
- k3s ServiceLB's status loop ignores `loadBalancerClass` and blanks kube-vip's status, so the Service also
  carries `externalIPs: [192.168.1.210]` (kube-proxy programs it from spec) and
  `allocateLoadBalancerNodePorts: false` (no per-node port, F-001). Live 2026-10-22 (f89ecdb, 8315ac6).
- The VIP lives on the kube-vip leader (a control-plane node); failover follows the API VIP's lease.
