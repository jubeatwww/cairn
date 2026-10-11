#!/usr/bin/env bash
# Restore one night's backup from the NAS (charts/backup): an app's, or a component's.
#
#   scripts/restore.sh <name> <YYYY-MM-DD>     name: an entry in site.yaml's apps, or a component
#                                              with a backup (monitoring)
#
# Lists what it would restore and the workloads it would stop (those mounting the backed-up volumes,
# and with a database, those using its credentials), and asks first. Then it stops them, restores
# the database dump (in one transaction: if it fails, the database is unchanged) and the volume
# archives (unpacked over what's there; files the backup leaves out, like HA's history database,
# stay), and starts them again. Needs the release to exist: on a fresh cluster, helmfile apply first.
# Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig (run with sudo).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO"

name=${1:-} day=${2:-}
[[ -n $name && $day =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: $0 <name> <YYYY-MM-DD>" >&2; exit 1; }

job=restore-$(date +%s)
manifest=$(helmfile -q -f helmfile.yaml.gotmpl template --skip-deps -l backup="$name" \
  --set restore.date="$day" --set restore.job="$job" --show-only templates/restore-job.yaml) ||
  { echo "Nothing to restore for $name: no backup release for it in helmfile.yaml.gotmpl." >&2; exit 1; }

# From the Job: its namespace, the PVCs it writes, and whether it restores a database.
read -r ns db claims < <(python3 -c '
import sys, yaml
job = next(d for d in yaml.safe_load_all(sys.stdin) if d)
spec = job["spec"]["template"]["spec"]
claims = [v["persistentVolumeClaim"]["claimName"] for v in spec["volumes"] if "persistentVolumeClaim" in v]
db = any(c["name"] == "database" for c in spec.get("initContainers", []))
print(job["metadata"]["namespace"], int(db), ",".join(claims))
' <<< "$manifest")
k() { kubectl -n "$ns" "$@"; }

# The Deployments and StatefulSets to stop: "<kind>/<name> <replicas> <pod selector>" per line.
workloads=$(k get deploy,statefulset -o json | python3 -c '
import json, sys
claims, db = set(filter(None, sys.argv[1].split(","))), sys.argv[2] == "1"
for w in json.load(sys.stdin)["items"]:
    pod = w["spec"]["template"]["spec"]
    uses_claim = any(v.get("persistentVolumeClaim", {}).get("claimName") in claims for v in pod.get("volumes", []))
    containers = pod.get("containers", []) + pod.get("initContainers", [])
    refs = [e.get("valueFrom", {}).get("secretKeyRef", {}).get("name") for c in containers for e in c.get("env", [])]
    refs += [e.get("secretRef", {}).get("name") for c in containers for e in c.get("envFrom", [])]
    if uses_claim or (db and "postgres-app" in refs):
        selector = ",".join(f"{k}={v}" for k, v in w["spec"]["selector"].get("matchLabels", {}).items())
        kind, name, replicas = w["kind"].lower(), w["metadata"]["name"], w["spec"].get("replicas", 1)
        print(f"{kind}/{name} {replicas} {selector}")
' "$claims" "$db")

echo "Restore $name from $day (namespace $ns):"
((db)) && echo "  database: replaced by that day's dump"
[[ -n $claims ]] && echo "  volumes:  ${claims//,/, } (archives unpacked over them)"
echo "Stopped meanwhile:"
if [[ -n $workloads ]]; then while read -r w n _; do echo "  $w ($n)"; done <<< "$workloads"; else echo "  (none)"; fi
read -rp "Go ahead? [y/N] " ok
[[ $ok == [yY] ]] || { echo "Nothing changed."; exit 0; }

start() { [[ -z $workloads ]] || while read -r w n _; do k scale "$w" --replicas="$n"; done <<< "$workloads"; }
if [[ -n $workloads ]]; then
  echo "==> Stopping"
  while read -r w _ sel; do
    k scale "$w" --replicas=0
    while k get pods -l "$sel" -o name | grep -q .; do sleep 2; done
  done <<< "$workloads"
fi

echo "==> Restoring ($job)"
k apply -f - <<< "$manifest"
until status=$(k get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}') && [[ $status != / ]]; do sleep 2; done
k logs "job/$job" --all-containers || true
if [[ $status != 1/* ]]; then
  echo "ERROR: restore failed. The workloads stay stopped; fix it and re-run, or start them as they are:" >&2
  [[ -z $workloads ]] || while read -r w n _; do echo "  kubectl -n $ns scale $w --replicas=$n" >&2; done <<< "$workloads"
  exit 1
fi

echo "==> Starting"
start
echo "==> Done"
