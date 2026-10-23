# ADR-040 — Cluster DNS no longer inherits the nodes' resolv.conf

- **Status:** Draft (2026-09-17) — describes what is RUNNING since 2026-09-16
- **Deciders:** Stefanos
- **Relates to:** ADR-004 (internal DNS, superseded — LAN-side DNS, not cluster DNS),
  ADR-036 (bootstrap components under GitOps), ADR-039 (network rebuild, where "where does
  DNS live" gets decided for the LAN)
- **Tracked in:** Plane NET-17 (the one piece still outside git)

## Context

CoreDNS in k3s runs with `dnsPolicy: Default` and no mounted resolv.conf, so its upstreams are
whatever the *node* has in `/etc/resolv.conf` at pod creation. Every node runs Tailscale with
`CorpDNS: true`, and Tailscale owns that file. It wrote:

    nameserver 100.100.100.100
    nameserver fd7a:115c:a1e0::53
    search taila09f30.ts.net

The nodes have no IPv6 default route. So every cluster DNS query went through tailscaled's
MagicDNS resolver, and every AAAA lookup either failed or timed out on an unroutable
nameserver. This was never decided; it is what happens when Tailscale is installed on a node
after k3s.

It cost real things before it was found. On 2026-09-16 at 01:15Z the Vaultwarden backup died
because `apk add sqlite` could not resolve `dl-cdn.alpinelinux.org`; ArgoCD went Degraded and
xyOps alerted every 30 minutes for nine hours about the Job, while the actual damage — the
password manager with no backup for two nights — stayed silent, because the watchdog's age
threshold and the Kuma push interval stack to ~52 h (STOR-36). brain-capture's `EAI_AGAIN` on
`api.telegram.org` had the same cause.

Two further facts shaped the fix:

1. Nothing in the cluster resolves tailnet names. Every reference in `kubernetes/` to a tailnet
   host is a raw 100.x address. The single `.ts.net` mention is `tailscale serve` *presenting* a
   Let's Encrypt name for Grafana, which needs no resolver.
2. CoreDNS was a single pod, and k3s regenerates
   `/var/lib/rancher/k3s/server/manifests/coredns.yaml` from an embedded template on every
   server start (mtime = k3s ActiveEnterTimestamp + 1 s, all three servers). A `kubectl scale`
   or an edit to that file is undone at the next restart.

## Decision

Three layers, each independent of the others, applied 2026-09-16 in this order.

### 1. Take Tailscale out of the nodes' DNS path

`tailscale set --accept-dns=false` on all five nodes. Tailscale restores whatever each node had
before it took over: r1 and g2 came back with `1.1.1.1` + `8.8.8.8`, b3/w1/w2 with the router
`192.168.1.1`. That inconsistency is accepted — after layer 2 the cluster does not read these
files at all, and unifying host DNS belongs to the OPNsense/Pi-hole decision (ADR-039, NET).

Rollback is one command per node and needs no k3s restart.

### 2. Give kubelet its own resolv.conf

`/etc/k3s-resolv.conf` on every node:

    nameserver 192.168.1.1
    nameserver 1.1.1.1
    nameserver 9.9.9.9
    options timeout:2 attempts:2

wired in with `resolv-conf: /etc/k3s-resolv.conf` in `/etc/rancher/k3s/config.yaml` — the
config file, NOT the systemd unit, because the k3s install script rewrites the unit on upgrade
and leaves config.yaml alone. Agents w1/w2 had no config.yaml before and got one containing
only this key. Applied with rolling restarts, agents first, then the three etcd servers one at
a time with `kubectl wait --for=condition=Ready` and an etcd health check between each.

Effect: CoreDNS's injected resolv.conf is now that file, verified by `coredns_forward_requests_total`
showing three upstreams sharing the load and no `fd7a:` series. Cluster DNS no longer depends
on host DNS, so Tailscale could own `/etc/resolv.conf` again tomorrow without the cluster
noticing.

Reference copies: `kubernetes/bootstrap/k3s-server-config.yaml` is the repo's record of what
config.yaml should contain and MUST gain the `resolv-conf` line (drift from this ADR until it
does). Backups of the pre-change files sit next to them as
`config.yaml.bak-20260916-dns` on the three servers.

### 3. Hold CoreDNS at two replicas without owning CoreDNS

A HorizontalPodAutoscaler `kube-system/coredns` with `minReplicas = maxReplicas = 2`. It is a
separate object k3s never regenerates; whenever the addon controller re-applies `replicas: 1`
the HPA raises the Deployment back within its sync period. The packaged Deployment already
carries a `DoNotSchedule` hostname spread constraint, so the two pods land on different nodes.
Proven by killing one pod under a 2-second resolution loop, and by surviving the b3 server
restart the same afternoon.

Rejected: `coredns.yaml.skip` plus the whole CoreDNS manifest in git. That disowns the
ConfigMap, the Service with its pinned ClusterIP and the RBAC in one move, and makes this repo
responsible for CoreDNS's upgrade path across every future k3s release — on a stack whose
stated end state is Talos + Flux. The HPA is a hack and it is the right one.

The HPA lives in `kubernetes/bootstrap/coredns/` under its own Application (ADR-036 pattern,
`prune: false`, `selfHeal: true`).


### 4. (added 2026-09-22) Stub the old search suffix so pre-change pods stop leaking upstream

Layer 2 fixed what kubelet injects into *new* pods. A pod's resolv.conf is written at sandbox
creation, so the 210 pods running since before 2026-09-16 kept the search list
`… cluster.local taila09f30.ts.net`. With `ndots:5`, `postgres.bjj.svc.cluster.local` (four
dots) is tried as `postgres.bjj.svc.cluster.local.taila09f30.ts.net` — an upstream query —
before the bare name. glibc walks on after a SERVFAIL; musl (Alpine: n8n, WordPress, Firefly,
Plane, Penpot, Nextcloud) returns EAI_AGAIN on the first one. So every WAN packet-loss episode
(the uplink has been lossy since 2026-09-15) surfaced as in-cluster database lookups failing
in n8n ("The DNS server returned an error"). ~70% of CoreDNS upstream traffic was this junk.

`kubernetes/bootstrap/coredns/custom.yaml` (commit 292cd81): ConfigMap `coredns-custom`, which
the k3s Corefile imports via `/etc/coredns/custom/*.server` and never regenerates, with a
`taila09f30.ts.net` server block answering NXDOMAIN + a local SOA from the `template` plugin.
NXDOMAIN, not SERVFAIL, is what makes every resolver advance to the next search candidate.
Verified: 0 ms answer with the local SOA, upstream forward counter unchanged over 30 queries,
an old Alpine pod resolves `postgres.bjj` first try. Nothing in the cluster resolves tailnet
names, so the stub costs nothing; it can stay after the last old pod is recreated.

Lesson: a resolv.conf change is not done when the nodes restart; it is done when the pods do.

## Consequences

- Cluster DNS is decoupled from both the router and Tailscale. Losing the router still costs
  LAN-side name resolution (ADR-004's inverted lesson), but pods keep resolving through
  1.1.1.1 / 9.9.9.9.
- CoreDNS survives losing a node.
- Two things remain host-side and are lost on a node rebuild: the resolv-conf file + config
  line (five nodes), and the Tailscale DNS setting. `kubernetes/bootstrap/k3s-server-config.yaml`
  is the checklist; a rebuilt node must be diffed against it.
- Backup jobs that install packages at runtime were the canary for this and are the wrong
  shape regardless; the Vaultwarden job now runs an image with sqlite baked in (ef96f48).
- When the LAN gets its own resolver (OPNsense box, NET), the first nameserver in
  `/etc/k3s-resolv.conf` should become that resolver. The public fallbacks stay.

## Alternatives considered

- **Leave Tailscale DNS on and only add `resolv-conf`.** Would have worked for the cluster, but
  leaves five nodes whose own tooling (apt, ssh, tailscale control) resolves through an
  unroutable IPv6 nameserver half the time. No reason to keep a broken path for nothing.
- **Point CoreDNS at Tailscale's resolver deliberately** (MagicDNS for tailnet names in-cluster).
  Nothing needs it (fact 1 above), and it would make every pod's DNS depend on tailscaled.
- **Fix upstream in the Corefile** (`forward . 1.1.1.1 9.9.9.9` instead of `/etc/resolv.conf`).
  The Corefile is inside the regenerated addon manifest — same restart problem as the replica
  count, and the `coredns-custom` ConfigMap override only adds zones, it does not replace the
  default forward.
- **PodDisruptionBudget instead of an HPA** for availability. A PDB protects existing replicas
  during drains; it cannot create the second replica that k3s keeps deleting.
