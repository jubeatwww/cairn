#!/bin/sh
# OpenEBS LVM LocalPV: https://github.com/openebs/lvm-localpv
# Idempotent: installs on the first run, upgrades (or does nothing) afterwards.
set -eu
# values.yaml, then the site's override if any: values/lvm-localpv.yaml in $CAIRN_SITE, else the
# repo root (scripts/lib.sh).
site=$(cd "${CAIRN_SITE:-$(dirname "$0")/../..}" && pwd)
cd "$(dirname "$0")"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
set -- --values values.yaml
[ ! -f "$site/values/lvm-localpv.yaml" ] || set -- "$@" --values "$site/values/lvm-localpv.yaml"

helm upgrade --install lvm-localpv lvm-localpv \
  --repo https://openebs.github.io/lvm-localpv \
  --version 1.10.1 \
  --namespace openebs --create-namespace \
  "$@" \
  --wait --timeout 5m
