#!/usr/bin/env bash
# Encrypts the real secret values into the committable SealedSecret files.
#
#     ./scripts/seal-secrets.sh                    # namespace ha-prod
#     ./scripts/seal-secrets.sh --namespace ha-test
#
# Values are read interactively and never written to disk in plaintext, never
# echoed, and never placed in shell history.
#
# The OUTPUT is meant to be committed. That is the point of Sealed Secrets:
# ciphertext safe in git that only this cluster can decrypt, so the whole
# install rebuilds from the repository after a disk failure.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

NAMESPACE="ha-prod"
if [[ "${1:-}" == "--namespace" ]]; then
  NAMESPACE="${2:?--namespace needs a value}"
fi

OUT_DIR="k8s/overlays/prod/secrets"
[[ "$NAMESPACE" == "ha-prod" ]] || OUT_DIR="k8s/overlays/${NAMESPACE#ha-}/secrets"

command -v kubeseal >/dev/null 2>&1 || {
  echo "kubeseal not found. Install it:" >&2
  echo "  https://github.com/bitnami-labs/sealed-secrets/releases" >&2
  exit 1
}

KUBECTL="kubectl"
command -v kubectl >/dev/null 2>&1 || KUBECTL="microk8s kubectl"

mkdir -p "$OUT_DIR"

ask() {  # ask VAR "prompt"
  local __var="$1" __prompt="$2" __val
  read -rsp "  ${__prompt}: " __val
  echo
  [[ -n "$__val" ]] || { echo "  (empty — aborting)" >&2; exit 1; }
  printf -v "$__var" '%s' "$__val"
}

# Build a Secret on stdout, pipe straight into kubeseal. The plaintext Secret
# never touches the filesystem.
seal() {  # seal NAME key=value...
  local name="$1"; shift
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done

  $KUBECTL create secret generic "$name" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml \
    "${args[@]}" \
  | kubeseal --format yaml --namespace "$NAMESPACE" \
  > "${OUT_DIR}/${name}.sealed.yaml"

  echo "  wrote ${OUT_DIR}/${name}.sealed.yaml"
}

echo "Sealing secrets for namespace: $NAMESPACE"
echo "(input is hidden)"
echo

echo "── Home Assistant (config/secrets.yaml) ──"
ask HOME_NAME       "Home name"
ask HOME_LAT        "Latitude"
ask HOME_LON        "Longitude"
ask HOME_ELEV       "Elevation (m)"
ask PG_USER         "Postgres username [ha]"
ask PG_PASS         "Postgres password"

# secrets.yaml is delivered as a single file, because that is how Home
# Assistant consumes it — the initContainer copies it to /config/secrets.yaml.
SECRETS_YAML=$(cat <<EOF
home_name: "${HOME_NAME}"
home_latitude: ${HOME_LAT}
home_longitude: ${HOME_LON}
home_elevation: ${HOME_ELEV}
home_timezone: "Europe/Stockholm"
recorder_db_url: "postgresql://${PG_USER}:${PG_PASS}@postgres.${NAMESPACE}.svc.cluster.local:5432/homeassistant"
EOF
)

echo
echo "── Grafana Cloud (docs/grafana-cloud.md § Credentials) ──"
ask GC_PROM_URL   "Prometheus remote_write URL"
ask GC_PROM_USER  "Prometheus username (instance ID)"
ask GC_LOKI_URL   "Loki push URL"
ask GC_LOKI_USER  "Loki username (a DIFFERENT number)"
ask GC_TOKEN      "Grafana Cloud access token"
ask HA_TOKEN      "Home Assistant long-lived access token"

echo
echo "── restic backup ──"
ask RESTIC_REPO   "Repository (e.g. s3:http://minio.lan:9000/ha-backups)"
ask RESTIC_PASS   "Repository password"
ask S3_KEY        "S3 access key ID"
ask S3_SECRET     "S3 secret access key"

echo
echo "Sealing..."

$KUBECTL create secret generic ha-secrets \
  --namespace "$NAMESPACE" --dry-run=client -o yaml \
  --from-literal=secrets.yaml="$SECRETS_YAML" \
| kubeseal --format yaml --namespace "$NAMESPACE" \
> "${OUT_DIR}/ha-secrets.sealed.yaml"
echo "  wrote ${OUT_DIR}/ha-secrets.sealed.yaml"

seal postgres-credentials \
  "username=${PG_USER}" \
  "password=${PG_PASS}"

seal grafana-cloud \
  "prometheus-url=${GC_PROM_URL}" \
  "prometheus-username=${GC_PROM_USER}" \
  "loki-url=${GC_LOKI_URL}" \
  "loki-username=${GC_LOKI_USER}" \
  "api-token=${GC_TOKEN}" \
  "ha-token=${HA_TOKEN}"

seal restic \
  "repository=${RESTIC_REPO}" \
  "password=${RESTIC_PASS}" \
  "aws-access-key-id=${S3_KEY}" \
  "aws-secret-access-key=${S3_SECRET}"

cat <<EOF

Done. Review and commit:

    git add ${OUT_DIR}
    git diff --cached --stat
    git commit -m "Seal secrets for ${NAMESPACE}"

┌──────────────────────────────────────────────────────────────────────────┐
│ STORE THE RESTIC PASSWORD IN A PASSWORD MANAGER, NOW.                    │
│                                                                          │
│ The dependency is circular: restoring Sealed Secrets needs the sealing   │
│ key, restoring the sealing key needs the backup, and reading the backup  │
│ needs this password. If it only exists inside the cluster, losing the    │
│ cluster makes every backup permanently unreadable.                       │
└──────────────────────────────────────────────────────────────────────────┘
EOF
