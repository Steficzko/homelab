#!/usr/bin/env bash
# Run on the Debian VM once to install dependencies and register the service.
# Expects the Unraid NFS share to be configured in /etc/fstab first.
set -euo pipefail

UNRAID_IP="192.168.1.100"
UNRAID_SHARE="DictaPhone"
MOUNT_POINT="/mnt/dictaphones"

echo "=== Installing dependencies ==="
apt-get update -qq
apt-get install -y -qq inotify-tools nfs-common curl ffmpeg

echo "=== Creating mount point ==="
mkdir -p "$MOUNT_POINT"

echo "=== Adding NFS mount to /etc/fstab ==="
FSTAB_LINE="${UNRAID_IP}:/mnt/user/${UNRAID_SHARE} ${MOUNT_POINT} nfs defaults,_netdev,soft,timeo=100,retrans=3 0 0"
if ! grep -qF "$MOUNT_POINT" /etc/fstab; then
    echo "$FSTAB_LINE" >> /etc/fstab
    echo "Added: $FSTAB_LINE"
else
    echo "Already in fstab, skipping"
fi

echo "=== Mounting ==="
systemctl daemon-reload
mount "$MOUNT_POINT" || echo "Mount failed — check Unraid NFS exports"

echo "=== Installing script ==="
cp "$(dirname "$0")/transcribe-watch.sh" /usr/local/bin/transcribe-watch.sh
chmod +x /usr/local/bin/transcribe-watch.sh

echo "=== Installing env file ==="
if [[ ! -f /etc/transcribe-watch.env ]]; then
    cp "$(dirname "$0")/env.example" /etc/transcribe-watch.env
    echo "Edit /etc/transcribe-watch.env to set WHISPER_URL"
fi

echo "=== Installing systemd service ==="
cp "$(dirname "$0")/transcribe-watch.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now transcribe-watch.service

echo "=== Done ==="
echo "Status: systemctl status transcribe-watch"
echo "Logs:   journalctl -fu transcribe-watch"
