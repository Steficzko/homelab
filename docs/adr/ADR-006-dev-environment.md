# ADR-006 — Dev Environment: Debian VM on Unraid with Syncthing Replication

## Status
Accepted

## Context

All homelab tooling (kubectl, helm, argocd CLI, sops, age, Claude Code) had been
run ad-hoc from wherever a terminal was open — a Windows editing PC, a laptop, or
an SSH session to a cluster node. This creates three practical problems:

1. **State fragility** — CLI config, kubeconfigs, age keys, and agent memory live on
   whatever machine was used last. No single source of truth.
2. **Travel + multi-machine access** — working from multiple machines or a travel
   laptop without a stable dev baseline means re-installing tools or carrying keys
   around on USB drives.
3. **Agent memory persistence** — Claude Code agents (TheContrarian, adr-writer, etc.)
   maintain memory in `.claude/agent-memory/`. This state must survive machine
   reboots and be reachable from any device.

The cluster nodes are not appropriate as a dev host: they are compute infrastructure,
not general-purpose Linux boxes, and draining a node for maintenance should not
interrupt a dev session. The Unraid server runs 24/7, has a static IP, and already
hosts other persistent services.

## Decision

**Provision a Debian 12 VM on Unraid as the sole persistent dev environment.**

### VM specification

| Resource | Value |
|----------|-------|
| vCPU | 2 |
| RAM | 4 GB |
| OS disk | 32 GB vdisk on Unraid cache pool |
| Network | Bridge to LAN (static IP, Tailscale installed) |

### Storage: devdata share via virtio-9p

An Unraid array-backed share (`devdata`) is mounted into the VM using virtio-9p
(VirtIO Plan 9 filesystem passthrough). This keeps all working data — repo clones,
kubeconfigs, age keys, agent memory — on the Unraid array rather than the vdisk.
The vdisk is OS-only and is disposable.

This separation means the VM can be destroyed and rebuilt without losing any dev
state. The working directory for all tooling is `/mnt/devdata/homelab`.

### Remote access

Tailscale is installed on the VM. All machines (desktop, laptop, travel devices)
reach it via `ssh dev-vm` regardless of which network they are on. `mosh` is also
installed to survive flaky connections during travel.

### Toolchain

All homelab CLI tools are installed once on the VM and nowhere else:
kubectl, helm, argocd CLI, sops, age, Claude Code, git.

The SOPS age private key lives on the VM under `~/.config/sops/age/keys.txt`. It
is not kept on individual workstations.

### Syncthing replication

The `devdata` share is replicated peer-to-peer via Syncthing between the Prague
Unraid and the Greece Unraid. This serves two purposes:

1. The DR site (ADR-005) gets a live copy of all dev state, including agent memory,
   kubeconfigs, and repo working directory.
2. If Prague Unraid is unavailable, the Greece copy of devdata can be mounted into
   the Greece VM and work continues without re-cloning or re-configuring.

### Nextcloud External Storage

The `devdata` share is also wired to Nextcloud as an External Storage mount (read
window). This makes repo files and outputs browsable from the Nextcloud web UI and
mobile client without requiring SSH access — useful for reading logs or ADR drafts
from a phone.

## Consequences

**Wins:**
- Single, reproducible dev baseline reachable from any device via Tailscale
- VM rebuild is consequence-free: OS is the only thing on the vdisk, all state is
  on the array-backed devdata share
- Agent memory (`.claude/agent-memory/`) is persistent and reachable from the
  same path on every session
- DR site naturally gets a copy of dev state as part of Syncthing replication

**Costs and open risks:**

- **virtio-9p throughput under heavy write loads** — virtio-9p has known
  cache coherence and throughput limitations compared to a native filesystem or
  virtiofs. Under heavy write workloads (e.g. large git operations, agent context
  writes at high frequency) this may become a bottleneck. virtiofs (VIRTIO_FS) is
  the preferred migration target: it uses FUSE with a DAX window for direct memory
  access and has better cache semantics. Migration is tracked in todos. This is a
  known accepted risk for the current iteration — the workload is predominantly
  small file reads/writes and is unlikely to saturate virtio-9p in practice.

- **Syncthing file versioning is not yet configured** — Syncthing replicates
  changes between peers immediately. An accidental deletion (e.g. `rm -rf` inside
  devdata) propagates to the Greece peer within seconds, before any human can
  intervene. There is currently no undo. Configuring versioning (staggered or
  simple file versioning on the receive side) is tracked in todos and is an open
  risk until done. The age key and kubeconfig are the highest-stakes files; until
  versioning is in place, manual backups of those specific files are the mitigation.

- **Single VM is a single point of failure for dev access** — if the Prague
  Unraid goes down, the dev VM is unavailable. The Greece Unraid holds a Syncthing
  copy of devdata, so a replacement VM can be spun up there, but there is no
  automatic failover. Acceptable given Unraid's UPS coverage and stability record.

- **age key on a VM** — the SOPS age private key lives on the VM. If the VM is
  compromised, encrypted secrets in the git repo could be decrypted. Mitigation:
  the VM is LAN-only with no open inbound ports; Tailscale is the only access path.
  Key rotation would require re-encrypting all SOPS secrets.

## Alternatives Considered

- **Devcontainer on a workstation** — rejected. State is tied to whichever physical
  machine the container is running on. Travel or machine failure breaks the session.

- **K3s node as dev host** — rejected. Cluster nodes are infrastructure. Draining
  a node for maintenance should not interrupt a dev session. Node failures should
  not lose dev state.

- **Cloud VM (e.g. a small VPS)** — rejected. Adds monthly cost, takes data outside
  the home network, and creates a dependency on an external provider for something
  the Unraid handles better at zero marginal cost.

- **virtiofs from the start** — not yet adopted because Unraid's virtiofs support
  requires a newer QEMU/kernel combination that needs validation. virtio-9p works
  today. virtiofs is the planned migration target, not a rejected alternative.
