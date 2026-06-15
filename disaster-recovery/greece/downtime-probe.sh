#!/usr/bin/env bash
# downtime-probe.sh — measure USER-FACING availability of the public endpoints
# CONTINUOUSLY across a DR cutover. Start it, run failover.sh -> failback.sh, then stop
# it (Ctrl-C / SIGTERM, or set DURATION). It prints, per host, the worst-case run of
# consecutive failed samples (= worst-case downtime a user would have seen) and a code
# breakdown, and optionally pushes a summary to Uptime Kuma.
#
#   ./downtime-probe.sh                  # probe defaults every 1s until stopped (Ctrl-C)
#   INTERVAL=0.5 ./downtime-probe.sh     # tighter sampling
#   DURATION=900 ./downtime-probe.sh     # auto-stop after 15 min (for an unattended drill)
#   TARGETS="https://app.teamelwany.com https://auto.kostikidis.net" ./downtime-probe.sh
#
# CLOUDFLARE ACCESS CAVEAT: both hosts sit behind Access (anon curl -> 302, the origin is
# NEVER contacted). Two modes, chosen automatically:
#   * AUTHENTICATED — if ~/.cf_access_app_token exists (line1=CLIENT_ID, line2=CLIENT_SECRET)
#     AND an Access policy allows that service token, requests pass through to the origin,
#     so 200=up / 5xx|52x|530|000=DOWN measures the REAL user path.
#   * EDGE (default, no token) — every sample is a 302 from Access; the probe reports edge
#     reachability and flags samples as GATED. It CANNOT see Prague/Greece origin health,
#     so it will NOT produce a trustworthy cutover-downtime number. You are warned loudly.
set -uo pipefail   # deliberately NO -e: a failed curl is a measurement, not a fatal error

INTERVAL="${INTERVAL:-1}"
DURATION="${DURATION:-0}"                 # 0 = run until SIGINT/SIGTERM
# Probe the documented health endpoints, NOT bare roots. Per ADR-026 the BJJ app's
# health signal is app.teamelwany.com/api/health (a root 502 is the documented nginx-proxy
# failure mode, not "the app"). auto.kostikidis.net (n8n) sits behind Cloudflare Access.
TARGETS="${TARGETS:-https://app.teamelwany.com/api/health https://auto.kostikidis.net}"
LOG="${LOG:-$HOME/downtime-probe.log}"
KPUSH="${KUMA_PROBE_PUSH:-}"              # optional, separate from the drill's own monitor

ACC_ID=""; ACC_SECRET=""; MODE="EDGE"
if [ -f "$HOME/.cf_access_app_token" ]; then
  ACC_ID="$(sed -n '1p' "$HOME/.cf_access_app_token")"
  ACC_SECRET="$(sed -n '2p' "$HOME/.cf_access_app_token")"
  [ -n "$ACC_ID" ] && [ -n "$ACC_SECRET" ] && MODE="AUTH"
fi
HDR=(); [ "$MODE" = AUTH ] && HDR=(-H "CF-Access-Client-Id: $ACC_ID" -H "CF-Access-Client-Secret: $ACC_SECRET")

log(){ echo "$*" | tee -a "$LOG"; }
log "===== downtime-probe $(date '+%F %T %Z') ====="
log "mode=$MODE  interval=${INTERVAL}s  duration=$([ "$DURATION" = 0 ] && echo until-stopped || echo ${DURATION}s)"
log "targets: $TARGETS"
[ "$MODE" = EDGE ] && log "WARN: no ~/.cf_access_app_token -> 302 (Access login) is logged as GATED. EDGE mode does NOT measure real origin downtime."

declare -A total ok gated down cur max
start=$(date +%s); stop=0
trap 'stop=1' INT TERM

while [ "$stop" = 0 ]; do
  ts=$(date '+%F %T')
  for url in $TARGETS; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HDR[@]}" "$url" 2>/dev/null); : "${code:=000}"
    total[$url]=$(( ${total[$url]:-0} + 1 ))
    case "$code" in
      200|204|206|301) state=OK;    ok[$url]=$(( ${ok[$url]:-0} + 1 )); cur[$url]=0 ;;
      302)             if [ "$MODE" = AUTH ]; then state=DOWN; down[$url]=$(( ${down[$url]:-0} + 1 )); cur[$url]=$(( ${cur[$url]:-0} + 1 ))
                       else state=GATED; gated[$url]=$(( ${gated[$url]:-0} + 1 )); cur[$url]=0; fi ;;
      *)               state=DOWN;  down[$url]=$(( ${down[$url]:-0} + 1 )); cur[$url]=$(( ${cur[$url]:-0} + 1 )) ;;
    esac
    [ "${cur[$url]:-0}" -gt "${max[$url]:-0}" ] && max[$url]=${cur[$url]}
    echo "$ts  $url  $code  $state" >>"$LOG"
  done
  [ "$DURATION" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$DURATION" ] && break
  sleep "$INTERVAL"
done

elapsed=$(( $(date +%s) - start ))
log "----- summary after ${elapsed}s -----"
worst=0; sumline=""
for url in $TARGETS; do
  t=${total[$url]:-0}; o=${ok[$url]:-0}; g=${gated[$url]:-0}; d=${down[$url]:-0}; m=${max[$url]:-0}
  secs=$(awk -v m="$m" -v i="$INTERVAL" 'BEGIN{printf "%.1f", m*i}')
  log "$url : samples=$t ok=$o gated=$g down=$d | worst consecutive down = $m samples (~${secs}s)"
  awk -v s="$secs" -v w="$worst" 'BEGIN{exit !(s>w)}' && worst=$secs
  sumline+="$(echo "$url" | sed 's#https\?://##') down~${secs}s; "
done
[ "$MODE" = EDGE ] && log "NOTE: EDGE mode — 'gated' samples were never tested against the origin; the downtime numbers above only reflect edge/Access errors, not Prague/Greece failover."
log "===== downtime-probe done (worst ~${worst}s) ====="

if [ -n "$KPUSH" ]; then
  st=$(awk -v w="$worst" 'BEGIN{print (w>0)?"down":"up"}')
  curl -s -G "$KPUSH" --data-urlencode "status=$st" --data-urlencode "msg=$sumline mode=$MODE" -o /dev/null --max-time 10 || true
fi
