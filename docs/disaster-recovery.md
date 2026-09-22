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

**ENABLED 2026-09-20.** `backup.timer` is installed by
`scripts/bootstrap-podman.sh` but not auto-enabled — see
[podman-deploy.md](podman-deploy.md). It stayed disabled from the Podman
migration right through to 2026-09-20, with every `RESTIC_*`/`AWS_*` value
still the literal `CHANGEME`: for that entire period **nothing was backed
up**, and nothing said so. It is now enabled, pointed at a local repository
(see "Where backups go"), and the first restore drill has been run.

Two stages in one script:

1. **`VACUUM INTO`**, SQLite's own consistent-snapshot command, run inside
   the `homeassistant` container against the live recorder database. Not a
   filesystem copy of `home-assistant_v2.db` — copying a WAL-mode SQLite file
   out from under a running Home Assistant produces a torn, unrestorable
   snapshot, the same reason `pg_dump` existed when the recorder was Postgres.
2. **restic** ships the staged snapshot plus `/config` and `/otbr` to the
   restic repository — an S3-compatible bucket or a local path — applies
   retention, and verifies.

## Incidents

### 2026-08-25 — quadlet crash loop filled the root disk

Root disk usage climbed 65%->74% (on the 9.8 GiB `/` partition) because
`homeassistant.service`, `matter-server.service`, `otbr.service`, and a
stale `postgres.service` (leftover from before the SQLite switch, no longer
in the repo) were left enabled while genuinely broken, and systemd
crash-looped them for roughly 25 minutes - the restart counter reached 89
on one unit. Root cause of the *unbounded* part: `StartLimitIntervalSec`/
`StartLimitBurst` were set in `[Service]` in all three current `.container`
files, where systemd silently ignores them ("Unknown key ... ignoring").
They're now in `[Unit]`, where they actually apply (burst raised to 10 to
tolerate a slow legitimate cold start on this hardware without
false-triggering).

Two more bugs surfaced once the units were re-enabled, both worked around at
the time: `otbr.container`'s `Sysctl=` lines don't work under podman 5.7.0
with `Network=host` (moved to host-level `/etc/sysctl.d/`), and OTBR's own
entrypoint needs NAT44 kernel modules loaded on the host
(`/etc/modules-load.d/`). Both were moot after **2026-08-28, when the on-host
OTBR was decommissioned** and those host files were removed. The OTBR was
re-added 2026-09-15 with both workarounds restored (see
[podman-deploy.md § Host prerequisites](podman-deploy.md#host-prerequisites)
and [hardware.md § Radios](hardware.md#radios)).

Separately, image pulls stage in `/var/tmp` (`image_copy_tmp_dir` in
`containers.conf`) regardless of where the podman store's `graphroot`
points - a 500GB second disk (`/mnt/storage`, mounted from an external
SSHD) was fitted the same day (see
[hardware.md § The disk is the constraint](hardware.md#the-disk-is-the-constraint)),
and both the podman store and the live `/var/lib/smart-home-and-hearth`
data now live there (the latter via a symlink, so the Quadlet units'
`Volume=` paths didn't need to change) - but `image_copy_tmp_dir` had to be
set explicitly in `containers.conf` on top of that, since moving
`graphroot` alone left pull staging still hitting the small disk.

## What is backed up, in order of criticality

### 1. `/config/.storage/`

The entity registry, device registry, auth tokens, user accounts and dashboards.

Losing this loses the install even with a perfect database restore — every
entity comes back with a new ID, so every automation, script and dashboard
breaks. `.storage` is what makes a restored Home Assistant *the same* Home
Assistant.

Full exclude list and the reasoning:
[`podman/restic-excludes.txt`](../podman/restic-excludes.txt).

The Home Assistant OTBR's Thread network dataset
(`/var/lib/smart-home-and-hearth/otbr`, deployed 2026-09-15 — see
docs/hardware.md § Radios) is in this tier too. Losing it means forming a new
network and re-commissioning every Thread device by hand. It lives outside
`/config`, so `scripts/backup.sh` backs it up as `/otbr` and
`scripts/restore.sh --target prod` restores it. HA also keeps a copy of the
dataset in `.storage/thread.datasets`. (Zigbee has no radio, so there is no
`zigbee.db`.)

### 2. The recorder database

SQLite, snapshotted via `VACUUM INTO` (see above) — a single file, no
version-specific restore tooling needed. This is your history and long-term
statistics.

Least critical of the two: losing it costs you graphs, not a working house.

## Retention

7 daily, 4 weekly, 6 monthly. Enough to recover from a corruption you did not
notice for a month, without unbounded growth.

`restic check --read-data-subset=5%` runs every night, so the whole repository
is structurally verified over a few weeks without the cost of a full re-read.

## Where backups go

Moving targets is a change to one value in `.env.prod.secret`
(`RESTIC_REPOSITORY`) rather than a rewrite.

| Stage | Target | Status |
|---|---|---|
| Active | `/mnt/storage/restic` — local path on the 500 GB SSHD | ☑ since 2026-09-20 |
| Recommended | A second, offsite target (Backblaze B2) via `restic copy` | ☐ your call |

A `RESTIC_REPOSITORY` that starts with `/` is a **host** path, but restic runs
in a container — `backup.sh`, `restore.sh` and `restic.sh` each bind-mount it
at the same path so one value works inside and out. Without that mount restic
says "repository does not exist", which points at the wrong problem.

### On the offsite gap

**This is the known weak point of the current setup, and it is deliberate.**
Home Assistant's data lives on `/mnt/storage` too (`/var/lib/smart-home-and-hearth`
is a symlink onto the SSHD), so the repository shares a disk with the thing it
is backing up. That means the local repository protects against:

- a bad config edit, a broken upgrade, an accidental delete;
- recorder-database corruption;
- a container-store reset like the one the 2026-08-25 migration performed.

and **not** against the SSHD dying, a fire, a theft, or a lightning strike on
the mains — the exact failure that started this project. One disk failure
still takes the house's automation with it.

3-2-1 is three copies, two media, **one offsite**. A Backblaze B2 bucket as a
second target costs roughly €0.50/month at this data size (the repository is
~30 MB) and closes the gap:

```bash
# Second repo, then a nightly copy that needs no re-read of the source data.
restic -r s3:s3.eu-central-003.backblazeb2.com/<bucket> init \
  --copy-chain-from-repo /mnt/storage/restic
./scripts/restic.sh copy --from-repo /mnt/storage/restic ...
```

Adding it is your call; it is flagged rather than assumed.

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
./scripts/restic.sh restore latest \\
  --target /tmp/restore --include /config/.storage
```

`scripts/restic.sh` wraps the restic container: it reads the credentials from
`.env.prod.secret`, bind-mounts a local repository, and passes everything else
straight through (`snapshots`, `ls latest /otbr`, `stats`, `diff`, ...).

### The database

`scripts/restore.sh` handles this automatically — it's a file copy, not a
version-specific restore tool, once the snapshot's staged out of restic (see
the script for the exact steps). Stop Home Assistant first
(`sudo systemctl stop homeassistant.service`) if doing it by hand —
restoring underneath a running recorder will not end well.

### Bare metal, from nothing

`scripts/restore.sh --target prod` automates all of this. The full sequence:

1. Install Ubuntu on the replacement disk.
2. `scripts/bootstrap-podman.sh` — Podman, runtime directories, Quadlet units.
3. Recreate `config/secrets.yaml` and `.env.prod.secret` — from a password
   manager, not from any automated backup (see the Podman migration note
   above). Nothing else can start until these exist.
4. `scripts/restore.sh --target prod --snapshot latest` — restores `/config`
   (including the recorder DB, installed from the staged `VACUUM INTO`
   snapshot), then starts `homeassistant.service` itself.

You need exactly three things that are not in git: **the restic password**,
**`config/secrets.yaml` / `.env.prod.secret`**, and **network access to the
backup target**.

## The restore drill

> **An untested backup is not a backup.** That is the lesson the dead SSD
> already taught, and it is the only reason this document exists.

**Run this once before considering the migration complete, then every six
months.** It is the acceptance test for the whole project.

**Drill log — 2026-09-20, first drill, PASSED.** Snapshot `8a48d2b8`: 1138
entity-registry entries (byte-identical count to prod), both user accounts
present, recorder DB `PRAGMA integrity_check` ok with 74 230 state rows
spanning 2026-09-13 → 2026-09-20, `thread.datasets` back with
`preferred_dataset` still pointing at `ha-thread-a999`, all three `/otbr`
settings files in the snapshot, and the drill Home Assistant served HTTP 200
with nothing in its log. Next drill due **2027-03-20**.

```bash
# Restores the latest snapshot into an isolated network, and brings up a
# throwaway Home Assistant at http://127.0.0.1:8124 (no radios — prod owns
# them; no scratch database container needed, the recorder DB is a plain
# SQLite file). Does not touch the live install.
./scripts/restore.sh --target drill --snapshot latest
```

Check, in the restored instance:

- [ ] It loads and you can log in **with your existing password** (proves
      `.storage` auth data restored)
- [ ] Your devices and entities are present with their **original entity IDs**
      (proves the registries restored — new IDs mean everything downstream is
      broken)
- [ ] Dashboards render as you built them
- [ ] History shows data from before the snapshot (proves the recorder DB restored)
- [ ] The OTBR Thread dataset is in the snapshot: `restic ls <snapshot> /otbr`
      lists its `*.data` settings file, and the restored
      `.storage/thread.datasets` shows `ha-thread-a999` (PAN `0xa999`, ext PAN
      `65cb0d082358c46f`) as preferred

Then tear it down (the drill script prints these same commands at the end):

```bash
podman rm -f homeassistant-drill
sudo rm -rf /var/lib/smart-home-and-hearth-drill
podman network rm ha-drill
```

If any check fails, the backup is not doing its job — **fix it now**, while you
still have the original.
