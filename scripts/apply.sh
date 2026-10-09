#!/usr/bin/env bash
# Install or upgrade everything in this repo, in dependency order, rendered with site.yaml.
#
#   scripts/apply.sh             install/upgrade
#   scripts/apply.sh --dry-run   validate the local charts against the cluster, change nothing
#
# cert-manager goes first: its CRDs back the ClusterIssuers and Certificates in the local charts.
# Then LVM LocalPV and charts/cluster, whose StorageClass lvm the monitoring volumes need.
# Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig (run with sudo). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi

dry=()
case ${1:-} in
  "") ;;
  --dry-run) dry=(--dry-run=server --hide-secret) ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

[[ -f site.yaml ]] || { echo "site.yaml is missing: run scripts/configure.py (shape: site.example.yaml)" >&2; exit 1; }
[[ -f site.secret.yaml ]] || {
  echo "site.secret.yaml is missing: run scripts/setup-gandi-dns01.sh, or copy site.secret.example.yaml and fill it in" >&2
  exit 1
}

# A third-party release in helm/. Its install.sh has no dry-run mode, so a dry run skips it.
release() {
  if ((${#dry[@]})); then
    echo "==> $1 (skipped: dry run)"
  else
    echo "==> $1"
    "helm/$1/install.sh"
  fi
}

release cert-manager
release cert-manager-webhook-gandi
release lvm-localpv

echo "==> charts/cluster"
helm upgrade --install cluster charts/cluster --namespace kube-system \
  --values site.yaml --values site.secret.yaml --wait --timeout 5m "${dry[@]}" > /dev/null

# Monitoring next: kube-prometheus-stack brings the ServiceMonitor/PodMonitor CRDs.
release kube-prometheus-stack
release loki
release alloy

echo "==> charts/home"
helm upgrade --install home charts/home --namespace home --create-namespace \
  --values site.yaml --wait --timeout 10m "${dry[@]}" > /dev/null

echo "==> charts/immich"
helm upgrade --install immich charts/immich --namespace immich --create-namespace \
  --values site.yaml --wait --timeout 15m "${dry[@]}" > /dev/null

echo "==> charts/monitoring"
helm upgrade --install monitoring charts/monitoring --namespace monitoring --create-namespace \
  --values site.yaml --wait --timeout 5m "${dry[@]}" > /dev/null

echo "==> Done${dry:+ (dry run, nothing changed)}"
