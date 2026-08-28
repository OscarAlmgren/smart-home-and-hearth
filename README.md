# smart-home-and-hearth

Home Assistant running on **Podman Quadlets** on `henrybook` (bare metal —
MicroK8s was decommissioned 2026-08-06). Recorder DB is SQLite. Matter runs
on-host via `matter-server.container`; Thread is served off-host by a
Google/Nest Wifi Thread Border Router (an on-host OTBR was tried and
decommissioned 2026-08-28). Zigbee/ZHA is pending a dongle re-flash.

> **Live deployment:** **[docs/podman-deploy.md](docs/podman-deploy.md)**. Start there.
> **[docs/MIGRATION.md](docs/MIGRATION.md)** is kept as the historical record of the
> MicroK8s build-out this replaced; `k8s/`/`argocd/` remain in git as reference only.

## Layout

```
CLAUDE.md               # agent instructions — read before changing storage
docs/
  podman-deploy.md      # ← live deployment, read this first
  hardware.md           # the t610, its limits, dongle/radio placement
  disaster-recovery.md  # backup and restore runbook
  MIGRATION.md          # historical: the MicroK8s build-out
  grafana-cloud.md      # monitoring setup (not yet ported to Podman)
  lcm.md                # branch model and promotion (CI-only now, see below)
  microk8s-bootstrap.md # historical: one-time MicroK8s server build
podman/                 # Quadlet + systemd units — the live deployment
  homeassistant.container matter-server.container
  ha-sync-config.service backup.service backup.timer
k8s/                     # reference only — still CI-validated, not live
  base/ overlays/{dev,test,prod}/
argocd/                  # reference only, not live
config/                  # Home Assistant YAML — source of truth
  configuration.yaml
  packages/              # recorder, http, prometheus, logger
scripts/
  bootstrap-podman.sh    # one-time server build (the live path)
  backup.sh restore.sh   # disaster recovery
  render-env.sh          # keeps .env.* and k8s/ overlays in sync (CI only)
.env.dev .env.test .env.prod   # per-environment knobs — TRACKED, no secrets
docker-compose.yml      # legacy, kept for local editing only
```

## Environments

The `dev`/`test`/`main` branch model and `.env.*` files are still CI-gated
(`k8s/overlays/{dev,test,prod}` build and schema-check on every push), but
none of it has a cluster to deploy to anymore — the live instance is Podman
on henrybook, deployed from whatever's checked out on the server, not by
branch promotion. See CLAUDE.md § Environments for the current state of this.

Changes flow `dev` → `test` → `main` by pull request. Never commit to `main`
directly. See [docs/lcm.md](docs/lcm.md).

## Making a change

```bash
git switch dev
# edit config/ or podman/
kubectl kustomize k8s/overlays/prod >/dev/null   # must build clean — still CI-gated
./scripts/render-env.sh --check                  # .env <-> overlay drift — still CI-gated
git commit && git push
```

Open a PR `dev` → `test`, then `test` → `main`. On the server, deploying a
change is manual for now (see docs/podman-deploy.md § Known gaps):

```bash
git pull
sudo systemctl restart homeassistant.service   # or matter-server.service
```

Home Assistant is at `http://<server-ip>:8123` on the LAN. Remote access is
**phase 3** — there is deliberately no Ingress and no TLS yet.

## Local editing without a cluster

`docker-compose.yml` is retained purely as a workstation escape hatch for
editing Home Assistant YAML:

```bash
cp .env.example .env
cp config/secrets.yaml.example config/secrets.yaml   # fill in
docker compose up
```

This is **not** how the server runs anything. Do not deploy from it.

## Things that will bite you

- **`.env.dev` / `.env.test` / `.env.prod` are tracked in git.** Only bare `.env`
  is ignored. Never put a secret in them — real secrets go in `config/secrets.yaml`
  / `.env.prod.secret`, both gitignored, `chmod 600`.
- **Storage sizing is gated on hardware.** Runtime state lives under
  `/var/lib/smart-home-and-hearth/` on a 16 GB flash module with ~12 GiB usable.
  Ask before changing any retention setting or moving anything to the HDD — see
  [CLAUDE.md](CLAUDE.md).
- **The Sonoff dongle is being re-flashed from OpenThread RCP back to Zigbee**
  now that Thread runs on the Nest Wifi border router, not this box. USB 2.0
  port on an extension cable when it goes in: USB 3.0 controllers emit 2.4 GHz
  noise that degrades Zigbee badly.
- **Disk exhaustion is the most likely failure mode.** The root-filesystem alert
  is the most valuable thing in the monitoring stack.
