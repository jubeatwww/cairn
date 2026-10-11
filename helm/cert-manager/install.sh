#!/bin/sh
# cert-manager: https://cert-manager.io/docs/installation/helm/
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
# values.yaml, then the site's override if any: values/cert-manager.yaml in $CAIRN_SITE, else the
# repo root (scripts/lib.sh).
site=$(cd "${CAIRN_SITE:-$(dirname "$0")/../..}" && pwd)
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
set -- --values values.yaml
[ ! -f "$site/values/cert-manager.yaml" ] || set -- "$@" --values "$site/values/cert-manager.yaml"

helm upgrade --install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --version v1.21.2 \
  --namespace cert-manager --create-namespace \
  "$@" \
  --wait --timeout 5m
