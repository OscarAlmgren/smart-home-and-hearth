#!/usr/bin/env bash
# Restore Home Assistant from a restic backup.
#
#     ./scripts/restore.sh --target drill --snapshot latest   # drill: isolated, port 8124, does not touch prod
#     ./scripts/restore.sh --target prod  --snapshot latest   # for real: stops prod, overwrites its data
#
# Port of the k8s version — no kubectl, no scratch namespace. A dedicated
# bridge network plays the role the scratch namespace used to: full
# isolation from the live install. No scratch database container is needed
# anymore — the recorder DB is SQLite, a single file that comes back with the
# rest of /config, not a separate dump/restore pipeline.
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

RESTIC_IMAGE="docker.io/restic/restic:0.17.3"

# backup.service supplies the restic credentials via EnvironmentFile=; a
# manual restore has no such wrapper, so read the same file directly.
if [[ -z "${RESTIC_REPOSITORY:-}" && -f .env.prod.secret ]]; then
  set -a; . ./.env.prod.secret; set +a
fi
# Explicit tests rather than "${VAR:?message}": that idiom puts a secret's
# name immediately before a colon and a string, which secret scanners read as
# a hardcoded assignment (GitGuardian flagged all three of these scripts). It
# also states plainly where the value is meant to come from.
for _var in RESTIC_REPOSITORY RESTIC_PASSWORD; do
  if [ -z "${!_var:-}" ]; then
    echo "$_var is not set — put it in .env.prod.secret" >&2
    exit 1
  fi
done
unset _var

# The containers are rootful, so anything but a root invocation needs sudo.
SUDO=()
PODMAN=(podman)
if [[ $EUID -ne 0 ]]; then
  # sudo also resets the environment, and the `-e VAR` flags below take their
  # values *from* it — so the restic credentials have to survive the hop.
  # --preserve-env keeps them out of argv, which `-e VAR=value` would not.
  SUDO=(sudo)
  PODMAN=(sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY podman)
fi

# An absolute RESTIC_REPOSITORY is a host directory that has to be
# bind-mounted into the restic container at the same path. See backup.sh.
REPO_MOUNT=()
if [[ "$RESTIC_REPOSITORY" == /* ]]; then
  REPO_MOUNT=(-v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY")
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING" 2>/dev/null || sudo rm -rf "$STAGING"' EXIT

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [[ "$TARGET" == "prod" ]]; then
  CONFIG_DIR="/var/lib/smart-home-and-hearth/ha-config"
  OTBR_DIR="/var/lib/smart-home-and-hearth/otbr"
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
  │  and the OTBR Thread dataset — the entity registry, the recorder    │
  │  database and every dashboard — with the contents of snapshot:      │
  │  ${SNAPSHOT}
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
# Restoring underneath a running recorder or a running OTBR agent produces a
# corrupt result.
if [[ "$TARGET" == "prod" ]]; then
  say "Stopping Home Assistant and OTBR"
  sudo systemctl stop homeassistant.service otbr.service
fi

# ── 2. Restore config + the staged DB snapshot ──────────────────────────────
# home-assistant_v2.db* is excluded from the /config backup (it's live
# WAL-mode SQLite — see podman/restic-excludes.txt), so /config comes back
# without a recorder DB. The consistent snapshot backed up from /staging
# (scripts/backup.sh's VACUUM INTO output) becomes the restored DB file.
say "Restoring config from snapshot ${SNAPSHOT}"
sudo mkdir -p "$CONFIG_DIR"
"${PODMAN[@]}" run --rm \
  "${REPO_MOUNT[@]}" \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v "$CONFIG_DIR:/config" \
  -v "$STAGING:/staging-out" \
  --entrypoint sh \
  "$RESTIC_IMAGE" -eu -c "
    restic restore '${SNAPSHOT}' --target / --include /config
    restic restore '${SNAPSHOT}' --target /staging-out --include /staging
    ls -lh /staging-out/staging/
  "

say "Installing the restored recorder database"
sudo cp "$STAGING/staging/home-assistant_v2.db" "$CONFIG_DIR/home-assistant_v2.db"
sudo rm -f "$CONFIG_DIR/home-assistant_v2.db-shm" "$CONFIG_DIR/home-assistant_v2.db-wal"

if [[ "$TARGET" == "prod" ]]; then
  say "Restoring the OTBR Thread dataset"
  sudo mkdir -p "$OTBR_DIR"
  "${PODMAN[@]}" run --rm \
    "${REPO_MOUNT[@]}" \
    -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    -v "$OTBR_DIR:/otbr" \
    "$RESTIC_IMAGE" restore "${SNAPSHOT}" --target / --include /otbr

  say "Starting Home Assistant and OTBR"
  sudo systemctl start otbr.service homeassistant.service
  exit 0
fi

# ── 3. Drill: fully isolated, never touches prod ────────────────────────────
say "Setting up an isolated drill environment"
"${PODMAN[@]}" network exists ha-drill || "${PODMAN[@]}" network create ha-drill

say "Starting a scratch Home Assistant (bridge network, port 8124 — no radios, prod owns them)"
"${PODMAN[@]}" rm -f homeassistant-drill >/dev/null 2>&1 || true
"${PODMAN[@]}" run -d --name homeassistant-drill --network ha-drill \
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
  [ ] History shows data from before the snapshot (proves the DB restore)
  [ ] The OTBR Thread dataset is in the snapshot: restic ls ${SNAPSHOT} /otbr
      lists a *.data settings file (the drill doesn't start an OTBR; prod
      owns the radio). HA's copy of the dataset is in /config/.storage/thread.datasets.

Tear down when done:

  sudo podman rm -f homeassistant-drill
  sudo rm -rf /var/lib/smart-home-and-hearth-drill
  sudo podman network rm ha-drill

If any check fails, the backup is not doing its job — fix it now, while you
still have the original.
NOTE
