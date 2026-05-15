# ADR-002: Infrastructure Split (K3s vs Unraid vs ML Machine)

**Status:** Accepted  
**Date:** 2026-05-15

## Context

The homelab runs on multiple machines with different strengths. The question is which workloads belong where.

## Decision

### Unraid Server (CWWK N305) — NAS + Media + Home Automation

Hosts everything that requires direct filesystem access or LAN-level hardware integration:

- **Media streaming stack:** Jellyfin (Intel iGPU hardware transcoding), qBittorrent, Radarr, Sonarr, Prowlarr, Bazarr, Jellyseerr, Navidrome, Audiobookshelf
- **Home Assistant** — home automation, LAN device discovery, and WoL orchestrator for the ML machine
- **NFS exports** — multiple shares with per-share credentials (least-privilege per consumer)

The *arr stack must share one filesystem with qBittorrent so that Radarr/Sonarr can hardlink completed downloads to their media libraries. Hardlinks are instant and cost no extra disk space; crossing a filesystem boundary forces a full copy.

### K3s Cluster (3× Lenovo M910q, i5-8400T) — Application Platform

Hosts all apps that do not require direct filesystem access to media:

- Immich (photo management) — mounts photos NFS share from Unraid
- Nextcloud — file sync and source of truth for voice memos and photo dumps
- Vaultwarden, Paperless-ngx, n8n, Obsidian LiveSync (CouchDB)
- Homepage dashboard, Prometheus + Grafana monitoring
- Cloudflare Tunnel, cert-manager, ingress-nginx
- **Light ML tier:** small/short voice memos processed by a Whisper pod on the cluster CPUs (always-on, no wake cost)

### ML Machine (Debian, AMD Ryzen 7 3800X, 32 GB RAM, RX 6700 XT 12 GB VRAM) — Heavy GPU Inference

Dedicated to workloads that need GPU acceleration. Normally sleeps; woken via WoL by Home Assistant.

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
