#!/usr/bin/env bash
# Pull the latest config from git and (re)start Home Assistant via Docker Compose.
# Run this on the Ubuntu server, from anywhere: it cd's to the repo root itself.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ ! -f .env ]; then
  echo "==> No .env found. Copy .env.example to .env and set it up first." >&2
  exit 1
fi

if [ ! -f config/secrets.yaml ]; then
  echo "==> No config/secrets.yaml found. Copy config/secrets.yaml.example and fill it in first." >&2
  exit 1
fi

echo "==> Pulling latest config from git..."
git pull --ff-only

echo "==> Pulling latest container image..."
docker compose pull

echo "==> Starting Home Assistant..."
docker compose up -d

echo "==> Done. Tailing logs (Ctrl+C to stop tailing; container keeps running)..."
docker compose logs -f --tail=50
