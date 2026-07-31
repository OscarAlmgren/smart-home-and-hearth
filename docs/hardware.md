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
| Container images (HA ~2 GB, Postgres, Alloy, Argo CD, Calico, KSM) | ~5 GB |
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
- Postgres data moves to the HDD when it arrives.

**Nothing important may live only on this flash module.** See
[disaster-recovery.md](disaster-recovery.md).

## Radios

### Zigbee — Sonoff Zigbee 3.0 USB Dongle Plus

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

Put that path in `k8s/overlays/prod/` — the manifest mounts it at `/dev/zigbee`
inside the pod. Kernel enumeration order changes across reboots, so
`/dev/ttyACM0` will eventually point at the wrong radio.

### Thread — second dongle, phase 2

A second Sonoff dongle, flashed with **OpenThread RCP** firmware, dedicated to
Thread.

Deliberately *not* using one dongle for both: running Zigbee and Thread
concurrently on a single radio requires Silicon Labs multiprotocol RCP firmware,
which Home Assistant has deprecated and stopped recommending after sustained
reports of degraded Zigbee reliability. Two cheap dongles are the supported
path.

Thread and Matter also need `otbr` and `matter-server` pods, both on
`hostNetwork` with working IPv6 on the LAN. That is phase 2 work.

## Planned additions

| Item | Purpose | Status |
|---|---|---|
| Larger HDD | Container images, Postgres data, restic repo | ☐ not fitted — **gates storage changes** |
| Second Sonoff dongle (OpenThread RCP) | Thread border router | ☐ phase 2 |
| Raspberry Pi + MinIO | S3 backup target on the LAN | ☐ phase 1 backup target |

MinIO on the LAN is **not offsite** — a fire, theft or power event takes both
copies. Adding an offsite target (e.g. a Backblaze B2 bucket, ~€0.50/month at
this data size) is recommended to complete 3-2-1, and is Oscar's call.
