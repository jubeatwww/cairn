#!/bin/sh
# Grafana Alloy: https://github.com/grafana/alloy/tree/main/operations/helm/charts/alloy
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
# values.yaml, then the site's override if any: values/alloy.yaml in $CAIRN_SITE, else the repo root (scripts/lib.sh).
site=$(cd "${CAIRN_SITE:-$(dirname "$0")/../..}" && pwd)
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
set -- --values values.yaml
[ ! -f "$site/values/alloy.yaml" ] || set -- "$@" --values "$site/values/alloy.yaml"

helm upgrade --install alloy alloy \
  --repo https://grafana.github.io/helm-charts \
  --version 1.13.0 \
  --namespace monitoring --create-namespace \
  "$@" \
  --wait --timeout 5m
