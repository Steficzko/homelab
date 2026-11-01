# ADR-039 — Network segmentation: OPNsense, a managed switch, and VLANs

- **Status:** Draft (2026-09-15) — **REPLANNED 2026-09-22, to be superseded, not edited.**
  The edge box is now a **GL.iNet Flint 2 (GL-MT6000) on mainline OpenWrt** (ordered, in
  transit), not OPNsense. The cluster and both NAS boxes **keep `192.168.1.0/24`** as the infra
  segment and stay on the unmanaged 8-port; the managed switch and VLANs are deferred with no
  date. Two decisions below are therefore reversed (OPNsense; "do not keep 192.168.1.x"). The
  kube-vip claim in the inventory and Consequences is also wrong: kube-vip floats only the
  apiserver VIP `.200`; ingress is k3s ServiceLB on node IPs `.201`–`.205`. The "one VLAN for the
  cluster" conclusion still holds, on Longhorn replication, NFS and the real `.200`. A superseding
  ADR-041 will carry the new plan; this draft stays as the record of what was considered.
- **2026-10-22:** superseded in practice by ADR-045 (amendment 2026-10-22) and ADR-046 — VLANs are live on an
  OpenWrt router (Beelink interim, Flint 2 later). Kept as the record of what was considered.
- **2026-11-01:** the subnet map below is the CONSIDERED plan, not the live one. Live on wrt-edge:
  untagged `lan` 192.168.1.0/24 (cluster, NAS, Proxmox) · VLAN 5 iot 192.168.5.0/24 ·
  VLAN 10 trusted 192.168.10.0/24 · VLAN 20 family 192.168.20.0/24 · **VLAN 30 agents
  192.168.30.0/24** (Hermes VM; internet only plus exact pinholes; design
  record pending as Plane CLSTR-50) · VLAN 90 mgmt 192.168.90.0/24. VLAN 30 is NOT IoT.
- **Deciders:** Stefanos
- **Tracked in:** Plane project `NET` (Networking), NET-1 … NET-13
- **Supersedes:** the flat `192.168.1.0/24` addressing in [[project_network_convention]]

## Context

Everything in the estate sits on one flat `/24`. Every device can reach the cluster,
both NAS boxes, the Proxmox host and the ML guests. A phone on the WiFi is one hop from
Unraid's SMB shares and the Kubernetes API.

### What is actually on the wire (scanned 2026-09-15)

| IP | MAC vendor | What it is |
|---|---|---|
| 192.168.0.1 | — | Vodafone CPE, operator-managed, public 78.45.149.228 |
| 192.168.1.1 | TP-Link | inner router, **OpenWrt 19.07.10 — EOL since 2021** |
| 192.168.1.100 | Changwang | Unraid Prague (`unraid-repy`) — SSH, HTTP, SMB, NFS, 8080 |
| 192.168.1.106 | Intel | unidentified, fully firewalled — likely a laptop |
| 192.168.1.122 | Gigabyte | Proxmox host (`pve`) |
| 192.168.1.180 | G-PRO | Windows PC (SMB only open) |
| 192.168.1.201 | Lenovo | k3s-prg-r1 **+ LB VIP** (ingress-nginx, promtail-syslog) |
| 192.168.1.202 | Lenovo | k3s-prg-g2 |
| 192.168.1.203 | Lenovo | k3s-prg-b3 (default kubectl target) |
| 192.168.1.204 | Lenovo | k3s-prg-w1 **+ LB VIP** (brain-syncthing) |
| 192.168.1.205 | Lenovo | k3s-prg-w2 |
| 192.168.1.224-227 | Proxmox | four ML guests (ollama-gpu on .224, whisper on .225, ollama on .227) |
| .175 .181 .200 .232 | Lenovo (dup MACs) | secondary/VIP addresses on the k3s nodes |

Wireless devices do not all appear in an ARP scan; the tailnet lists the rest —
`marianna-repy` (Windows), `poco-f8-ultra` and `poco-f3-linage` (Android),
`lenovo-x13`, `popika-hp`, `soprano-rs`, `stefanos-streacom`, `waveyavenue`.

### Why now

Two forcing functions. The OpenWrt box is four years past end-of-life and unpatched. And
on 2026-09-15 the Vodafone CPE rebooted itself into new firmware at 00:26 UTC and broke
every Cloudflare tunnel for 19 hours — a device we have no access to, in the path of
everything. See the tunnel incident recorded in `kubernetes/networking/cloudflared/`.

## Decision

Rebuild in three phases: **OPNsense → managed switch → VLANs.**

### Subnet map

| VLAN | Name | Subnet | Members |
|---|---|---|---|
| 10 | Core | 10.10.10.0/24 | Unraid, all 5 k3s nodes, Proxmox + 4 ML guests, Stefanos's main PC |
| 20 | Trusted | 10.10.20.0/24 | Marianna's PC, household laptops and phones |
| 30 | IoT | 10.10.30.0/24 | TVs, smart devices, printer |
| 40 | Guest | 10.10.40.0/24 | visitors, client isolation on |
| 99 | Mgmt | 10.10.99.0/24 | OPNsense, switch, AP management interfaces |

Moving off `192.168.1.x` entirely is deliberate: a changed prefix makes every stale
hardcoded address fail loudly and immediately, rather than half-working.

### Inter-VLAN policy

- **Core → anywhere:** allow. It initiates backups, scraping and replication.
- **Trusted → Core:** allow only published services — SMB/NFS to Unraid, and HTTPS to the
  ingress VIP. Not the Kubernetes API, not SSH, not Proxmox, not IPMI.
- **IoT → anywhere:** internet only. Deny all RFC1918. This is the whole point of VLAN 30.
- **Guest → anywhere:** internet only, client isolation on, no mDNS leakage.
- **Mgmt:** reachable from Core only, or over Tailscale. Never from Trusted/IoT/Guest.
- **DNS:** every VLAN's outbound `:53` is redirected to the local resolver, so devices
  with hardcoded `8.8.8.8` cannot bypass filtering.
- **Default:** deny between VLANs; each allow is written down.

## Physical topology

Confirmed 2026-09-15: the existing 8-port switch is **unmanaged** and stays in the
homelab. Two more switches are being bought — one general, one 2.5GbE.

The governing rule is that **one unmanaged switch serves exactly one VLAN**: it cannot
read tags, so every port behind it inherits whatever VLAN its uplink access port is set
to. That makes unmanaged switches perfectly good VLAN *extensions*, and useless as VLAN
*boundaries*.

    OPNsense (Lenovo)
      └── 2.5GbE MANAGED switch          <- the only VLAN-aware device; mandatory
           ├── access:Core  2.5G  main PC
           ├── access:Core  2.5G  Unraid Prague        .100
           ├── access:Core  2.5G  ML / Proxmox host    .122   (4 ML guests are VMs on it)
           ├── trunk              WiFi AP  (all VLANs, SSID -> tag)
           ├── access:Core  1G -> existing 8-port UNMANAGED (see port budget below)
           └── access:<vlan>   -> second new switch, serving ONE area
                                  (managed only if that area needs 2+ VLANs)

### Port budget on the unmanaged 8-port

Planned occupants: the 5 k3s nodes, one NIC from the Proxmox host, one of Unraid's two
NICs, and the uplink.

    5 k3s nodes                  5
    Proxmox (1 port)             1
    Unraid (1 of its 2)          1
    uplink to managed switch     1
                                ---
                                 8 of 8   -- FULL
    a 6th node                  +1        -- over capacity

It is exactly full on day one. Treat the sixth node as the event that forces either a
larger second switch or moving a device up to the 2.5G switch. Do not discover this
while holding a cable.

### Dual-homed hosts must be BONDED, not given two addresses

Unraid has two NICs and the plan puts one on each switch; the Proxmox host may end up
the same. Both switches are Core, so those are two interfaces in ONE broadcast domain.
Configured as two independent IPs that produces ARP flux, asymmetric return paths and
intermittent faults that present as application problems.

Use **active-backup bonding (mode 1)**. It is the only bonding mode that requires no
switch cooperation, so it works through an unmanaged switch and across two *different*
switches. LACP (802.3ad) is NOT an option here — it needs a managed switch at both ends
of the bond.

Done deliberately this is a gain, not a workaround: Unraid runs 2.5G primary with
automatic failover to the 1G path if the managed switch fails. Configure it explicitly;
do not arrive at it by accident.

Why this works out: the only three 2.5GbE-capable devices — main PC, Unraid and the ML
box — are all in Core, so bulk storage traffic stays on one switch and never crosses the
router. That is what makes a 1G router acceptable and router-on-a-stick survivable. The
five k3s nodes are 1G regardless, so putting them behind the unmanaged switch costs
nothing: 5 nodes plus an uplink is 6 of its 8 ports.

Port floor on the managed switch is 8, and 8 is the floor rather than comfort: uplink,
three 2.5G Core devices, an AP trunk, a Core downlink and at least one other-VLAN port
is seven before any spares.

## Consequences

### The constraint that shapes everything: the cluster stays whole

All five k3s nodes, both NAS boxes, Proxmox and the ML guests live in Core **together**.
kube-vip announces LoadBalancer IPs by ARP, which does not cross a VLAN boundary — split
the nodes and `.201` and `.204` simply stop working. Longhorn replicates between nodes
continuously and assumes a flat fast path. Every node NFS-mounts Unraid.

### Re-IP breaks things silently

The failure mode is NFS hanging, NetworkPolicies dropping, and stale Endpoints — all of
which look like application faults. `grep -rn '192.168.1.'` in the repo before starting.
The known list is in NET-11; the ones with no reconciliation at all are the hand-applied
Endpoints for `ollama-gpu` and `whisper-ryzen`, because ArgoCD refuses to manage
Endpoints.

### Wireless is the gate, not the wiring

Marianna's PC and every phone are wireless. Without an AP that maps SSIDs to tagged
VLANs, the only devices that can be segmented are the wired ones — and those are already
the trusted ones. The plan delivers nothing until that AP exists. This is the most
important item on the shopping list and the easiest to overlook.

### What this finally fixes

The flat LAN is the reason several audit findings keep recurring, and the tailnet ACL is
still the stock allow-all grant (SEC-8). Segmentation is the durable answer to that class
of problem instead of another per-host rule.

## Open questions (blockers, tracked as NET-1..3)

1. ~~Is the existing 8-port switch 802.1Q capable?~~ **ANSWERED 2026-09-15: no, it is
   unmanaged — and it is kept, as a Core-only extension behind one access port. The
   consequence is that the 2.5GbE switch MUST be managed, since it becomes the only
   VLAN-aware device in the house.**
2. Does any current AP support multi-SSID → tagged VLAN? (NET-2) — the real blocker.
3. How many NICs does the Lenovo have, and is there a slot for a second? (NET-3)

Neither remaining question blocks *buying* the managed 2.5G switch, which is required
under every answer. Both block the VLAN cutover itself.

## Alternatives considered

- **Keep the flat network, harden per-host.** Rejected: it is what we do today, and the
  same findings keep reappearing because there is no boundary to enforce.
- **Segment the cluster itself across VLANs.** Rejected: breaks kube-vip ARP and turns
  Longhorn replication into a routed problem, for no security gain — the nodes are
  uniformly trusted.
- **Keep `192.168.1.x` for Core to avoid the re-IP.** Rejected: half-migrated addressing
  is how stale references survive unnoticed. A clean prefix makes them fail loudly.
