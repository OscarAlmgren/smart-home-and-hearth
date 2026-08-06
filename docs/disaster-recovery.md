# Backup and disaster recovery

This project exists in its current form because an SSD failed and took the
Home Assistant install with it, unrecoverably. This document is the response to
that, and it is the part of the setup most worth getting right.

## The design

Nightly systemd timer at 03:15, defined in
[`podman/backup.timer`](../podman/backup.timer) /
[`podman/backup.service`](../podman/backup.service), running
[`scripts/backup.sh`](../scripts/backup.sh).

**Podman migration note (see [podman-deploy.md](podman-deploy.md)):** this
used to be a k8s `CronJob` (still in
[`k8s/base/backup/cronjob.yaml`](../k8s/base/backup/cronjob.yaml) for
reference) with a stage that exported the Sealed Secrets private key. That
stage is gone — there is no Sealed Secrets controller anymore, so there is no
sealing key a restore depends on. Secrets are now plain gitignored files
(`config/secrets.yaml`, `.env.prod.secret`); back those up yourself outside
this repo's automation (a password manager, same as the restic password
below).

Two stages in one script:

1. **`pg_dump`** of the recorder database, over the network in custom format.
   Not a filesystem copy of `PGDATA` — copying a data directory from under a
   running Postgres produces a torn, unrestorable snapshot.
2. **restic** ships the staged dump plus `/config` to an S3-compatible target,
   applies retention, and verifies.

## What is backed up, in order of criticality

### 1. The Zigbee network database (`/config/zigbee.db`)

Holds the coordinator's network key, PAN ID and the pairing state of every
Zigbee device.

**Without it you re-pair every Zigbee device in the house by hand** — physically
visiting each one, including the ones behind furniture and in the ceiling. This
is the most commonly forgotten file in Home Assistant backups and by far the
most annoying to lose.

### 2. The recorder database

`pg_dump --format=custom`, which restores with `pg_restore` and survives
Postgres version changes. This is your history and long-term statistics.

Least critical of the three: losing it costs you graphs, not a working house.

### 3. `/config/.storage/`

The entity registry, device registry, auth tokens, user accounts and dashboards.

Losing this loses the install even with a perfect database restore — every
entity comes back with a new ID, so every automation, script and dashboard
breaks. `.storage` is what makes a restored Home Assistant *the same* Home
Assistant.

Full exclude list and the reasoning:
[`podman/restic-excludes.txt`](../podman/restic-excludes.txt).

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

Stored in `.env.prod.secret` — and it must **also** live somewhere outside
this machine.

The dependency is circular: `.env.prod.secret` is not in git (it can't be —
it's the secrets file), and if it only exists on this machine's disk, the
same failure that destroys the disk destroys the one thing needed to read the
backup that was supposed to save you.

**Put it in a password manager.** It is the one credential that cannot live only
on this machine.

## Restoring

### Single file or directory

```bash
podman run --rm \
  -e RESTIC_REPOSITORY=... -e RESTIC_PASSWORD=... \
  -v /tmp/restore:/tmp/restore \
  restic/restic:0.17.3 \
  restore latest --target /tmp/restore --include /config/.storage
```

### The database

```bash
podman exec -i postgres \
  pg_restore -U ha -d homeassistant --clean --if-exists < homeassistant.dump
```

Stop Home Assistant first (`sudo systemctl stop homeassistant.service`) —
restoring underneath a running recorder will not end well.

### Bare metal, from nothing

`scripts/restore.sh --target prod` automates the config + dump half. The full
sequence:

1. Install Ubuntu on the replacement disk.
2. `scripts/bootstrap-podman.sh` — Podman, runtime directories, Quadlet units.
3. Recreate `config/secrets.yaml` and `.env.prod.secret` — from a password
   manager, not from any automated backup (see the Podman migration note
   above). Nothing else can start until these exist.
4. `scripts/restore.sh --target prod --snapshot latest` — restores `/config`
   and stages the database dump.
5. `pg_restore` the staged dump into Postgres (the script prints the exact
   command).
6. `sudo systemctl start homeassistant.service`.

You need exactly three things that are not in git: **the restic password**,
**`config/secrets.yaml` / `.env.prod.secret`**, and **network access to the
backup target**.

## The restore drill

> **An untested backup is not a backup.** That is the lesson the dead SSD
> already taught, and it is the only reason this document exists.

**Run this once before considering the migration complete, then every six
months.** It is the acceptance test for the whole project.

```bash
# Restores the latest snapshot into an isolated network + scratch Postgres,
# and brings up a throwaway Home Assistant at http://127.0.0.1:8124
# (no Zigbee dongle — prod owns it). Does not touch the live install.
./scripts/restore.sh --target drill --snapshot latest
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

Then tear it down (the drill script prints these same commands at the end):

```bash
podman rm -f homeassistant-drill postgres-drill
sudo rm -rf /var/lib/smart-home-and-hearth-drill
podman network rm ha-drill
```

If any check fails, the backup is not doing its job — **fix it now**, while you
still have the original.
