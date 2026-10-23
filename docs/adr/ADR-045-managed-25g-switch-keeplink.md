# ADR-045: Managed 2.5 GbE switch (KeepLink KP-9000-9XHML-X) as the rack core

- **Status:** Draft, 2026-10-20
- **Supersedes:** the switch section of ADR-039 (network segmentation), whose 2026-09-22 replan said
  "cluster and both NAS stay on the unmanaged 8-port, managed switch and VLANs deferred with no date".
- **Related:** ADR-039 (VLAN plan, Flint 2), ADR-040 (cluster DNS), ADR-041 (Longhorn HDD tier).

## Context

On 2026-10-20 a KeepLink KP-9000-9XHML-X (8× 2.5 GbE RJ45 + 1× 10 GbE SFP+, web-managed,
Realtek RTL8372/8373 class, firmware V100.9.4 of Aug 2024, no vendor firmware channel) was
installed in the Prague rack. It was installed before this decision was written; this ADR records
the resulting topology and the decisions it forces.

Observed state after install (switch MAC table + host checks):

| Switch port | Link | Device |
|---|---|---|
| 1 | 2500 full | 192.168.1.157 (client, a8:a1:59:32:10:21) |
| 2 | 1000 full | uplink to the old unmanaged 8-port switch — all five k3s nodes |
| 3 | 2500 full | Unraid NodeRepy eth0 (I226-V) — br0 192.168.1.100, dev-seat VM |
| 4 | 1000 full | router side (Vodafone ARRIS .1) |
| 6 | 1000 full | Proxmox pve nic0 (igb, 1 GbE) — LXCs .224–.228 |
| 5, 7, 8 | down | free |
| 9 (SFP+) | empty | free |

Unraid's second I226-V port (eth2) was briefly cabled straight into the old 8-port; it took a DHCP
lease (.212) and a second default route, and each address event restarted Unraid's NFS server
(2 min 7 s without nfsd). The owner removed that cable the same day.

The install also cut pve's link for 11 minutes (14:41–14:52); no alert reached anyone because
PVEExporterDown was warning/15m (made critical/5m the same day, COMP-28).

Facts that bound the design:

- k3s nodes have 1 GbE NICs (e1000e). The old 8-port is 1 GbE. The inter-switch link (port 2) is
  1 GbE. Cluster↔Unraid traffic is therefore capped at 1 GbE in aggregate regardless of Unraid's
  2.5 GbE port; measured 118 MB/s aggregate from two nodes.
- pve has two unused 10 GbE ports (int10g1/int10g2); Unraid has an unused 10 GbE Aquantia
  (eth1, 10.10.10.10/24, MTU 9000); the switch has one SFP+ cage.
- Every NFS export, the manual Endpoints (immich-ml-ryzen/-unraid, ollama-gpu, whisper-ryzen,
  whisper-rtx), netpol ipBlocks and the k3s node config hard-code 192.168.1.0/24 (ADR-039 inventory
  requirement, still not done).
- The switch sits on a DHCP lease (.168) inside the router's pool; admin UI is HTTP only;
  factory password status unverified.

## Decision

1. The KeepLink is the rack core. The old unmanaged 8-port stays as the cluster leaf behind port 2
   until the nodes are re-cabled directly into the KeepLink (five free ports exist only if port 1
   moves; otherwise this needs the SFP+ uplink or a second managed switch).
2. Unraid keeps a single L3 presence on the LAN: br0 = .100 on one physical port. No second
   addressed NIC in 192.168.1.0/24. The owner's intent is to swap the Unraid interface rules so
   the port that goes to the cluster becomes eth0/br0 and the 2.5 GbE port on the KeepLink becomes
   eth2 for a future tagged VLAN. This is a planned maintenance (Unraid reboot: NFS stale handles
   in Immich pods, xyOps/Kuma/MinIO/ML-fallback down, dev-seat down) and only after item 4.
3. The switch gets a static management address outside the DHCP pool (NET-33 planned .2), the
   admin password is changed, and the UI is only reached from the LAN/tailnet (it has no TLS).
4. No VLAN is created until the 192.168.1.x inventory from ADR-039 exists and the DHCP pool /
   eth2 overlap (NET-32) is resolved.
5. 10 GbE is the next bandwidth step, not more 2.5 GbE: one SFP+ DAC from the KeepLink to pve's
   int10g or Unraid's Aquantia. Which one is decided when ADR-041's HDD tier or a 10 GbE NAS
   path is actually needed.

## Consequences

- Nothing about the cluster's storage path changed today; it is 1 GbE as before.
- The pve outage proved the hypervisor needs its own page (done) and that the ML LXCs have no
  direct probe (open, COMP-28).
- Immich's Unraid ML fallback had never cached the SigLIP2 model; the first failover cost two
  minutes of HTTP 500. It is cached now.
- Debt accepted knowingly: a managed switch without a VLAN plan is just a faster unmanaged switch
  with a web page. The page must not become the plan; ADR-039 does.

## Amendment 2026-10-22 — VLANs went live (items 2 and 4 superseded)

Owner decision on the night of 2026-10-21/22, made with the hardware in hand rather than waiting
for the Flint 2. What changed, all verified on the running boxes:

- **Item 4 is superseded.** VLANs exist before the full 192.168.1.x inventory: 10 trusted
  (`192.168.10.0/24`), 5 IoT (no internet), 20 family (internet only), 90 mgmt (address only;
  the KeepLink firmware cannot move its own admin onto a VLAN, so it stays on VLAN 1 at `.2`).
  The router is the Beelink ME mini on OpenWrt (interim for the Flint 2); the old TP-Link is an
  AP + VLAN switch in front of KeepLink port 1. The inventory became the address plan instead
  (NET-41): `.1–.10` network gear, DHCP `.20–.99` on VLAN 1, `.100` = each VLAN's staple
  device, owner's devices `< .100`, Marianna's `> .200` on VLAN 10. NET-32 (pool vs eth2
  overlap) was cancelled — eth2 left VLAN 1.
- **Item 2 is superseded by ADR-046.** Unraid now has two addressed legs on purpose: br0
  `.1.100` (cluster/NFS, fixed) and eth2 on VLAN 10, DHCP-reserved router-side to `.10.100`
  with no gateway. LACP was rejected. The interface swap described in item 2 did not happen.
- DNS: AdGuard Home on the router answers every VLAN; filtering is off for VLAN 1 and IoT
  (ADR-046 point 4). dnsmasq keeps DHCP and `home.arpa` names on `:5354`.
- Not done, and still the plan: firewall lockdown of VLAN 1 (NET-42) last; guest VLAN 50 and
  an IoT SSID with the Flint 2.

The rest of ADR-045 (KeepLink as core, static `.2` + password, 10 GbE next) stands.
