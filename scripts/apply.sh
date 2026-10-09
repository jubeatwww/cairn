#!/usr/bin/env bash
# Install or upgrade everything in this repo, in dependency order, rendered with site.yaml.
#
#   scripts/apply.sh             install/upgrade
#   scripts/apply.sh --dry-run   validate the local charts against the cluster, change nothing
#
# cert-manager goes first: its CRDs back the ClusterIssuers and Certificates in the local charts.
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

if ((${#dry[@]})); then
  echo "==> Dry run: skipping helm/*/install.sh (third-party releases)"
else
  echo "==> cert-manager"
  helm/cert-manager/install.sh
  echo "==> cert-manager-webhook-gandi"
  helm/cert-manager-webhook-gandi/install.sh
  # Monitoring next: kube-prometheus-stack brings the ServiceMonitor/PodMonitor CRDs.
  echo "==> kube-prometheus-stack"
  helm/kube-prometheus-stack/install.sh
  echo "==> loki"
  helm/loki/install.sh
  echo "==> alloy"
  helm/alloy/install.sh
fi

echo "==> charts/cluster"
helm upgrade --install cluster charts/cluster --namespace kube-system \
  --values site.yaml --values site.secret.yaml --wait --timeout 5m "${dry[@]}" > /dev/null

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
