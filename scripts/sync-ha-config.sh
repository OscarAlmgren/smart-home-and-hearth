#!/usr/bin/env bash
# Copies git-managed Home Assistant config from the repo checkout into the
# runtime config directory. Run before (re)starting the homeassistant
# container — see podman/ha-sync-config.service.
#
# Port of the sync-config initContainer from k8s/base/homeassistant/deployment.yaml.
# Runs directly on the host rather than in a container: with a bind-mounted
# /config there is no need for the ConfigMap/Secret indirection k8s required.
#
#     ./scripts/sync-ha-config.sh REPO_DIR RUNTIME_DIR
set -euo pipefail

REPO_DIR="${1:?usage: sync-ha-config.sh REPO_DIR RUNTIME_DIR}"
RUNTIME_DIR="${2:?usage: sync-ha-config.sh REPO_DIR RUNTIME_DIR}"

echo "==> syncing git-managed config into $RUNTIME_DIR"

# Git owns these. Overwrite unconditionally.
cp -f "$REPO_DIR/config/configuration.yaml" "$RUNTIME_DIR/configuration.yaml"

# Clear packages/ first so a package deleted in git actually disappears from
# the running config, rather than lingering forever because nothing ever
# removes it.
mkdir -p "$RUNTIME_DIR/packages"
rm -f "$RUNTIME_DIR/packages"/*.yaml
cp -f "$REPO_DIR/config/packages/"*.yaml "$RUNTIME_DIR/packages/"

# Home Assistant's UI editors WRITE these files. Copying over them on every
# restart would silently delete every automation, script and scene created
# through the UI. Seed them only if absent (-n = no clobber).
cp -n "$REPO_DIR/config/automations.yaml" "$RUNTIME_DIR/automations.yaml" || true
cp -n "$REPO_DIR/config/scripts.yaml"     "$RUNTIME_DIR/scripts.yaml"     || true
cp -n "$REPO_DIR/config/scenes.yaml"      "$RUNTIME_DIR/scenes.yaml"     || true

# config/secrets.yaml is gitignored and lives directly in the checkout on the
# server (same pattern the docker-compose escape hatch already used) — see
# config/secrets.yaml.example.
cp -f "$REPO_DIR/config/secrets.yaml" "$RUNTIME_DIR/secrets.yaml"
chmod 600 "$RUNTIME_DIR/secrets.yaml"

echo "==> done"
