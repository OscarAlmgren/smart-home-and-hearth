#!/usr/bin/env bash
# One-time setup of Podman on henrybook, replacing MicroK8s.
#
# Idempotent — safe to re-run. Run it on the server, not from your laptop.
#
#     ./scripts/bootstrap-podman.sh
#
# See docs/podman-deploy.md for what each step does and how to verify it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "Run this on the server, not on macOS."

# ── Preflight ───────────────────────────────────────────────────────────────
say "Preflight"

avail_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
say "Free space on /: ${avail_gb}G"
if (( avail_gb < 2 )); then
  die "Less than 2G free on /. Free space before continuing — see docs/hardware.md."
fi

# ── Podman ──────────────────────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
  say "Installing Podman"
  sudo apt-get update
  sudo apt-get install -y podman
else
  say "Podman already installed ($(podman --version))"
fi

# Quadlets need Podman 4.4+; the generator ships inside the podman package
# itself on modern Ubuntu, no separate install.
podman_major_minor=$(podman --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
say "Podman version: $podman_major_minor"

# ── Runtime directories ─────────────────────────────────────────────────────
# Deliberately outside the git checkout: `git clean`/`git pull` must never be
# able to touch runtime state (recorder DB, .storage, entity registry).
say "Creating runtime data directories"
sudo mkdir -p /var/lib/smart-home-and-hearth/ha-config
sudo mkdir -p /var/lib/smart-home-and-hearth/postgres
# Postgres in the official image runs as uid 999.
sudo chown -R 999:999 /var/lib/smart-home-and-hearth/postgres

# ── Quadlets and plain units ─────────────────────────────────────────────────
say "Installing Quadlet units"
sudo mkdir -p /etc/containers/systemd
sudo cp podman/postgres.container podman/homeassistant.container /etc/containers/systemd/
sudo cp podman/ha-sync-config.service podman/backup.service podman/backup.timer /etc/systemd/system/
sudo systemctl daemon-reload

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
Podman is ready. Remaining steps, in order:

  1. Create the two secret files on the server (plain files now, not Sealed
     Secrets — see docs/podman-deploy.md § Secrets):
         cp config/secrets.yaml.example config/secrets.yaml
         cp .env.prod.secret.example .env.prod.secret
         # edit both with real values — POSTGRES_USER/PASSWORD in
         # .env.prod.secret MUST match the credentials embedded in
         # config/secrets.yaml's recorder_db_url
         chmod 600 config/secrets.yaml .env.prod.secret

  2. Put the actual Zigbee device path into podman/homeassistant.container
     once the dongle is fitted:
         ls -l /dev/serial/by-id/

  3. Start it:
         sudo systemctl enable --now postgres.service
         sudo systemctl enable --now ha-sync-config.service
         sudo systemctl enable --now homeassistant.service
         sudo systemctl enable --now backup.timer

  4. Run the restore drill BEFORE trusting any of this — see
     docs/disaster-recovery.md § The restore drill:
         ./scripts/restore.sh --target drill --snapshot latest

  5. Verify:      docs/podman-deploy.md § Verification
────────────────────────────────────────────────────────────────────────────
EOF
