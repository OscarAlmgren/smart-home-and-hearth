# Hardware

The server is `henrybook`, an **HP t610 WW thin client** (B8C95AA#ABD). Full
`lshw` output is committed as [`henrybook-stats.yaml`](../henrybook-stats.yaml).

## Specification

| Component | Detail | Consequence |
|---|---|---|
| CPU | AMD G-T56N — 2 cores @ 1.65 GHz, Bobcat (2011), 18 W TDP | Roughly a Raspberry Pi 4. One Home Assistant, not three. **Never set a CPU limit on the HA container** — CFS throttling makes the UI unusable. |
| RAM | 6 GiB DDR3 (2 GiB @ 533 MHz + 4 GiB @ 800 MHz) | Mismatched pair, so effectively single-channel. ~3–3.5 GiB is the realistic workload budget. |
| Storage | **16 GB SATA flash**, largest partition ~12 GiB | The binding constraint. See below. |
| SATA | SB7x0/SB8x0/SB9x0 controller in **IDE mode** | No AHCI, no NCQ. The incoming HDD will be slow — fine for backups and the DB, keep hot paths on flash. |
| Network | 1× Broadcom BCM57781 gigabit (`enp3s0`) | No WiFi. |
| Bluetooth | **none** | Dropped from scope. Would need a USB adapter plus host D-Bus in the pod. |
| USB | OHCI + EHCI (USB 2.0), TUSB73x0 xHCI (USB 3.0) | Enough ports. Placement matters — see below. |

## The disk is the constraint

The 16 GB flash module (`/dev/sda`, ~9.8 GiB usable on the LVM root `/` after
partitioning) holds **Ubuntu Server and the Podman packages only**. Everything
else that isn't inherently OS state lives on the 500 GB Seagate SSHD, fitted
2026-08-25 and mounted at `/mnt/storage` (see the 2026-08-25 incident in
[disaster-recovery.md](disaster-recovery.md)):

| On `/mnt/storage` | How |
|---|---|
| Rootful Podman image/container store (HA, matter-server) | `graphroot` in `/etc/containers/storage.conf` → `/mnt/storage/containers/storage-root` |
| Rootless Podman store (the Bedrock server, user `oscaralmgren`) | `rootless_storage_path` in `~/.config/containers/storage.conf` → `/mnt/storage/containers/rootless` (moved off the boot disk 2026-08-28 — rootless podman ignores `graphroot`) |
| Image-pull staging | `image_copy_tmp_dir` in `/etc/containers/containers.conf` — `graphroot` alone does **not** cover this; pulls stage in `/var/tmp` by default regardless of `graphroot` |
| `/var/lib/smart-home-and-hearth` (config, recorder DB, Matter data) | root is a symlink to `/mnt/storage/smart-home-and-hearth` — the Quadlet units' `Volume=` paths are unchanged |

MicroK8s (and the PVC/containerd-data-root budget this section used to
track) is decommissioned - see
[podman-deploy.md § MicroK8s decommissioning](podman-deploy.md#microk8s-decommissioning).

Practical rules:

- **Disk exhaustion is the most likely failure mode** — it already happened
  once (2026-08-25, see disaster-recovery.md), from a crash-looping Quadlet
  unit, not from legitimate growth. The root-filesystem alert (fires at 80%)
  is the single most valuable thing in the monitoring stack.
- `journalctl` is capped at 200M (`/etc/systemd/journald.conf.d/99-cap-size.conf`)
  so a noisy period can't fill the disk on its own regardless of which
  service is misbehaving.
- Swap (`/swapfile`, 1G) stays on the flash module, not `/mnt/storage` —
  deliberately: swap over the USB-attached SSHD would add real latency and a
  disconnect/enclosure hiccup under swap pressure risks a hang, and this box
  barely swaps in practice (worth revisiting only if that changes).

## Flash wear

The previous SSD suffered a catastrophic failure that destroyed the install.
This class of part is consumable, and Home Assistant's recorder writes
continuously. Mitigations already in the config:

- `packages/recorder.yaml` excludes chatty entities and raises `commit_interval`.
- `purge_keep_days: 7` while on flash.
- The recorder DB (`home-assistant_v2.db`, SQLite) now lives on the HDD, via
  the `/var/lib/smart-home-and-hearth` symlink — see above.

**Nothing important may live only on this flash module.** See
[disaster-recovery.md](disaster-recovery.md).

## Radios

### Thread/Matter — off-host, Google/Nest Wifi Thread Border Router

Thread is **not** run on henrybook. An on-host containerized OpenThread
Border Router (`podman/otbr.container`, using the Sonoff dongle reflashed to
OpenThread RCP) was tried between 2026-08-25 and 2026-08-28, then
decommissioned: the household already has a **Google/Nest Wifi Thread Border
Router**, Home Assistant's `thread` integration discovers it over mDNS, and
both commissioned Matter-over-Thread devices were already homed on the Nest
mesh (`NEST-PAN-0057`), not on the OTBR network. Running a second border
router on a 2-core / 6 GiB box for no devices was pure overhead — plus OTBR's
`latest` image logs at `-d7` and buried the journal.

`podman/matter-server.container` (`python-matter-server`) stays — it backs
HA's Matter integration, which only exists as a HAOS supervisor add-on
otherwise. It reaches Thread devices via the Nest border router over mDNS; it
needs no radio, no host sysctls, and no kernel modules.

### Zigbee — Sonoff dongle, being re-flashed back to Zigbee

With Thread now handled off-host, the Sonoff Zigbee 3.0 USB Dongle Plus V2
(originally bought for Zigbee, temporarily flashed to OpenThread RCP for the
OTBR experiment) is being **re-flashed back to Zigbee coordinator firmware**
for ZHA. No second dongle is needed anymore.

**Plug it into a USB 2.0 port, on an extension cable.**

USB 3.0 controllers and their cabling emit broadband noise around 2.4 GHz, which
is exactly where Zigbee lives. A dongle seated directly in a USB 3.0 port is the
single most common cause of "Zigbee devices randomly drop off" reports. The
extension cable also gets the antenna away from the chassis and the Ethernet
port.

Reference it by stable path, never `/dev/ttyACM0`:

```bash
ls -l /dev/serial/by-id/
# usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20240124154748-if00
# (this dongle's path ends -if00 — no -port0 suffix)
```

Put that path in `podman/homeassistant.container`'s commented `AddDevice=`
line. Kernel enumeration order changes across reboots, so `/dev/ttyACM0` will
eventually point at the wrong radio.

## Planned additions

| Item | Purpose | Status |
|---|---|---|
| Larger HDD | Container images, recorder DB, restic repo | ☑ fitted 2026-08-25 — rootful + rootless podman stores and `/var/lib/smart-home-and-hearth` moved onto it, restic repo still pending (see disaster-recovery.md § Where backups go) |
| Zigbee via ZHA | Sonoff dongle (re-flashing from OpenThread RCP back to Zigbee firmware) | ☐ pending re-flash + `AddDevice=` in `podman/homeassistant.container` |
| Raspberry Pi + MinIO | S3 backup target on the LAN | ☐ phase 1 backup target |

MinIO on the LAN is **not offsite** — a fire, theft or power event takes both
copies. Adding an offsite target (e.g. a Backblaze B2 bucket, ~€0.50/month at
this data size) is recommended to complete 3-2-1, and is Oscar's call.
