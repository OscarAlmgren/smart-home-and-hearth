# CLAUDE.md

Home Assistant on MicroK8s, GitOps-driven by Argo CD. Migration status and the
full task list live in [docs/MIGRATION.md](docs/MIGRATION.md).

## Check in with Oscar before changing storage

**Storage sizing is gated on hardware.** The current PVCs (800 Mi total) are
sized for a 16 GB SATA flash module with ~12 GiB usable. A larger HDD is
expected but **not yet fitted**.

Before changing any of the following, **ask Oscar whether the HDD has arrived
and been mounted**. Do not assume, and do not infer it from the repo:

- any PVC size
- `purge_keep_days` or any recorder retention setting
- restic retention policy or backup target
- moving containerd's data root

## Non-obvious constraints

These are load-bearing. Changing them breaks the deployment in ways that are
slow to diagnose.

- **`strategy: Recreate` on the Home Assistant Deployment.** RollingUpdate
  deadlocks — two pods cannot both bind host `:8123` or open the same serial
  device.
- **Serial devices are referenced by `/dev/serial/by-id/`, never `/dev/ttyACM0`.**
  Kernel enumeration order changes across reboots and will silently point Home
  Assistant at the wrong radio.
- **No CPU limit on the Home Assistant container.** The node has 2 slow cores;
  CFS throttling makes the UI unusable. Memory limits only.
- **`.env.dev`, `.env.test` and `.env.prod` are tracked in git.** Only bare
  `.env` is ignored. Never write a secret into them — secrets go through Sealed
  Secrets.
- **`hostpath-storage` does not enforce PVC sizes.** The declared size is
  bookkeeping; the real limit is free space on `/`. Disk-full is the most likely
  failure mode on this hardware.

## Environments

| Branch | Env | Cluster presence |
|---|---|---|
| `dev` | `.env.dev` | none — CI validation only |
| `test` | `.env.test` | `ha-test` namespace, HA at `replicas: 0` |
| `main` | `.env.prod` | `ha-prod` namespace, live, Argo CD auto-sync |

Promotion is by PR: `dev` → `test` → `main`. Never commit directly to `main`.

`HA_VERSION` in each `.env.*` must match the `images:` newTag in the
corresponding overlay. `scripts/render-env.sh --check` enforces this and CI
fails on drift.

## Verifying changes

```bash
kubectl kustomize k8s/overlays/prod          # must build clean
./scripts/render-env.sh --check              # .env <-> overlay tag drift
```

Full verification matrix, including the cluster-side checks, is in
docs/MIGRATION.md § Verification.

## Deferred work

Do not add these without being asked — they are scoped to later phases:

- **Phase 2:** Matter/Thread (`otbr` + `matter-server` pods), OCPP EV charger
  integration, derived HA image for HACS custom components.
- **Phase 3:** domain, DNS, public IPv6 access, Ingress, TLS. Phase 1 is
  **LAN-only** — there is deliberately no Ingress and no cert-manager.
