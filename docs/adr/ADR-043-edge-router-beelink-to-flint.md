# ADR-043 — The edge router: Beelink interim, Flint 2 as the planned permanent edge

- **Status:** Draft, 2026-10-22
- **Deciders:** Stefanos
- **Tracked in:** Plane `NET` — NET-22 (this decision), NET-24 (config export, done here),
  NET-46 (Flint cutover), NET-47 (retire Xiaomi R3 + repeater)
- **Related:** [[project_opnsense_migration]], ADR-039 (OPNsense plan, superseded record),
  ADR-044 (Traefik + the LAN Immich VIP `.210`), ADR-045 (managed switch), ADR-046 (portable cage)
- **Supersedes:** ADR-039's edge section (OPNsense, and "do not keep 192.168.1.x")

## Context

The edge was rebuilt on **2026-10-22** — ahead of the Flint 2 arriving — onto a **Beelink
"AZW ME mini" mini-PC running OpenWrt 25.12.6** (`wrt-edge`, `192.168.1.1`). It holds the public
IP on `eth1` (Vodafone already bridged, `78.45.151.25`), LAN on `eth0` via `br-lan`, and the five
VLANs the segmentation plan calls for: `lan` (untagged, `192.168.1.0/24`, infra), `iot` (VLAN 5),
`trusted` (VLAN 10), `family` (VLAN 20, guest + family for now), `mgmt` (VLAN 90). AdGuard Home
answers DNS on `:53` on every VLAN; dnsmasq sits behind it on `:5354` and does DHCP + the
split-horizon rewrites for the four Immich hosts to `.210` (ADR-044).

The Beelink has **12 GB RAM and a 57 GB disk**. The **Flint 2 (GL-MT6000) has 1 GB RAM and 8 GB
eMMC** and is still unbought. Two things follow:

1. The Beelink is not the long-term edge — it is a stopgap that happened to be on the shelf. The
   Flint 2 is the intended permanent edge: it is a supported mainline-OpenWrt device, it has the
   radios the Beelink lacks (so it can also *be* the Wi-Fi AP for the VLANs). It stays at home:
   ADR-046 rejected carrying the router with the portable cage.
2. Anything built on the edge must fit the Flint's limits. No long-term logs, metrics databases,
   or analytics on the router — those ship off-box (Loki/Prometheus in-cluster). This is already
   the standing rule ([[feedback_router_flint_budget]]); this ADR records *why*.

## Decision

1. **The Beelink stays the live edge until the Flint 2 is in hand and cut over.** It is working;
   there is no reason to rush. Cutover is NET-46, scheduled when the Flint arrives, not before.

2. **The Flint 2 inherits the Beelink's config, not a from-scratch rebuild.** The live config is
   exported and kept as the cutover template:
   `~/adr-drafts/ADR-043-flint-cutover-config-template.conf` (NET-24, done 2026-10-22). It carries
   `network`, `firewall`, and `dhcp` verbatim.

3. **What ports verbatim vs. what is rewritten on the Flint:**
   - **`firewall` and `dhcp`: verbatim.** Zones, forwardings, the per-device rules (Immich LAN
     `.210` accepts, HA↔IoT, printers, the Elegoo/Xiaomi no-WAN rules), reservations and the
     split-horizon `address`/`server` lines are all device-independent — `uci import` and reload.
   - **`network`: rewritten.** Port names differ. The Beelink is `eth0` (LAN) / `eth1` (WAN) on a
     plain bridge; the Flint is **DSA** — `wan` is its own port and LAN is `lan1`–`lan4` on a DSA
     `br-lan`. The VLAN interfaces (`br-lan.5/.10/.20/.90`, 802.1q) and the static IPs carry over,
     but the bridge `ports` list and the WAN device are Flint-specific.
   - **The trunk path changes too.** Today the TP-Link (OpenWrt 19.07.10, EOL) is the 1G trunk
     between the Beelink and KeepLink port 1 (ADR-045 amendment), a single point of failure. At
     cutover the Flint trunks straight to the KeepLink, which takes the TP-Link out of the path.
   - **`wireless`: new.** The Beelink has no radios, so its export has no `wireless`. On the Flint
     the radios become the APs for the VLAN SSIDs (iot/family on VLAN 5/20, trusted on VLAN 10),
     which **retires the Xiaomi R3 + repeater** (NET-47) and the TP-Link's AP duty.
   - **Drop `network.globals.dhcp_default_duid`** — it is the Beelink's, not the Flint's.

4. **AdGuard Home and Tailscale are reinstalled as packages on the Flint and their own configs
   restored separately** — they are not uci state, so they are not in the export. AdGuard's config
   and filter lists and the tailscale node key/state are backed up and restored by hand at cutover.
   Check after the restore that ADR-046 point 4 survived: filtering is **off per client for VLAN 1
   and IoT**. That setting protects cluster DNS and is easy to lose in a manual restore.

5. **DNS continuity at cutover (hard rule):** the Flint must be answering DNS on `:53` for all
   VLANs *before* the Beelink is unplugged — never remove a resolver before its replacement serves
   ([[project_dns_hardening_plan]] discipline). Stage the Flint on a spare IP (`.8.1`, never `.1`)
   and swap IPs last.

## Consequences

- Cutover is a config *restore*, not a rebuild: `firewall` + `dhcp` import clean, `network` is a
  known small rewrite (port map only), `wireless` is the one genuinely new piece.
- The Flint's 1 GB RAM is ample for OpenWrt + AdGuard Home + Tailscale (AdGuard idles well under
  200 MB; the Beelink currently uses ~190 MB of its 12 GB). The budget rule costs nothing here — it
  only forbids piling logs/metrics onto the box, which we were never going to do.
- The Flint doing Wi-Fi collapses three boxes (Beelink edge + Xiaomi R3 + repeater, and the
  TP-Link's AP role) toward one edge + the TP-Link as a reflashed wired AP where coverage needs it
  (NET-27). Fewer hops, no double-NAT.
- If the Flint's radios don't cover the flat, the TP-Link becomes a wired AP once it is out of the
  trunk path and has been reflashed from 19.07.10 to 24.10.3 (NET-27). The VLAN tagging is already
  on the wire, so an AP is just an SSID↔VLAN bridge.
- Risk: the config template is a point-in-time snapshot (proven on day one: the printer moved from
  .5.128 to .5.100 an hour after the first export). Any firewall/dhcp change on the Beelink
  between now and cutover must be re-exported, or the restore loses it. Re-run the export at
  cutover rather than trusting this copy.

## Not decided here

- Whether `family` (VLAN 20) splits into a separate guest VLAN 50 (NET-30) — open; the config
  ports either way.
- The managed switch / 2.5G trunking (ADR-045) and the portable two-leg cage (ADR-046) — separate.
