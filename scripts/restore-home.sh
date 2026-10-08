#!/usr/bin/env bash
# Restore Zigbee2MQTT and Home Assistant state from a nightly backup on the NAS (charts/home, backup).
#
#   scripts/restore-home.sh <YYYY-MM-DD>
#
# Stops both apps, unpacks that day's archives over their volumes, and starts them again
# (a couple of minutes of downtime). Files the backup doesn't contain, such as HA's history
# database, are left as they are. The NAS location comes from site.yaml. Needs the PVCs to exist,
# so run scripts/apply.sh first on a fresh cluster.
# Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig (run with sudo).
set -euo pipefail
cd "$(dirname "$0")/.."

day=${1:-}
[[ $day =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: $0 <YYYY-MM-DD>" >&2; exit 1; }

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi
k() { kubectl -n home "$@"; }

[[ -f site.yaml ]] || { echo "site.yaml is missing: run scripts/configure.py (shape: site.example.yaml)" >&2; exit 1; }

job=restore-$(date +%s)
manifest=$(helm template home charts/home --namespace home --values site.yaml \
  --set restore.date="$day" --set restore.job="$job" --show-only templates/backup/restore-job.yaml)

echo "==> Stopping home-assistant and zigbee2mqtt"
k scale deploy/home-assistant deploy/zigbee2mqtt --replicas=0
while k get pods -l 'app.kubernetes.io/name in (home-assistant,zigbee2mqtt)' -o name | grep -q .; do sleep 2; done

echo "==> Restoring $day ($job)"
k apply -f - <<< "$manifest"

until status=$(k get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}') && [[ $status != / ]]; do sleep 2; done
k logs "job/$job" || true
if [[ $status != 1/* ]]; then
  echo "ERROR: restore failed. The apps stay stopped; fix it and re-run, or start them as they are:" >&2
  echo "  kubectl -n home scale deploy/home-assistant deploy/zigbee2mqtt --replicas=1" >&2
  exit 1
fi

echo "==> Starting home-assistant and zigbee2mqtt"
k scale deploy/home-assistant deploy/zigbee2mqtt --replicas=1
