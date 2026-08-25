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
# able to touch runtime state (recorder DB — a SQLite file under ha-config,
# .storage, entity registry, Thread network dataset).
say "Creating runtime data directories"
sudo mkdir -p /var/lib/smart-home-and-hearth/ha-config
sudo mkdir -p /var/lib/smart-home-and-hearth/otbr
sudo mkdir -p /var/lib/smart-home-and-hearth/matter-server

# ── OTBR host prerequisites ─────────────────────────────────────────────────
# otbr.container can't set these itself (podman 5.7.0 rejects per-container
# Sysctl= under Network=host, and its entrypoint's own NAT44 setup needs
# netfilter kernel modules present) - see podman/host-config/ and
# docs/podman-deploy.md § Host prerequisites.
say "Installing OTBR host prerequisites (sysctls, kernel modules)"
sudo cp podman/host-config/99-otbr-forwarding.conf /etc/sysctl.d/
sudo sysctl --system >/dev/null
sudo cp podman/host-config/otbr-nat-modules.conf /etc/modules-load.d/
sudo modprobe iptable_nat iptable_mangle iptable_filter ip6table_filter

# ── Quadlets and plain units ─────────────────────────────────────────────────
say "Installing Quadlet units"
sudo mkdir -p /etc/containers/systemd
sudo cp podman/homeassistant.container podman/otbr.container podman/matter-server.container /etc/containers/systemd/
sudo cp podman/ha-sync-config.service podman/backup.service podman/backup.timer /etc/systemd/system/
sudo systemctl daemon-reload

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
Podman is ready. Remaining steps, in order:

  1. Create the two secret files on the server (plain files now, not Sealed
     Secrets — see docs/podman-deploy.md § Secrets):
         cp config/secrets.yaml.example config/secrets.yaml
         cp .env.prod.secret.example .env.prod.secret
         # edit both with real values
         chmod 600 config/secrets.yaml .env.prod.secret

  2. Start Thread/Matter — podman/otbr.container already has the real device
     path for the reflashed Sonoff dongle (confirmed unchanged from its
     Zigbee-firmware days, see docs/hardware.md § Radios). If the dongle is
     ever swapped, re-run `ls -l /dev/serial/by-id/` and update it there.

     NOTE: these are Quadlet units (podman/*.container) — systemd's own
     `enable` doesn't apply to them (their WantedBy= is already applied by
     the generator at daemon-reload, which just ran above). Just start them:
         sudo systemctl start otbr.service
         sudo systemctl start matter-server.service

     Zigbee is deferred until a separate dongle is available — see
     docs/hardware.md § Radios.

  3. Start Home Assistant (also a Quadlet unit — `start`, not `enable`;
     ha-sync-config.service starts automatically as its dependency, no
     separate step needed):
         sudo systemctl start homeassistant.service

  4. OPTIONAL — backups. Skip this for a first deploy. podman/backup.service
     and backup.timer are already installed, but the timer is NOT enabled
     above: with placeholder RESTIC_*/AWS_* values it would just fail every
     night at 03:15. When you're ready (see docs/disaster-recovery.md):
         # fill in real RESTIC_*/AWS_* values in .env.prod.secret first
         sudo systemctl enable --now backup.timer
         ./scripts/restore.sh --target drill --snapshot latest

  5. Verify:      docs/podman-deploy.md § Verification
────────────────────────────────────────────────────────────────────────────
EOF
