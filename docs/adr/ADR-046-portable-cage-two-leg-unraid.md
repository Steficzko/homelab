# ADR-046: Portable homelab cage — fixed inside, adaptive access leg

- **Status:** Draft, 2026-10-21
- **Related:** ADR-045 (KeepLink core switch), ADR-040 (cluster DNS), ADR-044 (tunnels as sole entry),
  NET-19, NET-38, NET-41 (address plan), NET-42 (VLAN 10 lockdown)

## Context

The homelab is meant to be picked up and run anywhere. What moves is the **cage**: the k3s nodes, their
unmanaged Netgear switch, and **Unraid** (storage). The house router (Beelink now, Flint 2 later) and the
KeepLink core switch **stay home**.

Wherever the cage lands, the network is someone else's. Usually that is `192.168.1.0/24` with the router at
`.1`; sometimes it is not (e.g. `192.168.0.0/24`).

The cage is wired to be self-contained:

- nodes `192.168.1.201-.205` (+ API VIP `.200`), static, gateway and first DNS `192.168.1.1`, fallback DNS
  `1.1.1.1` / `9.9.9.9` (`/etc/k3s-resolv.conf`);
- Unraid **eth0** (`..:9E`, 1G, on the cage switch) = `192.168.1.100`, static, bridge `br0`, the only default
  route — cluster/NFS side;
- Unraid **eth2** (`..:9F`, 2.5G) = **automatic (DHCP)** — the access leg. At home it lands on VLAN 10 and the
  router hands it `192.168.10.100` with no gateway and an infinite lease (router-side reservation).

## Decision

1. **Inside of the cage is fixed and never re-addressed.** Nodes and Unraid eth0 keep their static
   `192.168.1.x` addresses everywhere. The cluster talks to itself and to its storage over the cage switch
   regardless of the outside network.
2. **Unraid eth2 is the adaptive leg and stays on DHCP — configured router-side, never static on Unraid.**
   It is the way in on any network: it takes whatever address the local router offers. At home the address
   is pinned by a reservation on the router, not on Unraid.
3. **dev-seat (VM on Unraid) is the jump host.** It gets a second vNIC on eth2's side (bridged), so a laptop
   on the outside network reaches dev-seat directly, and dev-seat reaches every node on `192.168.1.x`.
   *(Built 2026-10-23: Unraid `br2` on eth2; dev-seat `cage-leg` enp2s0 on br0 = `192.168.1.191` static,
   never-default; `access-leg` enp4s0 on br2 = DHCP, keeps the gateway and is the VM's internet. At home the
   router reservation `dev-seat-access` pins it to `192.168.10.50`, same rule as Unraid's `.10.100`.)*
4. **Router-as-DNS on the nodes is intentional** (closes NET-19): `.1` is "whatever router the cage is
   plugged behind". At home AdGuard answers on every VLAN (full query log), but **filtering is off for
   VLAN 1 and IoT** (per-client setting), so no blocklist can break the cluster; nodes keep the
   `1.1.1.1` / `9.9.9.9` fallback if AdGuard is down. *(Owner decision 2026-10-22, option (a).)*
5. **Tailscale remains the location-independent path** whenever the cage has internet.

## Consequences

**Foreign network is `192.168.1.0/24` with router at `.1`** (the common case):
- everything works as at home: internet, tunnels, Tailscale, apps;
- check that `.100` and `.200-.205` are free there (many routers lease up to `.254`); a clash takes a node or
  Unraid off the network.

**Foreign network is anything else** (e.g. `192.168.0.0/24`):
- the cluster keeps running internally (pods, Longhorn, NFS to Unraid all work over the cage switch);
- the cage side has **no internet**: no gateway at `192.168.1.1` → Cloudflare tunnels, Tailscale on the
  nodes, image pulls and Unraid's own internet are down (Unraid's default route stays on br0);
- access is **only** via eth2: Unraid and dev-seat at their local DHCP addresses, the cluster through dev-seat;
- giving the cage internet there would need Unraid to route/NAT for it — a separate decision, not taken here.

**At home:**
- eth2 sits on VLAN 10 (workstations) at `192.168.10.100`; workstations reach Unraid directly (2.5G) without
  a router hop. NET-42 (lockdown) must account for this: the router firewall does not see that traffic.
  Router DNS hands VLAN 10 clients `.10.100` for `unraid.home.arpa` and every Unraid app name (ADR-047).
- **Nothing on the access leg is static.** Anything that must work wherever the cage lands follows eth2's
  DHCP address (host networking or the VM's own DHCP leg), never a fixed `192.168.10.x` set on Unraid.
  A container with a fixed br2 address works only at home.
- Tailscale's direct path at home: the router forwards WAN UDP 41642 → dev-seat and 41643 → Unraid, so remote
  peers on hard NAT connect without a relay. Abroad these forwards do not exist; Tailscale falls back to hole
  punching or relays.

## Arrival checklist (new location)

1. Plug the cage switch into the local network; plug Unraid eth2 into it too.
2. Check the local router is `192.168.1.1` and that `.100`, `.200-.205` are free.
3. Find eth2's address (local router's DHCP list) or use Tailscale.
4. If the network is not `192.168.1.0/24`: work through dev-seat; expect no internet on the cage side.

## Alternatives considered

- **Re-address the cage per location** — rejected: hardcoded `192.168.1.x` across NFS exports, Endpoints,
  netpols and node config (NET-11) makes every move a migration.
- **Carry the router with the cage** — rejected by the owner: the router stays home.
- **LACP bond of Unraid's two 2.5G ports** — rejected 2026-10-21: single transfers stay at 2.5G, the cage
  uplink is 1G, and it removes the adaptive leg this design depends on.
