# CLAUDE.md — Kostikidis Homelab

## What this repo is

GitOps repository for a three-node K3s cluster in Prague.
Owner: Stefanos Kostikidis — photographer/videographer turned infrastructure engineer, studying CKA.
This is personal and family infrastructure, not a demo or consulting project.

**Repo contains exactly two things:**
- `kubernetes/` — ArgoCD app-of-apps manifests, Helm values, SOPS-encrypted secrets
- `docs/adr/` — Architecture Decision Records (committed, finalized only)

**Nothing else is ever committed.** Not notes, todos, runbooks, scripts, diagrams, drafts, or personal docs.
Before any commit, ask: is this a K8s manifest or a finalized ADR? If not, do not commit it.

---

## Cluster topology

| Host | Role | IP | SSH alias |
|------|------|----|-----------|
| k3s-prg-r1 | control-plane + etcd | 192.168.1.201 | `ssh k3s-prg-r1` |
| k3s-prg-g2 | control-plane + etcd | 192.168.1.202 | `ssh k3s-prg-g2` |
| k3s-prg-b3 | control-plane + etcd | 192.168.1.203 | `ssh k3s-prg-b3` |
| pve | Proxmox VE (CKA VMs + ML LXCs) | 192.168.1.122 | `ssh pve` |
| Unraid | NAS, NFS, AdGuard, MinIO | 192.168.1.100 | — |

**VIP**: 192.168.1.200 (kube-vip — floats across control-plane nodes)
**SSH key**: `~/.ssh/id_ed25519_github` works on all homelab machines.

**LXC containers on Proxmox:**
- 110 `xt-ml` → 192.168.1.224 — Ollama GPU (RX 6700 XT), port 11434
- 111 `ryzen-ml` → 192.168.1.225 — Whisper CPU large-v3 + diarization, port 8000
- 112 `whisper-gpu` → 192.168.1.226 — Whisper GPU (ROCm), port 8000

**IP convention:** ~100s = Unraid/NAS side. ~200s = cluster side. Never cross them.

---

## SSH rules

Over SSH into any node: **read/inspect only by default.**
Commands that mutate state (kubectl apply, systemctl restart, file writes, installs, config edits) require the user to explicitly ask first.
Read-only commands (get, describe, logs, cat, df, top, journalctl) are always fine.

Use `k3s-prg-b3` as the default kubectl target — it's the most stable node.

---

## GitOps — critical rules

ArgoCD reads from **GitHub** (`https://github.com/Steficzko/homelab.git`), not the local filesystem.
**Local commits have zero effect on the cluster until pushed.**
Always push before expecting ArgoCD to pick up any change.

**Verification is mandatory after every cluster change:**
```
kubectl get application -n argocd        # confirm Synced/Healthy
kubectl get <resource> -n <namespace>    # confirm cluster matches git
```
A commit is not done until the cluster confirms it. This rule exists because two Hall-of-Shame incidents
(ollama PVC shrink, Prometheus retention cap) were "fixed" in git but never applied to the cluster.

**App-of-apps layout:**
- `kubernetes/bootstrap/apps/` — ArgoCD Application manifests (managed by root app)
- `kubernetes/apps/` — per-app Helm values and raw manifests
- `kubernetes/networking/` — ingress-nginx, cloudflared, kube-vip, cert-manager
- `kubernetes/infrastructure/` — Longhorn, descheduler
- `kubernetes/monitoring/` — Prometheus, Grafana values

---

## Secrets

All secrets use SOPS + Age. Never commit plaintext credentials.
Encrypted files end in `.sops.yaml`. Plaintext examples end in `.example`.
Pattern: edit `.sops.yaml` with `sops`, never touch raw values files for secrets.

---

## ADR workflow

1. Draft → write to `/home/stefanos/adr-drafts/` only (outside the repo entirely)
2. User reviews and approves
3. User says "push it" → copy to `docs/adr/` in repo, commit, push
4. Never write drafts into the repo directory, not even as untracked files

**Current ADR state:** ADR-001–010 in repo. Next number: ADR-011.
Old drafts with numbering conflicts at `/mnt/devdata/drafts/` — resolve before committing.

---

## Backup

**Velero** (02:00 daily): K8s resource manifests → MinIO at 192.168.1.100:9100, bucket `velerok3s`, TTL 30d.
**Longhorn** (03:00 daily): Volume data → MinIO at 192.168.1.100, bucket `longhornk3s`, retain 30.

Volumes included in Longhorn daily backup have label `recurring-job.longhorn.io/daily-backup=enabled`.
To add a new volume: `kubectl label volumes.longhorn.io <pvc-name> -n longhorn-system recurring-job.longhorn.io/daily-backup=enabled`

Both backup targets are on the same Unraid box — a known SPOF.

---

## Known operational quirks

**`/dev/kfd` major number drift** — changes every time Proxmox reboots. After any PVE reboot,
check `ls -la /dev/kfd` on the host and update LXC 110's cgroup rule in `/etc/pve/lxc/110.conf`
to match the new major number. This gates the entire GPU inference stack.

**PVC sizing is a one-way ratchet** — Longhorn PVCs can expand but never shrink.
Size once with headroom. Do not try to rightsize downward.

**Velero + Longhorn are not coordinated** — Velero backs up manifests, Longhorn backs up data,
separately, one hour apart. No CSI external-snapshotter is installed. Restoring requires
both: Velero restore (manifests) + Longhorn volume restore (data).

---

## Running services (key namespaces)

| Namespace | What |
|-----------|------|
| `ai` | LiteLLM gateway, Ollama (CPU), Open WebUI, Whisper |
| `nextcloud` | Nextcloud + postgres + redis |
| `paperless` | Paperless-ngx (Xartura) + postgres |
| `paperless-drali` | Paperless-ngx isolated instance for Dr. Ali |
| `obsidian-livesync` | CouchDB for Obsidian LiveSync |
| `n8n` | n8n automation (Telegram → Whisper → Obsidian) |
| `studioconcreteluka` | WordPress + MariaDB (client site, internet-facing) |
| `monitoring` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| `velero` | Velero backup operator |
| `ingress-nginx` | Ingress controller |
| `cloudflare-tunnel` | Cloudflare tunnels (no inbound ports) |
| `cert-manager` | TLS via Cloudflare DNS-01 |

---

## What not to do

- Do not commit anything outside `kubernetes/` or `docs/adr/`
- Do not push to GitHub without the user asking — local commits are staged, not deployed
- Do not apply `kubectl` mutations without explicit request (SSH read-only rule)
- Do not write ADR drafts inside the repo directory
- Do not shrink PVCs
- Do not add consulting framing to anything (this is personal infrastructure)
- Do not consider a fix done until `kubectl get` confirms the cluster agrees with git
