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
| Bluetooth | Realtek RTL8761BU USB dongle (`0bda:a760`, BT 5.x; sold as "Bluetooth 6.0"), added 2026-09-15 | Host runs `bluez` + `bluetooth.service`; HA reaches it via `/run/dbus` mounted into the container. USB autosuspend must stay off (`/etc/udev/rules.d/50-rtl8761bu-no-autosuspend.rules`) or it times out and resets on the OHCI controller. |
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

### Thread/Matter — Home Assistant OTBR, Sonoff dongle as the Thread radio

**Target:** Thread is owned by an **on-host OpenThread Border Router** that
Home Assistant manages. The Sonoff Zigbee 3.0 USB Dongle Plus V2 stays on
**OpenThread RCP firmware** and is that border router's radio. HA runs as a
container here, not HAOS, so there is no OTBR add-on. Instead an OTBR
container (`podman/otbr.container`, to be re-added) drives the dongle, and HA
connects to it through its **Open Thread Border Router** integration. The
HA-owned Thread network becomes the preferred dataset, and Thread devices are
re-commissioned onto it.

**Status (2026-09-15):** planned, not deployed. Until then Thread is still
served by the household's 2019 Google Nest Wifi units, which HA's `thread`
integration discovers over mDNS.

**Why the plan is back on-host.** A first OTBR ran 2026-08-25 → 2026-08-28 and
was removed in favour of the Nest Wifi border routers. That turned out to be
the wrong trade: each 2019 Nest Wifi unit (H2D router / H2E point) runs its
own separate Thread network with no way to merge them, and mains-powered
Thread routers (GRILLPLATS plug, KAJPLATS bulb) kept dropping out of HA. The
Nest units are also being replaced. An HA-owned border router gives one
network that HA controls and a local Thread path.

**Lessons to carry into the new `otbr.container`** (from the first attempt):

- Pin an image version. The old `latest` image logged at `-d7` and buried the
  journal.
- `Sysctl=` doesn't work under podman 5.7.0 with `Network=host`. Set IPv6
  forwarding in `/etc/sysctl.d/`, and load the `iptable_nat`,
  `iptable_mangle`, `iptable_filter` and `ip6table_filter` modules via
  `/etc/modules-load.d/`.
- Add `ConditionPathExists=` on the dongle's by-id path so a missing dongle
  skips the unit instead of crash-looping (see the 2026-08-25 incident in
  disaster-recovery.md).
- The Thread network dataset is state worth backing up. The first attempt's
  dataset is archived at `/mnt/storage/otbr-thread-dataset-20260828.tgz`.

`podman/matter-server.container` (`python-matter-server`) backs HA's Matter
integration, which only exists as a HAOS supervisor add-on otherwise. It
reaches Thread devices through whichever border router is advertised over
mDNS and needs no radio of its own.

**Dongle placement.** Plug it into a USB 2.0 port, on an extension cable.
USB 3.0 controllers and their cabling emit broadband noise around 2.4 GHz,
which is exactly where Thread (channel 17 ≈ 2435 MHz) lives. The extension
also gets the antenna away from the chassis, the Ethernet port and the
Bluetooth dongle. As of 2026-09-15 it is on USB port 2-3 (OHCI), on a 1.5 m
extension, taped high up on the outside of an AC unit. That spot is temporary
until a better one is found.

Reference it by stable path, never `/dev/ttyACM0`:

```bash
ls -l /dev/serial/by-id/
# usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20240124154748-if00
# (this dongle's path ends -if00 — no -port0 suffix)
```

The USB product name says "Zigbee" whatever firmware is flashed. Kernel
enumeration order changes across reboots, so `/dev/ttyACM0` will eventually
point at the wrong radio.

### Zigbee — no radio

Zigbee/ZHA is not planned. The only 802.15.4 dongle is the Thread radio above,
and Zigbee would need a second dongle of its own.

## Planned additions

| Item | Purpose | Status |
|---|---|---|
| Larger HDD | Container images, recorder DB, restic repo | ☑ fitted 2026-08-25 — rootful + rootless podman stores and `/var/lib/smart-home-and-hearth` moved onto it, restic repo still pending (see disaster-recovery.md § Where backups go) |
| Home Assistant OTBR | On-host Thread Border Router: `podman/otbr.container` + HA's Open Thread Border Router integration, Sonoff dongle (OpenThread RCP) as the radio | ☐ planned — dongle attached 2026-09-15, container not yet re-added |
| Raspberry Pi + MinIO | S3 backup target on the LAN | ☐ phase 1 backup target |

MinIO on the LAN is **not offsite** — a fire, theft or power event takes both
copies. Adding an offsite target (e.g. a Backblaze B2 bucket, ~€0.50/month at
this data size) is recommended to complete 3-2-1, and is Oscar's call.
