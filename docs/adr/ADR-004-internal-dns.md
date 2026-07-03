# ADR-004 — Internal DNS: AdGuard Home over Pi-hole

**Status:** Accepted — pending deployment

## Context

The cluster runs 3 nodes on static IPs (192.168.1.201–203) behind a consumer router.
The router serves as the default DNS server via DHCP for all LAN devices.

Two failure modes motivated this decision:

1. **ISP firmware updates** push a router reboot, taking DHCP and DNS down for 1–5 minutes.
   During this time all `*.kostikidis.net` hostnames stop resolving, even though the cluster
   is healthy and reachable by IP.

2. **Split DNS gap** — without a local DNS override, devices on the LAN resolve
   `*.kostikidis.net` through Cloudflare's public DNS, which routes traffic out to the
   internet and back in through the Cloudflare Tunnel. For local users this is unnecessary
   latency and a dependency on Cloudflare availability for internal access.

The fix requires a DNS server that:
- Runs independently of the router
- Can override `*.kostikidis.net` to resolve to the internal kube-vip VIP (192.168.1.200)
- Serves the entire LAN via router DHCP

## Decision

**AdGuard Home** running as a Docker container on Unraid, bound to `192.168.1.100:53`.

### Why AdGuard Home over Pi-hole

| Capability | AdGuard Home | Pi-hole |
|-----------|--------------|---------|
| DNS rewrites (wildcard) | Native UI support | Requires manual config file |
| DoH / DoT upstream | Built-in | Plugin/workaround |
| Per-client rules | Yes | Limited |
| Admin interface | Modern, HTTPS-ready | Dated |
| Active development | Yes | Slower cadence |
| API | Full REST API | Limited |

Pi-hole is more widely known in homelab circles but AdGuard Home is the correct choice for an environment where DNS rewrite rules and per-client policies matter.

### Why on Unraid, not the cluster

AdGuard must survive cluster issues — if Longhorn degrades or a node goes down, you still need DNS to diagnose the problem. Running DNS inside the cluster creates a circular dependency.

Unraid has a dedicated static IP on the LAN (`192.168.1.100`) that is independent of the cluster and the router's DHCP pool.

### Unraid network interfaces (important for binding)

Unraid runs 3 network interfaces:

| Interface | IP | Speed | Purpose |
|-----------|-----|-------|---------|
| LAN (2.5G) | 192.168.1.100 (static) | 2.5GbE | File shares, DNS, cluster access |
| Internet uplink (2.5G) | DHCP from router | 2.5GbE | Internet access |
| Direct link (10G) | 10.10.10.10 (static) | 10GbE | Direct connection to editing PC only |

AdGuard binds **only to `192.168.1.100`**. The 10G interface is an isolated direct link and must not be used for DNS. The DHCP interface is the internet uplink and must not be exposed for DNS.

## DNS rewrite rules

| Rule | Target | Reason |
|------|--------|--------|
| `*.kostikidis.net` | `192.168.1.200` | Route all cluster apps to kube-vip VIP internally |

All other resolution forwarded to upstream DoH resolvers (Cloudflare 1.1.1.1 / Google 8.8.8.8 over HTTPS).

## Consequences

- Router reboot / ISP update: zero DNS impact for LAN devices
- Internet down: all `*.kostikidis.net` apps still resolve and load locally
- New cluster apps get internal resolution automatically (wildcard covers all subdomains)
- Unraid going down takes out internal DNS — mitigation: Unraid is on a UPS and is the most stable machine in the setup
- All LAN devices must use AdGuard as DNS — set in router DHCP as DNS server field

## Alternatives considered

- **Pi-hole** — rejected, see table above. Wildcard DNS rewrite requires editing `/etc/dnsmasq.d/` manually; AdGuard does it in the UI.
- **CoreDNS on the cluster** — rejected, circular dependency (DNS inside the thing DNS needs to find).
- **Router DNS overrides** — rejected, router firmware doesn't support wildcard rewrites and is the failure we're trying to survive.
- **Hosts file on each device** — rejected, doesn't scale, breaks for phones and guest devices.
