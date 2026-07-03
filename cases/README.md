# Field notes — real incidents, root causes, fixes

These aren't tutorials. Each is a problem I actually hit running this cluster —
what broke, how I found the real cause (not the first plausible one), and the
fix that stuck. They're the debugging trail behind the [ADRs](../docs/adr/).

| Case | The problem, in one line |
|---|---|
| [immich-pg-restore-oomkill](immich-pg-restore-oomkill.md) | `pg_restore` kept getting OOMKilled — the real cause was the pgvector HNSW index build spiking memory, not the restore itself. |
| [nfs-unraid-k3s-incident](nfs-unraid-k3s-incident.md) | A full NFS-between-Unraid-and-K3s outage that turned out to be **three** stacked sub-problems, debugged one layer at a time. |
| [argocd-sops-prune-conflict](argocd-sops-prune-conflict.md) | ArgoCD kept pruning SOPS-decrypted secrets back to empty — solved with the placeholder + `ignoreDifferences` pattern. |
| [argocd-selfheal-maintenance](argocd-selfheal-maintenance.md) | `selfHeal` silently reverting my `kubectl apply` during maintenance, and how to pause it without disabling GitOps. |
| [argocd-gitops-endpoints-configmap](argocd-gitops-endpoints-configmap.md) | ArgoCD won't manage `Endpoints`/`EndpointSlice` — hand-applied Endpoints for selector-less external services, plus ConfigMap-change restart handling. |
| [gitops-helmrelease-vs-imperative](gitops-helmrelease-vs-imperative.md) | When a GitOps-managed `HelmRelease` is worth it vs. a plain `helm install` — the tradeoff, decided deliberately. |
| [lxc-amd-gpu-whisper-rocm](lxc-amd-gpu-whisper-rocm.md) | AMD GPU passthrough into an LXC for Whisper STT — the ROCm, DNS, disk, and pip traps nobody documents. |
| [proxmox-cpu-power-management](proxmox-cpu-power-management.md) | Cutting the Proxmox node from ~230 W to ~170 W idle: `amd-pstate-epp`, `fancontrol`, PCIe ASPM. |
| [ssh-batchmode-stricthostkeychecking](ssh-batchmode-stricthostkeychecking.md) | Getting SSH `BatchMode` vs `StrictHostKeyChecking` right so cluster automation fails loudly instead of hanging. |

**How to read one:** each follows the same shape — symptom → what I *thought* it was → what it *actually* was → the fix → what I'd do differently.
