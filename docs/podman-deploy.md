# Podman deployment (replaces MicroK8s)

**Status: Home Assistant (SQLite recorder) + OTBR (Thread) + Matter +
backup/restore.** Thread is served by an on-host OpenThread Border Router with
a Connect ZBT-1 as its radio, deployed 2026-09-15 (radio swapped 2026-09-19);
devices are still being moved over from the Google Nest Wifi Thread networks. Monitoring
(Alloy) and the git-pull deploy loop that replaces Argo CD are not ported yet. `k8s/` and `argocd/` are left in place for reference until the
cutover is confirmed working; they are not deleted by this doc.

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
| Sealed Secrets | Plain files: `config/secrets.yaml` (HA's own secrets) + `.env.prod.secret` (Grafana Cloud/restic credentials), both gitignored, `chmod 600` |
| `livenessProbe` / `readinessProbe` | `HealthCmd=` + `HealthOnFailure=restart` |
| CrashLoopBackOff | `StartLimitBurst=10` / `StartLimitIntervalSec=600` in `[Unit]` (systemd ignores them in `[Service]`) — 10 restarts in 10 minutes, then stop and require a human, same shape the Argo CD `retry:` block used |
| Backup `CronJob` | `podman/backup.timer` + `podman/backup.service`, running `scripts/backup.sh` — see docs/disaster-recovery.md |
| `scripts/restore.sh` (scratch namespace) | `scripts/restore.sh --target drill` — scratch bridge network instead of a namespace (no scratch DB container needed; the recorder DB is a SQLite file that restores with the rest of `/config`) |
| Argo CD GitOps sync | Not yet ported — see Known gaps below |

Also new since the MicroK8s version and not a straight port of anything:
`podman/otbr.container` + `podman/matter-server.container`, the containerized
OpenThread Border Router and Matter Server that replace HAOS's supervisor
add-ons. A first OTBR ran 2026-08-25 → 2026-08-28 and was removed in favour of
the Google Nest Wifi border routers; it was re-added 2026-09-15, managed from
HA's Open Thread Border Router integration. See docs/hardware.md § Radios.

## Host prerequisites

`scripts/bootstrap-podman.sh` installs the first two from `podman/host-config/`
and checks for the third. None of them show up in the Quadlet unit files
themselves - it's tempting to put them there and they used to be, until
reality disagreed:

- **OTBR forwarding sysctls** (`net.ipv4.conf.all.forwarding`,
  `net.ipv6.conf.all.forwarding`). `otbr.container` used to set these itself
  via `Sysctl=`, but podman 5.7.0 rejects per-container sysctls under
  `Network=host` ("can't be set since Network Namespace set to host: invalid
  argument") - with host networking the container *is* the host netns, so
  they have to be host-level (`/etc/sysctl.d/99-otbr-forwarding.conf`)
  instead.
- **NAT44 kernel modules** (`iptable_nat`, `iptable_mangle`,
  `iptable_filter`, `ip6table_filter`). OTBR's own container entrypoint runs
  a NAT44 setup step via legacy `iptables` and `die`s outright if these
  aren't loaded ("Table does not exist (do you need to insmod?)").
  `/etc/modules-load.d/otbr-nat-modules.conf` loads them at boot.
- **A udev rule that restarts `otbr.service` when the dongle re-appears**
  (`/etc/udev/rules.d/60-otbr-thread-dongle.rules`). `otbr.container` uses
  `BindsTo=` on the dongle's `.device` unit so an unplug stops the border router
  cleanly rather than crash-looping it against a missing radio — but `BindsTo=`
  only propagates *stop*. Without this rule a knocked-out USB cable takes Thread
  down permanently: on 2026-09-20 a cable swap stopped the unit and nothing
  brought it back when the dongle returned a minute later. The rule matches the
  dongle's USB serial via `ATTRS{}` (not `ID_SERIAL_SHORT`, which isn't set yet
  when these rules run) and sets `SYSTEMD_WANTS=otbr.service`. Verify with
  `systemctl stop otbr.service && sudo udevadm trigger --action=add --sysname-match=ttyUSB0`
  — the unit should come back within ~10 s.
- **`accept-ra: true` for `enp3s0` in `/etc/netplan/`** (renders
  `IPv6AcceptRA=yes`). With IPv6 forwarding on, systemd-networkd otherwise
  stops accepting router advertisements, and the host slowly loses its SLAAC
  address, its IPv6 default route and the RA-learned routes to other Thread
  border routers' networks. Matter devices still homed on another border
  router become unreachable within ~30 minutes. Apply it before the forwarding
  sysctls, ideally with a rollback timer armed
  (`systemd-run --on-active=180 ... netplan apply` of the old file), since a
  bad netplan apply over SSH can cut you off.

The first two surfaced as `otbr.service` crash-looping on a fresh start. See
the Aug 25 incident notes in [disaster-recovery.md](disaster-recovery.md) for
how much damage a crash loop can do before these were understood.

The OTBR image's own startup script also runs `sysctl --system` against the
image's `/etc/sysctl.d`, which under `--privileged` + host networking rewrites
the host's `rp_filter` and the kernel `accept_ra` on `enp3s0`.
`otbr.container` masks that directory with an empty tmpfs (`notmpcopyup`), so
host sysctls stay owned by the files above.

## Thread network

A fresh `/var/lib/smart-home-and-hearth/otbr` has no Thread network. Form it on
the OTBR **before** adding HA's Open Thread Border Router integration: the
integration's setup flow imports HA's *preferred* dataset into any OTBR without
one, which would join someone else's network (on 2026-09-15 that was the Nest
Wifi network).

```bash
ot() { sudo podman exec otbr ot-ctl "$@"; }
ot ifconfig up
ot scan energy 500              # a few passes; prefer 15/20/25 (between Wi-Fi 1/6/11)
ot dataset init new
ot dataset channel 20
ot dataset networkname ha-thread-<panid hex from `ot dataset panid`>
ot dataset commit active
ot thread start
ot state                        # leader within ~30 s
```

Then HA → Settings → Devices & Services → Add integration → **Open Thread
Border Router**, URL `http://127.0.0.1:8081` (REST is loopback-only; HA is
host-networked). There is no auto-discovery for it without Supervisor; the
Thread panel separately lists border routers it sees over `_meshcop._udp`. In
the Thread panel, make the new network the **preferred network**, then sync
Thread credentials to phones from the HA Companion app.

To restore instead of forming, `scripts/restore.sh` restores the `otbr`
directory (the OTBR's settings file) along with `/config`.

## Secrets

Two files, both gitignored, both `chmod 600`, neither ever committed:

- **`config/secrets.yaml`** — copy from `config/secrets.yaml.example`. Home
  Assistant's own secrets (home name/location, `recorder_db_url` pointing at
  the SQLite recorder DB, the Prometheus token used for documentation).
- **`.env.prod.secret`** — copy from `.env.prod.secret.example`. Grafana
  Cloud credentials (not yet wired to anything — see Known gaps) and restic
  credentials (optional for a first deploy — see docs/disaster-recovery.md).

## Install

```bash
git clone git@github.com:OscarAlmgren/smart-home-and-hearth.git /home/oscaralmgren/smart-home-and-hearth
cd /home/oscaralmgren/smart-home-and-hearth
./scripts/bootstrap-podman.sh
```

Follow the printed next steps (secrets, enabling the
units). Full sequence is in `scripts/bootstrap-podman.sh`'s own output.

## Deploying a config change

`config/` is git-managed but Home Assistant reads
`/var/lib/smart-home-and-hearth/ha-config`. `ha-sync-config.service` copies one
to the other — and it is a `oneshot` with `RemainAfterExit=yes`, so **restarting
`homeassistant.service` does not re-run it**: systemd sees the dependency as
already satisfied and Home Assistant restarts against the old files. Restarting
the sync unit instead stops Home Assistant with it (`Requires=`), and does not
bring it back. So:

```bash
git pull
sudo systemctl restart ha-sync-config.service   # re-syncs; stops HA as a dependent
sudo systemctl start homeassistant.service      # start it again
sudo podman exec homeassistant python -m homeassistant --script check_config -c /config
```

Check the runtime copy really changed (`grep` the file under
`/var/lib/smart-home-and-hearth/ha-config/packages/`) before concluding a config
edit had no effect.

## Verification

```bash
systemctl status homeassistant.service ha-sync-config.service otbr.service matter-server.service
journalctl -u homeassistant.service -f          # watch first boot
sudo podman exec otbr ot-ctl state              # leader (or router)
curl -sf http://localhost:8123/ >/dev/null && echo ok
ls -lh /var/lib/smart-home-and-hearth/ha-config/home-assistant_v2.db   # recorder DB exists
```

- [ ] Home Assistant reachable at `http://<server-ip>:8123`; onboarding completes
- [ ] Recorder is on SQLite — `home-assistant_v2.db` exists in `/var/lib/smart-home-and-hearth/ha-config`, no `postgres` container running
- [ ] `otbr.service` is healthy and the Thread network is formed (§ Thread network); the Open Thread Border Router integration is loaded and its network is **preferred** in HA's Thread panel; `ip -6 route` shows its OMR prefix on `wpan0` and the `proto ra` routes still refreshing
- [ ] Add the Matter integration in HA pointing at `ws://127.0.0.1:5580/ws`
- [ ] `systemctl reboot` — all units come back on their own (`WantedBy=multi-user.target`)
- [ ] Edit `config/configuration.yaml` in git, `git pull` on the server, `systemctl restart homeassistant.service` — change takes effect (manual for now; see Known gaps)
- [x] **Done 2026-09-20.** `backup.timer` is enabled and `sudo systemctl start backup.service` completes without error (`journalctl -u backup.service`). The repository is the local path `/mnt/storage/restic`; the restore drill has been run and passed — see docs/disaster-recovery.md for both, including the still-open offsite gap.
- [ ] **Restore drill**, once backups are enabled — `./scripts/restore.sh --target drill --snapshot latest`, then work through the checklist in docs/disaster-recovery.md § The restore drill. Do this before trusting backups with anything real.

## MicroK8s decommissioning

Done. Removed from henrybook via `sudo snap remove microk8s --purge`
(2026-08-06). It never had a workload running on it, and all four
`k8s/overlays/prod/secrets/*.sealed.yaml` files were still unfilled
placeholders (`encryptedData: {}`) — there was nothing to extract first.
Verified clean afterward: no leftover Calico interfaces, no leftover
`cali`/`kube` iptables chains, `/var/snap/microk8s` gone, disk usage
74%→59%, load average ~2.3-2.7→~1.0-1.5 on the idle box. `k8s/` and
`argocd/` remain in git as reference for the manifests this was ported from.

## Known gaps — not yet ported

- **Monitoring.** Alloy's k8s-specific scrape targets (kubelet, cAdvisor,
  kube-state-metrics) have no equivalent without a cluster and need to be
  dropped from its config, not just re-pointed.
- **GitOps loop.** No automated `git pull` + restart yet — deploying a change
  today means `git pull && sudo systemctl restart homeassistant.service` by
  hand on the server.
