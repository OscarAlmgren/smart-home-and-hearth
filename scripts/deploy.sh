#!/usr/bin/env bash
# DEPRECATED. Deploys are GitOps now — this script no longer does anything.
#
# It used to `git pull && docker compose up -d` on the server. Running that
# today would start a second Home Assistant in Docker, competing with the
# Kubernetes pod for host :8123 and the Zigbee dongle. Whichever won would be
# unclear, and the symptoms confusing.
#
# Kept as a refusing stub rather than deleted, because it was the muscle-memory
# command for months.
set -euo pipefail

cat >&2 <<'EOF'

  scripts/deploy.sh is deprecated and does nothing.

  Deployment is now GitOps. Argo CD watches this repository and syncs `main`
  to the ha-prod namespace automatically.

  To ship a change:

      git switch dev
      # edit config/ or k8s/
      ./scripts/render-env.sh --check
      git commit -am "..." && git push

      # then open PRs: dev -> test -> main
      # Argo CD applies main within ~3 minutes

  To see what is deployed right now:

      export ARGOCD_OPTS='--core'
      argocd app get ha-prod
      argocd app diff ha-prod
      kubectl -n ha-prod get pods

  Full workflow:      docs/lcm.md
  Cluster bring-up:   docs/microk8s-bootstrap.md

EOF
exit 1
