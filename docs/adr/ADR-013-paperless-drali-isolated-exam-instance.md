# ADR-013 — Isolated Paperless-ngx Instance for Dr. Ali Adnan's Exam Knowledge Base

**Status:** Accepted  
**Date:** 2026-05-25  
**Deployed:** 2026-05-26

## Context

This ADR is self-contained. Relevant background:

The homelab runs a k3s cluster on Proxmox VE, managed via ArgoCD GitOps. Secrets are encrypted with SOPS/age. All persistent storage uses Longhorn-replicated PVCs unless an NFS mount is explicitly required. New services are exposed externally via Cloudflare Tunnel, with Cloudflare Zero Trust Access as the planned auth layer (not yet deployed — see note under Consequences).

An existing Paperless-ngx instance ("xartura") serves as the owner's personal document archive. Its stack: PostgreSQL 16, Redis 7, Apache Tika, Gotenberg, and Paperless-ngx 2.20.15, all on Longhorn PVCs, with an additional NFS PV for the media library (large personal document collection).

Open WebUI is deployed at `chat.kostikidis.net` and provides a built-in RAG/Knowledge Collections feature backed by Ollama (Gemma running on-cluster). Users can create named knowledge collections and inject them into chat sessions with `#collection-name`.

**The immediate need:**

Dr. Ali Adnan is a friend and colleague with approximately 2 GB of medical study notes — predominantly OCR-scanned PDFs. He has an exam within one week. He needs to query this material via natural-language chat without uploading it to a cloud service.

The privacy constraint is real: medical study notes may contain patient-adjacent content. Using a cloud service (Google NotebookLM, ChatGPT file upload, etc.) is not acceptable. The data must stay on the cluster.

The time constraint is also real: a bespoke RAG pipeline (vector database, embedding service, custom ingestion tooling) would take 3–5 days of engineering. The exam is this week.

## Decision

Deploy a second, fully isolated Paperless-ngx instance in namespace `paperless-drali`, exposed at `dralibjj.kostikidis.net`. The stack is a direct clone of the xartura configuration with independent PostgreSQL, Redis, Apache Tika, Gotenberg, and Longhorn PVCs. No component is shared with xartura. Dr. Ali receives his own admin credentials.

After the exam, the entire namespace and all associated PVCs are deleted. `kubectl delete namespace paperless-drali` removes all state cleanly.

The knowledge-base layer uses Open WebUI's built-in Knowledge Collections — not a custom RAG stack. The workflow:

1. Dr. Ali's PDFs are placed in the Paperless consume directory
2. Paperless runs OCR via Apache Tika + Gotenberg (eng-only; Swedish OCR pack was attempted and reverted — typed PDFs process correctly without it)
3. paperless-gpt processes each document post-OCR via the LiteLLM gateway (`litellm.ai.svc.cluster.local:4000`) and auto-generates title, correspondent, synopsis, and free-form tags in Swedish dental/medical context
4. Dr. Ali queries at `chat.kostikidis.net` via Open WebUI using two named workspaces, each with a different system prompt variant for Gemma

### Storage allocation

All PVCs are Longhorn-only. No NFS mounts. Approximate sizes:

| Volume | Purpose | Requested size |
|--------|---------|---------------|
| media | Processed document storage | 20 Gi |
| data | Paperless application data | 5 Gi |
| postgres | PostgreSQL database | 5 Gi |
| consume | Incoming document staging | 10 Gi |

Total: approximately 40 Gi of Longhorn storage for the lifetime of the instance.

### Isolation model

The drali instance shares no database, no storage path, and no Kubernetes service with xartura. Namespace isolation ensures:

- Dr. Ali's documents cannot cross into the owner's personal archive
- A `kubectl delete namespace paperless-drali` removes everything — postgres data, document storage, and all PVCs — in a single operation
- Open WebUI knowledge collections are per-user: `dr-ali-exam` is owned by Dr. Ali's account and is not visible to other users

## Reasoning

**Isolation is the primary design constraint, not performance or cost.**

Medical study notes carry a higher sensitivity expectation than general documents. Putting Dr. Ali's content into a subfolder of xartura — technically possible — would mean his data lives in the same PostgreSQL database as the owner's personal archive. A clean teardown would require manual database surgery. Namespace isolation is the correct boundary: hard wall between datasets, trivial teardown.

**Open WebUI Knowledge Collections eliminates the RAG engineering problem.**

A custom RAG pipeline — embedding service, vector database (e.g. Qdrant or Chroma), ingestion tooling, chunk-size tuning — is the right long-term approach for a production knowledge base. For a one-week exam use case, it is the wrong approach. Open WebUI's built-in knowledge collection is already deployed, already working against the on-cluster Gemma model, and requires no additional infrastructure. The OCR pipeline (Paperless + Tika + Gotenberg) handles the hard part: turning scanned PDFs into clean, queryable text.

**Longhorn-only storage simplifies teardown.**

The xartura instance has an NFS PV for its media library — a large personal collection that predates the Longhorn-first storage convention. The drali instance is temporary and its total data volume (2 GB of source material) fits comfortably in Longhorn. No NFS PV means no NFS PV/PVC cleanup step after the exam. `kubectl delete namespace` is the complete teardown procedure.

**The clone pattern is proven.**

The xartura stack is the template. Cloning it into a new namespace with new credentials and new PVC names requires changing a namespace prefix and a handful of environment variables. No new services or manifests are introduced. ArgoCD manages the application as a standard app targeting the `paperless-drali` namespace.

## Consequences

**Wins:**

- Deployed in approximately one hour. Dr. Ali has a private OCR pipeline and a queryable knowledge base before the exam.
- Complete data isolation: no shared storage, no shared database, no shared credentials with xartura.
- Clean teardown: one `kubectl delete namespace paperless-drali` removes all state. No residual PVCs, no database entries to prune, no NFS exports to clean up.
- Data never leaves the cluster. Medical study notes do not touch any cloud service.
- Zero ongoing cost. No per-query fees, no external API calls for the RAG layer.
- Validates the clone-and-isolate pattern for future guest or short-lived deployments.

**Costs and open risks:**

- **~40 Gi of Longhorn storage consumed for the duration.** Longhorn replicates across cluster nodes by default (typically 2–3 replicas), so the actual storage footprint is 80–120 Gi of raw disk. This is a temporary reservation, not a permanent cost, but it is non-trivial if other Longhorn consumers are expanding simultaneously.

- **No Cloudflare Zero Trust on this instance.** Zero Trust has not been deployed yet (planned for the cohort hardening session). `dralibjj.kostikidis.net` is exposed via Cloudflare Tunnel and protected only by Paperless-ngx's own admin credentials. Application-level credentials are the sole auth layer until ZT is configured. The subdomain is public. This is the same posture as all other pre-ZT services in this cluster — it is a known, accepted gap, not an oversight.

- **No automated teardown.** There is no TTL mechanism or automated namespace cleanup. The owner must manually run `kubectl delete namespace paperless-drali` after the exam. If this is not done promptly, the Longhorn storage reservation persists indefinitely.

- **OCR quality depends on scan quality.** Apache Tika and Gotenberg produce text from machine-readable PDFs reliably. For low-resolution scans or handwritten notes, OCR accuracy degrades. Swedish OCR (`tesseract-ocr-swe`) was attempted and reverted — it improved handwritten scan coverage but corrupted ligatures and soft hyphens in the typed PDFs that form the majority of the corpus. Eng-only is the accepted tradeoff for this use case.

- **Open WebUI knowledge collection upload is manual.** Processed documents from Paperless must be manually downloaded and uploaded into Open WebUI collections if the RAG approach is used. For this deployment the primary interface is direct Gemma chat via workspaces — manual upload is a one-time step, acceptable for a one-week use case, not acceptable for a production integration.

- **No automated teardown.** There is no TTL mechanism or automated namespace cleanup. The owner must manually run `kubectl delete namespace paperless-drali` after the exam. If this is not done promptly, the Longhorn storage reservation persists indefinitely.

## Alternatives Considered

- **Give Dr. Ali a folder within the xartura instance** — rejected. Dr. Ali's data would share xartura's PostgreSQL database and Longhorn PVC. Clean teardown requires manual database operations and selective PVC management. Data isolation is not guaranteed at the storage level.

- **Custom RAG pipeline (vector database + embedding service)** — rejected. Deploying and tuning a vector store (Qdrant, Chroma, or similar) plus an embedding service, ingestion tooling, and chunking configuration is a 3–5 day engineering task. The exam is within one week. Open WebUI's built-in Knowledge Collections delivers equivalent query capability with zero new infrastructure.

- **Cloud service (Google NotebookLM, ChatGPT file upload, or similar)** — rejected. Medical study notes may contain patient-adjacent content. Uploading this material to a third-party cloud service is not acceptable on privacy grounds. The cluster provides equivalent capability on-premises.

## Outcome

Deployment confirmed working as of 2026-05-26.

**What shipped vs. the original design:**

- **paperless-gpt added.** An additional pod in `paperless-drali` runs post-OCR against the LiteLLM gateway and auto-generates document title, correspondent, synopsis, and free-form tags in Swedish dental/medical context. This was not in the original plan — it emerged during deployment and materially improves document organisation inside Paperless. Teardown is unaffected: paperless-gpt is in the same namespace.

- **Swedish OCR attempted and reverted.** `tesseract-ocr-swe` was added then removed (commit e31ffc3). The typed PDFs that form the bulk of the material process correctly on the eng-only model. Handwritten scan coverage was sacrificed.

- **Open WebUI workspaces configured.** Dr. Ali has 2 named workspaces in Open WebUI, each pinning a different system prompt variant for Gemma — one general study partner, one stricter OSCE simulation mode.

- **Handover complete.** Dr. Ali is technical and will self-tune Gemma system prompts and workspaces going forward. No ongoing support from the owner is expected post-deployment.

**Remaining open item:** `kubectl delete namespace paperless-drali` to be run after the exam. No other cleanup required.
