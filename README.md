# homeassistant

Foundational, container-based Home Assistant setup. This repo is meant to be
cloned onto the Ubuntu server and run with Docker Compose — no local HA
install, no host Python.

## Layout

```
docker-compose.yml    # Home Assistant container definition
.env.example           # copy to .env — image tag + timezone
config/                # mounted into the container at /config
  configuration.yaml
  automations.yaml
  scripts.yaml
  scenes.yaml
  secrets.yaml.example # copy to secrets.yaml — never committed
scripts/
  deploy.sh             # git pull + docker compose pull + up -d
```

## First-time setup (on the Ubuntu server)

1. Clone this repo and `cd` into it.
2. `cp .env.example .env` and edit (timezone, HA version pin).
3. `cp config/secrets.yaml.example config/secrets.yaml` and fill in real values.
4. `./scripts/deploy.sh`

Home Assistant will come up at `http://<server-ip>:8123`.

## Updating

Push config changes from wherever you edit, then on the server:

```
./scripts/deploy.sh
```

This pulls the latest git state, pulls the latest container image, and
restarts the stack.

## Notes

- `docker-compose.yml` uses `network_mode: host` and `privileged: true` —
  the standard upstream baseline, needed for mDNS/SSDP discovery and USB
  devices (Zigbee/Z-Wave sticks) if/when those are added.
- `config/secrets.yaml` and `.env` are gitignored — only the `.example`
  templates are tracked.
- This is intentionally minimal (core Home Assistant only). Additional
  containers (MQTT broker, Zigbee2MQTT, ESPHome, etc.) are left for the
  next planning pass.
