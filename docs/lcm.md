# Lifecycle management

Three branches, three environments, one live Home Assistant.

## The model

| Branch | Env file | Namespace | Runs? | Gate |
|---|---|---|---|---|
| `dev` | `.env.dev` | — | no | CI static validation |
| `test` | `.env.test` | `ha-test` | applied, `replicas: 0` | CI + manual Argo sync |
| `main` | `.env.prod` | `ha-prod` | **live** | Argo CD auto-sync |

### Why dev doesn't run

The server is a 2-core, 6 GiB thin client with ~12 GiB of disk
([hardware.md](hardware.md)). It can host one Home Assistant and its supporting
services. Three would swap and fill the disk.

So `dev` is a compile check: `kustomize build`, `kubeconform`, Home Assistant's
own `check_config`, and the `.env`/overlay consistency check. That catches
essentially every mistake that is cheap to catch.

### Why test runs at zero replicas

This is the useful trick. `ha-test` **is** applied to the API server, so you get
validation that no static tool provides:

- admission controllers and Pod Security enforcement
- full schema validation against the actual cluster version and its CRDs
- conflicts against immutable fields on the previously applied version
- RBAC and namespace existence

...and it costs nothing, because nothing is scheduled. `hostpath` PVCs bind
`WaitForFirstConsumer`, so not even disk is consumed.

It also keeps `test` off host `:8123`, which `ha-prod` owns exclusively.

The test overlay deliberately excludes monitoring and backup. Both define
`ClusterRole` and `ClusterRoleBinding`, which are **cluster-scoped** — setting
`namespace:` does not make them unique. Including them in both environments
would leave two Argo CD Applications claiming the same ClusterRoles, each
reverting the other, and both stuck `OutOfSync`. There is also nothing to
scrape or back up at zero replicas.

## Making a change

```bash
git switch dev
# edit config/ or k8s/

kubectl kustomize k8s/overlays/prod --load-restrictor LoadRestrictionsNone >/dev/null
./scripts/render-env.sh --check

git commit -am "..." && git push
```

CI runs on the push. Fix anything red before promoting.

## Promotion

```
dev ──PR──► test ──PR──► main ──Argo CD──► ha-prod (the live house)
```

Both hops are pull requests. `.github/workflows/promote.yml` rejects a PR into
`test` that does not come from `dev`, and a PR into `main` that does not come
from `test` — so nothing reaches production without passing through test.

### dev → test

1. Open a PR from `dev` into `test`. Merge when CI is green.
2. Sync it and confirm the API server accepts it:

```bash
argocd app sync ha-test
argocd app get ha-test      # must be Synced / Healthy
```

A failure here is the point of the environment: it means the manifests are
structurally fine but the cluster rejects them.

### test → main

1. Open a PR from `test` into `main`.
2. **Read the "Rendered changes to `ha-prod`" diff** in the workflow summary.
   That is literally what Argo CD will apply to the live house on merge.
3. Merge. Argo CD auto-syncs within ~3 minutes.

```bash
argocd app get ha-prod
kubectl -n ha-prod get pods -w
```

Use fast-forward merges to keep history linear:

```bash
git switch test && git merge --ff-only dev && git push
```

Never commit to `main` directly. It is production, and it is auto-synced.

## Bumping the Home Assistant version

New versions land on `dev` first.

1. On `dev`, set `HA_VERSION` in `.env.dev` to the new version.
2. `./scripts/render-env.sh --write` mirrors it into the overlay's image tag —
   they have to agree, and CI fails if they drift.
3. Commit, push, let CI validate the config against the new image.
4. Promote as above, updating `.env.test` then `.env.prod` at each hop.

Never use `stable`, `latest` or `beta`. `render-env.sh --check` rejects them:
with a floating tag, two syncs of the same commit can produce different running
software, which defeats the point of declarative deployment.

## Smoke-testing in test

At `replicas: 0` nothing runs, so nothing consumes the secrets. Scaling up for
real needs secrets sealed into `ha-test` first — they are encrypted against a
specific namespace and name, so the `ha-prod` ones will not decrypt there.

```bash
./scripts/seal-secrets.sh --namespace ha-test
kubectl -n ha-test scale deploy/postgres --replicas=1
kubectl -n ha-test scale deploy/homeassistant --replicas=1

kubectl -n ha-test port-forward deploy/homeassistant 8124:8123
```

**Scale it back to 0 when you are done.** Left running it contends with prod for
memory, and if the Zigbee patch is ever added to the test overlay, for the
dongle too.

## Rolling back

Argo CD keeps sync history:

```bash
argocd app history ha-prod
argocd app rollback ha-prod <ID>
```

That is a live-cluster rollback and leaves git ahead of the cluster. Follow it
with a real `git revert` on `main`, or the next auto-sync will reapply the
change you just rolled back.

For a Home Assistant version regression, reverting the `.env.prod` and overlay
change is usually cleaner than an Argo rollback.

## Argo CD without a UI

Argo CD runs in **core mode**: no API server, no web UI, no Dex, which saves
around 700 Mi on a 6 GiB box. The `argocd` CLI talks to the Kubernetes API
directly.

```bash
export ARGOCD_OPTS='--core'
argocd app list
argocd app get ha-prod
argocd app diff ha-prod        # cluster vs git
argocd app sync ha-test
```

`argocd app diff` is the one worth remembering — it answers "what is actually
different right now" without a UI.

If you later want the UI, `kubectl apply -n argocd -f` the full install manifest
instead of `core-install.yaml`, and budget the extra memory.
