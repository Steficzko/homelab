# ADR-009 — LiteLLM as Unified Inference Gateway with Tiered Fallback

**Status:** Accepted

## Context

ADR-007 documented the ML node architecture: two LXCs on a Proxmox host that is off
by default and woken via WoL. ADR-002 documented the k3s cluster as the always-on
application platform with a light CPU inference tier. This ADR records how those two
tiers are connected into a single inference surface.

**The problem:** inference consumers — Open WebUI, the n8n voice pipeline, the Dr. Ali
dental study assistant — each need to reach an Ollama or Whisper endpoint. The ML
machine is frequently off. If each application holds a direct endpoint URL, every power
state change requires an app-level configuration update: either the app gets a 502, or
someone manually redirects it to the fallback. Neither is acceptable in a system where
the off-state is normal operation.

**Forces:**

- The ML machine (192.168.1.224–225) is off by default. Boot-to-first-inference
  latency is 60–90 seconds. Apps that target it directly will error during that window
  and whenever the node is sleeping.
- The k3s cluster (3× Lenovo M910q, i5-8400T) is always-on and runs a CPU-only
  Ollama pod and a CPU Whisper pod as a permanent fallback tier.
- Model quality degrades on the CPU tier — smaller quantised models, slower throughput
  — but availability is continuous. That trade-off must happen transparently, without
  the consumer knowing which tier is serving the request.
- A future n8n pipeline (Telegram voice → Whisper transcription → Gemma cleanup →
  Obsidian vault) will add a third inference consumer. Hard-coding tier selection into
  every pipeline node creates an O(n) maintenance problem as consumers grow.
- The Dr. Ali study assistant runs experimental fine-tuned Gemma variants on an
  isolated endpoint at 192.168.1.227. That endpoint must be reachable by name without
  being in the general fallback chain.

## Decision

**Deploy LiteLLM as a single OpenAI-compatible routing gateway in the `ai` namespace.
All inference consumers use one base URL — `litellm.ai.svc.cluster.local:4000` — and
never reference tier endpoints directly.**

### Gateway placement

LiteLLM runs as a Deployment in `kubernetes/apps/ai/`. It is in-cluster, always-on,
and routes requests to external endpoints (ML node LXCs) and in-cluster pods depending
on which are healthy. The routing logic is entirely inside LiteLLM — consumers are
unaware of it.

### Model routing table

| Model alias | Primary endpoint | Fallback endpoint | Notes |
|-------------|-----------------|-------------------|-------|
| `chat`, `gemma4` | `ollama-gpu.ai.svc.cluster.local` → XT_ML (192.168.1.224) | `ollama.ai.svc.cluster.local` (in-cluster CPU pod) | GPU-first; falls to M910q CPU tier |
| `whisper` | `whisper-ryzen.ai.svc.cluster.local` → RYZEN_ML (192.168.1.225, CPU) | `whisper.ai.svc.cluster.local` (in-cluster CPU pod) | large-v3 on ryzen-ml CPU (primary); in-cluster CPU pod as fallback. No GPU Whisper — CTranslate2 has no ROCm backend |
| `DrGemmaQ4`, `DrGemmaQ8` | 192.168.1.227 (isolated custom endpoint) | None | Experimental fine-tuned Gemma for Dr. Ali assistant; intentionally not in fallback chain |

The ML node LXCs are registered in the cluster as Service+Endpoints manifests so they
appear as named cluster services. This keeps raw IP addresses out of the LiteLLM
config and respects the cluster's service discovery layer.

### Router settings

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `cooldown_time` | 60 s | Matches ML node WoL boot window; keeps a failed endpoint quarantined long enough for it to come online before re-attempting |
| `num_retries` | 1 | One retry per model before promoting to fallback; avoids hammering a sleeping node |
| `fallbacks` | Explicit map per model alias | No implicit global fallback; each model's degradation path is declared |

### Health check and failover mechanics

LiteLLM polls primary endpoints at its configured health-check interval. When XT_ML or
RYZEN_ML are unreachable (ML node off, WoL not yet triggered, or cooldown active), the
health check fails and LiteLLM routes to the declared fallback for that model alias.
When the node wakes and the endpoint becomes healthy again, LiteLLM routes back to the
primary automatically after the cooldown window expires.

This is an **expected operating mode**, not an error condition. The off-state of the ML
node is designed, and the fallback tier exists precisely to cover it.

### Consumer registration

| Consumer | Base URL used | Model alias |
|----------|--------------|-------------|
| Open WebUI | `litellm.ai.svc.cluster.local:4000` | `chat`, `whisper` |
| Dr. Ali study assistant | `litellm.ai.svc.cluster.local:4000` | `DrGemmaQ4`, `DrGemmaQ8` |
| n8n pipeline (planned) | `litellm.ai.svc.cluster.local:4000` | `whisper`, `chat` |

The n8n pipeline currently deployed on-cluster connects to OpenAI (migrated from Unraid
n8n). Migration to in-cluster inference via LiteLLM is planned once the pipeline nodes
are wired; the gateway is already in place and the model aliases are ready.

## Consequences

**Wins:**

- All inference consumers are decoupled from hardware topology. The ML node can be
  off, waking, or mid-reboot; consumers see no configuration change and no persistent
  error — only a temporary quality downgrade while fallback is active.
- Adding a new consumer means pointing it at one URL. Adding a new hardware tier
  means updating the LiteLLM config, not every consumer's config.
- The `DrGemmaQ4`/`DrGemmaQ8` aliases give the Dr. Ali assistant a stable name for an
  experimental endpoint that may change IP or model version without breaking the
  consumer.
- The n8n migration path is clear: change one `base_url` value in the n8n credential,
  not every HTTP node in every workflow.
- LiteLLM's OpenAI-compatible interface means any consumer that can talk to OpenAI
  can talk to this gateway with a credential swap — no SDK changes.

**Costs and open risks:**

- **LiteLLM is a new critical path component.** If the gateway pod crashes or is
  misconfigured, all inference consumers fail simultaneously — including production
  services (Dr. Ali assistant, Open WebUI). It is not replicated. A single pod restart
  takes seconds; a misconfiguration that reaches production takes down the whole
  inference surface. Mitigate by keeping config in git and using ArgoCD sync for
  rollbacks.

- **Cooldown timer interacts with WoL latency.** The 60-second cooldown is calibrated
  to the ML node's boot time. If the node boots faster, the cooldown window
  unnecessarily delays primary endpoint recovery. If a future hardware change
  increases boot time past 60 seconds, the primary endpoint will be retried before it
  is ready and will fail again, extending effective downtime. Revisit `cooldown_time`
  if hardware changes.

- **DrGemmaQ4/Q8 has no fallback.** If 192.168.1.227 is unreachable, the Dr. Ali
  assistant gets a hard error. This is intentional — the fine-tuned model has no
  generic equivalent — but it means the study assistant depends on a third machine
  being online. Document this dependency in the Dr. Ali runbook.

- **n8n migration is pending.** Until the Unraid n8n workflows are migrated, the
  cluster has two separate inference paths in production: LiteLLM for new consumers,
  OpenAI direct for existing n8n workflows. This is a transitional inconsistency, not
  a design choice. It should be resolved before the n8n pipeline goes into production.

## Alternatives Considered

- **Direct endpoint per consumer** — each app configures `OLLAMA_BASE_URL` or
  equivalent pointing at XT_ML or RYZEN_ML directly. Rejected. Any ML node power
  state change or IP change requires touching every consumer's config. The off-state
  is the normal state; this pattern turns routine operation into recurring manual work.

- **Single always-on GPU node** — run a GPU machine 24/7 so fallback is never needed.
  Rejected. Idle draw for a 5950X + RX 6700 XT is 80–120 W continuously with no
  burst workload to justify it. WoL-driven operation is the correct power model (see
  ADR-007).

- **OpenAI API as primary** — route all inference to OpenAI and use the local tier
  only as a cost fallback. Rejected. Data privacy is a hard constraint: voice memos
  processed via the n8n pipeline and dental exam content processed by the Dr. Ali
  assistant must not leave the cluster. Cost is a secondary concern.

- **Bring-your-own router (custom proxy)** — write a small FastAPI proxy that
  implements the same fallback logic. Rejected. LiteLLM ships this exact feature set
  — health checks, fallbacks, cooldown, OpenAI compatibility — and is actively
  maintained. A custom proxy would replicate its functionality at the cost of ongoing
  maintenance with no differentiated benefit.
