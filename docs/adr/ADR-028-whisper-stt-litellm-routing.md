# ADR-028 — Whisper STT Routing via LiteLLM Gateway

**Status:** Draft (UNSTABLE — see Known Issues)
**Date:** 2026-05-23

---

## Context

Open WebUI supports speech-to-text via a configurable STT endpoint. The homelab already runs a LiteLLM gateway (`litellm.ai.svc.cluster.local:4000`) as the central inference router for all AI workloads. Routing STT through LiteLLM keeps all model access consolidated behind one endpoint, enables future provider swaps without touching OWUI config, and makes timeouts/retries configurable in one place.

The primary Whisper backend is a `faster-whisper-server` Docker container running inside Proxmox LXC 111 (ryzen-ml). A fallback cluster pod exists for redundancy.

---

## Decision

Route Open WebUI STT through LiteLLM with the following configuration:

**LiteLLM model registration:**
```yaml
- model_name: Systran/faster-whisper-large-v3
  litellm_params:
    model: openai/Systran/faster-whisper-large-v3
    api_base: http://ryzen-ml:9090/v1   # /v1 required — LiteLLM appends path suffix directly
    api_key: <REDACTED>                  # dummy key; faster-whisper-server may not require auth
    timeout: 180                         # large-v3 cold start ~90s on CPU; 60s default times out
```

**Open WebUI STT config:**
- Endpoint: `http://litellm.ai.svc.cluster.local:4000`
- Model: `Systran/faster-whisper-large-v3`

**Fallback:** cluster `whisper` pod, registered as a separate LiteLLM deployment on the same model name with lower priority.

---

## Consequences

### Good
- Single config point for all AI model routing, including STT.
- Timeout, retry, and fallback policy managed in LiteLLM `config.yaml`, not in OWUI.
- Provider swap (e.g., switch to OpenAI Whisper API) requires only a LiteLLM config change.

### Bad / Known Issues

**THIS ADR DESCRIBES AN UNSTABLE CONFIGURATION.**

- `whisper-ryzen` (primary) runs as an unmanaged Docker container inside LXC 111 (ryzen-ml, CPU). There are no Kubernetes health checks, no resource limits enforced by k8s, and no automatic restart policy visible to the cluster. OOMKill risk exists.
- LiteLLM has no way to detect that the LXC Docker container has died; it will route to a dead endpoint and surface a 5xx to the caller.
- The fallback cluster pod is a partial mitigation but is not tested under production load.

**This is intentional technical debt.** The Docker-in-LXC deployment was the fastest path to a working STT pipeline. It will be replaced with a proper Kubernetes deployment on dedicated ML infrastructure when the ML node setup matures (see ADR-007 for that roadmap).

---

## Lessons from Wiring

Six root causes hit in sequence before the first successful transcription:

1. OWUI running Whisper in-pod by default — OOMKill with no UI indication.
2. Wrong model name format (`whisper/large-v3`) — "no healthy deployments".
3. OpenAI canonical name (`whisper-1`) — rejected; server returns valid names on request.
4. Correct name (`Systran/faster-whisper-large-v3`) — 404.
5. Missing `/v1` in `api_base` — LiteLLM appends path directly to base URL.
6. Correct path — timeout because cold start exceeds default 60s limit.

These are documented here so the next person (or future me after a node rebuild) doesn't replay all six.

---

## Alternatives Considered

- **OWUI direct to faster-whisper-server** — skips LiteLLM, simpler path, but breaks the single-gateway model and requires OWUI reconfiguration on any backend change.
- **OpenAI Whisper API** — no local inference, privacy tradeoff unacceptable for personal voice notes.
- **In-cluster Whisper pod only** — removes the unmanaged Docker problem, but shares k3s-node CPU; the dedicated ryzen-ml box (LXC 111) is preferred for transcription throughput. There is no GPU Whisper option — CTranslate2 (faster-whisper) has no ROCm backend, so both backends are CPU.

---

## Related

- ADR-007 — Proxmox ML Node architecture (ryzen-ml / xt-ml LXC split)
- `seeds/whisper-litellm-wiring.md` — blog seed for the debugging story
- `project_litellm_gateway.md` — LiteLLM gateway memory
