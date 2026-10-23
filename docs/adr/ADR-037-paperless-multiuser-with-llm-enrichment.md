# ADR-037 — Paperless-ngx: multi-user document store with LLM metadata enrichment

**Status:** Draft — not deployed
**Date:** 2026-09-07
**Supersedes in part:** ADR-029 (its risk assessment, not its decision)

## Context

There is no Paperless instance running. The previous one was removed; only its data
survives, as two Longhorn backups deliberately kept when the `paperless-drali`
backups were purged on 2026-08-18:

| volume | stored | last backup |
|---|---|---|
| `paperless/paperless-data-pvc` | 1.17 GB | 2026-06-02 |
| `paperless/postgres-pvc` | 0.40 GB | 2026-06-03 |

**Decision taken: build fresh, do not restore.** The backups remain untouched and can
still be restored later if that turns out to be wrong.

ADR-029 is `Accepted` and describes Paperless as deployed. It is not. That ADR also
justified public exposure on the basis that content was *"predominantly publicly
downloaded books, exported PDFs, and administrative documents… not financial records,
identity documents, or other high-sensitivity personal data"*. A multi-user household
document store invalidates that assessment — passports, contracts and tax paperwork
are exactly what a family scans. **ADR-029's risk paragraph must be rewritten, not
inherited.**

## Requirements

1. Multi-user: separate private documents per person, plus a genuinely shared pile.
2. OCR in **English, Greek, Czech, Arabic** — and **Sorani Kurdish**.
3. Arabic and Sorani documents must carry **English** titles and tags; the owner does
   not read either script.
4. Future: the corpus becomes a knowledge base OpenWebUI can answer questions from.

## Verified findings — do not re-derive these

Measured on `ghcr.io/paperless-ngx/paperless-ngx:latest` = **v3.1.3**,
digest `sha256:aa810a36942c63d4ee70d00eda7236cd3d6acfb7eb3f7987fb568ed14df8817a`.

**The image ships only `deu eng fra ita osd spa`.** No Greek, Czech, Arabic or
anything else needed here. The packs install cleanly from apt
(`tesseract-ocr-{ell,ces,ara}`) or by dropping `.traineddata` into
`/usr/share/tesseract-ocr/5/tessdata`. There is **no `PAPERLESS_OCR_LANGUAGES`
mechanism** in this version — the entrypoint is s6 (`/init`) with no
`custom-cont-init.d`, so languages must be supplied by an initContainer populating a
volume mounted over that tessdata path, or by a custom image.

**OCR accuracy, measured across 10 classic document faces** (Liberation Serif/Sans/
Mono, DejaVu Sans/Serif, FreeSerif/Sans, Nimbus Roman/Sans, C059):

| language | result |
|---|---|
| English | 10/10 faces exact |
| Kurmanji Kurdish (Latin) | 10/10 faces exact |
| Greek | 8/10 (misses on Nimbus Sans, C059) |
| Czech | 7/10 (misses on Liberation Mono, DejaVu Sans) |
| Arabic | 3/3 words on Noto Naskh, Noto Sans Arabic, FreeSerif |

**Sorani has no model and cannot be OCR'd accurately.** `ckb` and `kur` are 404 in
*all three* Tesseract repositories (`tessdata`, `tessdata_best`, `tessdata_fast`).
The fallbacks silently corrupt the Sorani-specific letters:

```
wanted:  سڵاو جیهان بەخێربێن
Arabic:  سلاو جيهان به خيربين     0/3   ڵ→ل  ێ→ي  ۆ→و
Persian: سلاو جیهان به‌خیربین      1/3   keeps ی, still loses ڵ and ێ
```

This is the same wall as `whisper-ckb` (COMP-5, open 57 days): **no viable Sorani
model exists**, in STT or OCR.

## Decision

**One instance, multi-user — not instance-per-person.** This deliberately differs
from the Immich pattern (four instances). Photo libraries are large and genuinely
separate; documents are small and want one search, shared correspondents and shared
tags. Critically, **common files are impossible across separate instances** — you
would end up emailing the mortgage PDF to yourself.

Three visibility tiers, driven by consume subdirectory and a workflow per user:

| tier | mechanism | visible to |
|---|---|---|
| common | owner unset | everyone (Paperless default for ownerless docs) |
| shared | owner set + view permission to group `family` | owner + group |
| private | owner set, no group | owner only |

```
PAPERLESS_CONSUMER_RECURSIVE: 1
consume/shared/    -> workflow: leave owner unset
consume/stefanos/  -> workflow: owner = stefanos
consume/marianna/  -> workflow: owner = marianna
PAPERLESS_FILENAME_FORMAT: {owner_username}/{created_year}/{title}
```

Known limitation, accepted: **workflows have no per-user permissions** — anyone who
can edit workflows can edit everyone's. Non-admin users therefore get no workflow
access. Fine for a household, unacceptable for a business.

**LLM enrichment is core, not optional.** Tesseract can produce Arabic-script text;
it cannot produce an English title or tags. `paperless-gpt` runs post-OCR against the
existing LiteLLM gateway and emits English metadata. Route: **`chat-json`**
(`ollama_chat/gemma4:12b`, GPU) — it respects `response_format` for constrained JSON
and already carries `think: false`, which is required because gemma4's thinking
consumes the whole context on long documents and returns empty content. Fallback
`json-extract` (`qwen3:4b`, CPU). Both routes verified reachable from the cluster.

This reframes OCR: for Arabic and Sorani it is **input to the LLM, not an end in
itself**. Imperfect Sorani OCR is tolerable because the deliverable is English
metadata. It would not be tolerable if accurate Sorani full-text search were needed.

**Accepted consequence:** Sorani documents get searchable English metadata but **no
reliable Sorani full-text search.**

## Architecture

```
kubernetes/apps/paperless/
  namespace.yaml
  postgres/            postgres + Longhorn PVC   (own, not shared)
  redis/               broker for the task queue
  paperless/           webserver + initContainer that installs tessdata
                       PVCs: data, media (Longhorn) ; consume (NFS)
  paperless-gpt/       post-OCR enrichment -> litellm.ai.svc
  secret.sops.yaml + secret-placeholder.yaml
  networkpolicy.yaml   default-deny + explicit allows
  postgres-backup-cronjob.yaml  -> MinIO, added to backup-watchdog
kubernetes/bootstrap/apps/paperless.yaml
  directory.exclude: '{*.sops.yaml,*placeholder*.yaml}'
```

**Storage:** Longhorn for `data` and `media` (replicated, in the nightly backup set);
**NFS only for `consume/`**, so drops work from a desktop and a stale NFS handle
cannot take the library with it. NFS reorganisation is pending — confirm export paths
at build time rather than reusing the old ones.

**The ArgoCD exclude is load-bearing.** ADR-029 records an incident where ArgoCD
applied `secret.example.yaml` templates as real Secrets, overwriting SOPS values with
`changeme` placeholders for the Postgres, Redis and admin passwords. The `n8n` app
manifest's exclude pattern is the stricter one and must be copied verbatim.

**Exposure:** public hostname behind Cloudflare Access, as Vaultwarden is.
**Blocker:** this must not ship before **CLSTR-4** is fixed. Anything on the tailnet
currently reaches ingress directly and bypasses Access — that is how Vaultwarden
answers HTTP 200 with no auth. Putting family documents behind the same ingress
inherits that hole. Narrow `loadBalancerSourceRanges` first.

## Phases

1. **Core** — namespace, postgres, redis, paperless with the tessdata initContainer
   (`eng+ell+ces+ara+kmr` plus script-level `Arabic`), Longhorn PVCs, netpol, backup
   CronJob wired into the watchdog. Verify ingestion in each language.
2. **Multi-user** — users, `family` group, three consume subdirs, one workflow per
   user. Verify a document dropped in each folder lands with the right ownership.
3. **Ingress** — hostname + cert + Cloudflare Access. **After CLSTR-4.**
4. **LLM enrichment** — `paperless-gpt` against `chat-json`. Verify an Arabic and a
   Sorani document both produce English title/tags.
5. **Knowledge base (future)** — sync OCR text into OpenWebUI Knowledge collections
   via the Paperless API. Design constraint for phases 1–4: keep full document text
   retrievable through the API so this stays possible. Set expectations honestly —
   RAG retrieves passages well and reasons across many documents poorly.

## Open questions

- Confirm the user list (assumed `stefanos`, `marianna`, group `family`).
- Confirm the hostname (assumed `paperless.kostikidis.net`).
- Were the three passwords and the SOPS age key rotated after the ADR-029 incident?
- ADR-029 needs amending: it claims Paperless is deployed, and its sensitivity
  assessment no longer holds for a household document store.
