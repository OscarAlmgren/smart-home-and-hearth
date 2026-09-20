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
# Sysctl= under Network=host, and its entrypoint's NAT44 setup needs netfilter
# kernel modules present) - see podman/host-config/ and
# docs/podman-deploy.md § Host prerequisites.
#
# IPv6 forwarding makes systemd-networkd stop accepting router advertisements
# unless netplan pins accept-ra. Applying netplan over SSH can drop the
# connection, so this script only checks for it.
say "Installing OTBR host prerequisites (sysctls, kernel modules)"
if ! sudo netplan get ethernets.enp3s0.accept-ra 2>/dev/null | grep -qx true; then
  die "Set 'accept-ra: true' for enp3s0 in /etc/netplan/ and apply it before enabling IPv6 forwarding - see docs/podman-deploy.md § Host prerequisites."
fi
sudo cp podman/host-config/99-otbr-forwarding.conf /etc/sysctl.d/
sudo sysctl --load=/etc/sysctl.d/99-otbr-forwarding.conf >/dev/null
sudo cp podman/host-config/otbr-nat-modules.conf /etc/modules-load.d/
sudo modprobe -a iptable_nat iptable_mangle iptable_filter ip6table_filter
# Restarts otbr.service when the dongle is re-plugged; otbr.container's
# BindsTo= only propagates stop, so without this a knocked-out cable leaves
# Thread down until someone notices.
sudo cp podman/host-config/60-otbr-thread-dongle.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules

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

  2. Start Thread and Matter. otbr.container drives the Connect ZBT-1
     (OpenThread RCP) as Home Assistant's Thread Border Router; matter-server
     reaches Thread devices through it (see docs/hardware.md § Radios).

     NOTE: these are Quadlet units (podman/*.container) — systemd's own
     `enable` doesn't apply to them (their WantedBy= is already applied by
     the generator at daemon-reload, which just ran above). Just start them:
         sudo systemctl start otbr.service matter-server.service

     On a fresh /var/lib/smart-home-and-hearth/otbr there is no Thread
     network yet: form or restore one before adding the Open Thread Border
     Router integration in HA — see docs/podman-deploy.md § Thread network.

     The ZBT-1 is the Thread radio, not a Zigbee coordinator. Do not pass it
     to homeassistant.container. If the radio is ever swapped, update the
     by-id path, both device units and the baud/flow-control settings in
     podman/otbr.container — see docs/hardware.md § Radios.

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
