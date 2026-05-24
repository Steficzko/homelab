---
date: 2026-05-23
tags: [proxmox, lxc, containers, cgroups, gpu, rocm, pytorch, networking, storage, linux, cka-adjacent]
---

# LXC AMD GPU passthrough for Whisper STT — ROCm, DNS, disk, pip traps

## Goal

Stand up a self-contained Whisper speech-to-text service in a Proxmox LXC using the RX 6700 XT via ROCm — no separate ROCm install, just a PyTorch ROCm wheel.

## Problem

Five independent failure modes hit in sequence:

1. `apt update` hung silently (no DNS configured in the LXC).
2. Disk ran out mid-wheel-download (default 20 GB rootfs too small for the ROCm torch wheel).
3. `pip install pyannote.audio` overwrote the ROCm torch wheel with a CUDA build pulled from PyPI.
4. ROCm did not recognise the RX 6700 XT (gfx1031/Navi22) without an env var override.
5. pyannote.audio 4.0.4 requires `torch>=2.8.0`, which conflicts with rocm6.2's max (2.5.1).

## Solution

### 1 — Fix DNS before anything else

```bash
echo nameserver 8.8.8.8 > /etc/resolv.conf
```

Permanent fix: set DNS in the Proxmox GUI under the LXC's Network tab, or set `nameserver` in `/etc/pve/lxc/<vmid>.conf`. The resolv.conf entry is wiped on container restart unless the permanent fix is in place.

Diagnostic: if `apt update` appears to hang with no output, check `ps aux | grep apt` — you'll see an `http` method process stuck on a DNS lookup with no TCP connection open.

### 2 — Live disk resize (no LXC restart needed)

```bash
# On the Proxmox host:
pct resize 112 rootfs +20G

# Verify inside the LXC immediately — no reboot:
df -h /
```

`pct resize` expands the LVM thin-pool volume and resizes the ext4 filesystem in one shot. The running container sees the new space immediately.

### 3 — LXC GPU passthrough config (AMD)

```
# /etc/pve/lxc/112.conf
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 235:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

- Major 226 = `/dev/dri/*` (render nodes)
- Major 235 = `/dev/kfd` (AMD GPU compute, used by ROCm/HSA)

**Critical:** device majors change after a PVE host reboot. Always verify on the host after reboot:

```bash
ls -la /dev/kfd /dev/dri/renderD128
# If the leading major number differs, update lxc.cgroup2.devices.allow accordingly.
```

### 4 — PyTorch ROCm self-contained wheel

```bash
pip install torch torchaudio --index-url https://download.pytorch.org/whl/rocm6.2
```

The wheel bundles all ROCm runtime libraries. Only the `amdgpu` kernel driver on the host is needed. No `apt install rocm-*` inside the LXC.

**RX 6700 XT (gfx1031) requires an env var:**

```bash
export HSA_OVERRIDE_GFX_VERSION=10.3.0
```

Without this, `torch.cuda.is_available()` returns False and ROCm falls back silently to CPU.

Verify GPU is visible:

```bash
python3 -c "import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))"
```

### 5 — pip custom-index ordering trap

```bash
# Wrong: pyannote.audio pulls CUDA torch from PyPI, overwrites ROCm torch
pip install torch --index-url https://download.pytorch.org/whl/rocm6.2
pip install pyannote.audio   # overwrites torch with CUDA build

# Correct: install ROCm torch LAST, or force-reinstall after everything else
pip install pyannote.audio
pip install torch torchaudio --index-url https://download.pytorch.org/whl/rocm6.2
# or:
pip install --force-reinstall torch torchaudio --index-url https://download.pytorch.org/whl/rocm6.2
```

### 6 — ROCm wheel size planning

| ROCm version | torch version | wheel size | 40 GB disk? | Notes |
|---|---|---|---|---|
| rocm6.2 | 2.5.1 | ~3.97 GB | yes (tight) | max torch for rocm6.2 |
| rocm6.3 | 2.9.1 | ~4.x GB | yes | min for pyannote.audio 4.x |
| rocm7.2 | 2.12.0 | ~6.18 GB | no | needs 50 GB+ disk |

pyannote.audio 4.0.4 requires `torch>=2.8.0`. rocm6.2 (max 2.5.1) is incompatible. rocm6.3 (torch 2.9.1) is the minimum workable target for GPU transcription + diarization in one LXC.

## Why it works

**DNS / resolv.conf:** Proxmox creates LXCs without injecting host DNS config. All outbound name lookups time out silently. `apt update` gives no error because the underlying HTTP method process is blocked on `getaddrinfo()`, not a connection failure.

**pct resize:** Wraps thin-LVM resize + `resize2fs` into one command. ext4 can grow on a live mount. Same mechanism as K8s PVC expansion on a StorageClass with `allowVolumeExpansion: true`.

**cgroup2 device rules:** The LXC kernel shares the host cgroup namespace. `c 226:* rwm` means "allow char device with major 226, any minor, read/write/mknod." Major numbers are assigned by the kernel at boot and can vary between reboots.

**ROCm PyPI wheels:** AMD ships self-contained wheels bundling libamdhip64, libMIOpen, etc. The host only needs the amdgpu KMS driver for the kernel-to-hardware path.

**HSA_OVERRIDE_GFX_VERSION:** ROCm's HSA runtime checks the GPU's GFX version against a compiled whitelist. gfx1031 (Navi22/RX 6700 XT) may be absent from older wheel whitelists. The override presents the card as 10.3.0.

## CKA angle

- **cgroup2 device access** mirrors Kubernetes device plugin resources. The `c <major>:<minor> rwm` syntax is what device plugin allocations translate into under the hood.
- **DNS misconfiguration causing silent hangs** is the same failure class as broken CoreDNS — pods appear to connect but TCP never opens. Check with `nslookup` inside the pod first.
- **Live volume expansion** maps directly to patching a PVC:

```bash
kubectl patch pvc <name> -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'
kubectl get sc <name> -o jsonpath='{.allowVolumeExpansion}'
```

## Revision prompts

1. A new LXC can't reach the internet and `apt update` hangs silently. First check and permanent fix?
2. You add cgroup2 device rules for `/dev/kfd` (major 235). After PVE reboots, GPU is invisible inside the container. Why, and what's the diagnostic command?
3. You install ROCm torch, then `pip install faster-whisper`. `torch.cuda.is_available()` returns False. What happened and how do you fix it without a full reinstall?

## Anki

What command configures DNS inside a Proxmox LXC before the first apt update? | echo nameserver 8.8.8.8 > /etc/resolv.conf (permanent: set in PVE GUI network tab)
What pct command expands an LXC rootfs by 20 GB without restarting the container? | pct resize <vmid> rootfs +20G — resizes LVM thin volume and ext4 live
What are the two cgroup2 device majors needed for AMD GPU compute in a Proxmox LXC? | 226 (/dev/dri) and 235 (/dev/kfd) — verify with ls -la /dev/kfd /dev/dri/renderD128 after each PVE reboot
Why can device major numbers change between Proxmox reboots and what breaks? | Majors are kernel-assigned at boot; if /dev/kfd shifts major, the cgroup2 rule no longer matches and the GPU is inaccessible
What env var makes ROCm recognise the RX 6700 XT (gfx1031)? | HSA_OVERRIDE_GFX_VERSION=10.3.0
How do you install PyTorch ROCm without installing the full ROCm stack in the LXC? | pip install torch torchaudio --index-url https://download.pytorch.org/whl/rocm6.2 — wheel bundles all ROCm userspace libs
What pip pitfall overwrites a custom-index torch install with a CUDA build? | Installing a PyPI package that depends on torch after the custom-index install; fix: install custom-index packages last or use --force-reinstall
Minimum ROCm version for pyannote.audio 4.x? | rocm6.3 (torch 2.9.1) — pyannote.audio 4.0.4 requires torch>=2.8.0; rocm6.2 tops out at 2.5.1
