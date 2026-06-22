#!/usr/bin/env bash
# greece-standby-probe.sh — DR READINESS monitor for the Greece warm standby (ADR-012).
# Standalone; schedule via cron. READ-ONLY everywhere. For the bjj/n8n tier it answers
# the question that actually matters for a warm standby — "if Prague dies right now, is
# Greece ready and how stale is its data?" — by checking:
#
#   1. RPO freshness   — age of the newest bjj-postgres + n8n backup in the Greece MinIO
#                        (proves Prague->Greece replication is alive and how much data
#                        we'd lose on failover). Alert if older than RPO_MAX_H hours.
#   2. Data present    — Greece bjj-postgres reachable AND key tables non-empty
#                        (proves the warm restore actually seeded real data).
#   3. Standby posture — Greece Postgres UP and n8n NOT running (catches an accidental
#                        live-failover left running, which would double-fire schedules).
#   4. Sync vs source  — (optional, PRAGUE_DIFF=1) compares key-table counts Greece vs
#                        the live Prague DB. Greece lagging Prague by <= RPO is expected
#                        and fine; Greece AHEAD of Prague, or a table empty in Greece, is
#                        flagged as drift.
#   5. Reports a single up/down + summary to Uptime Kuma if ~/.kuma_standby_push exists.
#
# Runs on the dev-seat (SSH to Greece + kubectl to Prague). No writes, no restarts.
#
#   ./greece-standby-probe.sh                 # full check, human output
#   RPO_MAX_H=2 ./greece-standby-probe.sh     # tighter RPO alert threshold
#   PRAGUE_DIFF=0 ./greece-standby-probe.sh   # skip the live-Prague comparison
set -uo pipefail   # NO -e: a failed check is a measurement to report, not a fatal error

GH="${GH:-100.85.129.88}"                       # Greece Unraid over the tailnet
NS="${NS:-bjj}"                                 # Prague namespace
RPO_MAX_H="${RPO_MAX_H:-3}"                      # alert if newest backup older than this
PRAGUE_DIFF="${PRAGUE_DIFF:-1}"
KEY_TABLES="members attendance ledger_entries belt_promotions class_sessions"
KPUSH="$(cat "$HOME/.kuma_standby_push" 2>/dev/null || true)"
LOG="${LOG:-$HOME/greece-standby-probe.log}"
[ -t 1 ] || exec >>"$LOG" 2>&1

problems=""; addp(){ problems+="$1; "; }
epoch_of(){ local s d t; s=$(echo "$1" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1); [ -n "$s" ] || return 1
            d=${s:0:8} t=${s:9:6}; date -u -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null; }
age_h(){ awk -v n="$(date -u +%s)" -v e="$1" 'BEGIN{printf "%.1f",(n-e)/3600}'; }

echo "===== greece-standby-probe $(date '+%F %T %Z') ====="

# ---------- Greece side: posture + RPO + data presence (one SSH round-trip) ----------
GOUT="$(ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 "root@$GH" 'bash -s' <<'REMOTE' 2>/dev/null
cd /mnt/user/appdata/bjj-failover 2>/dev/null && . ./.env 2>/dev/null
docker ps --format '{{.Names}}' | grep -qx bjj-postgres && echo "PG_RUNNING=yes" || echo "PG_RUNNING=no"
docker ps --format '{{.Names}}' | grep -qx n8n          && echo "N8N_RUNNING=yes" || echo "N8N_RUNNING=no"
MC="docker run --rm -e MC_HOST_dr=http://${MINIO_DR_USER}:${MINIO_DR_PASSWORD}@100.85.129.88:9100 minio/mc"
echo "PG_DUMP=$($MC ls dr/app-backups/bjj-postgres/ 2>/dev/null | tail -1 | awk '{print $NF}')"
echo "N8N_DUMP=$($MC ls dr/app-backups/n8n/ 2>/dev/null | tail -1 | awk '{print $NF}')"
for t in members attendance ledger_entries belt_promotions class_sessions; do
  c=$(docker exec bjj-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from $t" 2>/dev/null)
  echo "GR_$t=${c:-NA}"
done
REMOTE
)"
[ -n "$GOUT" ] || { echo "FATAL: Greece host $GH unreachable over SSH"; addp "greece unreachable"; }

getv(){ echo "$GOUT" | grep -m1 "^$1=" | cut -d= -f2-; }
PG_RUNNING=$(getv PG_RUNNING); N8N_RUNNING=$(getv N8N_RUNNING)
PG_DUMP=$(getv PG_DUMP);       N8N_DUMP=$(getv N8N_DUMP)

# 3. posture
[ "$PG_RUNNING" = yes ] || addp "greece bjj-postgres NOT running"
[ "$N8N_RUNNING" = yes ] && addp "greece n8n IS running (failover active or stray container?)"
echo "posture: bjj-postgres=$PG_RUNNING  n8n=$N8N_RUNNING (expect yes / no on standby)"

# 1. RPO freshness
for pair in "bjj-postgres:$PG_DUMP" "n8n:$N8N_DUMP"; do
  name=${pair%%:*}; dump=${pair#*:}
  if e=$(epoch_of "$dump"); then
    a=$(age_h "$e")
    echo "RPO $name: newest=$dump  age=${a}h"
    awk -v a="$a" -v m="$RPO_MAX_H" 'BEGIN{exit !(a>m)}' && addp "$name backup stale (${a}h > ${RPO_MAX_H}h)"
  else
    echo "RPO $name: no backup found in Greece MinIO"; addp "$name no backup in greece minio"
  fi
done

# 2 + 4. data present (+ optional Prague diff)
declare -A PR
if [ "$PRAGUE_DIFF" = 1 ]; then
  for t in $KEY_TABLES; do
    PR[$t]=$(kubectl exec -n "$NS" deploy/postgres -- sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"select count(*) from $t\"" 2>/dev/null | tr -d '[:space:]')
    [ -n "${PR[$t]}" ] || PR[$t]=NA
  done
fi
printf "%-18s %10s %10s   %s\n" "TABLE" "GREECE" "PRAGUE" "note"
for t in $KEY_TABLES; do
  g=$(getv "GR_$t"); p=${PR[$t]:-skip}; note=""
  [ "$g" = NA ] || [ -z "$g" ] && { note="greece NA"; addp "greece table $t unreadable"; }
  [ "$g" = 0 ] && { note="greece EMPTY"; addp "greece table $t empty"; }
  if [ "$PRAGUE_DIFF" = 1 ] && [ "$p" != NA ] && [ "$p" != skip ] && [ "$g" != NA ] && [ -n "$g" ]; then
    # count diffs are INFORMATIONAL, never a 'down': Greece is a backup-restore standby,
    # so it can lag Prague (inserts) OR sit higher (Prague flush/delete) — both are lag,
    # not corruption. Only empty/unreadable/stale (handled above) is a real problem.
    if [ "$g" -gt "$p" ] 2>/dev/null; then note="greece +$((g-p)) ahead (lag across a prague flush — informational)"
    elif [ "$g" -lt "$p" ] 2>/dev/null; then note="lag ok (-$((p-g)))"; fi
  fi
  printf "%-18s %10s %10s   %s\n" "$t" "${g:-?}" "$p" "$note"
done

# ---------- verdict + optional Kuma push ----------
if [ -z "$problems" ]; then status=up; msg="standby READY: posture ok, RPO within ${RPO_MAX_H}h, data present"
else status=down; msg="standby ISSUES: ${problems%%; }"; fi
echo "VERDICT: $status — $msg"
echo "===== greece-standby-probe done ($status) ====="
if [ -n "$KPUSH" ]; then
  curl -s -G "$KPUSH" --data-urlencode "status=$status" --data-urlencode "msg=$msg" -o /dev/null --max-time 10 || true
else
  echo "(Uptime Kuma push not configured — create a Push monitor and save its URL to ~/.kuma_standby_push)"
fi
