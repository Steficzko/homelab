# homelab

> From a failed Western Digital drive in 2009 to a 5-node Kubernetes HA cluster.
> This is the infrastructure that grew out of that loss.

## The short version

I'm a photographer. In 2009 a FireWire Western Digital drive failed and I lost
my entire year of work. That was the moment I stopped trusting single drives and
started taking storage seriously.

What followed was fifteen years of progressively more serious infrastructure:
a 2-bay Synology for syncing RAWs over the network (too slow), a FreeNAS build
with RAID-Z3, ZFS, ECC RAM and a SuperMicro Xeon board (still running in Greece
as a backup), TrueNAS, TrueNAS Scale, and eventually Unraid — because I wanted
something that could run Docker containers without FreeBSD getting in the way.

At some point I found Kubernetes. One thing led to another. I already knew Linux.
So I built a cluster.

## Highlights

- **5-node HA K3s** — 3 control-plane/etcd nodes + 2 dedicated worker nodes. The
  split (and *why* it isn't just "add RAM") is [ADR-030](docs/adr/ADR-030-dedicated-worker-nodes-topology-split.md).
- **GitOps for the application layer** — ArgoCD app-of-apps, 29 applications, every
  change a reviewed git commit. Honest exceptions: SOPS secrets are applied out-of-band
  by design, and Longhorn's install isn't in git yet (a known, tracked drift).
- **3-2-1 backups, actually *drilled*** — Longhorn + Velero → on-site MinIO,
  replicated off-site to Greece. The cross-site DR cutover is a real script with
  automatic failback, and I **measured ~0 s cutover downtime** on the drill — with the
  honest caveat: that's the *mechanism* with Prague still up; a real outage is RTO ≈ 1-2 min,
  RPO ≈ 1 h, one service ([details](disaster-recovery/README.md),
  [ADR-011](docs/adr/ADR-011-application-logical-backups-and-offsite-replication.md),
  [ADR-005](docs/adr/ADR-005-multi-site-dr-architecture.md)).
- **Secrets in SOPS + age** — encrypted before they reach git; every `*.sops.yaml` here
  is safe to commit. Full disclosure: one plaintext key slipped into history early on
  (`baed4916`) and was rotated + invalidated the *same day* it was caught (`a36664e`) —
  which is why `gitleaks` runs pre-commit now.
- **No inbound ports** — Cloudflare Tunnel + a Zero Trust wildcard deny-by-default
  ([ADR-010](docs/adr/ADR-010-cloudflare-zero-trust.md)).
- **32 ADRs documenting the *why* — including the ones I got wrong.** The one I'm
  most proud of is the [ADR-030 amendment](docs/adr/ADR-030-amendment-16gib-workers.md):
  I planned for 32 GB workers, the hardware turned out to be 16 GB, so I amended
  my own decision and wrote down exactly what that invalidated.

**New here? Start with [`docs/adr/`](docs/adr/) — that's where the reasoning lives.**

## The cluster

5-node K3s HA cluster: **3 control-plane/etcd nodes** (Lenovo M910q) + **2 dedicated
worker nodes** (Lenovo M920q). Control plane and workloads are split into tiers so
application memory spikes can't threaten etcd — the goal is a production-grade
self-hosted stack, the kind you'd run at a small company, but at home, on hardware
I can touch.

**Stack:** K3s · kube-vip · Longhorn · ingress-nginx · cert-manager ·
Cloudflare Tunnel · ArgoCD · Prometheus + Grafana · Velero · SOPS + age

**Public access:** Cloudflare Tunnel → Nginx Ingress → `*.kostikidis.net`

**Secrets:** Encrypted with SOPS + age before they reach git — every `*.sops.yaml`
file here is safe to commit. Full disclosure: one plaintext key leaked into history once
(`baed4916`); it was rotated and invalidated the day it was found (`a36664e`), and
`gitleaks` now runs pre-commit to keep it from recurring.

## Why this repo exists

Two reasons.

**First:** I'm working toward CKA certification. This cluster is my lab. Every
decision I've made here maps to something in the exam curriculum — HA etcd,
certificate SANs, storage classes, ingress, network policies. The
[`docs/adr/`](docs/adr/) folder documents the architecture decisions, including
the ones I got wrong.

**Second:** This is my portfolio. I run infrastructure across Prague (the cluster)
and Greece (off-site DR), operate from Erbil, work across Linux/Mac/Windows, and am
targeting a DevOps/SRE role. This repo is the evidence — and it's not a demo: it
runs real family services and a real client's app.

## Structure

```
kubernetes/
  apps/           — application manifests (ArgoCD-synced)
  bootstrap/      — ArgoCD app-of-apps + root application
  infrastructure/ — Longhorn, descheduler, cert-manager, ingress
  networking/     — cloudflared, kube-vip
  monitoring/     — Prometheus + Grafana, Loki
docs/
  adr/            — Architecture Decision Records (start here)
disaster-recovery/
  greece/         — cross-site failover/failback + downtime-probe scripts
```

## How I work

The dev environment runs as a Debian VM on my Unraid server, always on, accessed
via VS Code Remote-SSH over Tailscale from any machine. Working files live on an
NFS-mounted array share — if the VM's SSD dies, nothing of value was on it. See
[ADR-006](docs/adr/ADR-006-dev-environment.md) for the full reasoning.

I drive a lot of this with Claude Code plus a set of custom subagents for
continuity across sessions: an accountability ledger that survives context resets,
a study-notes keeper that builds CKA flashcards as I work, a pre-commit manifest
reviewer, and a "contrarian" that checks live cluster state and stops me going
down rabbit holes before I understand the real time cost.

## Blog

I write about what I build at [www.kostikidis.net](https://www.kostikidis.net).

## Status

Actively building. Five nodes, real workloads, backups and cross-site DR drilled.
The plan is to lock it down as my primary production platform once the setup is
complete and the CKA is done — and to scale it to the next client's app.

---

*Prague · Greece · Erbil · always on Tailscale*
