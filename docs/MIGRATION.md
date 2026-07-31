# Migration: Docker Compose → MicroK8s + Grafana Cloud

**Live progress tracker.** Tick boxes in the same commit as the work they
describe.

## Why

This repo was a single `docker-compose.yml` running Home Assistant with a
bind-mounted `config/` and a manual `scripts/deploy.sh`.

The rebuild was forced by a **catastrophic SSD failure** that destroyed the
previous install with no recoverable backup. That sets the priorities: backup
and restore are a first-class deliverable, not an afterthought, and nothing
important may live only on the boot flash.

Three goals:

1. Move the workload to MicroK8s on `henrybook`, GitOps-driven by Argo CD.
2. Ship metrics and logs to a free-tier Grafana Cloud account.
3. Formalise LCM across the `dev` → `test` → `main` branches.

Hardware context — and it drives most of the decisions below — is in
[hardware.md](hardware.md). Short version: 2 slow cores, 6 GiB RAM, and
**~12 GiB of usable disk**.

## Phases

| Phase | Contents | Status |
|---|---|---|
| **0 — Prep** | HDD fitted, second Sonoff dongle flashed, MinIO Pi | ☐ pending (hardware) |
| **1 — This document** | MicroK8s, Argo CD, HA + Postgres, Zigbee, backups, Grafana Cloud, CI/LCM, docs | ◐ steps 1–8 written, step 9 gated on phase 0 |
| **2 — Later** | Matter/Thread, OCPP EV charger, derived HA image for HACS | ☐ deferred |
| **3 — Later** | Domain, DNS, public IPv6 access, TLS | ☐ deferred |

Phase 1 is **LAN-only**. No Ingress, no cert-manager, no public exposure.

## Decisions

| Area | Decision | Why |
|---|---|---|
| Recorder DB | **PostgreSQL from day one** | No existing data, so choosing Postgres now means never doing a migration. `purge_keep_days: 7` initially to fit the disk. |
| Secrets | **Sealed Secrets** | Encrypted secrets in git means the cluster rebuilds from git after a disk failure. The sealing key becomes a top-priority backup item. |
| GitOps | **Argo CD core**, branch-per-env | Matches the three-branch model; core mode (no API server, UI or Dex) saves ~700 Mi. |
| Monitoring | **One hand-rolled Grafana Alloy Deployment** | The official `k8s-monitoring` Helm chart v3 runs an Alloy Operator plus several Alloy instances — far too heavy here. Alloy's built-in `prometheus.exporter.unix` also removes a separate node-exporter pod. |
| HA workload | **Deployment, `strategy: Recreate`** | RollingUpdate deadlocks — two pods cannot both bind host `:8123` or open the same serial device. |
| Radios | Zigbee in phase 1, Thread in phase 2 | Bluetooth dropped: no adapter present, and host D-Bus in a pod is the most fragile piece. |

---

## Step 1 — Repo hygiene and hardware truth

- [x] Write `CLAUDE.md` including the HDD check-in rule
- [x] Commit `henrybook-stats.yaml`
- [x] Fix `TZ=Etc/Stockholm` → `Europe/Stockholm` in all three env files
- [x] Pin `HA_VERSION` per environment (was floating `stable`)
- [x] Write `docs/hardware.md`
- [x] Seed this document, link it from `README.md`

> **Two real bugs fixed here.** `Etc/Stockholm` is not a tzdata zone — `Etc/`
> contains only UTC, GMT and GMT±N. glibc silently falls back to UTC, so every
> timestamp and every time-based automation would have been 1–2 h out.
> `HA_VERSION=stable` is a floating tag: two syncs of the same git commit could
> produce different running software, which defeats declarative deployment.

## Step 2 — HA configuration restructure (`config/`)

- [x] `configuration.yaml` gains `packages: !include_dir_named packages/`
- [x] `packages/recorder.yaml` — Postgres `db_url`, `purge_keep_days: 7`, excludes for chatty entities, raised `commit_interval` (flash wear)
- [x] `packages/http.yaml` — `use_x_forwarded_for` / `trusted_proxies` staged but commented out for phase 3
- [x] `packages/prometheus.yaml` — the `prometheus:` integration with an explicit `filter:` include list
- [x] `packages/logger.yaml`
- [x] Extend `secrets.yaml.example` with `recorder_db_url` and `prometheus_token`

> The `filter:` list is **the single most important knob for staying inside
> Grafana Cloud's 10k-series free tier**. An unfiltered Home Assistant can emit
> tens of thousands of series.

## Step 3 — Core workloads (`k8s/base/`)

`/config` must be writable — Home Assistant owns `.storage`, the DB and logs —
so it cannot be a read-only ConfigMap mount. The pattern: PVC at `/config`,
ConfigMap read-only at `/managed`, Sealed Secret at `/managed-secrets`, and an
initContainer that copies the managed files over `/config` on every pod start.
Git-managed files are overwritten each boot; HA-owned runtime state is untouched.

- [x] `namespace.yaml` with `pod-security.kubernetes.io/enforce: privileged`
- [x] HA `Deployment` — `Recreate`, `hostNetwork`, `ClusterFirstWithHostNet`, pinned to `henrybook`
- [x] Zigbee `hostPath` via `/dev/serial/by-id/`, mounted at `/dev/zigbee`
- [x] Resources: requests `250m`/`512Mi`, memory limit `1536Mi`, **no CPU limit**
- [x] `ha-config` PVC + `ha-managed-config` ConfigMap
- [x] `sync-config` initContainer
- [x] Postgres `StatefulSet` — `postgres:16-alpine`, tuned small
- [x] Sealed Secret for DB credentials

## Step 4 — Overlays and env wiring (`k8s/overlays/`)

- [x] `overlays/dev`, `overlays/test`, `overlays/prod`
- [x] `configMapGenerator` reads `.env.*` natively via `envs:`
- [x] `HA_VERSION` mirrored into each overlay's `images:` block
- [x] `scripts/render-env.sh` with a `--check` mode for CI
- [x] `overlays/test` patches HA to `replicas: 0`

## Step 5 — Monitoring (`k8s/base/monitoring/`)

One Alloy pod scrapes locally and `remote_write`s outbound. No inbound ports, no
local Grafana or Prometheus — correct both for security and for a 6 GiB box.

```
HA :8123/api/prometheus ─┐
kubelet + cAdvisor ──────┤
kube-state-metrics ──────┼─► Grafana Alloy ─► Grafana Cloud (Prometheus + Loki)
node metrics (built-in) ─┤        │
pod logs ────────────────┘        └─ ~250 Mi, one pod
```

- [x] Alloy `Deployment` + ConfigMap
- [x] `prometheus.scrape` — HA (bearer token), kubelet, cAdvisor, kube-state-metrics
- [x] `prometheus.exporter.unix` (built in — replaces node-exporter)
- [x] `loki.source.kubernetes`
- [x] `prometheus.relabel` drop rules for series budgeting
- [x] `prometheus.remote_write` + `loki.write`
- [x] kube-state-metrics
- [x] Sealed Secret for Grafana Cloud credentials
- [x] Write [grafana-cloud.md](grafana-cloud.md)

## Step 6 — Backup and disaster recovery (`k8s/base/backup/`)

**The part that matters most, given why this project is being rebuilt.**
Nightly restic `CronJob`, in order of criticality:

- [x] 1. **Sealed Secrets master key** — without it every encrypted secret in git is unrecoverable
- [x] 2. **Zigbee coordinator network backup** — losing this means re-pairing every device by hand
- [x] 3. **`pg_dump`** of the recorder DB
- [x] 4. **`/config/.storage/`** — entity registry, device registry, auth tokens, dashboards
- [x] 5. `config/` YAML, for a self-contained restore
- [x] Retention 7 daily / 4 weekly / 6 monthly
- [x] S3-first config so MinIO is an endpoint swap, not a rewrite
- [x] `scripts/restore.sh`
- [x] Write [disaster-recovery.md](disaster-recovery.md) with a restore drill

> An untested backup is not a backup — which is the lesson the dead SSD already
> taught. **The restore drill is the acceptance test for this whole project.**

## Step 7 — LCM, CI and GitOps

| Branch | `.env` | Cluster presence | Gate |
|---|---|---|---|
| `dev` | `.env.dev` | none | static validation |
| `test` | `.env.test` | `ha-test`, HA at `replicas: 0` | real server-side validation, ~zero cost |
| `main` | `.env.prod` | `ha-prod`, live | Argo CD auto-sync |

- [x] `.github/workflows/validate.yml`
- [x] `.github/workflows/promote.yml`
- [x] `argocd/project.yaml`
- [x] `argocd/applications/ha-prod.yaml` — auto-sync, self-heal, prune
- [x] `argocd/applications/ha-test.yaml` — manual sync
- [x] Write [lcm.md](lcm.md)

## Step 8 — Bootstrap and repo-side verification

- [x] `scripts/bootstrap-microk8s.sh`
- [x] Write [microk8s-bootstrap.md](microk8s-bootstrap.md)
- [x] `kustomize build` + `kubeconform` clean for all three overlays — verified
      in CI, run `30617928362` on commit `6630a3c`
- [x] `./scripts/render-env.sh --check` passes
- [x] All YAML parses; Home Assistant packages each expose exactly one domain key
- [x] `hass --script check_config` passes against the pinned image
- [x] Invariant assertions pass (`Recreate`, `hostNetwork`,
      `ClusterFirstWithHostNet`, no `/dev/tty*` device paths)

## Step 9 — GATE: cluster bring-up

Blocked on phase 0 hardware. Everything above is pure git and needs no server.

- [ ] MicroK8s installed; `hostpath-storage` + `dns` enabled, `ingress` **not**
- [ ] Sealed Secrets controller; real secrets sealed and committed
- [ ] Argo CD core installed, both Applications registered
- [ ] First sync of `ha-prod`
- [ ] Zigbee dongle paired, ZHA coordinator online
- [ ] Grafana Cloud stack created, first metrics flowing
- [ ] **Restore drill executed successfully**

---

## Verification

**Repo-side — no hardware needed:**

```bash
# NOTE: --load-restrictor LoadRestrictionsNone is mandatory. The base reads
# ../../config/ and ../../.env.*, outside its own directory, which kustomize
# forbids by default. Argo CD and CI both pass the same flag.
for o in dev test prod; do
  kustomize build --load-restrictor LoadRestrictionsNone "k8s/overlays/$o" \
    >/dev/null && echo "$o ok"
done

./scripts/render-env.sh --check

# Full schema validation (CI does this on every push)
kustomize build --load-restrictor LoadRestrictionsNone k8s/overlays/prod \
  | kubeconform -strict -summary -ignore-missing-schemas

# Home Assistant config syntax
docker run --rm -v "$PWD/config:/config" \
  ghcr.io/home-assistant/home-assistant:2026.7.4 \
  python -m homeassistant --script check_config -c /config
```

**Cluster-side — after the gate:**

- [ ] `microk8s status` — `hostpath-storage` and `dns` enabled, `ingress` **not**
- [ ] `kubectl -n ha-prod get pods` — `homeassistant` and `postgres` Running
- [ ] Home Assistant reachable at `http://<server-ip>:8123`; onboarding completes
- [ ] `kubectl -n ha-prod exec deploy/homeassistant -- ls -l /dev/zigbee` resolves; ZHA finds the coordinator
- [ ] Recorder is on Postgres — `psql ... -c '\dt'` shows HA tables, and **no `home-assistant_v2.db` exists** in `/config`
- [ ] `curl -H "Authorization: Bearer $TOKEN" http://<ip>:8123/api/prometheus | wc -l` — series count inside budget *before* pointing Alloy at Grafana Cloud
- [ ] Metrics in Grafana Cloud Explore (`up{job="homeassistant"}`); logs in Loki (`{namespace="ha-prod"}`)
- [ ] Test alert fires (stop the HA pod, confirm the notification arrives)
- [ ] **Restore drill** — `scripts/restore.sh` into a scratch namespace brings `.storage` and the DB back
- [ ] GitOps loop — commit a trivial `config/` change to `main`, confirm Argo syncs and the initContainer propagates it

## Known risks

| Risk | Mitigation |
|---|---|
| **Disk exhaustion on 12 GiB** — the most likely failure mode | Alert at 80%; move containerd data root to the HDD; `microk8s ctr images prune` in the runbook |
| Flash write wear (this class of part already failed once) | Recorder excludes + raised `commit_interval`; Postgres data to the HDD when available |
| MicroK8s below Canonical's 20 GB recommendation | Accepted knowingly. **k3s** is the fallback if it proves untenable — single binary, no snap, ~512 Mi |
| `hostNetwork` port conflicts | Only `ha-prod` uses it; `ha-test` runs at zero replicas |
| Argo CD core has no UI | `argocd` CLI + `kubectl`; documented in [lcm.md](lcm.md) |
| Phase 2 adds 2–3 more pods | Re-evaluate RAM headroom then; may depend on a hardware refresh |
