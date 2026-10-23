# ADR-007 Amendment — Sharing the ML Boxes to martunia over Tailscale

**Status:** Draft — amends ADR-007 (Proxmox ML node architecture). Not committed.
**Date:** 2026-09-09

## Context

ADR-007 defines the Proxmox ML node with its LXCs — `xt-ml` (LXC 110, RX 6700 XT,
Ollama on `192.168.1.224:11434`) and `ryzen-ml` (LXC 111, CPU, faster-whisper on
`192.168.1.225:8000`, Sorani whisper on `:8001`). It says nothing about who outside the
Prague LAN may use them.

Marta's box `martunia` (`100.78.162.96`, `martunia-work.tail349bf3.ts.net`) lives on
**her own tailnet** and is shared into ours. Access in the other direction works only
for nodes we share to her tailnet: today `unraid-ptolemaida` (Greece, for Kopia -> MinIO
`:9100/:9101` and the xyOps satellite -> conductor `:5522`) and `proxmox-server`
(`100.70.109.10`, the ML node's Proxmox host). She cannot reach Prague LAN addresses at
all (verified 2026-09-09: `192.168.1.203:6443` and node tailnet IPs time out from
martunia). The LXCs themselves are not tailnet nodes.

The tailnet policy was the stock `{src:*, dst:*, ip:*}` grant, so a shared node was
shared **whole**: `proxmox-server` exposed the PVE web UI (`:8006`) and SSH (`:22`,
root password auth per COMP-8) to every shared user, not just the ML ports.

## Decision

1. **Expose the two ML services on the Proxmox host's tailnet address with
   `tailscale serve` TCP forwards**, tailnet-only, persistent:

   ```
   tailscale serve --bg --tcp 11434 tcp://192.168.1.224:11434   # xt-ml Ollama
   tailscale serve --bg --tcp 8000  tcp://192.168.1.225:8000    # ryzen-ml faster-whisper
   ```

   Sorani (`:8001`) is deliberately not shared. No new tailnet nodes, no TUN passthrough
   into the LXCs, no subnet routes. Non-loopback TCP backends work despite the docs
   suggesting loopback only (the b3 Grafana serve already relied on that).

2. **Share `proxmox-server` to Marta's tailnet** (already in place, verified from
   martunia: both ports answer 200).

3. **Replace the stock allow-all policy with the first real grants:**
   - `autogroup:member -> * : *` — own devices unchanged.
   - `autogroup:shared -> 100.85.129.88 : *` — Greece stays exactly as it was for shared
     users (Kopia, xyOps), to be narrowed once every shared user's needs are enumerated.
   - `autogroup:shared -> 100.70.109.10 : 11434, 8000` — the ML share and nothing else on
     the Proxmox host. `:8006` and `:22` stop being reachable by shared users.
   - `tests` assert the member paths; the shared-user path is verified live from
     martunia because the ACL test evaluator cannot model a shared identity by IP.

   Policy file kept at `~/tailscale-acl-2026-09-09.hujson`; the previous policy at
   `~/tailscale-acl-before-2026-09-09.hujson`. Applied via the API (SEC-8's
   "policy-as-file" starts here; tagging the fleet is still open).

## Consequences

- Ollama and whisper are unauthenticated. Reach is now: Prague LAN, all own tailnet
  devices, and shared users on exactly two ports of one host. That is the accepted
  exposure; putting LiteLLM keys in front is the upgrade path if a non-family user is
  ever added.
- `tailscale serve` on the Proxmox host is host-level config outside Git, like the
  Grafana serve on b3. Both are recorded in CurrentState with their undo commands:
  `tailscale serve --tcp=11434 off`, `tailscale serve --tcp=8000 off`.
- Any node shared to an external tailnet that is **not** Greece or proxmox-server loses
  shared-user access under the new policy. From martunia only those two are visible;
  other shared-in identities (`kostikidoumarianthi@`, TopMountain, WaveyAvenue, Elwany)
  were not checked from their side and this is the residual risk of the change.
- COMP-8 (Proxmox root SSH with password auth) becomes less urgent from the tailnet
  side but is unchanged on the LAN.

## Verification

From martunia: `100.70.109.10:11434/api/version` 200, `:8000/health` 200,
`100.85.129.88:9100` 200, Prague addresses unreachable. After the policy change:
`:8006` and `:22` on `100.70.109.10` must fail from martunia and still work from a
member device.
