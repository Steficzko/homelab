# ADR-007 — Proxmox ML Node: GPU Inference Isolation, CPU Transcription Split, and WoL Power Strategy

## Status
Accepted

## Context

ADR-002 documented the original ML machine as a Debian system with a Ryzen 7 3800X
running bare-metal. That machine has been replaced and redesigned. This ADR supersedes
the ML machine section of ADR-002.

The current node is the primary GPU inference and heavy compute resource in the Prague
cluster. It is not an always-on service host — electricity cost is a real constraint
and the machine has no justified idle workload. It exists to run inference tasks that
are too large for the k3s cluster's CPU tier.

**Hardware:**

| Component | Spec |
|-----------|------|
| Motherboard | Gigabyte X570 AORUS PRO |
| CPU | AMD Ryzen 9 5950X (16c/32t) |
| RAM | 48 GB DDR4-3200 (3 of 4 sticks — one failed memtest, removed) |
| GPU | AMD RX 6700 XT 12 GB VRAM, IOMMU group 26 |
| NVMe | 238 GB (Proxmox OS + local-lvm, 141 GB usable) |
| SSD | 2× Samsung 850 EVO 250 GB → LVM-thin pool (vmdata-ssd, 457 GB) |
| NIC | Intel I211 1 GbE (active) |
| NIC | Intel X540-AT2 dual 10 GbE (inactive, reserved for future 2.5G/10G switch) |
| Hypervisor | Proxmox VE 9.2.0, kernel 7.0.2-6-pve |
| Network overlay | Tailscale (hostname: proxmox-server, 100.70.109.10) |

**Forces:**

- The k3s cluster (ADR-002) provides a light CPU inference tier (small models).
  Larger models and audio transcription with full accuracy require dedicated hardware.
- ROCm GPU inference and CPU transcription compete for system resources if colocated
  in one process. Separating them eliminates VRAM/RAM contention.
- Clients in legal, medical, and industrial contexts cannot route data to cloud AI APIs.
  This node is the reference implementation of air-gapped on-prem GPU inference —
  the same isolation pattern deployed to a client site.
- GDPR data-boundary requirements map cleanly to LXC boundaries: each LXC is a
  contained execution environment with a defined data surface.
- The machine is Prague-only. Greece DR site (ADR-005) runs CPU inference only.
  ML degradation at failover is accepted.

## Decision

**Run Proxmox VE as the hypervisor. Deploy two isolated LXCs: one for GPU inference,
one for CPU transcription. Keep the node off by default; wake via WoL from Home
Assistant.**

### Hypervisor: Proxmox VE

Proxmox VE provides IOMMU-based PCIe passthrough to LXC containers, a stable web UI
for on-demand VM management, and a thin management layer with no persistent overhead.
Bare-metal Debian is not used because Proxmox adds the CKA study environment as a
first-class use case: full VMs (kubeadm clusters, etcd operations) can be spun up and
torn down without disturbing the ML LXCs.

### LXC 1: XT_ML — GPU Inference

| Attribute | Value |
|-----------|-------|
| Purpose | GPU inference endpoint |
| IP | 192.168.1.224 |
| GPU access | RX 6700 XT passthrough via IOMMU group 26 |
| Runtime | ROCm 7.2 + Ollama |
| Model | Gemma 3 12B Q4 (~8 GB VRAM) primary — see note on Gemma 4 below |
| k3s role | External endpoint for GPU tasks |

The RX 6700 XT is in its own IOMMU group (group 26), making clean passthrough to a
single LXC possible without involving other devices. ROCm 7.2 is the runtime; Ollama
serves the model. The LXC has no network access to raw storage outside its mount
points — the GPU boundary is also a data boundary.

> **Model note:** Gemma 4 26B A4B (MoE, ~6–7 GB active VRAM) is the upgrade target
> once Ollama confirms stable MoE selective-loading support. Until then, Gemma 3 12B
> Q4 is the production model. Verify before switching.

### LXC 2: RYZEN_ML — CPU Transcription

| Attribute | Value |
|-----------|-------|
| Purpose | Audio transcription |
| IP | 192.168.1.225 |
| Compute | 5950X CPU (no GPU) |
| Runtime | faster-whisper large-v3-turbo |
| k3s role | External endpoint for audio workloads |

Audio transcription runs on CPU only, deliberately separated from the GPU LXC.
faster-whisper large-v3-turbo on a 5950X (16c/32t) handles transcription without
competing for VRAM. Keeping these as separate LXCs means:

1. A GPU OOM or ROCm crash in XT_ML does not affect transcription in RYZEN_ML.
2. Resource limits can be set independently.
3. The separation mirrors the client deployment pattern: one container per inference
   type, each with a defined resource envelope and data surface.

### k3s Integration and Graceful Degradation

Both LXCs are registered as external endpoints in the k3s cluster (alongside nodes
k3s-prg-b3, k3s-prg-g2, k3s-prg-r1) via Service+Endpoints manifests in
`kubernetes/apps/ai/`. **LiteLLM** acts as the single OpenAI-compatible routing
gateway. Its native health-check and fallback logic handles the on/off state of the
Proxmox node without custom probe code — GPU endpoint first, in-cluster CPU model
as automatic fallback.

| Workload | Primary endpoint | Fallback |
|----------|-----------------|---------|
| GPU inference / RAG | XT_ML (192.168.1.224) | Lighter in-cluster CPU model |
| Audio transcription | RYZEN_ML (192.168.1.225) | In-cluster Whisper small |

When the Proxmox node is powered off, LiteLLM's health check sees the endpoints
unreachable and routes to the fallback automatically. This is an **expected state**,
not an error condition.

### Power Management: WoL from Home Assistant

The node is **off by default**. Home Assistant (running on always-on Unraid) sends a
Wake-on-LAN magic packet when a GPU or large transcription workload is queued, or
when triggered manually. Boot-to-first-inference latency is approximately 60–90
seconds; this is acceptable for async pipelines. Real-time inference requirements
must be handled by the always-on k3s CPU tier.

### CKA Study Environment

On-demand VMs for Kubernetes practice (kubeadm clusters, etcd operations, network
plugin labs) are spun up on local-lvm (141 GB) and vmdata-ssd (457 GB LVM-thin).
These VMs are ephemeral and do not conflict with the ML LXCs.

### Planned Upgrades

| Upgrade | Current state | Target |
|---------|--------------|--------|
| RAM | 48 GB, 3 sticks (Flex mode) | 64 GB, 4 sticks when failed stick replaced |
| Network | 1 GbE active | 10 GbE via X540-AT2 when 2.5G/10G switch arrives |
| pfSense node | Not yet deployed | One Lenovo becomes network backbone before 2.5G upgrade |
| Gemma 4 26B A4B | Pending Ollama MoE support | Replace Gemma 3 12B when confirmed stable |

## Consequences

**Wins:**

- GPU and CPU inference workloads are isolated at the LXC boundary. A crash in one
  does not affect the other.
- IOMMU group 26 isolation is clean — passthrough does not require binding unrelated
  devices.
- WoL-driven power management eliminates idle draw. The always-on path (Unraid +
  k3s cluster) handles all low-intensity workloads without waking the node.
- Graceful degradation is a first-class design property. LiteLLM's fallback means
  no user-facing error when the node is off.
- Proxmox adds CKA study VMs at no extra hardware cost.
- The LXC isolation model and WoL orchestration pattern are directly portable to a
  client deployment.

**Costs and open risks:**

- **3-stick RAM in Flex mode** — one of the four original sticks failed memtest and
  was removed. Current RAM prices do not justify replacement. Running 48 GB across
  3 sticks forces the CPU into AMD Flex mode (asymmetric dual-channel), reducing
  effective memory bandwidth. Impact on XT_ML (GPU-bound) is low. Impact on RYZEN_ML
  (large faster-whisper batches are RAM-bandwidth-bound) is real. Replace the failed
  stick when prices allow; document the limitation before any client benchmark.

- **WoL boot latency** — 60–90 seconds from trigger to first inference response.
  Not suitable for interactive/real-time use cases. Those belong on the always-on
  k3s CPU tier.

- **ROCm + RX 6700 XT driver stability** — RDNA 2 (gfx1031) is functional under
  ROCm 7.2 but requires `HSA_OVERRIDE_GFX_VERSION=10.3.0`. Pin the ROCm version;
  test before updating.

- **Single GPU, no failover** — if XT_ML fails, GPU inference falls to the k3s CPU
  tier. Accepted; a second GPU node is not planned.

- **vmdata-ssd is not replicated** — CKA study VMs are ephemeral by design. Any
  future persistent VM data must be backed up explicitly.

## Alternatives Considered

- **Bare-metal Debian** — rejected. Prevents running CKA VMs alongside ML workloads
  without disruption. Proxmox overhead is negligible on a 5950X.

- **Single LXC for GPU + CPU inference** — rejected. VRAM/RAM contention under
  concurrent workloads is real. More importantly, colocating workloads eliminates
  the data boundary between GPU tasks and audio transcription — a compliance
  requirement in a client deployment.

- **k3s node with GPU device plugin** — rejected. Conflates the cluster node role
  with the inference node role. Keeping the ML machine as an external endpoint
  gives the k3s router explicit control and keeps the cluster topology clean.

- **Always-on node** — rejected. Idle draw for a 5950X + RX 6700 XT is 80–120 W
  continuously. WoL-driven power management is the correct trade-off for a
  burst-inference, not continuous-serving, workload profile.
