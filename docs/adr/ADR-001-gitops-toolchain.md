# ADR-001: GitOps Toolchain

**Status:** Accepted  
**Date:** 2026-05-15

## Context

The cluster needs a way to manage Kubernetes manifests that is auditable, reproducible, and safe to store in a public repository. The main options considered were ArgoCD (Flux, ArgoCD) for the GitOps engine and various secret management approaches (SOPS+Age, HashiCorp Vault, 1Password Connect, External Secrets Operator).

## Decision

- **GitOps engine:** ArgoCD with the App of Apps pattern
- **Manifest style:** Upstream Helm charts with custom `values.yaml` files committed to git; Kustomize for overlays where needed
- **Secret management:** SOPS + Age — secrets encrypted at rest in git, Age private key bootstrapped once into the cluster as a Kubernetes Secret, ArgoCD uses a CMP plugin to decrypt at sync time
- **Repository:** Public on GitHub (`github.com/Steficzko/homelab`)

## Consequences

**Accepted tradeoffs:**
- SOPS+Age requires manually re-encrypting secrets when rotating the Age key, but this is rare
- ArgoCD requires bootstrapping before it can manage itself — handled by `kubernetes/bootstrap/`
- Public repo means all secrets must be encrypted before commit — enforced by SOPS

**Not used:**
- Flux — ArgoCD chosen for its visual UI (better for interviews and learning)
- HashiCorp Vault / 1Password Connect — requires a running service; SOPS+Age is simpler with no runtime dependency
- External Secrets Operator — unnecessary complexity for a homelab scale
