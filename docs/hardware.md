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

Approximate budget against ~12 GiB usable:

| Consumer | Size |
|---|---|
| Ubuntu Server | ~4 GB |
| MicroK8s snap (plus retained revisions) | ~1 GB |
| Container images (HA ~2 GB, OTBR, matter-server, Alloy, Argo CD, Calico, KSM) | ~5 GB |
| PVCs | 0.8 GB |
| **Total** | **~11 of 12 GiB** |

That is *before* Home Assistant stores a byte. Canonical recommends 20 GB for
MicroK8s; this box is under that, knowingly.

Practical rules:

- **Disk exhaustion is the most likely failure mode.** The root-filesystem alert
  (fires at 80%) is the single most valuable thing in the monitoring stack.
- Keep the image count minimal. `microk8s ctr images prune` is in the runbook.
- Snap retains old revisions — `snap set system refresh.retain=2`.
- When the HDD is fitted, move containerd's data root and the PVC hostpath onto
  it. **Ask Oscar first** — see [CLAUDE.md](../CLAUDE.md).

`hostpath-storage` **does not enforce PVC size**. A `500Mi` PVC will happily
consume the whole filesystem. The declared sizes are bookkeeping; monitoring is
what actually protects you.

## Flash wear

The previous SSD suffered a catastrophic failure that destroyed the install.
This class of part is consumable, and Home Assistant's recorder writes
continuously. Mitigations already in the config:

- `packages/recorder.yaml` excludes chatty entities and raises `commit_interval`.
- `purge_keep_days: 7` while on flash.
- The recorder DB (`home-assistant_v2.db`, SQLite) moves to the HDD when it arrives.

**Nothing important may live only on this flash module.** See
[disaster-recovery.md](disaster-recovery.md).

## Radios

### Thread/Matter — Sonoff dongle, reflashed with OpenThread RCP (active)

The Sonoff dongle originally bought for Zigbee has been reflashed with
**OpenThread RCP** firmware and is now the Thread radio, run through a
containerized OpenThread Border Router (`podman/otbr.container`) plus
`python-matter-server` (`podman/matter-server.container`) — Home Assistant's
own OTBR/Matter Server add-ons only exist under HAOS's supervisor. This is
prioritized ahead of Zigbee; see CLAUDE.md § Deferred work.

**Same placement rule as below applies** — USB 2.0 port, on an extension
cable, referenced by `/dev/serial/by-id/`. Confirmed on henrybook: the by-id
string is unchanged from the Zigbee-firmware days
(`usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20240124154748-if00`) —
it's derived from the dongle's CP2102N USB-UART bridge chip, not the EFR32
application firmware, so reflashing the radio doesn't change it. Already set
in `podman/otbr.container`.

OTBR also needs the LAN NIC (`enp3s0`) as its backbone/infra interface, and
IPv6 forwarding enabled on it — see `podman/otbr.container` for the sysctls.

### Zigbee — deferred, needs its own dongle

Concurrent Zigbee+Thread on one radio requires Silicon Labs multiprotocol RCP
firmware, which Home Assistant has deprecated and stopped recommending after
sustained reports of degraded Zigbee reliability — so Zigbee is deferred until
a **separate** Sonoff Zigbee 3.0 USB Dongle Plus is available for it, rather
than sharing the one now dedicated to Thread.

**Plug it into a USB 2.0 port, on an extension cable.**

USB 3.0 controllers and their cabling emit broadband noise around 2.4 GHz, which
is exactly where Zigbee lives. A dongle seated directly in a USB 3.0 port is the
single most common cause of "Zigbee devices randomly drop off" reports. The
extension cable also gets the antenna away from the chassis and the Ethernet
port.

Reference it by stable path, never `/dev/ttyACM0`:

```bash
ls -l /dev/serial/by-id/
# usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_<serial>-if00-port0
```

Put that path in `podman/homeassistant.container`'s commented `AddDevice=`
line. Kernel enumeration order changes across reboots, so `/dev/ttyACM0` will
eventually point at the wrong radio.

## Planned additions

| Item | Purpose | Status |
|---|---|---|
| Larger HDD | Container images, recorder DB, restic repo | ☐ not fitted — **gates storage changes** |
| Second Sonoff dongle | Zigbee (deferred — original dongle now runs Thread) | ☐ deferred |
| Raspberry Pi + MinIO | S3 backup target on the LAN | ☐ phase 1 backup target |

MinIO on the LAN is **not offsite** — a fire, theft or power event takes both
copies. Adding an offsite target (e.g. a Backblaze B2 bucket, ~€0.50/month at
this data size) is recommended to complete 3-2-1, and is Oscar's call.
