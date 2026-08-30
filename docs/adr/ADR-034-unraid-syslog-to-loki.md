# ADR-034: Ship Unraid syslog to Loki (off-box), keep flash mirror as fallback

**Status:** Accepted — implemented 2026-08-26, verified 2026-08-31 (published from draft)

> Verified before publishing: `/boot/config/rsyslog.d/50-loki.conf` on Prague Unraid forwards
> `*.* @@(o)192.168.1.201:1514;RSYSLOG_SyslogProtocol23Format`, and the `promtail-syslog`
> LoadBalancer is live on that address. This ADR was marked Accepted *and implemented* while
> sitting in a drafts folder — it had no reason not to be in the repo.
**Context date:** 2026-08-26

## Context

Greece (`unraid-ptolemaida` / PtolemRaider) went down uncleanly at 07:55:49 on
2026-08-26. Investigating the cause was impossible: Unraid's root filesystem is a RAM
disk, `/var/log/syslog` dies with the box, `/boot/logs/` held only a diagnostics zip
from 2025, and `wtmp` began at the current boot. Every pre-crash log was destroyed by
the reboot itself.

This is not a one-off. No parity check is scheduled on that box, so every entry in
`parity-checks.log` was triggered — Mar 3, Mar 17, Jul 8, Jul 17, Aug 1, Aug 26 — i.e.
unclean shutdowns roughly every 2-3 weeks, none of them diagnosable. Prague also had an
unclean shutdown (2026-08-24 10:03, `forcesync` present) — the one behind the stale NFS
handles. Neither box has a UPS.

## Decision

Both Unraid boxes forward syslog over TCP to **promtail -> Loki**, which already runs in
the cluster. The **`/boot/logs/syslog` flash mirror stays enabled** as a fallback.

## Why not write to a local SSD

The obvious idea, and it does not work. Unraid mounts the array and cache pools *after*
boot and unmounts them *before* shutdown completes; its own `rsyslog_config` script gates
local logging on disk mount/unmount events. A disk path is unavailable at exactly the
moment the last lines matter. `/boot` (USB flash) is mounted first and released last,
which is why Unraid hardcodes `$template flash,"/boot/logs/syslog"`.

But flash has two flaws: it wears the stick, and it is only readable if the box comes
back. For a DR site in another country that second point is decisive — off-box is the
only copy that survives the machine.

## Consequences

- Logs survive the box dying, are queryable in Grafana, and sit alongside cluster logs.
- Flash mirror retained: remote logging loses whatever is in flight when power cuts, which
  is precisely the scenario under investigation. Belt and braces, and it costs one toggle.
- Flash wear continues while the mirror is on. Revisit if a stick gets flaky.

## Implementation notes (the traps)

1. **promtail's syslog receiver is RFC5424 ONLY.** rsyslog defaults to RFC3164. Both boxes
   must send `@@(o)<host>:1514;RSYSLOG_SyslogProtocol23Format` — `@@` TCP, `(o)`
   octet-counted framing. Without this promtail logs
   `invalid or unsupported framing` and drops the connection.
2. **`externalTrafficPolicy: Local` is required.** With the default (Cluster), kube-proxy
   MASQUERADEs external traffic to the node IP, so promtail never sees the NAS address and
   an `ipBlock` for it can never match. Safe because promtail is a DaemonSet — every node
   has a local endpoint.
3. **The `monitoring` namespace has a default-deny ingress netpol.** Port 1514 needs an
   explicit rule. Applying it with `kubectl` is useless: the app runs `selfHeal`, so ArgoCD
   reverts it within seconds. It must go through Git.
4. **`/etc` on Unraid is tmpfs.** The rule lives at `/boot/config/rsyslog.d/50-loki.conf`
   with an `install` + `rc.rsyslogd restart` hook appended to `/boot/config/go`.
5. **Queued forwarding** (`$ActionQueueType LinkedList`, `$ActionResumeRetryCount -1`) so a
   promtail or link outage never blocks logging on the NAS itself.
6. Greece targets the k3s node over the **tailnet** (`100.120.7.31`) — it has no LAN route
   to Prague. Prague uses `192.168.1.201`.

## Known ceiling

Each box points at a single k3s node. If that node is down, that box's shipping stops until
it returns (the queue holds, then drains). A VIP or a second target would remove this; not
worth the complexity yet.

## Not addressed by this ADR

The actual cause of the unclean shutdowns. **Neither box has a UPS** — that remains the real
fix, and this ADR only ensures the next occurrence is diagnosable.
