# CLAUDE.md

Home Assistant on `henrybook`, run via **Podman Quadlets** (`podman/`) —
MicroK8s was decommissioned 2026-08-06. [docs/podman-deploy.md](docs/podman-deploy.md)
is the primary reference for the live deployment; [docs/MIGRATION.md](docs/MIGRATION.md)
is kept as the historical record of the MicroK8s build-out (`k8s/` and
`argocd/` remain in git as reference only, not live).

## Check in with Oscar before changing storage

The 16 GB SATA flash module (~9.8 GiB usable `/`) holds only the OS + Podman
packages. A 500 GB SSHD was fitted 2026-08-25 at `/mnt/storage`; as of
2026-08-28 both the rootful and rootless Podman stores and
`/var/lib/smart-home-and-hearth` (via symlink) live on it — see
docs/hardware.md § The disk is the constraint.

Still **ask Oscar first** before changing any of the following (they have
cost/retention or data-safety implications beyond just free space):

- `purge_keep_days` or any recorder retention setting
- restic retention policy or backup target
- relocating anything else onto `/mnt/storage`, or repartitioning it

## Non-obvious constraints

These are load-bearing. Changing them breaks the deployment in ways that are
slow to diagnose.

- **Serial devices are referenced by `/dev/serial/by-id/`, never `/dev/ttyACM0`.**
  Kernel enumeration order changes across reboots and will silently point a
  radio container at the wrong device. Applies to the Sonoff Thread dongle
  (`usb-ITEAD_SONOFF_Zigbee_3.0_USB_Dongle_Plus_V2_20240124154748-if00`)
  when it is passed to `podman/otbr.container`.
- **The Sonoff dongle is the Thread radio, not a Zigbee coordinator.** It runs
  OpenThread RCP firmware for the planned Home Assistant OTBR, despite
  "Zigbee" in its USB name. Don't re-flash it to Zigbee and don't pass it to
  the Home Assistant container. See § Current: Matter/Thread.
- **No CPU limit on the Home Assistant container.** The node has 2 slow cores;
  CFS throttling makes the UI unusable. Memory limits only.
- **`config/secrets.yaml` and `.env.prod.secret` are plain gitignored files,
  `chmod 600`, never committed.** Copy from their `.example` templates on the
  server. Nothing checks that credentials referenced in one match the other
  where relevant — same caveat the old Sealed Secrets version had.
- **Bind mounts under `/var/lib/smart-home-and-hearth/` don't enforce a size
  limit.** The real limit is free space on `/`. Disk-full is the most likely
  failure mode on this hardware.

## Environments

CI still validates all three `k8s/overlays/{dev,test,prod}` on every push —
`.github/workflows/validate.yml` builds and schema-checks them, and
`scripts/render-env.sh --check` enforces that `HA_VERSION` in each `.env.*`
matches the corresponding overlay's `images:` tag. Keep these passing when
touching `.env.*` or `k8s/` even though the cluster itself is gone.

| Branch | Env | Cluster presence |
|---|---|---|
| `dev` | `.env.dev` | none — CI validation only |
| `test` | `.env.test` | none — CI validation only (was `ha-test`, pre-decommission) |
| `main` | `.env.prod` | none — was `ha-prod`, Argo CD auto-sync; **the live deployment is now Podman on henrybook, not this cluster** |

Promotion is by PR: `dev` → `test` → `main`. Never commit directly to `main`.

## Verifying changes

Live deployment (Podman, on henrybook — see docs/podman-deploy.md § Verification):

```bash
systemctl status homeassistant.service ha-sync-config.service matter-server.service
curl -sf http://localhost:8123/ >/dev/null && echo ok
```

`k8s/`/`argocd/` are reference-only but still CI-gated — if touching them:

```bash
kubectl kustomize k8s/overlays/prod          # must build clean
./scripts/render-env.sh --check              # .env <-> overlay tag drift
```

## Deferred work

Do not add these without being asked — they are scoped to later phases:

- **Zigbee.** No radio. The only 802.15.4 dongle is the Thread radio, and
  Zigbee would need a second one. See docs/hardware.md § Radios.
- **Phase 2 remainder:** OCPP EV charger integration, derived HA image for
  HACS custom components.
- **Phase 3:** domain, DNS, public IPv6 access, Ingress, TLS. Phase 1 is
  **LAN-only** — there is deliberately no Ingress and no cert-manager.

## Current: Matter/Thread

`python-matter-server` (`podman/matter-server.container`) backs HA's Matter
integration (HAOS-only add-on otherwise).

**Thread target: a Home Assistant OTBR on this box.** An OTBR container
(`podman/otbr.container`) uses the Sonoff dongle (OpenThread RCP) as its
Thread radio, and HA connects to it through the Open Thread Border Router
integration. HA's Thread network becomes the preferred dataset. **Status
(2026-09-15): planned, not deployed** — the dongle is attached, but the
container hasn't been re-added yet. Until then Thread is served by the Google
Nest Wifi border routers over mDNS.

A first on-host OTBR ran 2026-08-25 → 2026-08-28 and was removed. Re-adding
it, including its host IPv6-forwarding and NAT44-module setup, is now the
plan. Carry that attempt's fixes forward; they are listed in
docs/hardware.md § Radios. See also docs/podman-deploy.md.
