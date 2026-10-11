#!/bin/sh
# CloudNativePG operator: https://cloudnative-pg.io/documentation/current/installation_upgrade/
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
# values.yaml, then the site's override if any: values/cloudnative-pg.yaml in $CAIRN_SITE, else the
# repo root (scripts/lib.sh).
site=$(cd "${CAIRN_SITE:-$(dirname "$0")/../..}" && pwd)
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
set -- --values values.yaml
[ ! -f "$site/values/cloudnative-pg.yaml" ] || set -- "$@" --values "$site/values/cloudnative-pg.yaml"

helm upgrade --install cloudnative-pg cloudnative-pg \
  --repo https://cloudnative-pg.github.io/charts \
  --version 0.29.1 \
  --namespace cnpg-system --create-namespace \
  "$@" \
  --wait --timeout 5m
