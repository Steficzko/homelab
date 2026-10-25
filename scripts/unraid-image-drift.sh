#!/usr/bin/env bash
# Monthly drift check for containers Renovate cannot see: Unraid templates and Portainer stacks
# on both NAS boxes. Read-only. Prints every running container, oldest image first, and flags:
#   FLOAT  tag with no digest that moves under you (latest/stable/main/release/edge or none):
#          a recreate does NOT pull, so these silently stay on whatever was pulled last
#          (Home Assistant sat on 2026.10.0 for weeks, Bazarr on a July build, 2026-10-24).
#   OLD    image built more than $MAX_DAYS days ago: look upstream for a release.
# Updating is per container: Unraid template -> docker pull + update_container <name>;
# Portainer stack -> edit the pin in /mnt/user/appdata/portainer/compose/<id>/docker-compose.yml.
#
#   ./scripts/unraid-image-drift.sh            # both hosts
#   MAX_DAYS=30 ./scripts/unraid-image-drift.sh
set -euo pipefail
MAX_DAYS="${MAX_DAYS:-60}"

check() { # $1=label, rest = ssh args
  local label="$1"; shift
  echo "== $label"
  ssh -o ConnectTimeout=8 -o BatchMode=yes "$@" "MAX_DAYS=$MAX_DAYS sh -s" <<'EOF'
now=$(date +%s)
docker ps --format '{{.Names}} {{.Image}}' | while read -r name ref; do
  created=$(docker image inspect "$ref" --format '{{.Created}}' 2>/dev/null | cut -c1-10)
  [ -n "$created" ] || created=$(docker inspect "$name" --format '{{.Image}}' | xargs docker image inspect --format '{{.Created}}' | cut -c1-10)
  age=$(( (now - $(date -d "$created" +%s)) / 86400 ))
  tag=${ref##*/}; tag=${tag#*:}; [ "$tag" = "${ref##*/}" ] && tag=""
  flags=""
  case "$ref" in *@sha256:*) ;; *) case "$tag" in ""|latest|stable|main|release|edge|nightly) flags="FLOAT";; esac;; esac
  [ "$age" -gt "$MAX_DAYS" ] && flags="$flags OLD"
  printf '%5sd  %-34s %-6s %s\n' "$age" "$name" "${flags# }" "$ref"
done | sort -rn
EOF
}

check "Prague Unraid (192.168.1.100)" -i ~/.ssh/id_ed25519_github root@192.168.1.100
check "Greece Unraid (100.85.129.88)" -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@100.85.129.88
