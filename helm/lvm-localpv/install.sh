#!/bin/sh
# OpenEBS LVM LocalPV: https://github.com/openebs/lvm-localpv
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

helm upgrade --install lvm-localpv lvm-localpv \
  --repo https://openebs.github.io/lvm-localpv \
  --version 1.10.1 \
  --namespace openebs --create-namespace \
  --values values.yaml \
  --wait --timeout 5m
