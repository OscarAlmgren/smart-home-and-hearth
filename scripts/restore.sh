#!/usr/bin/env bash
# Restore Home Assistant from a restic backup.
#
#     ./scripts/restore.sh --namespace ha-drill --snapshot latest   # drill
#     ./scripts/restore.sh --namespace ha-prod  --snapshot latest   # for real
#
# Restores /config (entity registry, Zigbee network database, dashboards) and
# the recorder database. See docs/disaster-recovery.md for the full bare-metal
# sequence and the drill checklist.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE=""
SNAPSHOT="latest"
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --snapshot)  SNAPSHOT="${2:?}";  shift 2 ;;
    --yes)       ASSUME_YES=1; shift ;;
    *) echo "usage: $0 --namespace NS [--snapshot ID] [--yes]" >&2; exit 2 ;;
  esac
done

[[ -n "$NAMESPACE" ]] || { echo "--namespace is required" >&2; exit 2; }

KUBECTL="kubectl"
command -v kubectl >/dev/null 2>&1 || KUBECTL="microk8s kubectl"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ── Guard rail ──────────────────────────────────────────────────────────────
# Restoring over a live install destroys current state. Make that a deliberate,
# typed decision rather than a flag someone copy-pastes.
if [[ "$NAMESPACE" == "ha-prod" && $ASSUME_YES -eq 0 ]]; then
  cat >&2 <<EOF

  ┌────────────────────────────────────────────────────────────────────┐
  │  You are about to restore over the LIVE Home Assistant install.    │
  │                                                                    │
  │  This overwrites /config — the entity registry, the Zigbee network │
  │  database and every dashboard — and replaces the recorder database │
  │  with the contents of snapshot: ${SNAPSHOT}
  │                                                                    │
  │  Current state that is not in the snapshot will be lost.           │
  │                                                                    │
  │  If you are testing the backup, use a scratch namespace instead:   │
  │      $0 --namespace ha-drill                                       │
  └────────────────────────────────────────────────────────────────────┘

EOF
  read -rp "  Type the namespace to confirm: " confirm
  [[ "$confirm" == "ha-prod" ]] || { echo "  Aborted."; exit 1; }
fi

# ── 1. Stop writers ─────────────────────────────────────────────────────────
# Restoring underneath a running recorder produces a corrupt result.
say "Scaling down Home Assistant"
$KUBECTL -n "$NAMESPACE" scale deploy/homeassistant --replicas=0 --ignore-not-found
$KUBECTL -n "$NAMESPACE" wait --for=delete pod \
  -l app.kubernetes.io/name=homeassistant --timeout=120s 2>/dev/null || true

# ── 2. Restore /config ──────────────────────────────────────────────────────
say "Restoring /config from snapshot ${SNAPSHOT}"
$KUBECTL -n "$NAMESPACE" delete job restore-config --ignore-not-found
cat <<EOF | $KUBECTL -n "$NAMESPACE" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-config
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: henrybook
      containers:
        - name: restic
          image: restic/restic:0.17.3
          command: ["/bin/sh", "-eu", "-c"]
          args:
            - |
              echo "==> restoring /config"
              # --target / because the snapshot stores absolute paths.
              restic restore ${SNAPSHOT} --target / --include /config
              echo "==> staging files (database dump, sealing keys)"
              restic restore ${SNAPSHOT} --target /staging-out --include /staging
              ls -lh /staging-out/staging/
          env:
            - name: RESTIC_REPOSITORY
              valueFrom: { secretKeyRef: { name: restic, key: repository } }
            - name: RESTIC_PASSWORD
              valueFrom: { secretKeyRef: { name: restic, key: password } }
            - name: AWS_ACCESS_KEY_ID
              valueFrom: { secretKeyRef: { name: restic, key: aws-access-key-id } }
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom: { secretKeyRef: { name: restic, key: aws-secret-access-key } }
          volumeMounts:
            - { name: config, mountPath: /config }
            - { name: staging, mountPath: /staging-out }
      volumes:
        - name: config
          persistentVolumeClaim: { claimName: ha-config }
        - name: staging
          emptyDir: {}
EOF

$KUBECTL -n "$NAMESPACE" wait --for=condition=complete job/restore-config --timeout=1800s
$KUBECTL -n "$NAMESPACE" logs job/restore-config

# ── 3. Restore the database ─────────────────────────────────────────────────
say "Restoring the recorder database"
$KUBECTL -n "$NAMESPACE" scale statefulset/postgres --replicas=1
$KUBECTL -n "$NAMESPACE" rollout status statefulset/postgres --timeout=300s

cat <<'NOTE'

  The database dump was restored to a temporary volume inside the job above and
  is not automatically loaded — pg_restore over a live database is destructive
  and deserves an explicit step. Run it now:

    kubectl -n NAMESPACE exec -i sts/postgres -- \
      pg_restore -U ha -d homeassistant --clean --if-exists < homeassistant.dump

  Pull the dump out of the restore job first if you need it locally:

    kubectl -n NAMESPACE cp restore-config-POD:/staging-out/staging/homeassistant.dump ./homeassistant.dump

NOTE

# ── 4. Back up ──────────────────────────────────────────────────────────────
say "Scaling Home Assistant back up"
$KUBECTL -n "$NAMESPACE" scale deploy/homeassistant --replicas=1
$KUBECTL -n "$NAMESPACE" rollout status deploy/homeassistant --timeout=900s

cat <<EOF

Restore complete for ${NAMESPACE}.

Verify — this is the part that matters (docs/disaster-recovery.md § The restore drill):

  kubectl -n ${NAMESPACE} port-forward deploy/homeassistant 8124:8123

  [ ] logs, and you can sign in with your EXISTING password
  [ ] devices and entities present with their ORIGINAL entity IDs
  [ ] dashboards render as you built them
  [ ] history shows data from before the snapshot
  [ ] ZHA reports a coordinator (proves zigbee.db restored)

If any of those fail, the backup is not doing its job. Fix it while you still
have the original.
EOF
