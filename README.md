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
| `CAMSTACK_HUB_ADDRESS` | — | agent: hub IP/hostname |
| `CAMSTACK_NODE_ID` | CT hostname | agent: stable node id |
| `--force` | — | destroy existing VMID and recreate |

## Requirements

- Proxmox VE 9.x (kernel with `amdgpu`; `amdxdna` optional)
- Nested Docker needs `features: nesting=1,keyctl=1` (set by the script)
- Pass-through of `/dev/dri/renderD*` (and `/dev/accel` when present)

## Licence

MIT — see [LICENSE](LICENSE).
