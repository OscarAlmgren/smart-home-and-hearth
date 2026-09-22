#!/usr/bin/env bash
# Nightly backup: recorder DB snapshot + config -> restic. Run by
# podman/backup.service, scheduled by podman/backup.timer.
#
# Port of k8s/base/backup/cronjob.yaml. The "export Sealed Secrets private
# keys" stage is gone — there is no Sealed Secrets controller anymore, so
# there is no sealing key that a restore depends on.
#
# Needs RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY in the environment — backup.service supplies these
# via EnvironmentFile=.env.prod.secret.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONFIG_DIR="/var/lib/smart-home-and-hearth/ha-config"
OTBR_DIR="/var/lib/smart-home-and-hearth/otbr"
RESTIC_IMAGE="docker.io/restic/restic:0.17.3"

# Explicit tests rather than "${VAR:?message}": that idiom puts a secret's
# name immediately before a colon and a string, which secret scanners read as
# a hardcoded assignment (GitGuardian flagged all three of these scripts). It
# also states plainly where the value is meant to come from.
for _var in RESTIC_REPOSITORY RESTIC_PASSWORD; do
  if [ -z "${!_var:-}" ]; then
    echo "$_var is not set — backup.service supplies it from .env.prod.secret" >&2
    exit 1
  fi
done
unset _var

# The containers are rootful, so anything but a root invocation needs sudo.
# Under backup.service this already runs as root and SUDO stays empty.
SUDO=()
PODMAN=(podman)
if [[ $EUID -ne 0 ]]; then
  # sudo also resets the environment, and the `-e VAR` flags below take their
  # values *from* it — so the restic credentials have to survive the hop.
  # --preserve-env keeps them out of argv, which `-e VAR=value` would not.
  SUDO=(sudo)
  PODMAN=(sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY podman)
fi

# An absolute RESTIC_REPOSITORY is a *host* directory, but restic runs inside
# a container — bind-mount it at the same path so one value works both inside
# and outside. S3/SFTP/REST targets are URLs and need no mount.
REPO_MOUNT=()
if [[ "$RESTIC_REPOSITORY" == /* ]]; then
  [[ -d "$RESTIC_REPOSITORY" ]] || "${SUDO[@]}" mkdir -p "$RESTIC_REPOSITORY"
  REPO_MOUNT=(-v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY")
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING" 2>/dev/null || sudo rm -rf "$STAGING"' EXIT

# The recorder DB is a live WAL-mode SQLite file — a filesystem copy of it
# mid-write is torn and unrestorable (podman/restic-excludes.txt excludes it
# from the /config backup below for exactly this reason). VACUUM INTO
# produces a consistent snapshot even while Home Assistant has the file open,
# same role pg_dump used to play. Snapshot goes to the container's own /tmp
# (never touches the bind-mounted /config), then out via `podman cp`.
echo "==> snapshotting recorder database"
"${PODMAN[@]}" exec homeassistant python3 -c \
  "import sqlite3; c = sqlite3.connect('/config/home-assistant_v2.db'); c.execute(\"VACUUM INTO '/tmp/home-assistant_v2.snapshot.db'\"); c.close()"
"${PODMAN[@]}" cp homeassistant:/tmp/home-assistant_v2.snapshot.db "$STAGING/home-assistant_v2.db"
"${PODMAN[@]}" exec homeassistant rm -f /tmp/home-assistant_v2.snapshot.db
ls -lh "$STAGING/home-assistant_v2.db"

echo "==> backing up"
"${PODMAN[@]}" run --rm \
  "${REPO_MOUNT[@]}" \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v "$STAGING:/staging:ro" \
  -v "$CONFIG_DIR:/config:ro" \
  -v "$OTBR_DIR:/otbr:ro" \
  -v "$PWD/podman/restic-excludes.txt:/etc/restic/excludes.txt:ro" \
  --entrypoint sh \
  "$RESTIC_IMAGE" -eu -c '
    if ! restic cat config >/dev/null 2>&1; then
      echo "==> initialising restic repository"
      restic init
    fi

    echo "==> backing up"
    # /otbr holds the Thread network dataset (keys, PAN ID, channel). Losing
    # it means forming a new Thread network and re-commissioning every Thread
    # device, the Thread equivalent of /config/zigbee.db.
    restic backup \
      --host homeassistant \
      --tag automated \
      --exclude-file /etc/restic/excludes.txt \
      /staging /config /otbr

    echo "==> applying retention"
    restic forget \
      --host homeassistant \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
      --prune

    # Cheap structural check every run. A full --read-data would re-download
    # every pack and is far too slow here; 5% means the whole repo gets
    # verified over a few weeks.
    echo "==> verifying"
    restic check --read-data-subset=5%

    echo "==> done"
    restic snapshots --host homeassistant --latest 3
  '
