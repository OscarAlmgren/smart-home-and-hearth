# smart-home-and-hearth

Home Assistant running on **MicroK8s**, deployed by **Argo CD** from this
repository, monitored by **Grafana Cloud**.

> **Migrating from Docker Compose.** Progress, decisions and the full task list
> live in **[docs/MIGRATION.md](docs/MIGRATION.md)**. Start there.

## Layout

```
CLAUDE.md               # agent instructions — read before changing storage
docs/
  MIGRATION.md          # ← live progress tracker, read this first
  hardware.md           # the t610, its limits, dongle placement
  grafana-cloud.md      # monitoring setup end to end
  lcm.md                # branch model and promotion
  disaster-recovery.md  # backup and restore runbook
  microk8s-bootstrap.md # one-time server build
k8s/
  base/                 # namespace, Home Assistant, Postgres, monitoring, backup
  overlays/{dev,test,prod}/
argocd/                 # AppProject and Applications
config/                 # Home Assistant YAML — source of truth
  configuration.yaml
  packages/             # recorder, http, prometheus, logger
scripts/
  bootstrap-microk8s.sh # one-time server build
  render-env.sh         # keeps .env.* and overlays in sync
  restore.sh            # disaster recovery
.env.dev .env.test .env.prod   # per-environment knobs — TRACKED, no secrets
docker-compose.yml      # legacy, kept for local editing only
```

## Environments

| Branch | Env file | Cluster | Notes |
|---|---|---|---|
| `dev` | `.env.dev` | none | CI validation only |
| `test` | `.env.test` | `ha-test` | applied, but Home Assistant at `replicas: 0` |
| `main` | `.env.prod` | `ha-prod` | the live instance, Argo CD auto-syncs |

Only `ha-prod` runs a real Home Assistant — the server is a 2-core, 6 GiB thin
client and cannot host three. `ha-test` is applied to the API server at zero
replicas, which gives genuine admission and schema validation at essentially no
resource cost.

Changes flow `dev` → `test` → `main` by pull request. Never commit to `main`
directly. See [docs/lcm.md](docs/lcm.md).

## Making a change

```bash
git switch dev
# edit config/ or k8s/
kubectl kustomize k8s/overlays/prod >/dev/null   # must build clean
./scripts/render-env.sh --check                  # .env <-> overlay drift
git commit && git push
```

CI validates every branch. Open a PR `dev` → `test`, then `test` → `main`. Argo
CD picks up `main` and syncs `ha-prod` automatically.

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
  is ignored. Never put a secret in them — use Sealed Secrets.
- **Storage sizing is gated on hardware.** PVCs are sized for a 16 GB flash
  module with ~12 GiB usable. Ask before changing any PVC size or retention
  setting — see [CLAUDE.md](CLAUDE.md).
- **The Zigbee dongle belongs in a USB 2.0 port on an extension cable.** USB 3.0
  controllers emit 2.4 GHz noise that degrades Zigbee badly.
- **Disk exhaustion is the most likely failure mode.** The root-filesystem alert
  is the most valuable thing in the monitoring stack.
