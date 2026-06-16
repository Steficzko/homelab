# ADR-029 — Deploy Paperless-ngx and n8n Before Zero Trust: Acceptable Risk Window

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Both Paperless-ngx and n8n have been waiting for deployment. Each had a different
blocker. Both blockers cleared within the same 72-hour window before departure from
Prague on 2026-05-27 14:00. Zero Trust (ADR-010) is not yet deployed.

**Paperless-ngx**

The NFS infrastructure it depends on — Unraid exports, per-app subdirectory mounts,
read-only media library — was not ready. ADR-013 records that decision. The exports
are now live. Paperless can mount its consume and media directories.

The content classification is low sensitivity. The document store is predominantly
publicly downloaded books, exported PDFs, and administrative documents. It does not
hold financial records, identity documents, or other high-sensitivity personal data
at this time. The risk profile of exposing Paperless to the cluster before Zero Trust
is accordingly low.

There was an ArgoCD+SOPS incident during initial deployment. Secret manifests
generated from `secret.example.yaml` templates were being applied by ArgoCD as real
Kubernetes Secrets, overwriting SOPS-encrypted values with plaintext placeholders
(`changeme` strings for the Postgres password, Redis password, and Paperless admin
password). The incident is resolved. Before Zero Trust is enabled, all three passwords
will be rotated and the SOPS age key will be rotated. The incident is noted here for
the record; it does not change the deployment decision.

**n8n**

n8n is the automation layer for the Telegram → Whisper → Gemma → Obsidian pipeline
(ADR-010 references this as the primary motivation for Zero Trust). It was held back
previously because webhook security was unresolved. Public webhook URLs with no auth
layer were the concern.

The current state of the inference stack changes the calculus:

| Dependency | Status |
|-----------|--------|
| LiteLLM gateway | Live — litellm.ai.svc.cluster.local:4000 |
| Whisper (RYZEN_ML) | Live — faster-whisper large-v3 |
| Gemma 4 (XT_ML) | Live |
| n8n | Not yet deployed |

The ML machine stays in Prague permanently. Testing the end-to-end pipeline requires
physical presence: observing LiteLLM routing, confirming Whisper transcription latency,
verifying the Obsidian vault write. Remote debugging a broken pipeline after departure
is significantly harder than deploying now while the hardware is accessible.

**Why now specifically**

The departure deadline is 2026-05-27 14:00 — 3 days from this decision. The pipeline
must be deployed and end-to-end tested while physically present. Deploying after
departure means the first test run happens remotely, with no ability to inspect the ML
machine locally or restart LXCs without SSH.

Zero Trust will be deployed in the cohort hardening session after Prague (ADR-010).
That session is the right time to harden n8n webhooks, not before — piecemeal rollout
is worse than a clean cohort (established pattern, ADR-010).

## Decision

Deploy Paperless-ngx and n8n now. Operate both without Cloudflare Zero Trust until
the cohort hardening session. Rotate all Paperless credentials before ZT goes live.

**Paperless-ngx deployment:**

- Mounted on NFS exports per ADR-013
- Ingress exposed internally (k3s cluster ingress); not routed via Cloudflare tunnel
  until ZT cohort session
- Password rotation (Postgres, Redis, admin) scheduled before ZT go-live

**n8n deployment sequence:**

1. Deploy n8n to the cluster
2. Create the owner account immediately on first boot (this locks n8n's setup mode)
3. Configure LiteLLM, Whisper, and Obsidian credentials
4. Build and test the Telegram → Whisper → Gemma → Obsidian workflow end-to-end
5. Leave running; no sensitive automation is wired until after ZT is in place
6. ZT cohort session adds the Cloudflare Access layer

n8n's baseline security posture before ZT: owner account authentication is enforced.
Webhook URLs are UUID-based — not guessable by enumeration. This is an obscurity
measure, not an auth layer. It is accepted as the interim posture.

## Reasoning

**The pipeline dependency on physical presence is the forcing function.**

The ML machine is not a cloud service. LiteLLM routing, ROCm GPU passthrough, and
the LXC configuration all benefit from local access to inspect logs, restart
containers, and verify hardware state. A broken pipeline discovered remotely is a
stuck pipeline: SSH-only access with no ability to physically cycle hardware or
observe serial console output. Deploying now and testing while present is the lower-risk
path.

**Paperless content does not justify delaying on security grounds.**

The document library contains books and downloaded PDFs. The SOPS incident is notable
as a configuration class of bug — ArgoCD applying example secrets as real Secrets — but
it did not expose data externally; it was an internal cluster state issue. The plaintext
passwords existed inside the cluster, not outside it. Rotating before ZT go-live closes
the residual risk.

**Webhook security is a known gap, not an unknown one.**

The concern about n8n webhooks is documented. UUID-based URLs reduce accidental
exposure but are not authentication. The decision is to accept this gap for the window
between deployment and ZT cohort, with the constraint that no sensitive automation
(financial, identity, external API keys) is wired until ZT is in place. This constraint
is intentional and explicit.

**Test before lock-down, not after.**

The alternative sequence — deploy ZT first, then deploy n8n inside it — would require
debugging the pipeline through an additional auth layer with no local hardware access.
If something in the pipeline breaks (Whisper timeout, LiteLLM routing rule, Obsidian
vault mount), diagnosing it through Cloudflare Access logs and remote SSH is slower
and harder than diagnosing it directly. The test-then-harden sequence is the correct
order given the departure constraint.

## Consequences

**Wins:**

- The n8n pipeline can be end-to-end tested while hardware is accessible. Any LXC,
  LiteLLM, or Whisper issue discovered during testing can be resolved in-person.
- Paperless-ngx is unblocked the moment NFS exports are live — no artificial wait.
- No sensitive automation is wired to n8n during the risk window, limiting blast
  radius if a webhook URL is discovered.
- The ZT cohort session (ADR-010) remains the single place where all webhook hardening,
  ingress policies, and Access rules are applied consistently.

**Costs and open risks:**

- **n8n webhook exposure window** — between deployment and the ZT cohort session,
  n8n webhook URLs are accessible to anyone who discovers them. UUID-based URLs reduce
  the chance of discovery; they do not prevent it. Duration of this window is days to
  a few weeks. No sensitive automation may be wired during this period.

- **Paperless plaintext password incident** — the `changeme` placeholder passwords
  existed as Kubernetes Secrets in the cluster for some period. They were not exposed
  externally. All three (Postgres, Redis, admin) must be rotated before ZT go-live.
  The SOPS configuration that caused the incident must be fixed so example manifests
  cannot be applied as real Secrets.

- **No external auth layer for Paperless during this window** — Paperless is reachable
  from within the cluster without a ZT policy. It is not exposed via Cloudflare tunnel
  until ZT cohort. Intra-cluster access is the only surface.

- **Pipeline untested until deployed** — the Telegram → Whisper → Gemma → Obsidian
  path has not run end-to-end. The test session will surface integration bugs in
  LiteLLM routing, Whisper timeout config, or Obsidian vault path. These are expected
  and addressable while present.

## Alternatives Considered

- **Deploy ZT first, then deploy n8n** — rejected. The correct debugging environment
  for a first pipeline test run is local. Adding Cloudflare Access as an additional
  layer before the pipeline is proven working increases diagnostic surface during a
  time-constrained window. ZT cohort is the right sequencing.

- **Delay both deployments until after Prague** — rejected. The ML machine is
  permanently in Prague. An n8n pipeline that cannot be tested against its own
  inference backend during the initial deployment is not a deployment — it is a
  configuration exercise with no feedback loop. Paperless has no dependency on
  physical presence, but co-deploying with n8n is trivially easy now that NFS is live.

- **Deploy n8n with a WAF shared-secret on webhooks** — not yet implemented. The
  WAF shared-secret approach (requiring a header value on all webhook requests) is
  a credible hardening option noted in ADR-010 open risks. It is not used here because
  it requires additional Cloudflare WAF configuration that belongs in the ZT cohort
  session, not as a one-off change made under deadline pressure.
