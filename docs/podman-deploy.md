# Podman deployment (replaces MicroK8s)

**Status: Home Assistant + Postgres + backup/restore.** Monitoring (Alloy)
and the git-pull deploy loop that replaces Argo CD are not ported yet. `k8s/`
and `argocd/` are left in place for reference until the cutover is confirmed
working; they are not deleted by this doc.

## Why

MicroK8s never got a workload running on this box (no `ha-prod` namespace, no
Argo CD `Application` ever registered — see the Aug 6 incident notes), and its
control plane (`kubelite`, Calico, CoreDNS, Sealed Secrets controller) was
consuming a meaningful share of a 2-core / ~4.8 GiB machine before any of that
work even started. Single-node gets none of Kubernetes' actual value
(multi-node scheduling, cross-node self-healing) while paying its full
resource tax. Podman gets the same containers running with none of it.

This server ran Home Assistant successfully via plain `docker compose` before
the SSD failure that forced the MicroK8s rebuild — this is a return to that
shape, not new territory for this hardware.

## What changed from the MicroK8s version

| k8s concept | Podman equivalent |
|---|---|
| `Deployment` / `StatefulSet` | Quadlet `.container` unit → systemd service |
| PVC (`hostpath-storage`) | Bind mount under `/var/lib/smart-home-and-hearth/` |
| `sync-config` initContainer | `scripts/sync-ha-config.sh`, run by `ha-sync-config.service` before Home Assistant starts |
| Sealed Secrets | Plain files: `config/secrets.yaml` (HA's own secrets) + `.env.prod.secret` (Postgres/Grafana Cloud/restic credentials), both gitignored, `chmod 600` |
| `livenessProbe` / `readinessProbe` | `HealthCmd=` + `HealthOnFailure=restart` |
| CrashLoopBackOff | `StartLimitBurst=5` / `StartLimitIntervalSec=600` in `[Service]` — 5 restarts in 10 minutes, then stop and require a human, same shape the Argo CD `retry:` block used |
| Backup `CronJob` | `podman/backup.timer` + `podman/backup.service`, running `scripts/backup.sh` — see docs/disaster-recovery.md |
| `scripts/restore.sh` (scratch namespace) | `scripts/restore.sh --target drill` — scratch bridge network + throwaway Postgres instead of a namespace |
| Argo CD GitOps sync | Not yet ported — see Known gaps below |

## Secrets

Two files, both gitignored, both `chmod 600`, neither ever committed:

- **`config/secrets.yaml`** — copy from `config/secrets.yaml.example`. Home
  Assistant's own secrets (home name/location, `recorder_db_url` with the
  Postgres credentials embedded in the connection string, the Prometheus
  token used for documentation).
- **`.env.prod.secret`** — copy from `.env.prod.secret.example`. Postgres's
  own `POSTGRES_USER`/`POSTGRES_PASSWORD` (**must match** what's embedded in
  `recorder_db_url` above — nothing checks this automatically, same caveat
  the Sealed Secret version had), Grafana Cloud credentials, restic
  credentials.

## Install

```bash
git clone git@github.com:OscarAlmgren/smart-home-and-hearth.git /opt/smart-home-and-hearth
cd /opt/smart-home-and-hearth
./scripts/bootstrap-podman.sh
```

Follow the printed next steps (secrets, Zigbee device path, enabling the
units). Full sequence is in `scripts/bootstrap-podman.sh`'s own output.

## Verification

```bash
systemctl status postgres.service homeassistant.service ha-sync-config.service
journalctl -u homeassistant.service -f          # watch first boot
curl -sf http://localhost:8123/ >/dev/null && echo ok
podman exec postgres psql -U ha -d homeassistant -c '\dt'   # HA tables exist
```

- [ ] Home Assistant reachable at `http://<server-ip>:8123`; onboarding completes
- [ ] Recorder is on Postgres — `\dt` shows HA tables, **no `home-assistant_v2.db`** in `/var/lib/smart-home-and-hearth/ha-config`
- [ ] `systemctl reboot` — all three units come back on their own (`WantedBy=multi-user.target`)
- [ ] Edit `config/configuration.yaml` in git, `git pull` on the server, `systemctl restart homeassistant.service` — change takes effect (manual for now; see Known gaps)
- [ ] `sudo systemctl start backup.service` (runs it once, on demand) completes without error — `journalctl -u backup.service`
- [ ] **Restore drill** — `./scripts/restore.sh --target drill --snapshot latest`, then work through the checklist in docs/disaster-recovery.md § The restore drill. Do this before trusting this deployment with anything real.

## Known gaps — not yet ported

- **Monitoring.** Alloy's k8s-specific scrape targets (kubelet, cAdvisor,
  kube-state-metrics) have no equivalent without a cluster and need to be
  dropped from its config, not just re-pointed.
- **GitOps loop.** No automated `git pull` + restart yet — deploying a change
  today means `git pull && sudo systemctl restart homeassistant.service` by
  hand on the server.
MicroK8s itself has been removed from henrybook (`sudo snap remove microk8s
--purge`, 2026-08-06). It never had a workload running on it, and all four
`k8s/overlays/prod/secrets/*.sealed.yaml` files were still unfilled
placeholders (`encryptedData: {}`) — there was nothing to extract first.
Verified clean afterward: no leftover Calico interfaces, no leftover
`cali`/`kube` iptables chains, `/var/snap/microk8s` gone, disk usage
74%→59%, load average ~2.3-2.7→~1.0-1.5 on the idle box. `k8s/` and
`argocd/` remain in git as reference for the manifests this was ported from.
