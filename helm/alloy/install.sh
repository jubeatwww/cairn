#!/bin/sh
# Grafana Alloy: https://github.com/grafana/alloy/tree/main/operations/helm/charts/alloy
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install alloy alloy \
  --repo https://grafana.github.io/helm-charts \
  --version 1.13.0 \
  --namespace monitoring --create-namespace \
  --values values.yaml \
  --wait --timeout 5m
