# ADR-002: Infrastructure Split (K3s vs Unraid vs ML Machine)

**Status:** Accepted  
**Date:** 2026-05-15

## Context

The homelab runs on multiple machines with different strengths. The question is which workloads belong where.

## Decision

### Unraid Server (CWWK N305) — NAS + Media + Home Automation

Hosts everything that requires direct filesystem access or LAN-level hardware integration:

- **Media streaming stack:** Jellyfin (Intel iGPU hardware transcoding), qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr, Navidrome, Audiobookshelf
- **Home Assistant** — home automation and LAN device discovery *(the WoL-orchestrator role described below is obsolete — see the correction in the ML section)*
- **NFS exports** — 16 shares, each restricted to an explicit list of client IPs

> **Correction, 2026-08-30.** This line previously read "multiple shares with per-share credentials
> (least-privilege per consumer)". **That was never true, and it is a security claim, which makes it
> the most damaging inaccuracy in this repo.** Verified against `/etc/exports` on Prague Unraid:
> every share is `sec=sys` — NFSv3 `AUTH_SYS`, where the client asserts a UID and the server
> believes it. There are no credentials and there never were. What exists is a per-share **IP
> allow-list**, which is a real control but a materially weaker and different one: it authenticates
> the host, not the user, and it is only as strong as the assumption that no untrusted machine
> holds one of those IPs.
>
> **10 of the 16 shares carry `no_root_squash`**, meaning root on any allowed host is root on the
> share — including `NextCloud`, `Immich_Database`, `K3sAppData`, `Paperless-ngx`, `Team_Elwany`
> and `penpot-assets`. The remaining 6 use `all_squash` with `anonuid`/`anongid`, which is the
> safer posture.
>
> This is recorded rather than quietly reworded because the gap between the two descriptions is
> exactly the gap a reader of this repo would be misled by. The honest summary is: **NFS here is
> protected by network position, not by authentication.** That is a defensible choice on a trusted
> LAN; describing it as least-privilege credentials was not. (An earlier audit finding — one share
> exported to `*` — is separately fixed: zero wildcard exports remain.)

The *arr stack must share one filesystem with qBittorrent so that Radarr/Sonarr can hardlink completed downloads to their media libraries. Hardlinks are instant and cost no extra disk space; crossing a filesystem boundary forces a full copy.

### K3s Cluster (3× Lenovo M910q, i5-8400T) — Application Platform

> **Correction, 2026-08-30:** the cluster is **five nodes**, not three. `k3s-prg-w1` (.204) and
> `k3s-prg-w2` (.205) joined as agents in June 2026 — see ADR-030. The three M910qs remain the
> control-plane/etcd members; the two workers carry the application load.

Hosts all apps that do not require direct filesystem access to media:

- Immich (photo management) — mounts photos NFS share from Unraid
- Nextcloud — file sync and source of truth for voice memos and photo dumps
- Vaultwarden, Paperless-ngx, n8n, Obsidian LiveSync (CouchDB)
- Homepage dashboard, Prometheus + Grafana monitoring
- Cloudflare Tunnel, cert-manager, ingress-nginx
- **Light ML tier:** small/short voice memos processed by a Whisper pod on the cluster CPUs (always-on, no wake cost)

### ML Machine (Debian, AMD Ryzen 7 3800X, 32 GB RAM, RX 6700 XT 12 GB VRAM) — Heavy GPU Inference

Dedicated to workloads that need GPU acceleration. Normally sleeps; woken via WoL by Home Assistant.

> **Correction, 2026-08-30:** this no longer describes reality. ML compute is **four always-on
> Proxmox LXCs** on `pve` (192.168.1.122): `xt-ml` (110, GPU), `ryzen-ml` (111, CPU), `whisper-gpu`
> (112) and `DrGemma` (113). Nothing sleeps and nothing is woken by Home Assistant; the wake logic
> below was never carried into the LXC topology. See ADR-007 for the architecture that replaced it.
> Power was addressed differently in the end — PVE governor/EPP/PCIe tuning took the host from
> ~230 W to ~170 W, which is where the saving the WoL design was chasing actually came from.

- **Whisper large-v3 (multilingual)** — runs on CPU (3800X + 32 GB RAM). Stays as a persistent process.
- **Gemma 3 12B** — runs on GPU via Ollama + ROCm. ~8 GB VRAM at Q4_K_M. This is the ceiling for 12 GB VRAM.
- Because Whisper uses CPU/RAM and Gemma uses VRAM, both stay resident simultaneously with no conflict.

**Wake logic (orchestrated by Home Assistant):**
1. Nextcloud folder watcher detects new voice memo or photo dump
2. File size/duration check:
   - Small → route to K3s light tier, do not wake ML machine
   - Large → HA sends WoL magic packet → waits for machine online → triggers pipeline
3. Pipeline: Whisper → raw transcript → Gemma → cleaned note + summary → written back to Nextcloud
4. HA optionally suspends ML machine when pipeline is idle

## Consequences

- Jellyfin and the *arr stack are NOT in K3s — they live on Unraid. The `kubernetes/apps/` directory does not contain these.
- Production Immich in K3s requires an NFS PersistentVolume pointing to the Unraid photos share.
- The ML machine is not a K3s node — it is called remotely via Tailscale (Ollama API on port 11434).
- Future: a GPU K3s node (ASUS TUF B450 + RTX 3060) is planned for cluster-native GPU workloads (see `kubernetes/apps/ai/`).
