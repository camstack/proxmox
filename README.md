# CamStack on Proxmox VE

Public install scripts for running CamStack in an **unprivileged LXC** on
Proxmox VE (Ubuntu 24.04 + Docker CE), using the **AMD** image variant
(`ghcr.io/camstack/camstack:amd-latest`).

Unraid templates live separately in
[camstack/unraid-templates](https://github.com/camstack/unraid-templates).

## One image, two roles

`CAMSTACK_ROLE=hub|agent` selects the role. Hub and agent on the **same**
Proxmox host need **two containers** (host networking would collide on
4443/4444/6000).

## Install (on the PVE host)

```bash
# Hub (default VMID 200)
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/install-camstack-proxmox.sh \
  | bash

# Agent joining an existing hub (default VMID 201)
curl -fsSL https://raw.githubusercontent.com/camstack/proxmox/main/install-camstack-proxmox.sh \
  | ROLE=agent CAMSTACK_HUB_ADDRESS=192.168.1.9 CAMSTACK_NODE_ID=my-amd-box bash
```

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
| `--force` | — | destroy existing VMID and recreate |

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

### What you do **not** need for GPU / NPU

`/dev/dri` and `/dev/accel` are passed with `pct set -devN …,gid=…` by the
install script. No bind-mount or chmod script — device nodes are not a disk
tree. (ROCm `/dev/kfd` / XRT are out of scope for this image.)

### Later: backups on a second disk

Same pattern as recordings: host dir → `pct set -mpN …,mp=/opt/camstack/backups`
(compose already maps that path to `/backups`). A dedicated helper can be added
when needed; until then, mirror the recordings script with `CT_MP=/opt/camstack/backups`.

## Requirements

- Proxmox VE 9.x (kernel with `amdgpu`; `amdxdna` optional)
- Nested Docker needs `features: nesting=1,keyctl=1` (set by the script)
- Pass-through of `/dev/dri/renderD*` (and `/dev/accel` when present)
- For production media: a host disk bind (see above)

## Licence

MIT — see [LICENSE](LICENSE).
