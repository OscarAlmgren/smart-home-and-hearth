#!/usr/bin/env bash
# Run any restic command against the configured repository.
#
#     ./scripts/restic.sh snapshots
#     ./scripts/restic.sh ls latest /otbr
#     ./scripts/restic.sh stats latest
#     ./scripts/restic.sh restore latest --target /tmp/out --include /config/.storage/thread.datasets
#
# Exists because the repository is a local path (see docs/disaster-recovery.md)
# and restic runs in a container: without a bind-mount at the same path restic
# reports "repository does not exist", which points at the wrong problem.
# Credentials come from .env.prod.secret — the same file backup.service reads.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -z "${RESTIC_REPOSITORY:-}" && -f .env.prod.secret ]]; then
  set -a; . ./.env.prod.secret; set +a
fi
: "${RESTIC_REPOSITORY:?not set — put it in .env.prod.secret}"
: "${RESTIC_PASSWORD:?not set — put it in .env.prod.secret}"

RESTIC_IMAGE="docker.io/restic/restic:0.17.3"

# The containers are rootful. sudo also resets the environment, and the
# `-e VAR` flags below take their values *from* it, so the credentials have to
# survive the hop; --preserve-env keeps them out of argv.
PODMAN=(podman)
if [[ $EUID -ne 0 ]]; then
  PODMAN=(sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY podman)
fi

REPO_MOUNT=()
if [[ "$RESTIC_REPOSITORY" == /* ]]; then
  REPO_MOUNT=(-v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY")
fi

exec "${PODMAN[@]}" run --rm -i \
  "${REPO_MOUNT[@]}" \
  -e RESTIC_REPOSITORY -e RESTIC_PASSWORD -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  "$RESTIC_IMAGE" "$@"
