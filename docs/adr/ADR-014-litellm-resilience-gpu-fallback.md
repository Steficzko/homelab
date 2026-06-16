# ADR-014 — LiteLLM Resilience: Circuit-Breaker Cooldown and GPU Fallback Correction

**Status:** Proposed  
**Date:** 2026-05-26

## Context

The LiteLLM gateway (`litellm.ai.svc.cluster.local:4000`) is the central inference router. Its `chat` model routes to `ollama-gpu` (xt-ml LXC, 192.168.1.224, GPU inference). Its `chat-fallback` model routes to the in-cluster Ollama deployment (`ollama.ai.svc.cluster.local:11434`), which runs on k3s-prg-b3 — a Lenovo mini PC cluster node, not a dedicated inference host.

**What broke:**

The Ollama GPU runner on xt-ml crashed due to a cgroup v2 parse bug: LXC 110 has no explicit CPU limit, so `cpu.max` contains the string `"max"` rather than an integer. Ollama's cgroup reader crashes on this. Ollama auto-restarted the runner after approximately 7 minutes.

LiteLLM's circuit breaker had already tripped on `ollama-gpu`. Because no `cooldown_time` is set in `router_settings`, the circuit breaker never self-healed — it required a manual pod restart to clear. During that window, `chat-fallback` routed all inference to the in-cluster Ollama on k3s-prg-b3. That node is not sized for inference: CPU pegged, fans at full speed ("voooom").

**Two design flaws confirmed:**

1. No `cooldown_time` in `router_settings` — a tripped circuit breaker requires manual pod restart to recover.
2. `chat-fallback` points to the wrong CPU backend — the in-cluster Ollama on a cluster node, not `ryzen-ml` (192.168.1.225), which exists specifically for CPU inference.

The root-cause cgroup bug (LXC 110 missing `cpu.max`) is tracked separately and not addressed here.

## Decision

Two changes to `kubernetes/apps/ai/litellm/configmap.yaml`, plus one new manifest:

### 1. Add `cooldown_time` to `router_settings`

```yaml
router_settings:
  num_retries: 1
  timeout: 90
  cooldown_time: 60
  fallbacks: [{"chat": ["chat-fallback"]}, {"whisper": ["whisper-fallback"]}]
```

After a circuit-breaker trip, LiteLLM retries `ollama-gpu` after 60 seconds automatically. No pod restart required.

### 2. Redirect `chat-fallback` to `ryzen-ml`

Change `chat-fallback` `api_base` from `http://ollama.ai.svc.cluster.local:11434` to `http://ryzen-ml.ai.svc.cluster.local:11434`.

### 3. Add `ryzen-ml` Service and Endpoints manifest

`ryzen-ml` does not yet exist in the `ai` namespace. A new file at `kubernetes/apps/ai/ryzen-ml/service.yaml`, following the same headless Service+Endpoints pattern as `ollama-gpu`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ryzen-ml
  namespace: ai
spec:
  ports:
    - port: 11434
      targetPort: 11434
---
apiVersion: v1
kind: Endpoints
metadata:
  name: ryzen-ml
  namespace: ai
subsets:
  - addresses:
      - ip: 192.168.1.225
    ports:
      - port: 11434
```

Without this manifest, `ryzen-ml.ai.svc.cluster.local` does not resolve and every `chat-fallback` call fails silently.

### What is not changed

The in-cluster `ollama` Deployment remains deployed. It is a direct dependency of `paperless-gpt` and other consumers that call it without going through LiteLLM. It is removed only from the LiteLLM fallback chain.

## Consequences

**Wins:**

- Circuit-breaker trips self-heal within 60 seconds. No manual intervention for transient GPU-side failures.
- `chat-fallback` lands on hardware sized for CPU inference. Lenovo mini cluster nodes never do inference again.
- In-cluster Ollama consumers (paperless-gpt, etc.) are unaffected.
- Two YAML edits and one new manifest. No new services or dependencies.

**Cost of inaction:**

The next GPU blip trips the circuit breaker again and keeps it tripped until a manual pod restart. All inference load moves to k3s-prg-b3 in the meantime. This will recur because the underlying cgroup bug on LXC 110 has not been fixed yet.

**Risks:**

- `cooldown_time: 60` untested against this LiteLLM version. Verify pod starts cleanly after the configmap change.
- ryzen-ml Ollama readiness is assumed. Verify `ollama list` on ryzen-ml (192.168.1.225) and confirm the required model is pulled before deploying.
- 60s cooldown may be too short if GPU model reload consistently takes longer. Tune based on observed restart times.

## Alternatives Considered

- **Increase `num_retries` instead** — rejected. Retries address transient errors, not a tripped circuit breaker.
- **Remove circuit breaker entirely** — rejected. Without it, a down `ollama-gpu` causes every `chat` request to hang for 90s before falling through.
- **Right-size k3s-prg-b3 for inference** — rejected. Cluster nodes are not inference nodes. ryzen-ml exists for this purpose.
