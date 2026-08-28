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
RESTIC_IMAGE="restic/restic:0.17.3"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# The recorder DB is a live WAL-mode SQLite file — a filesystem copy of it
# mid-write is torn and unrestorable (podman/restic-excludes.txt excludes it
# from the /config backup below for exactly this reason). VACUUM INTO
# produces a consistent snapshot even while Home Assistant has the file open,
# same role pg_dump used to play. Snapshot goes to the container's own /tmp
# (never touches the bind-mounted /config), then out via `podman cp`.
echo "==> snapshotting recorder database"
podman exec homeassistant python3 -c \
  "import sqlite3; c = sqlite3.connect('/config/home-assistant_v2.db'); c.execute(\"VACUUM INTO '/tmp/home-assistant_v2.snapshot.db'\"); c.close()"
podman cp homeassistant:/tmp/home-assistant_v2.snapshot.db "$STAGING/home-assistant_v2.db"
podman exec homeassistant rm -f /tmp/home-assistant_v2.snapshot.db
ls -lh "$STAGING/home-assistant_v2.db"

echo "==> backing up"
podman run --rm \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -v "$STAGING:/staging:ro" \
  -v "$CONFIG_DIR:/config:ro" \
  -v "$PWD/podman/restic-excludes.txt:/etc/restic/excludes.txt:ro" \
  "$RESTIC_IMAGE" sh -eu -c '
    if ! restic cat config >/dev/null 2>&1; then
      echo "==> initialising restic repository"
      restic init
    fi

    echo "==> backing up"
    restic backup \
      --host homeassistant \
      --tag automated \
      --exclude-file /etc/restic/excludes.txt \
      /staging /config

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
