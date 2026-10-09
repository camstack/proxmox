#!/usr/bin/env bash
# Bind a host disk directory into a CamStack LXC at /opt/camstack/recordings
# (the path Docker already maps to CAMSTACK_MEDIA_ROOT=/recordings).
#
# Run on the PVE HOST after install-camstack-proxmox.sh — when a real HD is
# attached, or immediately if the path already exists.
#
# Usage:
#   # Explicit host directory (recommended once the disk is mounted on the host)
#   VMID=200 bash setup-camstack-recordings-volume.sh /mnt/recordings-hd/camstack-hub
#
#   # Proxmox "Directory" storage id (creates …/mounts/camstack-<role> under it)
#   VMID=200 bash setup-camstack-recordings-volume.sh --storage bulk-hdd
#
#   # Second CT on the same disk — use a DIFFERENT subdirectory
#   VMID=201 bash setup-camstack-recordings-volume.sh /mnt/recordings-hd/camstack-agent
#
# Why this exists (and GPU/NPU scripts do not): recordings are a filesystem
# bind. Unprivileged LXCs remap uid 1001 (camstack in the image) to
# 100000+1001 on the host; without chown/ACL the container cannot write.
# /dev/dri and /dev/accel use pct -devN,gid=… instead — no bind script.
set -euo pipefail

PCT=$(command -v pct || true)
if [ -z "$PCT" ]; then
  echo "pct not found. Run this on the Proxmox host."
  exit 1
fi

VMID="${VMID:-200}"
CT_MP="${CT_MP:-/opt/camstack/recordings}"
CONTAINER_UID="${CONTAINER_UID:-1001}"   # camstack user in the image
MP_SLOT="${MP_SLOT:-}"                   # empty = first free mpN, or replace if already CT_MP

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit 1
}

HOST_DIR=""
STORAGE_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --storage)
      STORAGE_ID="${2:-}"
      [ -n "$STORAGE_ID" ] || usage
      shift 2
      ;;
    --storage=*)
      STORAGE_ID="${1#--storage=}"
      shift
      ;;
    -*)
      echo "Unknown flag: $1"
      usage
      ;;
    *)
      HOST_DIR="$1"
      shift
      ;;
  esac
done

if [ -n "$STORAGE_ID" ] && [ -n "$HOST_DIR" ]; then
  echo "Pass either a host path or --storage, not both."
  exit 1
fi

if [ -n "$STORAGE_ID" ]; then
  BASE="/mnt/pve/$STORAGE_ID"
  if [ ! -d "$BASE" ]; then
    echo "Error: $BASE not found."
    echo "Create a Proxmox Directory storage named '$STORAGE_ID' in the UI first"
    echo "(Datacenter → Storage → Add → Directory), or pass an absolute host path."
    exit 1
  fi
  # Keep PVE's own backup/iso trees alone — use a mounts/ subtree.
  ROLE_SUFFIX=$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; exit}' || echo "$VMID")
  HOST_DIR="$BASE/mounts/camstack-${ROLE_SUFFIX}"
fi

if [ -z "$HOST_DIR" ]; then
  usage
fi

if [ ! -d "$HOST_DIR" ]; then
  echo "Creating $HOST_DIR"
  mkdir -p "$HOST_DIR"
fi

# Resolve host uid/gid for container uid 1001 under the unprivileged idmap.
# Default PVE map: u 0 100000 65536 → host_uid = 100000 + container_uid.
host_uid_for_ct_uid() {
  local ct_uid=$1
  local conf="/etc/pve/lxc/${VMID}.conf"
  local line map_from map_host map_count
  if [ -f "$conf" ]; then
    line=$(grep -E '^lxc\.idmap:\s*u\s+' "$conf" | head -1 || true)
    if [ -n "$line" ]; then
      # lxc.idmap: u <ct> <host> <count>
      map_from=$(echo "$line" | awk '{print $3}')
      map_host=$(echo "$line" | awk '{print $4}')
      map_count=$(echo "$line" | awk '{print $5}')
      if [ "$ct_uid" -ge "$map_from" ] && [ "$ct_uid" -lt $((map_from + map_count)) ]; then
        echo $((map_host + ct_uid - map_from))
        return
      fi
    fi
  fi
  # Unprivileged default when no explicit idmap line is written yet
  echo $((100000 + ct_uid))
}

if ! pct config "$VMID" >/dev/null 2>&1; then
  echo "CT $VMID not found. Install CamStack first (install-camstack-proxmox.sh)."
  exit 1
fi

HOST_UID=$(host_uid_for_ct_uid "$CONTAINER_UID")
HOST_GID=$HOST_UID
echo "CT $VMID: container uid $CONTAINER_UID → host uid $HOST_UID"
echo "Host path: $HOST_DIR"
echo "CT mount:  $CT_MP"

mkdir -p "$HOST_DIR"
# Marker so operators can see the volume was prepared for CamStack
mkdir -p "$HOST_DIR/.camstack-media"
chown -R "$HOST_UID:$HOST_GID" "$HOST_DIR"
chmod 0750 "$HOST_DIR"
# Writable by the mapped user only (not world-writable).

# If the CT already has files under CT_MP on the rootfs, the bind will hide them.
EXISTING=$(pct exec "$VMID" -- bash -c "if [ -d '$CT_MP' ]; then find '$CT_MP' -mindepth 1 -maxdepth 2 2>/dev/null | head -5; fi" || true)
if [ -n "$EXISTING" ]; then
  echo ""
  echo "WARNING: $CT_MP inside CT $VMID is not empty. After the bind mount those"
  echo "files remain on the CT rootfs but are hidden. Move/backup first if needed:"
  echo "  pct enter $VMID"
  echo "  # mv $CT_MP /opt/camstack/recordings.rootfs-bak"
  echo ""
fi

echo "Stopping CamStack container (if running)…"
pct exec "$VMID" -- bash -c 'cd /opt/camstack 2>/dev/null && docker compose --env-file .env stop 2>/dev/null || true' || true

echo "Stopping CT $VMID…"
pct stop "$VMID" >/dev/null

CONF="/etc/pve/lxc/${VMID}.conf"
# Drop any existing mpN that already targets CT_MP
if [ -f "$CONF" ]; then
  # mpN: /host,mp=/opt/camstack/recordings,…
  existing_slots=$(grep -E "^mp[0-9]+:" "$CONF" | grep -F "mp=$CT_MP" | sed -E 's/^mp([0-9]+):.*/\1/' || true)
  for s in $existing_slots; do
    echo "Removing previous mp${s} → $CT_MP"
    pct set "$VMID" --delete "mp${s}" || true
  done
fi

if [ -z "$MP_SLOT" ]; then
  n=0
  while pct config "$VMID" | grep -q "^mp${n}:"; do n=$((n + 1)); done
  MP_SLOT=$n
fi

echo "Adding mp${MP_SLOT}: $HOST_DIR → $CT_MP"
pct set "$VMID" -mp"${MP_SLOT}" "${HOST_DIR},mp=${CT_MP}"

echo "Starting CT $VMID…"
pct start "$VMID"
for i in $(seq 1 30); do
  pct exec "$VMID" -- true 2>/dev/null && break
  sleep 2
done

# Ensure mount visible and writable as camstack (via docker user namespace = CT rootfs uid)
pct exec "$VMID" -- bash -c "
  set -e
  mountpoint -q '$CT_MP' || { echo 'ERROR: $CT_MP is not a mountpoint inside the CT'; findmnt '$CT_MP' || true; exit 1; }
  # CT root can write; verify the mapped ownership looks right
  touch '$CT_MP/.camstack-write-test' && rm -f '$CT_MP/.camstack-write-test'
  df -h '$CT_MP'
"

echo "Starting CamStack…"
pct exec "$VMID" -- bash -c 'cd /opt/camstack && docker compose --env-file .env up -d'

echo ""
echo "=== Recordings volume attached ==="
echo "Host: $HOST_DIR  (owner ${HOST_UID}:${HOST_GID})"
echo "CT:   $CT_MP  →  container /recordings (CAMSTACK_MEDIA_ROOT)"
echo ""
echo "In the CamStack admin UI, point the Recordings storage location at"
echo "/recordings (default when CAMSTACK_MEDIA_ROOT=/recordings)."
echo ""
echo "Hub + agent on one host: repeat with a second subdirectory for VMID=201."
echo "Do not share one directory between two CTs."
