# Monitoring with Grafana Cloud

End-to-end setup for shipping Home Assistant, cluster and host telemetry to a
free-tier Grafana Cloud account.

This assumes you have set up Grafana against Ubuntu node metrics before, and
walks through what is *different* here: application metrics, Kubernetes, and
working inside a hard series budget.

## How it works

```
                    ┌──────────────────── henrybook ────────────────────┐
                    │                                                    │
  HA :8123/api/prometheus ──┐                                            │
  kubelet + cAdvisor ───────┤                                            │
  kube-state-metrics ───────┼──►  Grafana Alloy  ──┐                     │
  host metrics (built in) ──┤     (one pod, ~250Mi)│                     │
  pod stdout ───────────────┘                      │                     │
                    │                              │                     │
                    └──────────────────────────────┼─────────────────────┘
                                                   │  outbound HTTPS only
                                                   ▼
                                    Grafana Cloud (Prometheus + Loki)
```

One Alloy pod scrapes everything locally and pushes out. **Nothing listens for
inbound connections**, and there is no local Prometheus, Loki or Grafana — which
is both the secure arrangement and the only one that fits in 6 GiB alongside
Home Assistant.

Config: [`k8s/base/monitoring/config.alloy`](../k8s/base/monitoring/config.alloy).

> **Why not Grafana's official Helm chart?** `k8s-monitoring` v3+ deploys an
> Alloy Operator plus separate Alloy instances for metrics, logs, profiles and
> receivers. That is the right answer on a real cluster and roughly 5× the
> footprint this node can afford. If you ever move to better hardware, switching
> to the chart is the natural upgrade.

## What the free tier actually gives you

| Resource | Free tier |
|---|---|
| Active metrics series | **10,000** |
| Logs (Loki) | 50 GB/month |
| Traces / profiles | 50 GB each |
| **Retention** | **14 days, all signals** |
| Users | 3 |

Two of these shape the design.

**14-day retention** means Grafana Cloud is your *dashboard and alerting*
layer, not your history. Home Assistant's own long-term statistics in Postgres
keep 5-minute and hourly aggregates indefinitely, and that is what the Energy
dashboard and any "compare to last winter" question run against. Do not plan to
answer year-over-year questions in Grafana Cloud on the free tier.

**10,000 active series** is the one that will actually bite. A series is one
unique metric-name-plus-label-set. An unfiltered Home Assistant emits roughly
one per entity per numeric attribute — a modest install with a few dozen Zigbee
devices can produce 15,000–30,000 on its own, and you would exceed the cap
within days of pairing devices. Series budgeting is not premature optimisation
here; it is the main design constraint.

## 1. Create the stack

1. Sign up at [grafana.com](https://grafana.com) and create a stack. No card
   required.
2. From **My Account → your stack**, you need five values. They are in two
   different places, and the two usernames are **different numbers** — mixing
   them up is the most common setup mistake:

| Value | Where |
|---|---|
| `prometheus-url` | stack page → Prometheus → **Details** → "Remote Write Endpoint" |
| `prometheus-username` | same page → "Username / Instance ID" |
| `loki-url` | stack page → Loki → **Details** → push URL |
| `loki-username` | same page → "User" — **a different number** |
| `api-token` | **Access Policies** → create a policy with `metrics:write` and `logs:write`, then generate a token |

The URLs look like:

```
https://prometheus-prod-NN-prod-eu-west-N.grafana.net/api/prom/push
https://logs-prod-NNN.grafana.net/loki/api/v1/push
```

One token works for both signals — that is why the Secret has a single
`api-token` key.

## 2. Create the Home Assistant access token

Alloy authenticates to `/api/prometheus` with a Home Assistant long-lived
access token. Without it the endpoint returns 401.

In Home Assistant: **click your user (bottom left) → Security tab → scroll to
the very bottom → Create Token**.

Copy it immediately — it is shown once and never again.

## 3. Seal the credentials

```bash
./scripts/seal-secrets.sh
```

Supply the six values when prompted (the five above plus the HA token). The
script encrypts them with the cluster's public key and rewrites
`k8s/overlays/prod/secrets/grafana-cloud.sealed.yaml`.

Commit the result. That is the point of Sealed Secrets: the ciphertext is safe
in git and only this cluster can decrypt it.

```bash
git add k8s/overlays/prod/secrets/grafana-cloud.sealed.yaml
git commit -m "Add Grafana Cloud credentials"
git push
```

Argo CD syncs, the controller decrypts into a normal Secret, and Alloy starts.

## 4. Verify before trusting it

```bash
# Alloy running and not crash-looping
kubectl -n ha-prod get pods -l app.kubernetes.io/name=alloy

# Alloy's own view of its pipeline — every component should be "healthy"
kubectl -n ha-prod port-forward deploy/alloy 12345:12345
# then open http://localhost:12345
```

In Grafana Cloud → **Explore**:

```promql
up{job="homeassistant"}     # should be 1
up{job="node"}              # should be 1
```

```logql
{namespace="ha-prod"}       # should show Home Assistant's log lines
```

If `up` is 0 for `homeassistant`, it is almost always the bearer token. Check
Alloy's logs: `kubectl -n ha-prod logs deploy/alloy | grep -i homeassistant`.

---

## Series budgeting

**Do this before you have 8,000 series, not after.**

### Count what Home Assistant is emitting

```bash
curl -s -H "Authorization: Bearer $HA_TOKEN" \
  http://<server-ip>:8123/api/prometheus | grep -vc '^#'
```

That number is roughly how many series this scrape contributes. Keep the total
across all jobs comfortably under 10,000 — aim for 6,000 or so, leaving room to
add devices without a surprise.

### Where the budget goes

| Job | Typical | Controlled by |
|---|---|---|
| `homeassistant` | 500–3,000 | `config/packages/prometheus.yaml` → `filter:` |
| `node` | ~300 | `set_collectors` in `config.alloy` |
| `kube-state-metrics` | ~200 | the keep-list in `config.alloy` |
| `cadvisor` | ~50 | keep-list — only 2 metric families survive |

Everything except Home Assistant is already tightly bounded. **Home Assistant is
the variable, and it grows every time you pair a device.**

### Trimming, in order of preference

1. **Narrow the Home Assistant filter.** Edit `include_domains` in
   `config/packages/prometheus.yaml`. Not exporting a metric is always cheaper
   than exporting and discarding it. Ask what you would actually put on a
   dashboard — `switch` and `light` state history is rarely one of them.
2. **Exclude noisy entity globs.** `exclude_entity_globs` in the same file.
   Diagnostic sensors (`*_rssi`, `*_lqi`, `*_battery_voltage`) are usually the
   biggest offenders per device.
3. **Drop in Alloy.** Add a rule to `prometheus.relabel "budget"`. Use this only
   for metrics you cannot suppress at the source.

### Watching the number

Grafana Cloud → **Billing/Usage** shows active series over time. Also useful:

```promql
# Series by job, from Prometheus' own bookkeeping
sum by (job) (scrape_samples_scraped)
```

Set the alert in the next section so you find out at 8,000 rather than when
ingestion starts getting rejected.

---

## The three layers, and what matters in each

Coming from Ubuntu node monitoring, the host layer will be familiar and the
other two will not.

### Host — the node itself

Familiar territory: CPU, load, memory, disk, network. One thing matters far more
here than on a normal server:

```promql
# Root filesystem free space — THE metric on this box
100 * (1 - node_filesystem_avail_bytes{mountpoint="/"}
           / node_filesystem_size_bytes{mountpoint="/"})
```

With ~12 GiB total and ~11 GiB consumed by the OS, MicroK8s and container
images, **disk exhaustion is the single most likely way this install breaks.**
When `/` fills, containerd cannot write, the kubelet starts evicting, and
Postgres can corrupt. This is the most valuable alert you will configure.

### Cluster — Kubernetes itself

New if you have only monitored VMs. The useful questions:

```promql
# Is anything crash-looping?
rate(kube_pod_container_status_restarts_total[15m]) > 0

# Did a pod get OOM-killed?
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}

# Is Home Assistant approaching its 1536Mi memory limit?
container_memory_working_set_bytes{container="homeassistant"}

# Did the backup actually run?
time() - kube_cronjob_status_last_successful_time{cronjob="backup"}
```

That last one deserves emphasis. **A backup job that silently stops running is
indistinguishable from a working one until you need it** — which is precisely
the situation the dead SSD created.

### Application — Home Assistant

The layer with the most value and the least prior art.

```promql
# Is Home Assistant up?
up{job="homeassistant"}

# Entity count — a sudden drop means integrations failed to load
count(homeassistant_entity_available)

# Zigbee coordinator health — a stuck coordinator looks "up" but stops updating
time() - max(homeassistant_last_updated_time_seconds{entity=~".*coordinator.*"})

# Temperature sensors, for an actual dashboard
homeassistant_sensor_temperature_celsius
```

Logs are where integration failures actually surface:

```logql
{namespace="ha-prod", app="homeassistant"} |= "ERROR"
{namespace="ha-prod", app="homeassistant"} |~ "(?i)zha|zigbee"
```

Being able to grep Zigbee pairing failures from a laptop, rather than SSHing to
the server and tailing a file, is most of why logs are worth shipping.

---

## Dashboards

Import by ID in Grafana Cloud → **Dashboards → New → Import**:

| ID | Dashboard | Notes |
|---|---|---|
| `1860` | Node Exporter Full | Familiar. Some panels will be empty — `set_collectors` is a deliberate subset. |
| `15757` | Kubernetes / Views / Global | Cluster overview. |
| `15759` | Kubernetes / Views / Pods | Per-pod CPU and memory. |

For Home Assistant, build your own rather than importing. Community HA
dashboards assume the full unfiltered metric set and will mostly show "No data"
against the filtered export. Start with four panels:

1. `up{job="homeassistant"}` as a stat tile
2. Root filesystem usage as a gauge, thresholds at 70/80
3. Your temperature and humidity sensors as a time series
4. `rate(kube_pod_container_status_restarts_total{namespace="ha-prod"}[1h])`

## Alerts

The point of the exercise: hearing about problems before you notice them.

Grafana Cloud → **Alerting → Alert rules**. Configure a contact point first
(email works; [ntfy.sh](https://ntfy.sh) is good for phone push without an app
account).

| Alert | Condition | For | Why |
|---|---|---|---|
| **Home Assistant down** | `up{job="homeassistant"} == 0` | 5m | The obvious one. 5 minutes avoids paging on a normal restart. |
| **Root filesystem filling** | root fs usage `> 80` | 15m | **The most valuable alert here.** At 80% you have hours to act; at 95% the cluster is already misbehaving. |
| **Backup stale** | `time() - kube_cronjob_status_last_successful_time{cronjob="backup"} > 129600` | 0m | 36 hours. Catches a job that silently stopped. |
| **Pod crash-looping** | `rate(kube_pod_container_status_restarts_total{namespace="ha-prod"}[15m]) > 0` | 15m | Catches OOM kills and bad config. |
| **Postgres down** | `kube_statefulset_status_replicas_ready{statefulset="postgres"} == 0` | 5m | Home Assistant keeps running with a dead recorder — you would not otherwise notice. |
| **Zigbee coordinator stale** | no coordinator update in 30m | 30m | A wedged coordinator still reports "up" while every Zigbee device silently stops responding. |
| **Series budget** | active series `> 8000` | 1h | Warning shot before ingestion gets rejected. |

Start with the first three. The rest are refinements once you know what normal
looks like.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `up{job="homeassistant"} == 0`, 401 in Alloy logs | HA token wrong or expired. Regenerate, re-seal. |
| No metrics at all, `401` on remote_write | `prometheus-username` and `loki-username` swapped — they are different numbers. |
| `out of order sample` errors | Two Alloy instances writing the same series. There should be exactly one pod. |
| Ingestion rejected, `429` | Over 10k series. See § Series budgeting. |
| Logs missing but metrics fine | RBAC — Alloy needs `pods/log`. Check `k8s/base/monitoring/alloy-rbac.yaml`. |
| Alloy OOM-killed | Raise the 320Mi limit, but check for a scrape that exploded in cardinality first. |

## When the hardware improves

Two things change once this runs on something larger than a t610:

- Switch to Grafana's `k8s-monitoring` Helm chart for a maintained, fuller
  pipeline.
- Reconsider self-hosting Prometheus with long retention, keeping Grafana Cloud
  purely for alerting and remote dashboards. That removes the 14-day and 10k
  limits entirely.

Neither is worth doing on the current node.
