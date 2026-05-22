# homelab

> From a failed Western Digital drive in 2009 to a 3-node Kubernetes HA cluster.
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

## The cluster

3-node K3s HA cluster on Lenovo M910q mini PCs. Every node runs control-plane,
etcd, and worker. The goal is a production-grade self-hosted stack — the kind
you'd run at a small company, but at home, on hardware I can touch.

**Stack:** K3s · kube-vip · Longhorn · ingress-nginx · cert-manager ·
Cloudflare Tunnel · ArgoCD · Prometheus + Grafana · SOPS + age

**Public access:** Cloudflare Tunnel → Nginx Ingress → `*.kostikidis.net`

**Secrets:** Encrypted with SOPS + age. All `*.sops.yaml` files in this repo
are safe to commit. Plaintext secrets never touch git.

## Why this repo exists

Two reasons.

**First:** I'm working toward CKA certification. This cluster is my lab. Every
decision I've made here maps to something in the exam curriculum — HA etcd,
certificate SANs, storage classes, ingress, network policies. The
[`docs/adr/`](docs/adr/) folder documents the architecture decisions, including
the ones I got wrong.

**Second:** This is my portfolio. I manage infrastructure across Prague and
Ptolemaida, work across Linux/Mac/Windows, and am targeting a DevOps/SRE role.
This repo is the evidence.

## Structure

```
kubernetes/
  apps/          — application manifests (ArgoCD-synced)
  bootstrap/     — ArgoCD app-of-apps + root application
  infrastructure/ — Longhorn, storage
  networking/    — cert-manager, cloudflared, ingress-nginx, kube-vip
  monitoring/    — Prometheus + Grafana
docs/
  adr/           — Architecture Decision Records
  wiki/          — runbooks and operational notes
migration/       — runbooks for migrating from Unraid Docker stack
```

## How I work

The dev environment runs as a Debian VM on my Unraid server, always on,
accessed via VS Code Remote-SSH over Tailscale from any machine. Working files
live on an NFS-mounted array share — if the VM's SSD dies, nothing of value was
on it. See [ADR-006](docs/adr/ADR-006-dev-environment-continuity.md) for the
full reasoning.

I use Claude Code with a set of custom subagents for continuity across sessions:
an accountability ledger that survives context resets, a study-notes keeper that
builds CKA flashcards as I work, a pre-commit manifest reviewer, and a
"contrarian" that checks live cluster state and stops me from going down rabbit
holes before I understand the real time cost. The agents are not in this repo
yet — still tuning them.

## Blog

I write about what I build at [kostikidis.com](https://www.kostikidis.com).
The first post about this cluster covers what happens when your AI assistant
runs out of context and you lose two days to it.

## Status

Actively building. The cluster runs real workloads. The plan is to lock it down
as my primary production server once the setup is complete and the CKA is done.

---

*Prague · Ptolemaida · always on Tailscale*
