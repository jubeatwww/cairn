#!/bin/sh
# cert-manager-webhook-gandi: DNS-01 solver for Gandi LiveDNS, https://github.com/SINTEF/cert-manager-webhook-gandi
# Needs cert-manager installed first: the chart creates cert-manager Issuers and Certificates.
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
# values.yaml, then the site's override if any: values/cert-manager-webhook-gandi.yaml in
# $CAIRN_SITE, else the repo root (scripts/lib.sh).
site=$(cd "${CAIRN_SITE:-$(dirname "$0")/../..}" && pwd)
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
set -- --values values.yaml
[ ! -f "$site/values/cert-manager-webhook-gandi.yaml" ] || set -- "$@" --values "$site/values/cert-manager-webhook-gandi.yaml"

helm upgrade --install cert-manager-webhook-gandi cert-manager-webhook-gandi \
  --repo https://sintef.github.io/cert-manager-webhook-gandi \
  --version v0.6.0 \
  --namespace cert-manager \
  "$@" \
  --wait --timeout 5m
