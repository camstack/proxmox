#!/usr/bin/env bash
# Install CamStack into a Proxmox VE LXC (Ubuntu 24.04 + Docker CE + amd image).
# Run on the PVE HOST (needs `pct`), not inside a container.
#
#   ROLE=hub  VMID=200 bash install-camstack-proxmox.sh
#   ROLE=agent VMID=201 CAMSTACK_HUB_ADDRESS=192.168.1.9 \
#     CAMSTACK_NODE_ID=amd-proxmox bash install-camstack-proxmox.sh
#
# Hub and agent on the same machine = two CTs (host networking collides otherwise).
#
# Accelerators present on the host are passed into the CT and enabled in the
# generated compose: /dev/dri, /dev/accel, /dev/apex_* (Coral PCIe/M.2) and a
# Coral USB. PASS_ACCEL=none skips all of it; PASS_KFD=1 adds /dev/kfd (ROCm).
#
# Opt-in, separate host step (never run by an install):
#   bash install-camstack-proxmox.sh --install-coral-pcie-driver
#   (curl … | bash -s -- --install-coral-pcie-driver)
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
# auto = pass every accelerator node the host has; none = pass nothing.
PASS_ACCEL="${PASS_ACCEL:-auto}"
case "$PASS_ACCEL" in
  auto|none) ;;
  *) echo "PASS_ACCEL must be auto or none (got: $PASS_ACCEL)"; exit 1 ;;
esac
# /dev/kfd (AMD ROCm compute) only on request: the image has no ROCm runtime.
PASS_KFD="${PASS_KFD:-0}"
INSTALL_CORAL_PCIE_DRIVER=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --install-coral-pcie-driver) INSTALL_CORAL_PCIE_DRIVER=1 ;;
  esac
done

# Opt-in host step: build the Coral PCIe/M.2 driver (gasket + apex) through
# DKMS from the maintained fork. Never called by an install; it never reboots.
install_coral_pcie_driver() {
  local kver suite src=/usr/src/gasket-1.0
  kver=$(uname -r)
  # shellcheck disable=SC1091
  suite=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
  if [ -z "$suite" ]; then
    echo "Cannot read VERSION_CODENAME from /etc/os-release."
    exit 1
  fi
  echo "=== Coral PCIe/M.2 host driver (gasket-dkms, kernel $kver, $suite) ==="
  apt-get update -qq
  if ! apt-cache policy "proxmox-headers-$kver" | grep -q 'Candidate: [0-9]'; then
    echo "proxmox-headers-$kver not available; adding the pve-no-subscription repository ($suite)."
    echo "deb http://download.proxmox.com/debian/pve $suite pve-no-subscription" \
      > /etc/apt/sources.list.d/pve-no-subscription.list
    apt-get update -qq
  fi
  apt-get install -y --no-install-recommends "proxmox-headers-$kver" dkms git build-essential
  if [ ! -d "$src/.git" ]; then
    git clone https://github.com/feranick/gasket-driver.git "$src"
  fi
  cp "$src/debian/gasket-dkms.dkms" "$src/dkms.conf"
  sed -i 's/^PACKAGE_VERSION=.*/PACKAGE_VERSION=1.0/' "$src/dkms.conf"
  dkms status -m gasket -v 1.0 | grep -q . || dkms add -m gasket -v 1.0
  dkms build -m gasket -v 1.0 -k "$kver"
  dkms install -m gasket -v 1.0 -k "$kver" --force
  groupadd -f apex
  echo 'SUBSYSTEM=="apex", MODE="0660", GROUP="apex"' > /etc/udev/rules.d/65-apex.rules
  echo ""
  if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
    echo "Secure Boot is ON: enrol the DKMS key before rebooting, or the module will not load:"
    echo "  mokutil --import /var/lib/dkms/mok.pub   # set a one-time password, accept it in the MOK screen"
  fi
  echo "Driver installed. REBOOT the host to load it on a clean boot (not done for you), then:"
  echo "  ls -l /dev/apex_*    # expect crw-rw---- root apex"
  echo "A new install passes /dev/apex_* into the CT on its own. For an existing CT:"
  echo "  pct set <ct> -devN /dev/apex_0,gid=993,mode=0660   # one per unit, then pct reboot <ct>"
  echo "  and uncomment the matching /dev/apex_N line in /opt/camstack/docker-compose.yml."
}

if [ -n "$INSTALL_CORAL_PCIE_DRIVER" ]; then
  install_coral_pcie_driver
  exit 0
fi

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

# Compose markers (#@name) to uncomment for the devices actually passed.
ENABLED_MARKERS=()
# /dev/apex_N past the two units the compose template lists.
APEX_EXTRA=()
enable_marker() {
  local m
  for m in ${ENABLED_MARKERS[@]+"${ENABLED_MARKERS[@]}"}; do [ "$m" = "$1" ] && return 0; done
  ENABLED_MARKERS+=("$1")
}

# A Coral USB enumerates as 1a6e:089a before its firmware loads, 18d1:9302 after.
coral_usb_present() {
  local d ids
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ] || continue
    ids="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
    case "$ids" in
      1a6e:089a|18d1:9302) return 0 ;;
    esac
  done
  return 1
}

# gid = the group INSIDE the CT that owns the node; the image entrypoint then
# chowns it to `camstack` in the Docker container.
pass_dev() {
  local path=$1 mode=$2 marker=$3
  [ -e "$path" ] || return 0
  local gid
  if [[ "$path" == /dev/dri/card* ]]; then
    gid=$(pct exec "$VMID" -- getent group video | cut -d: -f3 || true)
    gid=${gid:-44}
  else
    gid=$(pct exec "$VMID" -- getent group render | cut -d: -f3 || true)
    gid=${gid:-993}
  fi
  if pct config "$VMID" | grep -qE "^dev[0-9]+: ${path}(,|$)"; then
    enable_marker "$marker"
    return 0
  fi
  # Find next free devN
  local n=0
  while pct config "$VMID" | grep -q "^dev${n}:"; do n=$((n + 1)); done
  pct set "$VMID" -dev"${n}" "${path},gid=${gid},mode=${mode}"
  echo "  dev${n} → $path (gid=$gid)"
  enable_marker "$marker"
}

if [ "$PASS_ACCEL" = "auto" ]; then
  echo "Passing through accelerator devices found on the host…"
  for node in /dev/dri/renderD* /dev/dri/card*; do
    pass_dev "$node" 0660 dri
  done
  for node in /dev/accel/accel*; do
    pass_dev "$node" 0660 accel
  done
  if [ "$PASS_KFD" = "1" ]; then
    pass_dev /dev/kfd 0660 kfd
  fi
  for node in /dev/apex_*; do
    [ -e "$node" ] || continue
    unit=${node#/dev/apex_}
    pass_dev "$node" 0660 "apex_${unit}"
    case "$unit" in
      0|1) ;;
      *) APEX_EXTRA+=("$node") ;;
    esac
  done
  if lspci -n 2>/dev/null | grep -q ' 1ac1:089a' && ! compgen -G '/dev/apex_*' >/dev/null; then
    echo "  Coral PCIe/M.2 card found but no /dev/apex_* node: the host driver is missing."
    echo "  Install it on this host (opt-in), then reboot and re-run the install:"
    echo "    curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/install-camstack-proxmox.sh \\"
    echo "      | bash -s -- --install-coral-pcie-driver"
  fi
  if coral_usb_present; then
    # The USB bus, not one node: the stick re-enumerates after firmware load.
    conf="/etc/pve/lxc/${VMID}.conf"
    grep -q '^lxc.cgroup2.devices.allow: c 189:\* rwm' "$conf" \
      || echo 'lxc.cgroup2.devices.allow: c 189:* rwm' >> "$conf"
    grep -q '^lxc.mount.entry: /dev/bus/usb ' "$conf" \
      || echo 'lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir' >> "$conf"
    echo "  Coral USB → /dev/bus/usb (cgroup c 189:* rwm + bind mount)"
    enable_marker usb
    # In an unprivileged CT the USB nodes stay host-root owned (nobody:nogroup
    # inside), so the Coral must be world-writable on the HOST — both ids,
    # because the stick re-enumerates as 18d1:9302 on its first invoke.
    if [ ! -f /etc/udev/rules.d/65-coral-usb.rules ]; then
      cat > /etc/udev/rules.d/65-coral-usb.rules <<'RULES'
# Coral USB Edge TPU: before (1a6e:089a) and after (18d1:9302) the firmware load.
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1a6e", ATTRS{idProduct}=="089a", MODE="0666"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="18d1", ATTRS{idProduct}=="9302", MODE="0666"
RULES
      udevadm control --reload-rules
      udevadm trigger --subsystem-match=usb
      echo "  Coral USB → host udev rule /etc/udev/rules.d/65-coral-usb.rules (0666)"
    fi
  fi
  if [ -e /dev/nvidia0 ]; then
    echo "  NVIDIA GPU found: not passed automatically (needs the driver in the CT and the"
    echo "  NVIDIA Container Toolkit); see 'gpus: all' in /opt/camstack/docker-compose.yml."
  fi
fi

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
# EVERY dir the compose binds must be writable by uid 1001, recordings too: a
# fresh dev hub (2026-10-23) got /recordings root:root 0755 and EACCES on
# /recordings/artifacts. An mp0 host bind mounted here is chowned host-side
# below (its uid is remapped); a rootfs dir is chowned here.
if mountpoint -q /opt/camstack/recordings; then
  echo "/opt/camstack/recordings is a host bind — ownership set on the host"
else
  chown -R 1001:1001 /opt/camstack/recordings
fi
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
# Uncomment the device lines for what was passed into the CT; the rest stay
# commented for the operator to enable later.
if [ "${#ENABLED_MARKERS[@]}" -gt 0 ]; then
  for marker in devices "${ENABLED_MARKERS[@]}"; do
    sed -i -E "s|^( *)# (.*#@${marker})$|\\1\\2|" "$COMPOSE_TMP"
  done
fi
for node in ${APEX_EXTRA[@]+"${APEX_EXTRA[@]}"}; do
  # Units past the two template lines: add them under the last apex entry.
  awk -v line="      - ${node}:${node}" '{ print } /#@apex_1$/ { print line }' \
    "$COMPOSE_TMP" > "${COMPOSE_TMP}.new" && mv "${COMPOSE_TMP}.new" "$COMPOSE_TMP"
done
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
  echo "Pair this agent from the hub (there is no cluster secret to enter):"
  echo "  - hub admin UI: Cluster -> Nodes -> Agents found on the network -> Pair (or Add by address: ${CT_IP:-<ct-ip>}, port 4444)"
  echo "  - confirm the same six-digit code on the hub and on the agent page http://${CT_IP:-<ct-ip>}:4444"
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
