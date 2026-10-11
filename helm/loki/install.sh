#!/bin/sh
# Loki: https://github.com/grafana/loki/tree/main/production/helm/loki
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
# values.yaml, then the site's override if any: values/loki.yaml in $CAIRN_SITE, else the repo root (scripts/lib.sh).
site=$(cd "${CAIRN_SITE:-$(dirname "$0")/../..}" && pwd)
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
set -- --values values.yaml
[ ! -f "$site/values/loki.yaml" ] || set -- "$@" --values "$site/values/loki.yaml"

helm upgrade --install loki loki \
  --repo https://grafana.github.io/helm-charts \
  --version 7.3.0 \
  --namespace monitoring --create-namespace \
  "$@" \
  --wait --timeout 10m
