# CamStack on Proxmox VE

Public install scripts for running CamStack in an **unprivileged LXC** on
Proxmox VE (Ubuntu 24.04 + Docker CE), using the **AMD** image variant
(`ghcr.io/camstack/camstack:amd-latest`).

Unraid templates live separately in
[camstack/unraid-templates](https://github.com/camstack/unraid-templates).

## One image, two roles

`CAMSTACK_ROLE=hub|agent` selects the role. Hub and agent on the **same**
Proxmox host need **two containers** (host networking would collide on
4443/4444/6443).

## Network and ports

Both compose files use `network_mode: host` inside the CT, and the CT sits on
the bridge you choose (`BRIDGE`), so it has its own LAN address.

| Port | Role | Purpose |
| --- | --- | --- |
| `4443/tcp` | hub | Admin UI and API over HTTPS |
| `4444/tcp` | agent | Status dashboard |
| `6443/tcp` | hub and agent | Mutual-TLS cluster mesh (hub accepts agents, agent accepts the hub) |
| `8554/tcp` | hub and agent | RTSP restream |
| `5353/udp` | hub | mDNS announcement of the hub (multicast) |

The clear mesh port `6000` and the UDP discovery port `4445` are retired; close
them in any firewall. Do not forward `6443` to the internet. mDNS needs the CT
on a bridge that shares a LAN with your clients; without it the hub is simply
not announced and you reach it by address.

## Install (on the PVE host)

```bash
# Hub (default VMID 200)
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/install-camstack-proxmox.sh \
  | bash

# Agent joining an existing hub (default VMID 201)
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/install-camstack-proxmox.sh \
  | ROLE=agent CAMSTACK_HUB_ADDRESS=192.168.1.9 CAMSTACK_NODE_ID=my-amd-box bash
```

An agent is not given a secret: pair it from the hub (Cluster → Nodes → Agents found on the network, or Add by address with the CT IP on port 4444) and confirm the same six-digit code on the hub and on the agent page (`http://<ct-ip>:4444`).

Or clone this repo and run `./install-camstack-proxmox.sh` (loads `compose/`
from disk).

### Useful env vars

| Variable | Default | Meaning |
| --- | --- | --- |
| `ROLE` | `hub` | `hub` or `agent` |
| `VMID` | `200` / `201` | LXC id |
| `HOSTNAME_CT` | `camstack` / `camstack-agent` | CT hostname |
| `CORES` / `MEMORY_MB` / `DISK_GB` | `8` / `8192` / `64` | resources |
| `STORAGE` | auto `local-lvm` or `local-zfs` | rootfs storage |
| `IMAGE_TAG` | `ghcr.io/camstack/camstack:amd-latest` | override image |
| `RECORDINGS_HOST_PATH` | — | optional host dir bound now at `/opt/camstack/recordings` |
| `CAMSTACK_HUB_ADDRESS` | — | agent: hub IP/hostname |
| `CAMSTACK_NODE_ID` | CT hostname | agent: stable node id |
| `PASS_ACCEL` | `auto` | `auto` passes every accelerator the host has (see below); `none` passes nothing |
| `PASS_KFD` | `0` | `1` also passes `/dev/kfd` (AMD ROCm; the image has no ROCm runtime today) |
| `--force` | — | destroy existing VMID and recreate |
| `--install-coral-pcie-driver` | — | opt-in host step: build the Coral PCIe/M.2 driver, then exit (see below) |

## Recordings on a real HD (do this when the disk arrives)

By default media lands on the **CT rootfs** (`/opt/camstack/recordings` →
container `/recordings`). That is only for smoke tests.

When a real disk is mounted on the PVE host, bind it into the CT with
[`setup-camstack-recordings-volume.sh`](setup-camstack-recordings-volume.sh).
Docker already maps that CT path to `CAMSTACK_MEDIA_ROOT=/recordings` — no
compose change.

```bash
# 1) Mount / format the HD on the PVE host yourself (fdisk, zfs, or a
#    Datacenter → Storage → Directory pointing at the disk).

# 2) Bind into the CamStack CT (hub example, VMID 200):
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/setup-camstack-recordings-volume.sh \
  | VMID=200 bash -s -- /mnt/recordings-hd/camstack-hub

# Or, if you created a Proxmox Directory storage named e.g. bulk-hdd:
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/setup-camstack-recordings-volume.sh \
  | VMID=200 bash -s -- --storage bulk-hdd
# → uses /mnt/pve/bulk-hdd/mounts/camstack-<hostname>
```

### Checklist for the HD

1. **Host path exists** and has free space (`df -h`).
2. **One subdirectory per CT** if hub-dev and agent share the disk  
   (`…/camstack-hub` and `…/camstack-agent`) — never the same directory on two VMIDs.
3. Run the setup script on the **PVE host** (needs `pct`). It will:
   - create the dir + `.camstack-media` marker
   - `chown` to the unprivileged idmap for container uid `1001` (usually host `101001`)
   - `pct set -mpN <host>,mp=/opt/camstack/recordings`
   - restart the CT and `docker compose up -d`
4. In CamStack admin: Recordings storage location stays on `/recordings`
   (matches `CAMSTACK_MEDIA_ROOT`).
5. If the CT already wrote media on the rootfs under that path, **move or
   backup first** — the bind hides the old tree without deleting it.

### Optional: pass the path at first install

If the disk is already mounted when you create the CT:

```bash
RECORDINGS_HOST_PATH=/mnt/recordings-hd/camstack-hub \
  bash install-camstack-proxmox.sh
```

### Later: backups on a second disk

Same pattern as recordings: host dir → `pct set -mpN …,mp=/opt/camstack/backups`
(compose already maps that path to `/backups`). A dedicated helper can be added
when needed; until then, mirror the recordings script with `CT_MP=/opt/camstack/backups`.

## Accelerators (GPU, NPU, Coral)

Two hops: the driver runs on the **PVE host**, the device node goes into the
**CT** as a `devN:` entry, and the compose inside the CT passes it on to the
**Docker container**. Full guide:
[Accelerator passthrough](https://camstack.io/docs/installation/accelerators).

With `PASS_ACCEL=auto` (the default) the installer passes what the host has,
and uncomments the matching lines in `/opt/camstack/docker-compose.yml`:

| Device | Detected by | Into the CT |
| --- | --- | --- |
| Intel / AMD iGPU | `/dev/dri/renderD*`, `/dev/dri/card*` | `devN: …,gid=<render/video>,mode=0660` |
| Intel NPU / AMD XDNA | `/dev/accel/accel*` | `devN: …,gid=<render>,mode=0660` |
| Coral PCIe / M.2 | `/dev/apex_*` (needs the host driver) | `devN: /dev/apex_N,gid=<render>,mode=0660` |
| Coral USB | USB id `1a6e:089a` / `18d1:9302` | `lxc.cgroup2.devices.allow: c 189:* rwm` + bind of `/dev/bus/usb` |
| AMD ROCm | only with `PASS_KFD=1` | `devN: /dev/kfd,…` |
| NVIDIA | never automatic | host driver, the same driver in the CT, NVIDIA Container Toolkit, then `gpus: all` |

Every device line in the compose is commented per hardware; Docker refuses to
start with a device the CT does not have, so uncomment only what you passed.
No `group_add` is needed: the image entrypoint makes each passed node openable
by the `camstack` user (and drops supplementary groups, so `group_add` would
not reach it anyway). A Coral USB in an unprivileged CT also needs a host udev
rule making it `0666` for both of its ids (`1a6e:089a` before the firmware
loads, `18d1:9302` after); the installer writes
`/etc/udev/rules.d/65-coral-usb.rules` and reloads udev when it finds a Coral
USB. Verified 2026-10-22 on an AMD Phoenix host: the stick re-enumerates with a
new device number on its first invoke and the bind of `/dev/bus/usb` follows it.

Adding a device to an existing CT by hand (keep the lines you have):

```bash
CT=201
pct set $CT -dev0 /dev/dri/renderD128,gid=993,mode=0660   # AMD/Intel iGPU
pct set $CT -dev1 /dev/accel/accel0,gid=993,mode=0660     # Intel NPU / AMD XDNA
pct set $CT -dev2 /dev/kfd,gid=993,mode=0660              # AMD ROCm (optional)
pct set $CT -dev3 /dev/apex_0,gid=993,mode=0660           # Coral PCIe unit 1
pct set $CT -dev4 /dev/apex_1,gid=993,mode=0660           # Coral PCIe unit 2
pct reboot $CT
# then uncomment the same nodes under devices: in /opt/camstack/docker-compose.yml
```

### Coral PCIe / M.2 host driver (opt-in)

Current kernels have no in-tree `gasket`/`apex` driver. This builds the
maintained fork ([feranick/gasket-driver](https://github.com/feranick/gasket-driver))
through DKMS, installs `proxmox-headers-$(uname -r)` (adding the
`pve-no-subscription` repository only when the headers are not otherwise
available), creates the `apex` group and the udev rule
`SUBSYSTEM=="apex", MODE="0660", GROUP="apex"`. It never runs as part of an
install and never reboots for you:

```bash
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/install-camstack-proxmox.sh \
  | bash -s -- --install-coral-pcie-driver
reboot                  # load on a clean boot
ls -l /dev/apex_*       # expect crw-rw---- root apex
```

With Secure Boot on, enrol the DKMS key first (`mokutil --import
/var/lib/dkms/mok.pub`, accept it in the MOK screen); the helper warns when it
sees Secure Boot enabled. Then install the Coral runtime inside the container
and enable the device per node, as in the guide.

### No custom entrypoint

The installer does not mount a `docker-entrypoint.sh`; the image's own handles
`/dev/dri`, `/dev/accel`, `/dev/apex_*` and Coral USB. If an older CT's compose
mounts a host copy (`/opt/camstack/docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh`),
remove that mount once the image is newer than v1.2.583: a mounted copy hides
every later entrypoint fix, and one without `/dev/apex_*` in its device `chown`
loop leaves a PCIe Coral `device-not-accessible`.

## Requirements

- Proxmox VE 9.x (kernel with `amdgpu`; `amdxdna` optional)
- Nested Docker needs `features: nesting=1,keyctl=1` (set by the script)
- Pass-through of `/dev/dri/renderD*` (and `/dev/accel`, `/dev/apex_*` when
  present; done by the script)
- For production media: a host disk bind (see above)

## Licence

MIT — see [LICENSE](LICENSE).
