#!/usr/bin/env bash
# Switch Immich's external photo library between read-only and writable.
#
#   scripts/immich-library.sh rw   before editing metadata (tags, descriptions, dates, ratings) in Immich
#   scripts/immich-library.sh ro   when done
#
# Immich keeps those edits in .xmp sidecars next to the originals. On a read-only mount the sidecar
# write fails silently and Immich re-reads the file, so the edit is lost without an error: edit only
# while rw. The NAS export must allow writes for rw to work. Restarts immich-server (about a minute).
# scripts/apply.sh always leaves the library read-only.
# Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig (run with sudo).
set -euo pipefail
cd "$(dirname "$0")/.."

case ${1:-} in
  rw) writable=true ;;
  ro) writable=false ;;
  *) echo "usage: $0 rw|ro" >&2; exit 1 ;;
esac
[[ -f site.yaml ]] || { echo "site.yaml is missing: run scripts/configure.py (shape: site.example.yaml)" >&2; exit 1; }

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi

echo "==> Remounting the library $1 (immich-server restarts)"
helm upgrade immich charts/immich --namespace immich --values site.yaml \
  --set libraryWritable="$writable" --wait --timeout 5m > /dev/null

ro=$(kubectl -n immich get deploy immich-server \
  -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="library")].readOnly}')
echo "==> Done: the library is $([[ $ro == true ]] && echo read-only || echo writable)"
