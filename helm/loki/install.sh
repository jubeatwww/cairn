#!/bin/sh
# Loki: https://github.com/grafana/loki/tree/main/production/helm/loki
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install loki loki \
  --repo https://grafana.github.io/helm-charts \
  --version 7.3.0 \
  --namespace monitoring --create-namespace \
  --values values.yaml \
  --wait --timeout 10m
