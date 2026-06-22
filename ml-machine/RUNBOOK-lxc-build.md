# ML Machine Build — Runbook

**Host:** Proxmox `pve` @ 192.168.1.199 (SSH as root)
**Hardware:** Ryzen 9 5950X (16c/32t) · 48GB RAM (3×16GB @ 3200MHz) · RX 6700 XT (12GB VRAM, gfx1031/Navi22) · Gigabyte X570 Aorus Pro BIOS F39d
**Goal:** ML LXC stack (Ollama GPU + Whisper CPU). CKA VMs are a SEPARATE later task.

---

## Hardware inventory

| Device | Disk | Role | Status |
|--------|------|------|--------|
| Samsung NVMe 238GB (nvme0n1) | nvme0n1 | Proxmox OS | ✅ done |
| Crucial MX500 465GB (sdd) | sdd | VM/LXC disks | ⏳ not set up yet |
| Samsung 850 EVO ×2 232GB (sdb, sdc) | sdb+sdc | ZFS mirror — templates/backup | ⏳ not set up yet |
| Hitachi 1.8TB (sda) | sda | ISOs, backups, snapshots | ⏳ not set up yet |
| Lexar NM790 1TB | — | **Not present ATM** | Primary VM storage when arrives |

**Network:**
- Management: `mbnic2` (Intel I211, MAC `B4:2E:99:3D:08:EA`) — WoL enabled ✅
- VM traffic: `i10g1`/`i10g2` (Intel X540 10G) — waiting for 2.5G switch ⏳

---

## Current state (as of 2026-05-21)

- Proxmox 9.2.2 installed, SSH working, WoL enabled
- GPU is in **VFIO mode** — amdgpu/radeon blacklisted, GPU bound to vfio-pci. **Must reverse this first.**
- VM 100 (`ollama-ml`) exists but dead — SVM disabled in BIOS (reset by Q-Flash attempt). **Delete it.**
- **BIOS SVM is OFF** — NOT needed for LXC, but required for CKA VMs later
- Storage pools NOT set up yet (waiting on 2.5G switch decision; can set up sdd/sdb/sdc/sda independently)

---

## Decisions locked in

- **ML via LXC** (not VM) — AMD GPU sharing into container, no VFIO/KVM needed
- **Two containers:** Ollama-GPU (CTID 110, privileged→unprivileged) + Whisper-CPU (CTID 111, unprivileged)
- **WoL via Home Assistant on Unraid** — built-in `wake_on_lan` integration, NOT a k3s CronJob
- **CKA stays on real VMs** — separate task, needs SVM BIOS fix first
- **LiteLLM** as the single OpenAI-compatible routing gateway in k3s (GPU first → CPU fallback)

## Model decisions

| Container | Model | VRAM/RAM |
|-----------|-------|----------|
| Ollama LXC (GPU) | Gemma 3 12B Q4 (~8GB) primary + Qwen 2.5 7B Q4 (~5GB) secondary | 12GB VRAM |
| Whisper LXC (CPU) | faster-whisper large-v3-turbo | ~6GB RAM |

**12GB VRAM ceiling:** Gemma 3 27B+ and Qwen 32B+ don't fit. Not simultaneously loadable either.

## Resource allocation

| VM/LXC | Cores | RAM | Disk |
|--------|-------|-----|------|
| Ollama LXC (110) | 4 | 8GB | 80GB on sdd |
| Whisper LXC (111) | 4 | 8GB | 20GB on sdd |
| CKA control plane | 2 | 4GB | later |
| CKA worker ×3 | 2 each | 2GB each | later |
| Proxmox host | 4 reserved | 6GB | — |

---

## STEP 1 — Set up storage (do this first, sdd is needed for LXCs)

```bash
# Wipe old partitions
wipefs -a /dev/sdd
wipefs -a /dev/sdb
wipefs -a /dev/sdc

# Crucial MX500 → LVM for LXC/VM disks
pvcreate /dev/sdd
vgcreate vmdata /dev/sdd
lvcreate -l 100%FREE -n vms vmdata
mkfs.ext4 /dev/vmdata/vms
mkdir /mnt/vmdata
mount /dev/vmdata/vms /mnt/vmdata
echo '/dev/vmdata/vms /mnt/vmdata ext4 defaults 0 2' >> /etc/fstab

# Register in Proxmox
pvesm add dir vmdata --path /mnt/vmdata --content images,rootdir

# ZFS mirror from 2× Samsung 850 EVO → templates + backup
zpool create -f vmbackup mirror /dev/sdb /dev/sdc
pvesm add zfspool vmbackup --pool vmbackup --content backup,images

# Hitachi → ISOs, backups
mkfs.ext4 /dev/sda
mkdir /mnt/backup
mount /dev/sda /mnt/backup
echo '/dev/sda /mnt/backup ext4 defaults 0 2' >> /etc/fstab
pvesm add dir backup --path /mnt/backup --content backup,iso,vztmpl
```

## STEP 2 — Reverse the VFIO config, get host's amdgpu back

```bash
sed -i 's/ amd_iommu=on iommu=pt vfio-pci.ids=1002:73df,1002:ab28//' /etc/default/grub
cat /etc/default/grub | grep GRUB_CMDLINE   # verify back to "quiet"

rm -f /etc/modprobe.d/vfio.conf
sed -i '/blacklist amdgpu/d;/blacklist radeon/d' /etc/modprobe.d/blacklist.conf
sed -i '/^vfio$/d;/^vfio_iommu_type1$/d;/^vfio_pci$/d;/^vfio_virqfd$/d' /etc/modules

update-initramfs -u -k all
update-grub
reboot
```

After reboot, verify:
```bash
lspci -k | grep -A3 "0b:00"
# WANT: Kernel driver in use: amdgpu  (NOT vfio-pci)
ls -la /dev/dri /dev/kfd
# WANT: card0/renderD128 under /dev/dri, /dev/kfd present

# Note GIDs for LXC config
getent group render video
```

If `/dev/kfd` is missing: `apt install -y rocm-dkms` and reboot.

## STEP 3 — Delete dead VM 100

```bash
qm stop 100 2>/dev/null; qm destroy 100 --purge
```

## STEP 4 — Create Ollama LXC (CTID 110, privileged, GPU)

```bash
# Get Debian 12 template
pveam update && pveam available | grep debian-12
pveam download local debian-12-standard_12.7-1_amd64.tar.zst

# Create container (onboot 0 — this is the night-schedule GPU container)
pct create 110 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname ollama-gpu --cores 4 --memory 8192 --swap 2048 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs vmdata:80 --unprivileged 0 --features nesting=1 --onboot 0
```

Add GPU passthrough to `/etc/pve/lxc/110.conf` (use GIDs from Step 2):
```
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 235:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
```

Start and configure:
```bash
pct start 110 && pct enter 110

apt update && apt install -y curl

# Install ROCm (AMD official Debian/Ubuntu instructions for gfx1031)
# Then Ollama:
curl -fsSL https://ollama.com/install.sh | sh

# RX 6700 XT needs GFX version override:
systemctl edit ollama
# Add under [Service]:
#   Environment="HSA_OVERRIDE_GFX_VERSION=10.3.0"
systemctl restart ollama

# Verify GPU is used (not CPU):
ollama pull gemma3:12b
ollama run gemma3:12b
# In another terminal: rocm-smi  — should show GPU utilization
```

Note the container IP (`ip a`).

## STEP 5 — Create Whisper LXC (CTID 111, unprivileged, CPU)

```bash
pct create 111 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname whisper-cpu --cores 4 --memory 8192 --swap 2048 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --rootfs vmdata:20 --unprivileged 1 --features nesting=1 --onboot 1
pct start 111 && pct enter 111

apt update && apt install -y docker.io
docker run -d --restart=always \
  -e WHISPER__MODEL=large-v3-turbo \
  -e WHISPER__COMPUTE_TYPE=int8 \
  -p 8000:8000 \
  fedirz/faster-whisper-server:latest-cpu
```

Note the container IP.

## STEP 6 — Tailscale on both containers

```bash
# Inside each LXC:
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

Record both Tailscale IPs.

## STEP 7 — Wire IPs into the repo

```bash
# kubernetes/apps/ai/ollama-gpu/service.yaml
# kubernetes/apps/ai/whisper-ryzen/service.yaml
# Replace STREACOM_ML_TAILSCALE_IP with real Tailscale IPs
# Commit + push → ArgoCD syncs → ai app goes Synced/Healthy
```

## STEP 8 — Home Assistant wake automation (on Unraid)

Add `wake_on_lan` integration in HA:
- MAC: `B4:2E:99:3D:08:EA` (Intel I211 NIC)
- Create switch entity → automate to wake host on schedule

**Decision needed:** Whole-host sleep vs. just stopping CTID 110?
- Whole host sleeps → set CTID 110 `--onboot 1` so it starts with host
- Host stays up, just CTID 110 stops → leave `--onboot 0`, HA starts the container via Proxmox API

## STEP 9 — Migrate Ollama LXC to unprivileged (after GPU proven)

Once `ollama run gemma3:12b` works on GPU, rebuild CTID 110 as `--unprivileged 1` with idmap for render/video GIDs.

---

## LATER — CKA practice VMs (separate task, don't mix with ML work)

**Requires BIOS fix first:**
- Reboot → BIOS → Settings → AMD CBS → SVM Mode → Enabled
- Also re-verify: IOMMU=Enabled, ErP=Disabled, AC Back=Always On, WoL=Enabled, SATA=AHCI, XMP=Profile 1
- Confirm: `lsmod | grep kvm` shows `kvm_amd`

**VM template plan:**
- Debian 12 or Ubuntu 22.04, 2 vCPU, 2-4GB RAM, 40GB disk on vmdata
- Build one → golden template → linked-clone ×4 → kubeadm cluster
- Disks on Crucial MX500 (sdd via vmdata), templates on ZFS mirror (vmbackup)

---

## LiteLLM routing strategy (wire into k3s after VMs are live)

See `docs/adr/ADR-006-ai-model-routing.md` (already in repo from earlier session — check numbering).

LiteLLM config (to be deployed as k3s pod):
```yaml
model_list:
  - model_name: chat
    litellm_params:
      model: ollama/gemma3:12b
      api_base: http://<ollama-tailscale-ip>:11434  # GPU LXC
  - model_name: chat          # same name = automatic fallback
    litellm_params:
      model: ollama/gemma3:2b
      api_base: http://ollama.ai.svc.cluster.local:11434  # CPU pod in k3s
```

---

## Open questions before starting

1. **Whole-host sleep vs CT-suspend only?** Affects `--onboot` and HA automation logic.
2. **Confirm `HSA_OVERRIDE_GFX_VERSION=10.3.0`** is correct for your ROCm version on gfx1031.
3. **Lexar 1TB returning when?** Primary fast storage for CKA VMs — plan around its arrival.
