# Backup and disaster recovery

This project exists in its current form because an SSD failed and took the
Home Assistant install with it, unrecoverably. This document is the response to
that, and it is the part of the setup most worth getting right.

## The design

Nightly restic `CronJob` at 03:15, defined in
[`k8s/base/backup/cronjob.yaml`](../k8s/base/backup/cronjob.yaml).

Three stages in one job:

1. **`pg_dump`** of the recorder database, over the network in custom format.
   Not a filesystem copy of `PGDATA` — copying a data directory from under a
   running Postgres produces a torn, unrestorable snapshot.
2. **Export the Sealed Secrets private keys.**
3. **restic** ships the staged files plus `/config` to an S3-compatible target,
   applies retention, and verifies.

## What is backed up, in order of criticality

### 1. The Sealed Secrets private key

Every secret in this repo is encrypted against a key pair whose private half
exists only inside the cluster. **Lose it and the committed `SealedSecret` files
are permanently undecryptable** — the repo restores perfectly and nothing
starts.

The controller also rotates in a fresh key roughly every 30 days while retaining
the old ones, so this needs to run on a schedule rather than being exported once
by hand.

The job fails loudly if the export comes back empty, because a silently-empty
sealing-key backup is worse than no backup: it looks like it is working.

### 2. The Zigbee network database (`/config/zigbee.db`)

Holds the coordinator's network key, PAN ID and the pairing state of every
Zigbee device.

**Without it you re-pair every Zigbee device in the house by hand** — physically
visiting each one, including the ones behind furniture and in the ceiling. This
is the most commonly forgotten file in Home Assistant backups and by far the
most annoying to lose.

### 3. The recorder database

`pg_dump --format=custom`, which restores with `pg_restore` and survives
Postgres version changes. This is your history and long-term statistics.

Least critical of the four: losing it costs you graphs, not a working house.

### 4. `/config/.storage/`

The entity registry, device registry, auth tokens, user accounts and dashboards.

Losing this loses the install even with a perfect database restore — every
entity comes back with a new ID, so every automation, script and dashboard
breaks. `.storage` is what makes a restored Home Assistant *the same* Home
Assistant.

Full exclude list and the reasoning:
[`k8s/base/backup/excludes.txt`](../k8s/base/backup/excludes.txt).

## Retention

7 daily, 4 weekly, 6 monthly. Enough to recover from a corruption you did not
notice for a month, without unbounded growth.

`restic check --read-data-subset=5%` runs every night, so the whole repository
is structurally verified over a few weeks without the cost of a full re-read.

## Where backups go

**restic is S3-first from day one**, so moving targets is a change to one Secret
key rather than a rewrite.

| Stage | Target | Status |
|---|---|---|
| Interim | Local path on the new HDD + a manual `rclone` copy off-box | ☐ pending HDD |
| Planned | MinIO on a Raspberry Pi — `s3:http://minio.lan:9000/ha-backups` | ☐ pending Pi |
| Recommended | A second, offsite restic target | ☐ your call |

### On the offsite gap

The HDD protects against flash failure only: same machine, same power supply,
same room. MinIO on the LAN is better — different machine, different disk — but
it is **still not offsite**. A fire, a theft, a lightning strike on the mains, or
a mistake that wipes both would take every copy you have.

3-2-1 is three copies, two media, **one offsite**. A Backblaze B2 bucket as a
second restic target costs roughly €0.50/month at this data size and closes the
gap. Adding it is your call; it is flagged rather than assumed.

### The restic password

Stored in the `restic` Sealed Secret — and it must **also** live somewhere
outside this machine and this cluster.

The dependency is circular: restoring Sealed Secrets needs the sealing key,
restoring the sealing key needs the backup, and reading the backup needs the
restic password. If the password only exists inside the cluster, a total loss of
the cluster makes every backup permanently unreadable.

**Put it in a password manager.** It is the one credential that cannot live only
in git.

## Restoring

### Single file or directory

```bash
kubectl -n ha-prod run restic-restore --rm -it --restart=Never \
  --image=restic/restic:0.17.3 \
  --env="RESTIC_REPOSITORY=..." --env="RESTIC_PASSWORD=..." \
  -- restore latest --target /tmp/restore --include /config/.storage
```

### The database

```bash
kubectl -n ha-prod exec -i sts/postgres -- \
  pg_restore -U ha -d homeassistant --clean --if-exists < homeassistant.dump
```

Stop Home Assistant first (`kubectl -n ha-prod scale deploy/homeassistant
--replicas=0`) — restoring underneath a running recorder will not end well.

### Bare metal, from nothing

`scripts/restore.sh` automates this. The sequence:

1. Install Ubuntu on the replacement disk.
2. `scripts/bootstrap-microk8s.sh` — MicroK8s, addons, Sealed Secrets, Argo CD.
3. **Restore the sealing key first**, before anything else:
   `kubectl apply -f sealed-secrets-keys.yaml` and restart the controller.
   Nothing else can decrypt until this is done.
4. Point Argo CD at this repo. It recreates every workload from git.
5. Restore `/config` and `pg_restore` the database.
6. Scale Home Assistant up.

You need exactly two things that are not in git: **the restic password** and
**network access to the backup target**.

## The restore drill

> **An untested backup is not a backup.** That is the lesson the dead SSD
> already taught, and it is the only reason this document exists.

**Run this once before considering the migration complete, then every six
months.** It is the acceptance test for the whole project.

```bash
# 1. Restore the latest snapshot into a scratch namespace
kubectl create namespace ha-drill
./scripts/restore.sh --namespace ha-drill --snapshot latest

# 2. Bring it up (no Zigbee dongle — prod owns it)
kubectl -n ha-drill scale deploy/homeassistant --replicas=1

# 3. Verify — this is the part that matters
kubectl -n ha-drill port-forward deploy/homeassistant 8124:8123
```

Check, in the restored instance:

- [ ] It loads and you can log in **with your existing password** (proves
      `.storage` auth data restored)
- [ ] Your devices and entities are present with their **original entity IDs**
      (proves the registries restored — new IDs mean everything downstream is
      broken)
- [ ] Dashboards render as you built them
- [ ] History shows data from before the snapshot (proves the `pg_restore`)
- [ ] ZHA reports a coordinator, even though the dongle is absent (proves
      `zigbee.db` restored)

Then tear it down:

```bash
kubectl delete namespace ha-drill
```

If any check fails, the backup is not doing its job — **fix it now**, while you
still have the original.
