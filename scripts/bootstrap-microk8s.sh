#!/usr/bin/env bash
# One-time build of the MicroK8s cluster on henrybook.
#
# Idempotent — safe to re-run. Run it on the server, not from your laptop.
#
#     ./scripts/bootstrap-microk8s.sh
#
# See docs/microk8s-bootstrap.md for what each step does and how to verify it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
say "Preflight"

[[ "$(uname -s)" == "Linux" ]] || die "Run this on the server, not on macOS."

# Canonical recommends 20 GB for MicroK8s. This node has ~12 GiB total, which
# is knowingly under that — so check free space and refuse to make it worse.
avail_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
say "Free space on /: ${avail_gb}G"
if (( avail_gb < 4 )); then
  die "Less than 4G free on /. Free space before continuing — disk exhaustion is the most likely failure mode on this hardware (docs/hardware.md)."
elif (( avail_gb < 8 )); then
  warn "Under 8G free. This will work but leaves little headroom for images."
fi

# Snap keeps old revisions of every snap, which on a 12 GiB disk is real money.
say "Limiting snap revision retention"
sudo snap set system refresh.retain=2

# ── MicroK8s ────────────────────────────────────────────────────────────────
if ! command -v microk8s >/dev/null 2>&1; then
  say "Installing MicroK8s"
  sudo snap install microk8s --classic --channel=1.31/stable
  sudo usermod -a -G microk8s "$USER"
  sudo mkdir -p ~/.kube && sudo chown -R "$USER" ~/.kube
  warn "You have been added to the microk8s group. Log out and back in, then re-run this script."
  exit 0
else
  say "MicroK8s already installed"
fi

microk8s status --wait-ready --timeout 300

# ── Addons ──────────────────────────────────────────────────────────────────
# Deliberately minimal. Every addon is disk and memory that Home Assistant
# needs more.
#
#   dns              required — Home Assistant resolves the Postgres Service
#   hostpath-storage required — PVC backing on a single node
#
# NOT enabled:
#   ingress       phase 3 (remote access). Nothing is exposed beyond the LAN yet.
#   cert-manager  phase 3, needs a domain
#   observability full Prometheus/Grafana stack — we ship to Grafana Cloud
#                 instead precisely because this node cannot host it
#   metrics-server not needed; kube-state-metrics + Alloy cover it
say "Enabling addons"
microk8s enable dns
microk8s enable hostpath-storage

# ── Kustomize load restrictor ───────────────────────────────────────────────
# k8s/base reads ../../config/ and ../../.env.*, outside its own directory.
# Kustomize forbids that by default. CI passes the same flag — if these two
# ever diverge, CI goes green and the cluster fails to sync.
say "Configuring Argo CD kustomize build options"
microk8s kubectl create namespace argocd --dry-run=client -o yaml | microk8s kubectl apply -f -

# ── Sealed Secrets ──────────────────────────────────────────────────────────
say "Installing Sealed Secrets controller"
microk8s kubectl create namespace sealed-secrets --dry-run=client -o yaml | microk8s kubectl apply -f -
microk8s kubectl apply -f \
  https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml
microk8s kubectl -n sealed-secrets rollout status deploy/sealed-secrets-controller --timeout=300s

# Lets the backup CronJob export the sealing keys. Applied directly rather than
# through Kustomize: it lives in the sealed-secrets namespace, and the overlay's
# `namespace:` transformer would silently rewrite it into ha-prod, where it
# grants nothing.
say "Granting the backup job access to the sealing keys"
microk8s kubectl apply -f k8s/cluster/backup-sealing-key-rbac.yaml

# ── Argo CD (core mode) ─────────────────────────────────────────────────────
# core-install.yaml: application controller, repo server, ApplicationSet
# controller and redis. No API server, no web UI, no Dex — roughly 700 Mi less
# than the full install, which matters on 6 GiB.
say "Installing Argo CD (core mode)"
microk8s kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/core-install.yaml

microk8s kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--load-restrictor LoadRestrictionsNone"}}'

microk8s kubectl -n argocd rollout restart statefulset/argocd-application-controller
microk8s kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

cat <<'EOF'

────────────────────────────────────────────────────────────────────────────
Cluster is up. Remaining steps, in order — each depends on the previous:

  1. Give Argo CD read access to the repo:
         microk8s kubectl -n argocd create secret generic repo-smart-home \
           --from-literal=type=git \
           --from-literal=url=git@github.com:OscarAlmgren/smart-home-and-hearth.git \
           --from-file=sshPrivateKey=/path/to/deploy-key
         microk8s kubectl -n argocd label secret repo-smart-home \
           argocd.argoproj.io/secret-type=repository

  2. Seal the real secrets and commit them:
         ./scripts/seal-secrets.sh

  3. Put the actual Zigbee device path into
     k8s/overlays/prod/patches/zigbee-device.yaml:
         ls -l /dev/serial/by-id/
     Use the by-id path. Never /dev/ttyACM0.

  4. Register the Argo CD applications:
         microk8s kubectl apply -f argocd/project.yaml
         microk8s kubectl apply -f argocd/applications/

  5. RUN THE RESTORE DRILL before trusting any of this:
         docs/disaster-recovery.md § The restore drill
────────────────────────────────────────────────────────────────────────────
EOF
