# ADR-038 — Second brain: a Markdown folder is the store, everything else is disposable

**Status:** Draft — phase A DEPLOYED 2026-09-11 (commits 93d938b, 8af3777, c6760d0); to be accepted into docs/adr after a week of use (BRAIN-10)
**Date:** 2026-09-10
**Related:** ADR-009 (LiteLLM gateway), ADR-015 (Open WebUI RAG)
**Supersedes in part:** ADR-022 — its `obsidian-livesync → /mnt/user/ObsidianVault` NFS row (live it is a Longhorn PVC; under this ADR the vault is a Longhorn PVC in `brain` and CouchDB is retired)

## Context

Stefanos wants a personal knowledge base ("second brain") on his own infrastructure, his own
GPU and models, with no lock-in to any app, so that modules can be swapped later. Scope is
staged: **A** capture and find (now), **B** chat over everything (later), **C** agents that act
(later still).

What already runs (verified 2026-09-10): Obsidian LiveSync CouchDB (`obsidian.kostikidis.net`),
LiteLLM with GPU-first routing, Whisper on ryzen-ml, in-cluster Ollama, Open WebUI, n8n,
Paperless, Neo4j, linkding, Readeck (replaced wallabag 2026-10-23), FreshRSS, Nextcloud, SearXNG. The Telegram → Whisper →
`json-extract` → vault pipeline (June 2026) was parked on one open question: how to write into
the vault.

Editors considered: Obsidian (plain Markdown over a folder), Logseq (2.0 DB beta since
2026-07-13 makes SQLite the canonical store; file-based "OG" fork is maintenance-mode and its
Markdown is outliner-flavoured). Memory layers considered: Cognee (v1.0 April 2026; graph +
vector over ingested files; supports Neo4j, pgvector, any OpenAI-compatible endpoint; MCP server).

## Decision

**The brain is a directory of Markdown files on a Longhorn volume in the cluster. Every other
component is an editor, a pipeline, or a rebuildable index over that directory.** Everything
runs in k3s. Unraid holds only what is dropped in and the raw artefacts that come out, over NFS:
**notes on the PVC, drops and data on the array.**

| Layer | Component | Replaceable? |
|---|---|---|
| Store (vault) | Longhorn PVC `brain/vault` (RWO, 10 Gi, expandable): the Obsidian vault — notes, `.obsidian/` | No — this *is* the brain |
| Drops + data | NFS PV to a Prague Unraid share: drop zone, own recordings, `attachments/` raw media, transcripts, frames | Any filesystem; referenced from notes by path |
| Documents | **Paperless-ngx** (already running): web pages rendered to PDF by Gotenberg, and any dropped PDF/scan; OCR, dedup, search. Its API is the phase B text source for these | Already in place; the brain only writes to its consume folder |
| Sync / DR | Syncthing container in the brain pod sharing the vault to laptop, dev-seat, phone and Greece (receive-only) | Any file sync; the laptop copy is plain files |
| Backup | Longhorn `daily-backup` label on the PVC (PVC carries `source` + group labels so git, not hand-labelling, decides) → MinIO → replicated to Greece | Existing mechanism, nothing new |
| Editor | Obsidian desktop opening the folder | Yes — any Markdown editor |
| Capture (A) | one `brain-capture` Deployment built from the existing `gesden/work/ingest.py` (inbox watcher) + `sorani-bot` (Telegram long-poll) + `ig_reels.py`/`batch.py` (yt-dlp) patterns; Whisper + `json-extract` via LiteLLM | Yes — any writer that creates files |
| Memory (B) | Cognee ingesting `brain/`, **its embedded graph (Ladybug) on the pod PVC**, vectors in pgvector, models via LiteLLM | Yes — delete and rebuild from files |
| Agents (C) | Cognee MCP + scheduled jobs (n8n or scripts) | Yes |

Obsidian is chosen as the editor because it is a thin layer over plain Markdown. Logseq 2.0 is
rejected because its canonical store is a database. Obsidian LiveSync / CouchDB is **not** the
store; it is retired once phone-side Syncthing works (see Decisions taken).

### Rules that keep it lock-in-free

1. **One writer: the master.** Notes are written only on the cluster vault — by the pipeline and
   by Stefanos through the browser Obsidian. Laptop, phone and Greece hold receive-only mirrors;
   an edit made there never reaches the master. Changes from a device go through the inbox as a
   new capture. Within the master, the pipeline touches only notes it created and that nobody has
   edited since (mtime guard): a human move or edit is final. (Amended 2026-09-11: the earlier
   "pipelines own inbox/, humans own the rest" assumed editing on replicas; filing at capture
   time and the single-writer decision replace it.)
2. **Indexes are disposable.** Any vector store, graph, or app database must be rebuildable
   from `brain/` with one command. If it cannot, it is not allowed to hold anything unique.
3. **Anything worth keeping becomes a note.** Agent memories that live only inside Cognee (or
   any successor) are lock-in through the back door; they get written back as Markdown.
4. **Inference goes through LiteLLM.** No component points at Ollama or Whisper directly.
5. **Text is forever; media is a safety net, not an archive.** Transcripts, captions, frames,
   screenshots and the original URL are never deleted. Media follows what can be re-obtained:
   - **His own recordings** (voice notes, DJI Mic) cannot be re-obtained, so the audio is kept
     **30 days** after the note is written, then deleted, once the transcript is verified.
     Editing the note or marking it keep inside the window cancels deletion permanently.
   - **Imported media** (a downloaded video or audio from a link) **is deleted once the capture
     is processed** — the note keeps the URL, transcript, caption and frames, and the source can
     be fetched again.
   - **BJJ technique videos are kept, gated on duration** (2026-09-11). A takedown is
     unrecoverable and frames plus a transcript are not enough to teach from, so the video stays
     — **if it runs 5 minutes or less**. Longer than that the media is deleted and the note keeps
     the link, the transcript and the frames. Duration, not file size: a 3-minute 4K clip is the
     library, a 40-minute instructional is a bookmark that `yt-dlp` can fetch again. The **keep**
     button overrides the gate for anything he wants regardless. Filed by taxonomy path (below).
   - **Nothing is ever deleted silently.** The bot asks at capture time and silence means the
     default; when his own audio reaches 30 days he is told what is about to go and can keep it
     with one tap.
6. **Agents never act on imported material alone.** Text that came in from the internet
   (pages, transcripts, chats) can carry instructions. From phase C on, an agent acts only on
   what a self note says; imported text is evidence, never a command.

### Security posture (design sweep 2026-09-10)

- **LAN is trusted by decision, but not by Chromium.** The Unraid shares are Stefanos's and
  bound to the cluster node IPs; the pod may reach LAN services it needs. Gotenberg, which
  renders whatever URL is pasted, is denied every private range (RFC1918, CGNAT/tailnet,
  loopback) and every cluster/LAN DNS suffix, because a pasted link is attacker input and
  Unraid, pve and the cluster all live in those ranges. Gotenberg itself has no NetworkPolicy
  (tracked on the board); the deny-list is the only guard today.
- **The LiteLLM key is the master key.** LiteLLM runs without a database, so scoped virtual
  keys cannot be minted; the brain uses the master key exactly as n8n does. A pod that parses
  attacker-chosen media therefore holds admin over the inference gateway. Accepted for phase A;
  giving LiteLLM a Postgres and minting a brain-scoped key is a Compute-board item.
- **Liveness never kills real work.** The capture loop refreshes its heartbeat after every
  transcription chunk; a drop counts as done only when its transcript exists beside the kept
  copy, and copies without a transcript are swept and retried, so a restart mid-transcription
  loses nothing.
- **Telegram is inbound only, and the acknowledgement is neutral:** a checkmark and the
  capture number, never a title or slug. The bot accepts messages from Stefanos's chat id only
  and drops everything else silently.
- **The capture pod is unprivileged:** runs as uid 99 / gid 100 (the Unraid `nobody:users`
  pair, so the share is exported with `all_squash` like devdata), read-only root filesystem,
  no capabilities, scratch on an emptyDir. It parses media chosen by whoever sent a link.
- **Remote reach stays in house.** Away from the LAN, the phone and laptop reach the vault and
  the chat endpoint over the tailnet only. The k3s nodes are already on the tailnet (verified 2026-09-11:
  reachable from Greece, nothing listening), so the likely shape is exposing the Syncthing and
  chat services on the nodes' tailnet addresses with a network policy limited to Stefanos's
  device IPs — no sidecar, no relays. Decided on the map's remote-reach ticket. The tailnet policy is stock
  allow-all today (SEC-8), so any tailnet door must be limited to Stefanos's devices, not the
  whole range.
- **The fence is a query fence.** Fenced relationship material still syncs to every device and
  to Greece as plain files. It protects against agents and digests, not against a lost phone.
  Device encryption is the phone's job.

## Prior art in the estate (this is why n8n is out of phase A)

The capture pipeline already exists, in plain Python, written for the Gesden rip and the Gompha
voice bot. Reusing it is the shortest path; rebuilding it as n8n nodes would be a rewrite of
working code into a GUI.

| Piece | Where | What it already does |
|---|---|---|
| `ingest.py` | `~/gesden/work/` | Watches an inbox folder, ffmpeg → 16 kHz mono → 10-min chunks (Whisper container has a 6 GiB limit, OOMs on long files) → Whisper on ryzen-ml → timestamped transcript next to the file. Resumable (skips files whose `.txt` exists). Scene-cut + timelapse **frames** for videos where the signal is on screen. Flags "thin" transcripts (music, no narration). Retries around a container restart. |
| `sorani-bot` | `/opt/sorani-bot/bot.py` on ryzen-ml **and** in-cluster `ai/sorani-bot` (`python:3.14-slim` + code ConfigMap + SOPS secret) | Telegram **long-polling** bot: no webhook, no ingress, no Cloudflare. Downloads the voice note, Whisper with auto-detect, LLM extraction, human-readable reply. The proven way to run a Telegram bot in this cluster. |
| `study_batch.py` | TUF WSL box (`100.69.56.89`, user `steficzko`), output `~/gesden_out/masterclass/` | Same shape on the RTX 4080: CUDA `large-v3` float16, scene-cut + 30 s frames at 1280 px, one folder per video with `transcript.txt` + `frames/`. Thirteen masterclasses done, ready to import. |
| `ig_reels.py`, `batch.py` | `~/gesden/work/` | `yt-dlp` → mp4 + caption/metadata + transcript for Instagram reels and YouTube playlists, no login needed for public content. This *is* the raw capture for video links; a Gotenberg screenshot of YouTube is a login wall. |

## Phase A — design

**Languages.** Voice notes arrive in English, Czech, Polish and Greek, often mixed. Whisper
`large-v3` handles all four; the watcher never pins a language — auto-detect per chunk, as
`ingest.py` already does (pinning garbles the other language in a mixed note). `json-extract`
writes the title in the note's own language and the tags in English, so tag search works across
languages. The Sorani re-route from `sorani-bot` is not carried over.

**Everything goes in and its text is kept forever.** The transcript, the caption, the frames,
the screenshot and the original link are kept on the data share. Media follows rule 5.

**Capture contract 1 — audio: a file appearing in the drop zone is a capture.** The drop zone
is a Syncthing folder the phone sends to (send-only on the phone); the pod never moves or
deletes anything inside it — it copies the file out to `data/audio/YYYY/`, processes the copy,
and skips files whose copy already exists (idempotent by name and size). A file the backend
could not process because Whisper or LiteLLM was unreachable stays where it is and is retried
next cycle; only a file that fails on its own content goes to `_failed/`. Sources
are interchangeable and none is special: a DJI Mic or any offline recorder saving to a folder
that Syncthing-Fork syncs from the phone/laptop; a Telegram voice note that the bot saves as a
file; a text note dropped directly. No custom uploader app is needed while every device can
write plain audio files to a normal folder. Device rule: records without an account, exports
plain audio. Cloud-tethered recorders are out. Telegram is the fast path for a thought on the
street; the recorder is for long sessions.

**Capture contract 2 — links: a URL sent to the Telegram bot is a capture.** The bot:
1. Writes the note immediately with the URL and the Telegram message id, so nothing is lost if
   the rest fails.
2. Video links (YouTube, Instagram, anything `yt-dlp` knows): `yt-dlp` fetches metadata, caption
   and the media into `brain/attachments/YYYY/<slug>/`; `ingest.py` logic transcribes it and
   cuts scene frames (the "screenshots" for video). Plain web pages and any dropped document
   go to **Paperless**: the **Gotenberg 8.36 already running in `n8n`** renders the URL to a
   PDF (`POST /forms/chromium/convert/url`), the pod writes it into a `brain/` subfolder of the
   Paperless consume share (`/mnt/user/Xartura`, recursive polling, OCR ell+eng+ces+pol), and
   Paperless OCRs, deduplicates and files it. The note carries the URL, the title and a pointer
   to the Paperless document (its title and, once consumed, its id). Title, transcript/caption
   and frame links are appended to the note.
3. Replies "What is this about?" — answering is optional. A reply-to on that message is
   matched by message id to the note still in `inbox/` and appended as a `## Why` section.
   Unanswered notes stand as they are.
Media is kept, not deleted; it is the raw. If attachments outgrow the phone, `.stignore` them
phone-side only.

**Namespace `brain` holds everything brain-related in k3s** — the capture pod now, Cognee and
its Postgres in phase B, agents in phase C. **Runtime for phase A: one Deployment, one pod, two
containers, one RWO volume:**
- `capture` — code in a ConfigMap from the repo (with a checksum annotation so a code push
  rolls the pod), Telegram token in a SOPS secret. Image: the repo has no image build pipeline,
  so instead of a self-built one-layer image the pod runs the community image
  `ghcr.io/jauderho/yt-dlp` (Alpine + Python 3.14 + ffmpeg 8 + yt-dlp, verified 2026-09-10),
  digest-pinned; nothing is installed at start. Trade-off accepted knowingly: a third-party
  image sits in the trust path of a pod holding the Telegram token and the LiteLLM key, and
  Renovate will bump the digest often. Revisit when the repo gets an image build. Two loops in one process: the inbox watcher
  (every minute) and the Telegram poller. All inference through LiteLLM (`whisper`,
  `json-extract`). n8n is not on the path.
- `syncthing` — official `syncthing/syncthing` image, mounts the vault PVC and the NFS data
  volume, config on a small second PVC. It shares **two** folders: the vault (to laptop,
  dev-seat, phone, and the Greece Unraid Syncthing as receive-only DR) and the drop zone
  `inbox/audio/` (to the phone, so the recorder app's output folder lands on the array). Port 22000
  exposed on a LoadBalancer IP for the LAN. Relays and global discovery are OFF: off-LAN peers
  (phone away from home, Greece) wait for the remote-reach decision (map ticket BRAIN-36).

Two containers in one pod is deliberate: Longhorn RWO is simpler and faster than RWX, and the
two writers (capture, Syncthing) never touch the same file — capture owns `inbox/` on the vault
and everything on the data volume; Syncthing replicates whatever the human edited elsewhere
and delivers recorder files into the drop zone. Gotenberg is called cross-namespace, which
needs one netpol rule.

**Split, and why.** The vault PVC holds only what Obsidian edits: Markdown and `.obsidian/`.
It stays small by construction (10 Gi is generous), which keeps Longhorn replicas cheap and
Syncthing to the phone fast. Everything heavy — dropped audio, downloaded video, frames,
screenshots, transcript files — lives on the Unraid array over NFS, where 4 TB disks are the
right home. Every note carries the transcript **inline** in its body, so a note is complete
without the array; the array holds the raw for when you want to go back to it.

**One capture folder shape, already in use everywhere** (on the data volume):
```
attachments/YYYY/<slug>/
  <media file>        # the original (kept)
  transcript.txt      # timestamped [mm:ss] lines, as ingest.py / study_batch.py write today
  caption.txt         # yt-dlp description/caption for links
  frames/             # scene_NNNN.jpg + t_NNN.jpg for video
(web pages and documents are not here — they are Paperless documents)
```
This is the exact output of `study_batch.py`, `batch.py`, `ig_reels.py` and `ingest.py`, so the
existing corpora (`~/gesden/CASE STUDY/*`, TUF `~/gesden_out/masterclass/*`) become part of
the brain by copying them under `attachments/` and generating one note per folder. No
reprocessing.

**Layout (day one):**
```
vault/  (Longhorn PVC — the Obsidian vault, synced to every device)
  inbox/*.md      # generated notes; pipelines own this folder
  .obsidian/
  ...             # everything else is Stefanos's, Obsidian-managed

data/   (NFS to Unraid — drops in, raw out; never synced to the phone except the drop zone)
  drops/             # phone send-only Syncthing folder; never moved or deleted by the pod
  audio/YYYY/        # copies of processed recordings (own voice: kept forever)
  attachments/       # one folder per capture (media + transcript + frames)
```

**Capture note format** (`inbox/YYYY-MM-DD-HHMM-<slug>.md`):
```
---
created: 2026-09-10T14:32:00+02:00
source: dji-mic | telegram-voice | telegram-link | text
audio: data/audio/2026/<file>             # audio captures (path on the array)
url: https://...                          # link captures
raw: data/attachments/2026/<slug>/        # video captures: media, frames
paperless: <document title or id>         # page and document captures
telegram_msg: 12345                     # link captures, for the reply-to match
tags: [..]
---
# <title from json-extract>

<transcript or message text>
```
**Two passes.** The watcher writes the note within the minute: transcript inline, first line
as title, no tags. A second pass, whenever the GPU is free (containment alias, see the map),
adds title, kind, tags and parties — and only to notes still in `inbox/` whose modification
time equals the time the pipeline wrote them, so a note Stefanos has opened and edited is
never rewritten. The hallucination detector runs on every transcript at the word level, not
only before a deletion.

The inbox watcher is `ingest.py` with three changes: output is a Markdown note with
frontmatter, written to the vault with the transcript inline (the `.txt` beside the media on
the array stays too); `json-extract` (qwen3:4b, `think:false`,
`response_format` json_schema) adds title, tags, slug; processed media moves to `done/`.
Whisper goes through the LiteLLM `whisper` alias instead of the hard-coded
`192.168.1.225:8000`. Chunking, retries, frames and the thin-transcript
flag stay as they are. Telegram voice notes are saved into `inbox/audio/` by the bot loop and
picked up by the same watcher; the bot replies with the filename.

**Storage manifests** in `kubernetes/apps/brain/`:
- `vault` PVC: `storageClassName: longhorn`, 10 Gi, RWO, labels
  `recurring-job.longhorn.io/daily-backup: enabled`, `recurring-job.longhorn.io/source: enabled`,
  `recurring-job-group.longhorn.io/default: enabled` (the trio verified 2026-09-10 to be what
  actually reaches the Volume CR; the label alone does not). Mounted at `/data/vault` in both
  containers.
- `data` PV/PVC: NFS to `192.168.1.100:/mnt/user/brain` following the Nextcloud PV pattern
  (`nfsvers=4.1`, `ReadWriteMany`, `Retain`); mounted at `/data/data` in both containers.
  One-off on Unraid: create the share, export it to the cluster node IPs with the devdata rule
  (`all_squash,anonuid=99,anongid=100`), ownership 99:100. The pod runs as 99:100.
- `syncthing-config` PVC: 1 Gi Longhorn, holds the device identity (losing it means every
  peer must re-pair — the Greece lesson).
- `brain` netpol: egress to Telegram API, yt-dlp targets (public internet), LiteLLM, the NFS
  server on 2049, and `n8n/gotenberg`. A second NFS PV to the Paperless consume share
  (`/mnt/user/Xartura/brain`), write-only from the pod's point of view. Gotenberg needs an ingress rule from `brain` and egress
  to the public internet for screenshots (today it only renders internal waiver HTML).
- The phone receives the vault (small) and sends into the drop zone; nothing else on the data
  volume syncs anywhere.

**"Find" in phase A** = Obsidian search. No vector index yet.

**Desktop access:** dev-seat and the laptop each hold a Syncthing copy of the vault; Obsidian
opens that copy. Obsidian's own config (`.obsidian/`) syncs too; exclude workspace state via
`.stignore` if it churns. The copies are plain files — that is the lock-in proof, and it is
also why the Longhorn volume being reachable only through the pod does not matter.

## Definition of done — phase A is demonstrable, not merely functional

Phase A is finished when all of these hold and can be shown on camera:

1. **Speed.** A Telegram voice note becomes a note visible in Obsidian on the laptop within
   60 s of sending (a 30 s clip transcribes in a few seconds; the rest is Syncthing).
2. **Links.** A YouTube or Instagram link becomes a note with title, caption, transcript and
   scene frames; a plain web page becomes a note plus a searchable, OCR'd document in Paperless. The bot asks
   "what is this about?" and the answer lands in the note.
3. **Recorder.** A file from the DJI Mic dropped in the phone's recorder folder appears as a
   note without touching anything else. The uploader is Syncthing; there is no app.
4. **Raw kept.** Every capture folder holds the original media next to its transcript.
5. **The lock-in proof.** Delete the capture Deployment, open the folder in a plain text
   editor: every note is readable. Reinstall: nothing to migrate. Later, in phase B, the same
   proof for the index: delete Cognee, rebuild from the folder, same answers.
6. **Observable.** The pod has liveness/readiness probes; the watcher pushes a heartbeat to
   Uptime Kuma each cycle (same pattern as the backup-watchdog), so a stalled capture loop is
   an alert, not a discovery weeks later. Capture count and last-capture age are visible on
   the homepage/Grafana.
7. **Backed up.** Longhorn daily backup of the vault PVC lands in MinIO and replicates to
   Greece; a restore from that backup is performed once and shown. Syncthing copies on laptop,
   dev-seat and Greece are the second line. The data share on the array is raw and
   re-creatable from the notes' point of view (transcripts are inline), but it is the only copy
   of the media: it gets the same receive-only Syncthing leg to Greece that devdata has.
8. **Documented in public.** This ADR accepted in `docs/adr/`, the Deployment + code ConfigMap +
   netpol + PV in `kubernetes/apps/brain/`, one diagram, and the operating lessons
   (10-minute chunking, forced-language routing, thin-transcript flag) written where a
   reader finds them.

## Why this shape — the interchangeability argument

| Concern | Mechanism | To swap | Cost |
|---|---|---|---|
| LLM (extraction, later chat) | every call names a LiteLLM alias (`json-extract`, `chat`), never a model | edit one line in `litellm` configmap | zero code |
| STT | LiteLLM `whisper` route with fallback | same | zero code |
| GPU / host | LiteLLM routes to the Proxmox ML boxes or in-cluster; failover already proven | change route | zero code |
| Editor | plain Markdown + relative links, no plugin-specific syntax in generated notes | open the folder elsewhere | zero |
| Sync | Syncthing container, one folder | any file sync | copy the folder from any peer |
| Index / memory (B) | rebuilt from files on demand | delete, deploy successor, re-ingest | one afternoon |
| Capture source | "a file in the inbox" | any device that writes a file | zero |
| Capture runtime | one stateless Deployment, code in git | rewrite freely, state lives in files | small |

**Upgradable:** every image is digest-pinned and Renovate already opens PRs; the capture pod
carries no state, so a bad upgrade is a rollback of one Deployment. Models are upgraded by
editing an alias.

**No maintenance:** no database of its own, no queue, no scheduler, no plugin ecosystem. The
only stateful thing is a folder, and folders do not need upgrading. The pod restarts itself;
the heartbeat tells you if it stops. Syncthing and LiteLLM are already operated for other
reasons, so the brain adds no new operational surface beyond one pod.

**Agile:** phases are additive. B and C read the folder A produces; nothing in A changes to
enable them. Each new capture source is a new writer, not a change to existing ones.

## Roadmap

| Phase | Adds | Demo scene |
|---|---|---|
| A (now) | capture: audio, links, recorder; raw kept; heartbeat | voice note → Obsidian in seconds; link → screenshot + transcript |
| A.1 | yt-dlp transcripts for video links; import of the existing Gesden/TUF corpora | one folder of 13 masterclasses becomes 13 notes |
| B | Cognee over the folder: **embedded graph**, vectors in pgvector, embeddings via LiteLLM | "what did I say about X?" answered with citations; delete-and-rebuild proof |
| C | Cognee MCP + scheduled agents that write into inbox/ | an agent files a Plane issue from a voice note |
| Later | Paperless documents as a second ingest source for B; phone Syncthing replaces CouchDB | — |

## Phase B — Cognee, sketched (not decided)

Cognee is the memory layer: it reads the vault, builds a knowledge graph plus vector index, and
answers "what did I say about X?" with citations. It is an index, never a store — rule 2.

**How it reaches the vault.** Cognee runs as its own Deployment in `brain` with a Syncthing
sidecar holding a **receive-only copy of the vault** on its own small PVC. This keeps the brain
pod untouched (RWO stays), and it makes the point on camera: Cognee is just another Syncthing
peer, like the laptop. Delete it and nothing upstream notices.

**Where its state goes — all rebuildable:**

| Cognee needs | Use | Why |
|---|---|---|
| graph store | **Cognee's embedded graph (Ladybug), files on the pod PVC** | ~~existing `neo4j`~~ — superseded 2026-09-11, see the Neo4j note below |
| vector store | Postgres + pgvector, a small dedicated instance in `brain` | Cognee's relational metadata goes in the same Postgres; one stateful pod, not two |
| LLM for entity/relationship extraction | LiteLLM alias `chat` (gemma4:12b on the GPU) | ADR-009; swap the model by editing the alias |
| embeddings | new LiteLLM alias `embed` → Ollama `bge-m3` on the GPU | multilingual: voice notes are English, Czech, Polish and Greek, the imported corpora add Spanish; MiniLM (ADR-015) is English-only |

**Rebuild command** (rule 2, demo scene): delete the Cognee namespace objects and their
PVCs, redeploy, run `cognify` over the vault copy. Same answers. Wall time depends on the GPU
and the vault size; measured and written into the accepted ADR.

**Interfaces.** Cognee's HTTP API for the demo UI; its MCP server for phase C so Claude Code
and n8n can query the brain. Open WebUI's built-in RAG (ADR-015) stays for ad-hoc document
chat; it does not become the brain's index.

**Prerequisites before B starts:** the `embed` alias in LiteLLM (none exists today); a pgvector
instance (**no Neo4j** — see below); confirm the Cognee image pins and its Ollama/OpenAI-compatible
embedding path against the docs at the time — this sketch is from September 2026 and Cognee
moves fast.

**Not decided:** whether Cognee also ingests Paperless documents and linkding bookmarks in B or
later; whether the vector store should be the Immich vchord Postgres instead of a new one
(rejected for now: the brain should not share a database with the photo stack).

## Phase C — sketch

Cognee's MCP server, plus n8n or scripts for scheduled jobs. Agents read through Cognee and
write only under `brain/inbox/` (rule 1).

## Decisions taken along the way

- **Mobile leg — Android.** Syncthing-Fork on the phone (the official Android app was
  discontinued end of 2024; the fork is the maintained one), paired to Prague as a *separate*
  peer of the in-cluster Syncthing. Obsidian mobile opens the synced folder as the vault; the
  recorder app's output folder is a second phone-side share pointed at `inbox/audio/`. Phone
  holds both send-receive; the cluster copy is master. Once this works,
  CouchDB LiveSync has no job and gets retired (own ADR, since it is a public ingress).
- **Inference backends are out of scope.** Whisper and the LLMs live on Proxmox LXCs behind
  LiteLLM; this ADR consumes the `whisper`, `json-extract`, `chat` (and later `embed`) aliases
  and nothing else. Which host answers, and its failover, is ADR-009's job. That includes the
  TUF laptop's RTX 4080: an opportunistic backend used only when the machine is on, which is
  exactly a LiteLLM fallback-order entry, not anything this ADR configures.

## Open

- **Bulk imports of the existing corpora** (Gesden case studies, TUF masterclasses, reels):
  copy them into `attachments/` on the Unraid data share; the watcher generates one note per
  folder from the transcripts already there. Anything without a transcript is processed like
  any other drop. Where the transcription actually runs is LiteLLM's routing decision
  (ADR-009), not this ADR's.
- **Side finding, not this ADR's problem any more:** devdata on Prague Unraid has NO
  point-in-time backup (verified 2026-09-10: no cron, user scripts, containers or xyOps jobs;
  only Syncthing replication and Greece's `.stversions`). It still holds CONTROL/, the cluster
  log and Gompha; tracked on the Plane board separately.
- **Unraid data share** name, export and Greece Syncthing leg: one-off manual steps.
- ~~Vault name~~ decided: `brain` — namespace, vault and Unraid share all carry it.


## Amendment 2026-09-11 — a browser Obsidian on the master vault (BRAIN-40)

**What changed.** The Decision table said "Obsidian desktop opening the folder" on a Syncthing
replica. A third container now runs Obsidian desktop *inside the brain pod*, streamed to the
browser (linuxserver/obsidian, KasmVNC), mounted on the master vault itself. It is a third writer
on the volume: capture owns `inbox/`, Syncthing replicates, and this Obsidian edits whatever
Stefanos edits — the same role the laptop's Obsidian had, moved onto the master. The inbox rule
still holds; the safety argument is unchanged because there is still one human editor per note.

**Reach.** Tailnet only: NodePort 30301 (the HTTPS twin — a secure context is needed for
clipboard/WebRTC) with `externalTrafficPolicy: Local` so the client's tailnet address survives to
the NetworkPolicy, which admits only Stefanos's devices by tailnet address (phone, the Windows
box, dev-seat, plus the Unraid box that hosts the Kuma monitor) on that port, and nothing from the
LAN or from any other tailnet device. The pod is pinned to `k3s-prg-w1` so the address is stable
(`https://k3s-prg-w1.taila09f30.ts.net:30301`); the cost is that the whole pod, capture included,
waits if w1 is down. Two gates: the device list, then HTTP basic auth (`brain-secret`). The tailnet
ACL being stock allow-all (SEC-8) no longer matters for this door. **Maintenance rule:** a device
re-enrolled in Tailscale gets a new address and fails closed until its line is updated; the Kuma
monitor from unraid-repy is the canary. A new device (the MacBook, not on the tailnet yet) is
enrolled first, then added as one line.

**What it does to the fence.** The earlier statement "the fence is a query fence, not a device
fence" assumed reading the vault required a device holding a replica. A streamed desktop makes
the whole vault, fenced material included, reachable from any tailnet browser with one password.
This is accepted knowingly: the device list plus the password are the fence for this door, the
password is rotated like the others, and the door is closed by scaling the container away if that ever feels wrong.

**Posture.** The image starts as root (s6) and drops to uid 99; it is the one container in the
pod with `runAsNonRoot: false`, declared explicitly so the pod-level invariant stays for the other
two. It keeps CHOWN/SETUID/SETGID/FOWNER/DAC_OVERRIDE for that drop. Syncthing's GUI, reachable
on localhost from this container, now requires a username and password (it did not before —
found by the 2026-09-11 review). Obsidian's per-device state (`.obsidian/workspace*.json`, cache,
trash) is excluded from sync on every peer via `.stignore`, so two Obsidian instances do not
fight over it.

**Costs accepted.** A 3.5 GB image now gates pod start for capture and Syncthing; a Renovate bump
of the Obsidian tag rolls all three. The phone keeps Obsidian mobile — a streamed desktop is not a
phone UI.

## Amendment 2026-09-11 — the vault keeps a local git history, with no remote (BRAIN-46)

**What changed.** The vault is now a git repository. A `.git` directory sits on the Longhorn volume
beside `.obsidian` and `.stfolder`, and a CronJob commits whatever changed. **It has no remote and
never will.** Nothing is pushed, fetched or hosted; the history is local state on the same volume as
the notes.

**Why this is not a contradiction of the in-house rule.** "The vault never reaches git" was stated as
a hard rule the same day, and it means **no remote**: no note, transcript or fragment is ever pushed
anywhere, encrypted or not. A repository with no remote does not move data. It is the same category of
thing as `.obsidian` — local files in a local folder. The distinction is load-bearing and easy to
misread, so it is written in `DECISIONS.md` as two separate entries, and "no remote, ever" is the
invariant that guards it. If a future change wants to push the vault anywhere, that is a new ADR, not
an implementation detail.

**Why it is needed, and why now.** The Markdown folder is the *only* durable artefact in this design,
and three things are about to start mutating it without a human in the loop: pass two moves every file
and rewrites its path from tags, the staged-correction path has an LLM rewriting note content, and the
master is now Syncthing `sendonly`, so a bad filing pass reaches every read-only mirror within seconds
with no undo anywhere. Until now "nothing is deleted silently" was a slogan with no mechanism behind
it — there was no diff, no journal and no way to answer "what did this note say last week". **Pass two
does not exist yet**, which is exactly why this lands now: it is cheap before the thing that moves
files exists, and awkward after.

A second benefit falls out for free. Because a note's history is now a series of diffs, "what did I
think about X in 2023" becomes a diff rather than a retrieval problem, which is the one question this
brain exists to answer and the one that pure retrieval answers worst.

**Rejected alternatives.** *Longhorn snapshots*, which already exist, are volume-level and
crash-consistent: they restore the whole vault at a coarse interval, give no readable content diff, and
recovering one note from one is heavy surgery. They answer "the volume died", not "the filing pass was
wrong". *An append-only journal written by the pipeline* would be new code, new bugs and a new format
to maintain, to reimplement badly what git already does. *Committing from `capture.py`* is impossible
today and is addressed below.

**How, given the pod's constraints.** The capture container runs
`ghcr.io/jauderho/yt-dlp` — Alpine, with `readOnlyRootFilesystem: true`, `runAsNonRoot`, all
capabilities dropped, and nothing installed at start. It has no `git` and cannot acquire one at
runtime. Building a custom image would break the pattern that keeps this project honest: upstream
images only, with the capture program delivered as a ConfigMap precisely so there is no image to
build. So the committer is a **CronJob in `brain` using an upstream git image**, mounting the same
vault PVC, running as `99:100` like everything else that touches the volume. This also matches the
standing decision that a script which needs to run is a Kubernetes Job, not a VM.

**The deliberate shortcut, and its ceiling.** Commits are **time-based, not per-capture**: the job
commits whatever changed since it last ran, so a commit may bundle several captures and its message
cannot name a capture id. The council's stronger form — one commit per pass, with the capture id in
the message — needs the committer to be the pipeline itself, which needs `git` inside the capture
image. The upgrade path is exactly that, and it is worth taking only once there is a reason to trace a
single capture through the history. The cheap version already delivers the undo and the diff, which is
the whole point.

**Syncthing must not see it.** `.git` goes in the vault's existing `.stignore`. Syncthing and git are a
bad pairing — thousands of small objects and constant index churn — and under a `sendonly` master the
history would be pushed to dev-seat and the laptop for no benefit whatsoever. The mirrors want the
notes, not the repository. This also keeps the guarantee honest: the history exists in exactly one
place, which is the same place the notes are written.

**Revert path.** Delete the CronJob, delete `.git`, drop the `.stignore` line. The vault is unchanged
Markdown either way and nothing reads the history, so removing it loses history and breaks nothing —
which is the interchangeability test this ADR sets for every component.

### Neo4j is out — corrected 2026-09-11 (research: `research/cognee-in-house.md`)

This ADR was drafted assuming the brain's graph would live in the **Neo4j already running in the
estate**, on its own database. **That assumption is wrong and the design no longer depends on it.**

Cognee separates datasets physically only in its **multi-user mode**
(`ENABLE_BACKEND_ACCESS_CONTROL=true`, which is the image default). That mode **refuses a plain
Neo4j provider**: it supports Neo4j only via Aura, which is cloud and therefore barred by the
in-house rule, or via a handler that spawns one Neo4j container per dataset through a Docker socket.
And **Neo4j Community cannot `CREATE DATABASE`** at all, so per-dataset isolation is impossible on
the instance we have.

That isolation is not a nicety here: the **fence** depends on relationship material sitting in a
dataset the digests and agents cannot see. A layout where datasets are only logically separated
would make the fence a filter rather than a boundary.

So phase B is **pgvector for the vectors plus Cognee's own embedded graph** (Ladybug, the Kuzu
successor, files on the pod's PVC). One stateful pod instead of two, and it is the layout upstream
actually ships, tests and documents. The estate's Neo4j stays for whatever else uses it; the brain
simply is not a consumer.

## Consequences

- One new stateful thing in the cluster: the vault PVC, backed up by the mechanism every other
  volume uses. The data share is raw on the array with a Greece replica. Everything else in
  the pod is stateless or re-pairable.
- Swapping editor, index, or agent layer is a redeploy, never a migration. Leaving k3s
  altogether is copying the folder from any Syncthing peer.
- The CouchDB LiveSync deployment becomes dead weight once phone Syncthing works; retire it.
- Cognee inherits the estate's inference routing and failover for free through LiteLLM.

## Revert path

Delete the `brain` namespace. The laptop, dev-seat and Greece copies of the vault remain, as
plain files, readable by anything; the Longhorn backup in MinIO remains restorable.
