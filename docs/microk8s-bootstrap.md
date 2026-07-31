# MicroK8s bootstrap

One-time build of the cluster on `henrybook`. Automated by
[`scripts/bootstrap-microk8s.sh`](../scripts/bootstrap-microk8s.sh); this
explains what it does and how to check each part.

> **Prerequisite:** the larger HDD should be fitted first. The 16 GB flash
> module has roughly 1 GiB spare after Ubuntu, and MicroK8s plus the container
> images need ~6 GB. See [hardware.md](hardware.md).

## Run it

```bash
git clone git@github.com:OscarAlmgren/smart-home-and-hearth.git
cd smart-home-and-hearth
./scripts/bootstrap-microk8s.sh
```

It is idempotent. The first run installs MicroK8s and adds you to the
`microk8s` group, then stops — group membership only applies to new logins. Log
out, back in, and run it again.

## What it installs, and what it deliberately does not

| Component | Why |
|---|---|
| MicroK8s 1.31 | The cluster |
| `dns` addon | **Required.** Home Assistant resolves the Postgres Service by name. |
| `hostpath-storage` addon | **Required.** PVC backing on a single node. |
| Sealed Secrets controller | Decrypts the committed `SealedSecret` files |
| Argo CD **core** | GitOps. No API server, UI or Dex — ~700 Mi lighter. |

Not enabled, on purpose:

- **`ingress`** — phase 3. Nothing is exposed beyond the LAN yet.
- **`cert-manager`** — phase 3, needs a domain.
- **`observability`** — a full Prometheus/Grafana/Loki stack. We ship to Grafana
  Cloud *precisely because* this node cannot host one. Enabling this would
  consume most of the remaining RAM.
- **`metrics-server`** — kube-state-metrics plus Alloy already cover it.

The script also sets `snap refresh.retain=2`. Snap keeps old revisions of every
snap by default, which on a 12 GiB disk is real money.

## The kustomize load restrictor

`k8s/base` reads `../../config/` and `../../.env.*`, which sit outside its own
directory. Kustomize forbids that by default, so every build needs:

```
--load-restrictor LoadRestrictionsNone
```

The script sets it for Argo CD via `kustomize.buildOptions` in `argocd-cm`. CI
passes the identical flag. **If those two ever diverge, CI goes green and the
cluster fails to sync** — a confusing failure, so it is asserted in both places.

The alternative was burying the Home Assistant YAML under
`k8s/base/homeassistant/config/`, which makes the files you edit most often the
hardest to find.

## After the script

Four steps, in order — each depends on the previous.

### 1. Give Argo CD read access to the repo

Create a read-only deploy key on GitHub (repo → Settings → Deploy keys), then:

```bash
microk8s kubectl -n argocd create secret generic repo-smart-home \
  --from-literal=type=git \
  --from-literal=url=git@github.com:OscarAlmgren/smart-home-and-hearth.git \
  --from-file=sshPrivateKey=/path/to/deploy-key
microk8s kubectl -n argocd label secret repo-smart-home \
  argocd.argoproj.io/secret-type=repository
```

### 2. Seal the real secrets

```bash
./scripts/seal-secrets.sh
git add k8s/overlays/prod/secrets && git commit -m "Seal secrets" && git push
```

See [grafana-cloud.md](grafana-cloud.md) for where the Grafana values come from.

**Store the restic password in a password manager before moving on.** Restoring
Sealed Secrets needs the sealing key, restoring the sealing key needs the
backup, and reading the backup needs that password — if it only exists in the
cluster, losing the cluster makes every backup unreadable.

### 3. Set the Zigbee device path

```bash
ls -l /dev/serial/by-id/
```

Put the full `usb-ITEAD_SONOFF_...-if00-port0` path into
`k8s/overlays/prod/patches/zigbee-device.yaml`, commit, push.

**Never `/dev/ttyACM0`.** That name is assigned in kernel enumeration order, so
once the Thread dongle arrives in phase 2 the two radios can swap after a
reboot and ZHA will silently attach to the wrong one. CI rejects `/dev/tty*`
paths for this reason.

### 4. Register the applications

```bash
microk8s kubectl apply -f argocd/project.yaml
microk8s kubectl apply -f argocd/applications/
```

`ha-prod` auto-syncs. `ha-test` is manual by design — see [lcm.md](lcm.md).

## Verifying

```bash
microk8s status                          # hostpath-storage + dns; NOT ingress
microk8s kubectl get nodes
microk8s kubectl -n ha-prod get pods     # homeassistant, postgres, alloy, ksm

export ARGOCD_OPTS='--core'
argocd app get ha-prod                   # Synced / Healthy
```

Home Assistant should answer on `http://<server-ip>:8123`. First start takes
several minutes on this CPU while it installs integration dependencies — the
`startupProbe` allows up to 10 minutes before giving up.

```bash
# Is the dongle visible inside the pod?
microk8s kubectl -n ha-prod exec deploy/homeassistant -- ls -l /dev/zigbee

# Is the recorder on Postgres rather than SQLite?
microk8s kubectl -n ha-prod exec sts/postgres -- \
  psql -U ha -d homeassistant -c '\dt'
microk8s kubectl -n ha-prod exec deploy/homeassistant -- \
  ls /config/home-assistant_v2.db     # should NOT exist
```

That last check matters: if Home Assistant cannot reach Postgres it falls back
to SQLite and carries on looking healthy, and you find out months later when
the disk fills.

### Then run the restore drill

```
docs/disaster-recovery.md § The restore drill
```

**This is the acceptance test for the whole migration.** An untested backup is
not a backup, which is the lesson the dead SSD already taught.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `microk8s: command not found` after install | Log out and back in — group membership needs a new login. |
| Argo CD: `rpc error... load restrictor` | `kustomize.buildOptions` missing from `argocd-cm`. Re-run the script. |
| Pods `Pending`, PVC unbound | `hostpath-storage` not enabled, or `/` is full. |
| HA pod `CreateContainerError` on `/dev/zigbee` | Device path wrong or dongle unplugged. Check `ls /dev/serial/by-id/`. |
| SealedSecret not decrypting | Sealed against a different namespace or cluster key. Re-run `seal-secrets.sh`. |
| Everything slow, evictions | Disk. `df -h /` then `microk8s ctr images prune`. |
