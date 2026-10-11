#!/bin/sh
# CloudNativePG operator: https://cloudnative-pg.io/documentation/current/installation_upgrade/
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install cloudnative-pg cloudnative-pg \
  --repo https://cloudnative-pg.github.io/charts \
  --version 0.29.1 \
  --namespace cnpg-system --create-namespace \
  --values values.yaml \
  --wait --timeout 5m
