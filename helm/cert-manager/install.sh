#!/bin/sh
# cert-manager: https://cert-manager.io/docs/installation/helm/
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version v1.21.2 \
  --namespace cert-manager --create-namespace \
  --values values.yaml \
  --wait --timeout 5m
