# ADR-033 — Dental Voice STT: on RYZEN-ML (not the cluster), transformers engine for the Sorani fine-tune, auto-detect routing

**Status:** Accepted — **AND CURRENTLY VIOLATED IN PRODUCTION** (verified 2026-08-31)

> **Read this before trusting the document below.** This ADR's title is its decision: Sorani STT
> runs on RYZEN-ML, *not* the cluster. Live right now:
>
> ```
> sorani-bot-565b8b5498-xmbcp   k3s-prg-b3
> ```
>
> It is in the cluster, and on `k3s-prg-b3` — a control-plane and etcd member, which is worse than
> merely being in the wrong place. It also points at the `whisper-ckb` Service, which has had **zero
> endpoints since 2026-07-06**, so the path reports `1/1 Running` while being structurally incapable
> of working. The owner is aware and is waiting on a viable Sorani model before resolving it.
>
> This is published in the violated state deliberately. The decision spent eight weeks in a drafts
> folder, and **a decision nobody can read is a decision nobody can be held to, including its
> author** — which is precisely how the implementation drifted from it unnoticed. Either the
> implementation moves to RYZEN-ML, or this ADR is superseded by one that argues for the cluster.
> What it must not do is stay unpublished while reality quietly disagrees with it.
**Date:** 2026-07-06
**Relates to:** ADR-007 (Proxmox ML node: GPU inference + CPU transcription split), ADR-009 (LiteLLM gateway)

## Context

The dental product's voice→deal-ledger pipeline needs speech-to-text for notes that are a mix of **Kurdish (Sorani), Arabic, and English**. Kurdish ASR is the product's #1 risk. A candidate model appeared: `rzgar/whisper-large-v3-sorani-kurdish-ckb-v2` (Apache-2.0, includes the Erbil/Hewlêr dialect).

Three questions had to be answered by building, not guessing: *where* it runs, *which engine* serves it, and *how* the language gets chosen when the incoming message language is unknown.

## Decision

**Placement — RYZEN-ML (LXC 111, `.225`), not the K3s cluster.** First attempts on the cluster fought hard: the workers were already CPU-request-saturated by the existing `whisper-cpu`, and a heavy STT pod kept landing on / crash-looping against control-plane nodes and Longhorn volume moves. RYZEN is the dedicated CPU-transcription box (ADR-007), already runs a large-v3 whisper, and has no scheduling/volume friction. LXC 111 was bumped 8→16GB (live) to fit two whisper models plus conversion. The pipeline runs as plain Docker containers in `/opt/` — deliberately **not** ArgoCD-managed (it's product tooling, iterating fast, not cluster infra).

**Engine — `transformers` pipeline, NOT faster-whisper, for the Sorani model.** The model card requires forcing the **Persian** language token (`language="persian"`) — the fine-tune hijacks Whisper's Persian slot to emit Sorani. This trick is transformers-specific: converting to CTranslate2 and serving via faster-whisper **hallucinated English** (proven). So the Sorani model runs as a small custom transformers FastAPI server (`:8001`). (Also: the HF repo omits `preprocessor_config.json`; large-v3 needs 128 mel bins or it errors on shape.)

**Routing — auto-detect, not a fixed language.** The operator can't know per-message whether input is Arabic or Kurdish. So: run the audio through **big whisper large-v3 with auto-detect** (`verbose_json` returns the detected language); Arabic/English → use that transcript; **detected Persian (`fa`) = Sorani Kurdish → re-run on the Sorani model**. Both servers stay resident.

**Extraction LLM — `gemma3:4b`, not `gemma4:12b`.** The extraction prompt (deal-ledger JSON) plus the tenant catalog is a large prompt. `gemma4:12b` at the required `num_ctx` spilled out of GPU VRAM to CPU and timed out; and ollama's OpenAI `/v1` endpoint can't set `num_ctx`, so the default silently truncated the prompt → empty output. `gemma3:4b` via ollama's native `/api/chat` (`format:json`, `num_ctx:4096`) fits with headroom and returns valid JSON in ~5s.

## Consequences

- STT proven: real Kurdish and Arabic transcribed; extraction proven (correct prices/tooth/procedure matching). Full setup captured in the `voice-pipeline` memory note.
- Not behind LiteLLM (ADR-009): the LiteLLM STT route is flagged unstable (ADR-028), and the box-local direct calls are simpler and avoid a hop. Registering `whisper-ckb` in LiteLLM remains an option, not a requirement.
- Product data (bot token, demo catalog) lives on RYZEN, outside the homelab repo — correct per repo scope; the dental product's own repo/`decisions.md` is its source of truth.
- Auto-detect weak spot: Kurdish mis-detected as Arabic would route to big whisper and transcribe roughly. Acceptable for now; revisit with a confidence/keyword tweak if it shows up on real clips.
- Follow-ups: rotate the Telegram bot token (leaked in a working session), swap the demo catalog for per-tenant live catalogs, and add the review-screen confirmation (numbers are too important to auto-commit from a transcript).
