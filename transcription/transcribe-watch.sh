#!/usr/bin/env bash
# Watches WATCH_DIR for audio files, transcribes via faster-whisper, writes filename.md.
# Skips files that already have a matching .md. Runs startup scan on launch
# so files dropped while the service was down are not missed.
#
# If LXC_ID and PVE_SSH are set, the LXC is started before the first job and
# stopped after the queue drains — useful for a dedicated sleep-until-needed
# GPU whisper container (LXC 112 on xt-ml).
set -euo pipefail

WATCH_DIR="${WATCH_DIR:-/mnt/dictaphones}"
WHISPER_URL="${WHISPER_URL:-http://192.168.1.225:8000/v1/audio/transcriptions}"
WHISPER_MODEL="${WHISPER_MODEL:-Systran/faster-whisper-large-v3}"
WHISPER_TIMEOUT="${WHISPER_TIMEOUT:-7200}"   # 2h max; GPU processes ~10x realtime
PARAGRAPH_GAP="${PARAGRAPH_GAP:-3}"         # seconds of silence → new paragraph

# Optional: set both to manage LXC lifecycle from this script
PVE_SSH="${PVE_SSH:-}"           # e.g. "root@192.168.1.122"
LXC_ID="${LXC_ID:-}"             # e.g. "112"
WHISPER_HEALTH_URL="${WHISPER_HEALTH_URL:-}"  # e.g. "http://192.168.1.112:8000/health"

LOG_TAG="transcribe-watch"
PENDING=0

log() { logger -t "$LOG_TAG" -- "$*" 2>/dev/null || echo "$(date -Iseconds) $*" >&2; }

is_audio() {
    [[ "${1,,}" =~ \.(mp3|wav|m4a|ogg|flac|opus|webm|aac|wma|mp4)$ ]]
}

is_video() {
    [[ "${1,,}" =~ \.(mkv|avi|mov|ts|wmv|m4v|3gp|mpg|mpeg)$ ]]
}

is_media() {
    is_audio "$1" || is_video "$1"
}

lxc_start() {
    [[ -z "$PVE_SSH" || -z "$LXC_ID" ]] && return 0
    log "starting LXC $LXC_ID on $PVE_SSH"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$PVE_SSH" "pct start $LXC_ID" 2>/dev/null || true
    if [[ -n "$WHISPER_HEALTH_URL" ]]; then
        log "waiting for whisper health at $WHISPER_HEALTH_URL"
        local i=0
        until curl -sf "$WHISPER_HEALTH_URL" >/dev/null 2>&1; do
            (( i++ > 60 )) && { log "ERROR: whisper did not come up after 60s"; return 1; }
            sleep 2
        done
        log "whisper ready"
    fi
}

lxc_stop() {
    [[ -z "$PVE_SSH" || -z "$LXC_ID" ]] && return 0
    log "stopping LXC $LXC_ID (queue empty)"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$PVE_SSH" "pct stop $LXC_ID" 2>/dev/null || true
}

transcribe_file() {
    local filepath="$1"
    local dir base stem md_file tmp_file response

    dir="$(dirname  "$filepath")"
    base="$(basename "$filepath")"
    stem="${base%.*}"
    md_file="$dir/$stem.md"

    [[ -f "$md_file" ]] && { log "skip: $base (transcript exists)"; return 0; }

    if (( PENDING == 0 )); then
        lxc_start
    fi
    (( PENDING++ )) || true

    log "transcribing: $base"

    tmp_file="$(mktemp "$dir/.${stem}.XXXXXX.md")"

    # For video files extract audio first — avoids sending gigabytes over the API
    local upload_file="$filepath"
    local tmp_audio=""
    if is_video "$base"; then
        tmp_audio="$(mktemp /tmp/.audio-XXXXXX.opus)"
        log "extracting audio from video: $base"
        if ! ffmpeg -i "$filepath" -vn -c:a libopus -b:a 48k "$tmp_audio" -y -loglevel error 2>/dev/null; then
            log "ERROR: ffmpeg failed for $base"
            rm -f "$tmp_audio" "$tmp_file"
            (( PENDING-- )) || true
            return 1
        fi
        upload_file="$tmp_audio"
    fi

    local raw_response
    raw_response=$(curl -sf -X POST "$WHISPER_URL" \
        -H "Authorization: Bearer dummy" \
        -F "file=@$upload_file" \
        -F "model=$WHISPER_MODEL" \
        -F "response_format=verbose_json" \
        -F "vad_filter=true" \
        --max-time "$WHISPER_TIMEOUT") || {
        log "ERROR: curl failed (exit $?) for $base"
        rm -f "$tmp_file" "$tmp_audio"
        (( PENDING-- )) || true
        return 1
    }
    rm -f "$tmp_audio"  # audio extract no longer needed

    if [[ -z "$raw_response" ]]; then
        log "ERROR: empty response for $base"
        rm -f "$tmp_file"
        (( PENDING-- )) || true
        return 1
    fi

    # Insert paragraph breaks on silence gaps or speaker changes.
    # If diarization is enabled, prefixes each new speaker block with **SPEAKER_XX**:.
    local response
    response=$(echo "$raw_response" | jq -r --argjson gap "$PARAGRAPH_GAP" '
      .segments as $s |
      reduce range($s | length) as $i ("";
        . as $acc |
        ($s[$i].text | ltrimstr(" ")) as $text |
        ($s[$i].speaker // null) as $spk |
        if $i == 0 then
          if $spk then "**" + $spk + "**: " + $text else $text end
        elif ($s[$i].start - $s[$i-1].end) > $gap then
          $acc + "\n\n" + (if $spk then "**" + $spk + "**: " + $text else $text end)
        elif $spk != null and $spk != ($s[$i-1].speaker // null) then
          $acc + "\n\n" + "**" + $spk + "**: " + $text
        else $acc + $text
        end
      )
    ')

    if [[ -z "$response" ]]; then
        log "ERROR: could not parse segments for $base"
        rm -f "$tmp_file"
        (( PENDING-- )) || true
        return 1
    fi

    { echo "# $stem"; echo; echo "$response"; } > "$tmp_file"
    mv "$tmp_file" "$md_file"
    log "done: $stem.md"
    (( PENDING-- )) || true
}

drain_and_sleep() {
    # Called after inotify processes a batch with no more files queued
    (( PENDING == 0 )) && lxc_stop
}

scan_existing() {
    log "scanning $WATCH_DIR for unprocessed audio"
    while IFS= read -r -d '' f; do
        is_media "$(basename "$f")" && transcribe_file "$f"
    done < <(find "$WATCH_DIR" -type f -print0 | sort -z)
    drain_and_sleep
    log "startup scan complete"
}

log "starting — watching $WATCH_DIR"
scan_existing

inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$WATCH_DIR" \
    | while IFS= read -r filepath; do
        if is_media "$(basename "$filepath")"; then
            transcribe_file "$filepath"
            drain_and_sleep
        fi
      done
