#!/bin/sh
# kube-prometheus-stack: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
# Helm only installs the chart's CRDs on the first install; after a version bump, apply the new
# CRDs first (see the chart's upgrade notes).
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --version 91.9.0 \
  --namespace monitoring --create-namespace \
  --values values.yaml \
  --wait --timeout 10m
