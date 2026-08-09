# CLAUDE.md

Home Assistant on `henrybook`, run via **Podman Quadlets** (`podman/`) —
MicroK8s was decommissioned 2026-08-06. [docs/podman-deploy.md](docs/podman-deploy.md)
is the primary reference for the live deployment; [docs/MIGRATION.md](docs/MIGRATION.md)
is kept as the historical record of the MicroK8s build-out (`k8s/` and
`argocd/` remain in git as reference only, not live).

## Check in with Oscar before changing storage

**Storage sizing is gated on hardware.** Runtime state lives under
`/var/lib/smart-home-and-hearth/` on a 16 GB SATA flash module with ~12 GiB
usable. A larger HDD is expected but **not yet fitted**.

Before changing any of the following, **ask Oscar whether the HDD has arrived
and been mounted**. Do not assume, and do not infer it from the repo:

- `purge_keep_days` or any recorder retention setting
- restic retention policy or backup target
- moving Podman's storage root, or any `/var/lib/smart-home-and-hearth/*` bind
  mount, onto the HDD

## Non-obvious constraints

These are load-bearing. Changing them breaks the deployment in ways that are
slow to diagnose.

- **Serial devices are referenced by `/dev/serial/by-id/`, never `/dev/ttyACM0`.**
  Kernel enumeration order changes across reboots and will silently point a
  radio container at the wrong device. Applies to both `podman/otbr.container`
  (Thread, active) and the commented Zigbee line in
  `podman/homeassistant.container` (deferred).
- **Radio device paths are placeholders (`REPLACE_ME`) until filled in on the
  server.** `podman/otbr.container`'s `AddDevice=` and
  `podman/homeassistant.container`'s commented Zigbee `AddDevice=` both need a
  real `ls -l /dev/serial/by-id/` path before their unit can start — this
  can't be known from the repo, it depends on what's plugged in.
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
systemctl status homeassistant.service ha-sync-config.service otbr.service matter-server.service
curl -sf http://localhost:8123/ >/dev/null && echo ok
```

`k8s/`/`argocd/` are reference-only but still CI-gated — if touching them:

```bash
kubectl kustomize k8s/overlays/prod          # must build clean
./scripts/render-env.sh --check              # .env <-> overlay tag drift
```

## Deferred work

Do not add these without being asked — they are scoped to later phases:

- **Zigbee.** The original Sonoff dongle was reflashed for Thread instead
  (see below) — Zigbee is deferred until a separate dongle is available. See
  docs/hardware.md § Radios.
- **Phase 2 remainder:** OCPP EV charger integration, derived HA image for
  HACS custom components.
- **Phase 3:** domain, DNS, public IPv6 access, Ingress, TLS. Phase 1 is
  **LAN-only** — there is deliberately no Ingress and no cert-manager.

## Current: Matter/Thread

Containerized OTBR (`podman/otbr.container`) + `python-matter-server`
(`podman/matter-server.container`), replacing the HAOS-only add-ons — this is
no longer deferred, it's the active IoT radio priority ahead of Zigbee. See
docs/hardware.md § Radios and docs/podman-deploy.md.
