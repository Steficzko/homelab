# ADR-014 — LiteLLM Resilience: Circuit-Breaker Cooldown and GPU Fallback Correction

**Status:** Accepted — partially implemented; decision 2 withdrawn 2026-08-29 (see Revision)
**Date:** 2026-05-26
**Revised:** 2026-08-29

## Context

The LiteLLM gateway (`litellm.ai.svc.cluster.local:4000`) is the central inference router. Its `chat` model routes to `ollama-gpu` (xt-ml LXC, 192.168.1.224, GPU inference). Its `chat-fallback` model routes to the in-cluster Ollama deployment (`ollama.ai.svc.cluster.local:11434`), which at the time of writing ran on k3s-prg-b3 — a Lenovo mini PC cluster node, not a dedicated inference host.

**What broke:**

The Ollama GPU runner on xt-ml crashed due to a cgroup v2 parse bug: LXC 110 has no explicit CPU limit, so `cpu.max` contains the string `"max"` rather than an integer. Ollama's cgroup reader crashes on this. Ollama auto-restarted the runner after approximately 7 minutes.

LiteLLM's circuit breaker had already tripped on `ollama-gpu`. Because no `cooldown_time` is set in `router_settings`, the circuit breaker never self-healed — it required a manual pod restart to clear. During that window, `chat-fallback` routed all inference to the in-cluster Ollama on k3s-prg-b3. That node is not sized for inference: CPU pegged, fans at full speed ("voooom").

**Two design flaws confirmed:**

1. No `cooldown_time` in `router_settings` — a tripped circuit breaker requires manual pod restart to recover.
2. `chat-fallback` points to a CPU backend running on a control-plane node rather than dedicated inference hardware.

The root-cause cgroup bug (LXC 110 missing `cpu.max`) is tracked separately and not addressed here.

## Decision

### 1. Add `cooldown_time` to `router_settings` — IMPLEMENTED

```yaml
router_settings:
  num_retries: 1
  timeout: 90
  cooldown_time: 60
  fallbacks: [{"chat": ["chat-fallback"]}, {"whisper": ["whisper-fallback"]}]
```

After a circuit-breaker trip, LiteLLM retries `ollama-gpu` after 60 seconds automatically. No pod restart required. Verified live in `kubernetes/apps/ai/litellm/configmap.yaml`.

### 2. Redirect `chat-fallback` to `ryzen-ml` — WITHDRAWN, DO NOT IMPLEMENT

The original decision was to repoint `chat-fallback` at `ryzen-ml.ai.svc.cluster.local:11434` and add a Service+Endpoints manifest for it. **This must not be done.** See the Revision section — implementing it as written would have converted a degraded-performance failure into a total one.

`chat-fallback` stays on `http://ollama.ai.svc.cluster.local:11434`.

### What is not changed

The in-cluster `ollama` Deployment remains deployed. It is a direct dependency of `paperless-gpt` and other consumers that call it without going through LiteLLM.

## Revision — 2026-08-29

**The problem this ADR set out to solve was real; the remedy it prescribed was wrong, and the reason it was wrong was recorded in this document from day one and never checked.**

The original Risks section said: *"ryzen-ml Ollama readiness is assumed. Verify `ollama list` on ryzen-ml (192.168.1.225) and confirm the required model is pulled before deploying."* That verification never happened. When it was finally performed, on 2026-08-29:

- **There is no Ollama on 192.168.1.225.** No `ollama` binary, systemd unit inactive, nothing listening on 11434. What runs on that LXC is whisper (8000), a uvicorn app (8001) and a python service (8020).
- **The `ryzen-ml` Service had no endpoints for 95 days.** The manifest at `kubernetes/apps/ai/ryzen-ml/service.yaml` declared both a Service and an Endpoints object, but **ArgoCD does not manage `Endpoints`/`EndpointSlice`** — it silently applied the Service and skipped the Endpoints, which nobody applied by hand. The Service existed with a ClusterIP and nothing behind it.

So decision 2 pointed the inference fallback path — the mechanism that exists to catch GPU failure — at a Service with no backends, fronting a host with no Ollama. Had it been implemented, a GPU blip would have failed *completely* instead of merely slowly.

**Why withdrawing is correct rather than fixing:** decision 2's actual purpose was to keep fallback inference off an etcd node. That is already achieved by other means. ADR-030's tier-A affinity work moved the in-cluster `ollama` Deployment onto `k3s-prg-w2`, a dedicated worker. The harm this decision was written to prevent — inference melting a control-plane/etcd node — no longer exists, so the remedy is unnecessary.

**Actions taken:**

- `kubernetes/apps/ai/ryzen-ml/` deleted. The Service is pruned from the cluster by ArgoCD on sync.
- `chat-fallback` remains pointed at the in-cluster Ollama, which now runs on a worker.
- The `192.168.1.225/32` reference in `kubernetes/monitoring/extras/networkpolicy.yaml` is retained — it serves whisper-ryzen, which is genuinely live on that host.

**The lesson worth keeping:** an assumption written into a Risks section is not a mitigation. This ADR named the exact check that would have caught the fault and was published without it being run. A risk that is documented but unverified reads, three months later, exactly like one that was handled.

## Consequences

**Wins:**

- Circuit-breaker trips self-heal within 60 seconds. No manual intervention for transient GPU-side failures.
- Fallback inference no longer lands on a control-plane/etcd node — achieved via ADR-030 placement, not via this ADR.
- One dead Service and its manifest removed; the repo no longer describes infrastructure that does not exist.

**Costs / open items:**

- There is no dedicated CPU-inference host in the fallback chain. If GPU inference fails, fallback runs on a cluster worker. This is acceptable at current load; revisit if fallback becomes hot.
- The underlying cgroup bug on LXC 110 is fixed separately (hookscript + systemd unit + udev rule).

**Risks:**

- `cooldown_time: 60` may be too short if GPU model reload consistently exceeds it. Tune based on observed restart times.

## Alternatives Considered

- **Increase `num_retries` instead** — rejected. Retries address transient errors, not a tripped circuit breaker.
- **Remove circuit breaker entirely** — rejected. Without it, a down `ollama-gpu` causes every `chat` request to hang for 90s before falling through.
- **Deploy Ollama on ryzen-ml and keep decision 2** (considered 2026-08-29) — rejected. It buys a second CPU backend that has not been needed in 95 days, and carries a permanent manual `kubectl apply` step for the Endpoints object that ArgoCD will never manage. The failure mode it guards against is already covered by ADR-030 placement.
- **Right-size k3s-prg-b3 for inference** — rejected. Cluster nodes are not inference nodes.
