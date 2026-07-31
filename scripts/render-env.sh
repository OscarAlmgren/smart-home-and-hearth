#!/usr/bin/env bash
# Keeps .env.<env> and k8s/overlays/<env>/kustomization.yaml agreeing.
#
# Kustomize can read .env files directly into a ConfigMap (configMapGenerator
# `envs:`), which covers TZ. It cannot set a container image tag from a
# ConfigMap — an image tag is part of the pod spec, resolved at build time —
# so HA_VERSION has to be mirrored into the overlay's `images:` block.
#
# That is a duplication, and duplication drifts. This script is the guard:
#
#   ./scripts/render-env.sh --check    verify they agree (CI uses this)
#   ./scripts/render-env.sh --write    copy .env.* -> overlays
#
# Also validates TZ, because `Etc/Stockholm` is not a tzdata zone and glibc
# silently falls back to UTC rather than erroring — which puts every timestamp
# and every time-based automation 1-2 h out with no visible cause.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODE="${1:---check}"
ENVS=(dev test prod)
FAILED=0

case "$MODE" in
  --check|--write) ;;
  *) echo "usage: $0 [--check|--write]" >&2; exit 2 ;;
esac

# Read KEY from a .env file, ignoring comments and surrounding whitespace.
env_value() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$file" \
    | tail -1 \
    | sed 's/[[:space:]]*$//'
}

overlay_tag() {
  local file="$1"
  awk '/^images:/{f=1} f&&/newTag:/{print $2; exit}' "$file"
}

for env in "${ENVS[@]}"; do
  envfile=".env.${env}"
  # prod is driven by .env.prod but its overlay directory is named prod too;
  # kept explicit in case that ever stops being true.
  overlay="k8s/overlays/${env}/kustomization.yaml"

  if [[ ! -f "$envfile" ]]; then
    echo "MISSING  $envfile" >&2; FAILED=1; continue
  fi
  if [[ ! -f "$overlay" ]]; then
    echo "MISSING  $overlay" >&2; FAILED=1; continue
  fi

  ha_version="$(env_value "$envfile" HA_VERSION)"
  tz="$(env_value "$envfile" TZ)"
  tag="$(overlay_tag "$overlay")"

  # ── HA_VERSION must be pinned ──────────────────────────────────────────
  if [[ -z "$ha_version" ]]; then
    echo "FAIL     $envfile: HA_VERSION is not set" >&2; FAILED=1
  elif [[ "$ha_version" =~ ^(stable|latest|beta|dev)$ ]]; then
    echo "FAIL     $envfile: HA_VERSION='$ha_version' is a floating tag." >&2
    echo "         Pin an exact version (e.g. 2026.7.4) — a floating tag means" >&2
    echo "         two syncs of the same commit can run different software." >&2
    FAILED=1
  fi

  # ── TZ must be a real zone ─────────────────────────────────────────────
  if [[ -z "$tz" ]]; then
    echo "FAIL     $envfile: TZ is not set" >&2; FAILED=1
  elif [[ "$tz" == Etc/* && ! "$tz" =~ ^Etc/(UTC|GMT|GMT[+-][0-9]{1,2}|Universal|Greenwich)$ ]]; then
    echo "FAIL     $envfile: TZ='$tz' is not a valid tzdata zone." >&2
    echo "         Etc/ contains only UTC, GMT and GMT+-N. glibc falls back to" >&2
    echo "         UTC silently — did you mean Europe/${tz#Etc/}?" >&2
    FAILED=1
  elif [[ -d /usr/share/zoneinfo ]] && [[ ! -f "/usr/share/zoneinfo/$tz" ]]; then
    echo "FAIL     $envfile: TZ='$tz' not found in /usr/share/zoneinfo" >&2
    FAILED=1
  fi

  # ── .env <-> overlay agreement ─────────────────────────────────────────
  if [[ "$MODE" == "--write" ]]; then
    if [[ "$tag" != "$ha_version" ]]; then
      # Only touch the newTag line inside the images: block.
      awk -v want="$ha_version" '
        /^images:/ { inimg = 1 }
        inimg && /newTag:/ && !done {
          sub(/newTag:.*/, "newTag: " want); done = 1
        }
        { print }
      ' "$overlay" > "$overlay.tmp" && mv "$overlay.tmp" "$overlay"
      echo "WROTE    $overlay: newTag $tag -> $ha_version"
    else
      echo "OK       $env: $ha_version"
    fi
  else
    if [[ "$tag" != "$ha_version" ]]; then
      echo "FAIL     $env: HA_VERSION='$ha_version' in $envfile but" >&2
      echo "         newTag='$tag' in $overlay" >&2
      echo "         Run: ./scripts/render-env.sh --write" >&2
      FAILED=1
    else
      echo "OK       $env: $ha_version, $tz"
    fi
  fi
done

if [[ $FAILED -ne 0 ]]; then
  echo >&2
  echo "render-env: checks failed" >&2
  exit 1
fi

echo "render-env: all environments consistent"
