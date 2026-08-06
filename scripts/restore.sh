#!/usr/bin/env bash
# Restore Home Assistant from a restic backup.
#
#     ./scripts/restore.sh --target drill --snapshot latest   # drill: isolated, port 8124, does not touch prod
#     ./scripts/restore.sh --target prod  --snapshot latest   # for real: stops prod, overwrites its data
#
# Port of the k8s version — no kubectl, no scratch namespace. A dedicated
# bridge network plus a second, throwaway Postgres container play the role
# the scratch namespace used to: full isolation from the live install.
#
# See docs/disaster-recovery.md for the full sequence and the drill checklist.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TARGET=""
SNAPSHOT="latest"
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   TARGET="${2:?}";   shift 2 ;;
    --snapshot) SNAPSHOT="${2:?}"; shift 2 ;;
    --yes)      ASSUME_YES=1; shift ;;
    *) echo "usage: $0 --target drill|prod [--snapshot ID] [--yes]" >&2; exit 2 ;;
  esac
done

[[ "$TARGET" == "drill" || "$TARGET" == "prod" ]] \
  || { echo "usage: $0 --target drill|prod [--snapshot ID] [--yes]" >&2; exit 2; }

RESTIC_IMAGE="restic/restic:0.17.3"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [[ "$TARGET" == "prod" ]]; then
  CONFIG_DIR="/var/lib/smart-home-and-hearth/ha-config"
else
  CONFIG_DIR="/var/lib/smart-home-and-hearth-drill/ha-config"
fi

# ── Guard rail ──────────────────────────────────────────────────────────────
# Restoring over a live install destroys current state. Make that a deliberate,
# typed decision rather than a flag someone copy-pastes.
if [[ "$TARGET" == "prod" && $ASSUME_YES -eq 0 ]]; then
  cat >&2 <<EOF

  ┌────────────────────────────────────────────────────────────────────┐
  │  You are about to restore over the LIVE Home Assistant install.    │
  │                                                                    │
  │  This overwrites ${CONFIG_DIR}
  │  — the entity registry, the Zigbee network database and every     │
  │  dashboard — with the contents of snapshot: ${SNAPSHOT}
  │                                                                    │
  │  Current state that is not in the snapshot will be lost.           │
  │                                                                    │
  │  If you are testing the backup, use the drill target instead:      │
  │      $0 --target drill                                             │
  └────────────────────────────────────────────────────────────────────┘

EOF
  read -rp "  Type 'prod' to confirm: " confirm
  [[ "$confirm" == "prod" ]] || { echo "  Aborted."; exit 1; }
fi

# ── 1. Stop writers ──────────────────────────────────────────────────────────
# Restoring underneath a running recorder produces a corrupt result.
if [[ "$TARGET" == "prod" ]]; then
  say "Stopping Home Assistant"
  sudo systemctl stop homeassistant.service
fi

# ── 2. Restore config + the staged DB dump ──────────────────────────────────
say "Restoring config from snapshot ${SNAPSHOT}"
sudo mkdir -p "$CONFIG_DIR"
podman run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v "$CONFIG_DIR:/config" \
  -v "$STAGING:/staging-out" \
  "$RESTIC_IMAGE" sh -eu -c "
    restic restore '${SNAPSHOT}' --target / --include /config
    restic restore '${SNAPSHOT}' --target /staging-out --include /staging
    ls -lh /staging-out/staging/
  "

if [[ "$TARGET" == "prod" ]]; then
  cat <<NOTE

  The database dump was restored to:
      ${STAGING}/staging/homeassistant.dump

  It is not automatically loaded — pg_restore over a live database is
  destructive and deserves an explicit step. Run it now, then bring Home
  Assistant back up:

    podman exec -i postgres sh -c \\
      'pg_restore -U "\$POSTGRES_USER" -d homeassistant --clean --if-exists' \\
      < ${STAGING}/staging/homeassistant.dump

    sudo systemctl start homeassistant.service

NOTE
  exit 0
fi

# ── 3. Drill: fully isolated, never touches prod's Postgres ────────────────
say "Setting up an isolated drill environment"
podman network exists ha-drill || podman network create ha-drill

DRILL_PG_DIR="/var/lib/smart-home-and-hearth-drill/postgres"
sudo mkdir -p "$DRILL_PG_DIR"
sudo chown -R 999:999 "$DRILL_PG_DIR"

say "Starting a scratch Postgres (does not touch the prod database)"
podman rm -f postgres-drill >/dev/null 2>&1 || true
podman run -d --name postgres-drill --network ha-drill \
  -e POSTGRES_DB=homeassistant -e POSTGRES_USER=ha -e POSTGRES_PASSWORD=drill \
  -v "$DRILL_PG_DIR:/var/lib/postgresql/data" \
  docker.io/library/postgres:16-alpine
until podman exec postgres-drill pg_isready -U ha -d homeassistant >/dev/null 2>&1; do sleep 1; done

say "Restoring the database dump into the drill Postgres"
podman exec -i postgres-drill pg_restore -U ha -d homeassistant --clean --if-exists \
  < "$STAGING/staging/homeassistant.dump"

say "Pointing the drill config at the drill database"
sed -i.bak -E 's#^recorder_db_url:.*#recorder_db_url: "postgresql://ha:drill@postgres-drill:5432/homeassistant"#' \
  "$CONFIG_DIR/secrets.yaml"

say "Starting a scratch Home Assistant (bridge network, port 8124 — no Zigbee dongle, prod owns it)"
podman rm -f homeassistant-drill >/dev/null 2>&1 || true
podman run -d --name homeassistant-drill --network ha-drill \
  -p 127.0.0.1:8124:8123 \
  -e TZ=Europe/Stockholm \
  -v "$CONFIG_DIR:/config" \
  ghcr.io/home-assistant/home-assistant:2026.7.4

cat <<NOTE

Drill environment is up: http://127.0.0.1:8124

Verify — this is the part that matters (docs/disaster-recovery.md § The restore drill):

  [ ] It loads and you can log in with your EXISTING password
  [ ] Devices and entities are present with their ORIGINAL entity IDs
  [ ] Dashboards render as you built them
  [ ] History shows data from before the snapshot (proves the pg_restore)
  [ ] ZHA reports a coordinator even with no dongle attached (proves zigbee.db restored)

Tear down when done:

  podman rm -f homeassistant-drill postgres-drill
  sudo rm -rf /var/lib/smart-home-and-hearth-drill
  podman network rm ha-drill

If any check fails, the backup is not doing its job — fix it now, while you
still have the original.
NOTE
