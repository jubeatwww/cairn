#!/bin/sh
# cert-manager-webhook-gandi: DNS-01 solver for Gandi LiveDNS, https://github.com/SINTEF/cert-manager-webhook-gandi
# Needs cert-manager installed first: the chart creates cert-manager Issuers and Certificates.
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install cert-manager-webhook-gandi cert-manager-webhook-gandi \
  --repo https://sintef.github.io/cert-manager-webhook-gandi \
  --version v0.6.0 \
  --namespace cert-manager \
  --values values.yaml \
  --wait --timeout 5m
