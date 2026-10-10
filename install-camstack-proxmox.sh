#!/usr/bin/env bash
# Install CamStack into a Proxmox VE LXC (Ubuntu 24.04 + Docker CE + amd image).
# Run on the PVE HOST (needs `pct`), not inside a container.
#
#   ROLE=hub  VMID=200 bash install-camstack-proxmox.sh
#   ROLE=agent VMID=201 CAMSTACK_HUB_ADDRESS=192.168.1.9 \
#     CAMSTACK_NODE_ID=amd-proxmox bash install-camstack-proxmox.sh
#
# Hub and agent on the same machine = two CTs (host networking collides otherwise).
set -euo pipefail

PCT=$(command -v pct || true)
if [ -z "$PCT" ]; then
  echo "pct not found. Run this on the Proxmox host."
  echo "Docs: https://camstack.io/docs/installation/proxmox"
  exit 1
fi

ROLE="${ROLE:-hub}"
case "$ROLE" in
  hub|agent) ;;
  *) echo "ROLE must be hub or agent (got: $ROLE)"; exit 1 ;;
esac

if [ "$ROLE" = "hub" ]; then
  VMID="${VMID:-200}"
  HOSTNAME="${HOSTNAME_CT:-camstack}"
  COMPOSE_NAME="hub.yml"
else
  VMID="${VMID:-201}"
  HOSTNAME="${HOSTNAME_CT:-camstack-agent}"
  COMPOSE_NAME="agent.yml"
fi

CORES="${CORES:-8}"
MEMORY_MB="${MEMORY_MB:-8192}"
SWAP_MB="${SWAP_MB:-2048}"
DISK_GB="${DISK_GB:-64}"
BRIDGE="${BRIDGE:-vmbr0}"
IMAGE_TAG="${IMAGE_TAG:-ghcr.io/camstack/camstack:amd-latest}"
# Optional: host directory for recordings, bound at /opt/camstack/recordings
# in the CT (same path Docker maps to CAMSTACK_MEDIA_ROOT). Prefer attaching
# a real HD later with setup-camstack-recordings-volume.sh if unknown now.
RECORDINGS_HOST_PATH="${RECORDINGS_HOST_PATH:-}"
FORCE="${FORCE:-}"
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMPOSE_SRC="$SCRIPT_DIR/compose/$COMPOSE_NAME"
if [ ! -f "$COMPOSE_SRC" ]; then
  # curl|bash: compose files sit next to this script on the same raw GitHub tree
  RAW_BASE="${CAMSTACK_PROXMOX_RAW:-https://raw.githubusercontent.com/camstack/proxmox/main}"
  mkdir -p /tmp/camstack-proxmox-compose
  curl -fsSL "$RAW_BASE/compose/$COMPOSE_NAME" -o "/tmp/camstack-proxmox-compose/$COMPOSE_NAME"
  COMPOSE_SRC="/tmp/camstack-proxmox-compose/$COMPOSE_NAME"
fi

echo "=== CamStack Proxmox install ==="
echo "ROLE=$ROLE VMID=$VMID hostname=$HOSTNAME image=$IMAGE_TAG"

if pct config "$VMID" >/dev/null 2>&1; then
  if [ -z "$FORCE" ]; then
    echo "CT $VMID already exists. Re-run with --force to destroy and recreate (WIPES the CT)."
    echo "  ROLE=$ROLE VMID=$VMID bash $0 --force"
    exit 1
  fi
  echo "Destroying existing CT $VMID (--force)…"
  pct stop "$VMID" >/dev/null 2>&1 || true
  pct destroy "$VMID"
fi

# Storage
STORAGE="${STORAGE:-}"
if [ -z "$STORAGE" ]; then
  if pvesm status | grep -qE '^local-lvm\s+.*active'; then
    STORAGE=local-lvm
  elif pvesm status | grep -qE '^local-zfs\s+.*active'; then
    STORAGE=local-zfs
  else
    echo "Could not pick storage (local-lvm / local-zfs). Set STORAGE=…"
    exit 1
  fi
fi

echo "Updating appliance templates…"
pveam update >/dev/null
TEMPLATE=$(pveam available | awk '/ubuntu-24\.04-standard.*amd64/ {print $2}' | tail -1)
if [ -z "$TEMPLATE" ]; then
  echo "No ubuntu-24.04-standard amd64 template in pveam available."
  exit 1
fi
if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
  echo "Downloading $TEMPLATE…"
  pveam download local "$TEMPLATE"
fi

CREATE_ARGS=(
  --hostname "$HOSTNAME"
  --unprivileged 1
  --features nesting=1,keyctl=1
  --cores "$CORES"
  --memory "$MEMORY_MB"
  --swap "$SWAP_MB"
  --rootfs "${STORAGE}:${DISK_GB}"
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
  --onboot 1
  --ostype ubuntu
)
if [ -n "$RECORDINGS_HOST_PATH" ]; then
  mkdir -p "$RECORDINGS_HOST_PATH"
  # Ownership fixed after create (idmap known); mount path matches compose.
  CREATE_ARGS+=(--mp0 "${RECORDINGS_HOST_PATH},mp=/opt/camstack/recordings")
  echo "Recordings host path: $RECORDINGS_HOST_PATH → /opt/camstack/recordings"
fi

echo "Creating CT $VMID on $STORAGE…"
pct create "$VMID" "local:vztmpl/$TEMPLATE" "${CREATE_ARGS[@]}"

pct start "$VMID"
# Wait for network
for i in $(seq 1 30); do
  if pct exec "$VMID" -- bash -c 'getent hosts archive.ubuntu.com >/dev/null 2>&1'; then
    break
  fi
  sleep 2
done

echo "Passing through DRM / accel devices…"
pass_dev() {
  local path=$1 mode=$2
  [ -e "$path" ] || return 0
  local gid
  if [[ "$path" == *render* ]] || [[ "$path" == *accel* ]]; then
    gid=$(pct exec "$VMID" -- getent group render | cut -d: -f3 || echo 993)
  else
    gid=$(pct exec "$VMID" -- getent group video | cut -d: -f3 || echo 44)
  fi
  # Find next free devN
  local n=0
  while pct config "$VMID" | grep -q "^dev${n}:"; do n=$((n + 1)); done
  pct set "$VMID" -dev"${n}" "${path},gid=${gid},mode=${mode}"
  echo "  dev${n} → $path (gid=$gid)"
}
pass_dev /dev/dri/renderD128 0660
for card in /dev/dri/card*; do
  pass_dev "$card" 0660
done
pass_dev /dev/accel/accel0 0660

# XDNA userspace (xrt-smi / VitisAI) mmaps large locked regions; the LXC
# default memlock (8 MiB) makes examine fail with EAGAIN. Unlimited is the
# documented Ryzen AI Linux requirement.
if ! grep -q '^lxc.prlimit.memlock:' "/etc/pve/lxc/${VMID}.conf"; then
  echo 'lxc.prlimit.memlock: unlimited' >> "/etc/pve/lxc/${VMID}.conf"
  echo "  lxc.prlimit.memlock → unlimited"
fi

pct reboot "$VMID"
sleep 5
for i in $(seq 1 30); do
  if pct status "$VMID" | grep -q running; then
    pct exec "$VMID" -- true 2>/dev/null && break
  fi
  sleep 2
done

echo "Installing Docker CE + Mesa userspace tools in CT…"
pct exec "$VMID" -- bash -s <<'INNER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl vainfo mesa-va-drivers mesa-vulkan-drivers
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
mkdir -p /opt/camstack/{data,config,backups,recordings}
# The image entrypoint does `mkdir -p /data/addons/@camstack` as root and only
# non-recursively chowns `/data/addons`. That left `@camstack` root-owned so
# the camstack user could not seed AGENT_PACKAGES (empty pipeline on a fresh
# AMD agent, 2026-10-10). Pre-create the scope as uid 1001 (image `camstack`)
# so first boot can write even before the image entrypoint fix ships.
mkdir -p /opt/camstack/data/addons/@camstack
chown -R 1001:1001 /opt/camstack/data /opt/camstack/config /opt/camstack/backups
INNER

# Align host-side ownership for an mp0 recordings bind (uid 1001 → 100000+1001).
if [ -n "$RECORDINGS_HOST_PATH" ]; then
  HOST_UID=$((100000 + 1001))
  if [ -f "/etc/pve/lxc/${VMID}.conf" ]; then
    line=$(grep -E '^lxc\.idmap:\s*u\s+' "/etc/pve/lxc/${VMID}.conf" | head -1 || true)
    if [ -n "$line" ]; then
      map_from=$(echo "$line" | awk '{print $3}')
      map_host=$(echo "$line" | awk '{print $4}')
      HOST_UID=$((map_host + 1001 - map_from))
    fi
  fi
  mkdir -p "$RECORDINGS_HOST_PATH/.camstack-media"
  chown -R "$HOST_UID:$HOST_UID" "$RECORDINGS_HOST_PATH"
  chmod 0750 "$RECORDINGS_HOST_PATH"
  echo "Recordings host dir owned by uid $HOST_UID (CT camstack)"
fi

# Compose file into the CT
COMPOSE_TMP=$(mktemp)
sed "s|ghcr.io/camstack/camstack:amd-latest|${IMAGE_TAG}|g" "$COMPOSE_SRC" > "$COMPOSE_TMP"
# Inject agent env defaults into a .env next to compose
ENV_TMP=$(mktemp)
{
  echo "CAMSTACK_HUB_ADDRESS=${CAMSTACK_HUB_ADDRESS:-}"
  echo "CAMSTACK_HUB_URL=${CAMSTACK_HUB_URL:-}"
  echo "CAMSTACK_NODE_ID=${CAMSTACK_NODE_ID:-$HOSTNAME}"
  echo "CAMSTACK_AGENT_NAME=${CAMSTACK_AGENT_NAME:-}"
} > "$ENV_TMP"
pct push "$VMID" "$COMPOSE_TMP" /opt/camstack/docker-compose.yml
pct push "$VMID" "$ENV_TMP" /opt/camstack/.env
rm -f "$COMPOSE_TMP" "$ENV_TMP"

echo "Pulling image and starting CamStack…"
pct exec "$VMID" -- bash -c 'cd /opt/camstack && docker compose --env-file .env pull && docker compose --env-file .env up -d'

CT_IP=$(pct exec "$VMID" -- bash -c "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" | head -1 || true)
echo ""
echo "=== Done ==="
echo "CT $VMID ($HOSTNAME) ROLE=$ROLE IP=${CT_IP:-unknown}"
if [ "$ROLE" = "hub" ]; then
  echo "Admin UI: https://${CT_IP:-<ct-ip>}:4443  (first login admin / changeme)"
else
  echo "Agent status: http://${CT_IP:-<ct-ip>}:4444"
  if [ -z "${CAMSTACK_HUB_ADDRESS:-}" ] && [ -z "${CAMSTACK_HUB_URL:-}" ]; then
    echo "No CAMSTACK_HUB_ADDRESS set — configure the hub from the agent dashboard."
  fi
fi
echo "Enter CT: pct enter $VMID"
echo "Logs:     pct exec $VMID -- docker compose -f /opt/camstack/docker-compose.yml logs -f"
if [ -z "$RECORDINGS_HOST_PATH" ]; then
  echo ""
  echo "Recordings are on the CT rootfs (/opt/camstack/recordings) — fine for smoke tests."
  echo "When you attach a real HD, bind it with (on this PVE host):"
  echo "  curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/setup-camstack-recordings-volume.sh \\"
  echo "    | VMID=$VMID bash -s -- /mnt/<your-hd>/camstack-$ROLE"
  echo "  # or:  … bash -s -- --storage <pve-directory-storage-id>"
fi
