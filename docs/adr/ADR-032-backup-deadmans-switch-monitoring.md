# ADR-032 — Backup Verification via a Dead-Man's-Switch (size + freshness), not "did it run"

**Status:** Accepted — implemented and since EXTENDED; see the 2026-08-30 note below

> **Verified and updated before publishing, 2026-08-31.** The principle in this ADR — verify the
> artifact (size + freshness), not the exit code — held up and is unchanged. The implementation has
> grown well past what is described here:
>
> - **5 checks -> 19.** At the time of drafting, five backups were watched. On 2026-08-29 an audit
>   found **eleven backup jobs with no watch at all**, including `vaultwarden-backup` (which holds
>   every credential, every SSH key, and the age key that decrypts this repo's SOPS secrets) and
>   `longhorn-system/daily-backup` (the block layer ADR-011 rests on). All are now covered.
> - **A second check shape.** `countcheck NAME PATH MIN_COUNT MAX_AGE PUSH` handles backups that
>   write a *tree* of objects (Longhorn's backupstore, Velero) where the signal is how much was
>   written recently rather than how big the newest file is.
> - **An external layer.** Kuma and the xyOps conductor both live on Prague Unraid, alongside the
>   MinIO they report on — so this switch could not detect the loss of the box it runs beside.
>   healthchecks.io now provides dead-man switches from outside the fleet (ADR pending).
>
> The lesson this ADR half-anticipated, stated plainly: **a dead-man's switch that lives inside the
> thing it watches is not a dead-man's switch.**
**Date:** 2026-07-06
**Relates to:** ADR-011 (backups + offsite replication), ADR-022 (Unraid shared service layer)

## Context

The logical backups (dental DB, gym n8n, gompha n8n, Prague→Greece replication) had no failure alerting. This turned out to matter more than usual because of a real incident: the dental `clinic-postgres-backup` had **never actually worked** — it shipped suspended, and even un-suspended it hit a NetworkPolicy pod-admission lag (see the netpol-admission-lag note) that made `pg_dump` run before the DB was reachable, so it **silently uploaded empty 200-byte files** and would have reported "success."

The lesson: a backup can "succeed" (exit 0, object written) while being **garbage**. Alerting must catch three distinct modes — *job failed*, *job never ran*, and *job wrote an empty/too-small file* — and the last one is invisible to any "did the CronJob complete" check.

A second constraint: the minimal backup images (`minio/mc`, `bitnamilegacy/kubectl`) have no HTTP client, so per-job "ping on success" isn't uniformly possible.

## Decision

Adopt a **dead-man's-switch (push-monitoring) pattern**, verified centrally by size + freshness:

- A single `backup-watchdog` CronJob (every 30 min, `backup` namespace) inspects MinIO for each backup: the newest object's **size ≥ threshold** and **age ≤ window**. Only if healthy does it ping an Uptime Kuma **push** monitor. A failed / empty / stale / missing backup withholds the ping → the monitor goes DOWN (90-min interval) → Telegram alert.
- This catches the silent-empty-dump mode with a size gate, and "never ran" with the freshness gate, **without needing an HTTP client inside the backup images**.
- The Greece warm-restore pings its own monitor from its cron (including on the legitimate "failover active, skip" path, so it doesn't false-alarm during a real failover).
- Monitors live in the existing CZ/Prague Uptime Kuma; notifications go to the existing Telegram channel.

## Options considered

- **Per-job "ping on success."** Rejected as the sole mechanism: uneven (images lack curl), and a job that writes an empty file still "succeeds," so it would ping green on garbage.
- **CronJob-completion alerting (ArgoCD/K8s job status).** Rejected: blind to empty-but-successful dumps — the exact failure that bit us.
- **Central size+freshness watchdog (chosen).** One place, catches all three modes, image-agnostic.

## Consequences

- Backups now alert on fail / didn't-run / empty, via Telegram. `backup-watchdog` + the `kuma-push` SOPS secret are committed under `backup-replication/`.
- **Known blind spot:** the watcher (CZ Kuma) runs in Prague, so a *total Prague outage* takes the watcher down with it and would not alert. The intended closer is an external dead-man's-switch (e.g. healthchecks.io) pinged from the **Greece** side, or a Greece-hosted Kuma — deferred, tracked.
- Thresholds are per-backup and hand-tuned (dental ≥50KB/90min; n8n small; replication ≥50KB/120min). Silent truncation risk if a real backup legitimately shrinks below the floor — revisit if a backup's normal size drops.
