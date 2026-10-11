#!/usr/bin/env bash
# Restore one Postgres cluster's database from a nightly dump on the NAS (charts/postgres-cluster).
#
#   scripts/restore-postgres.sh <namespace> <YYYY-MM-DD>
#
# Replaces the database's contents with that day's dump, in one transaction. Stop the apps that
# use it first: open connections hold locks that block the restore. Asks before changing anything.
# The NAS location comes from site.yaml (scripts/lib.sh). On a fresh cluster, run helmfile apply first.
# Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig (run with sudo).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO"

ns=${1:-} day=${2:-}
[[ -n $ns && $day =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: $0 <namespace> <YYYY-MM-DD>" >&2; exit 1; }

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi
k() { kubectl -n "$ns" "$@"; }

[[ -f $SITE/site.yaml ]] || { echo "$SITE/site.yaml is missing: run scripts/configure.py (shape: site.example.yaml)" >&2; exit 1; }

job=postgres-restore-$(date +%s)
manifest=$(helmfile -q -f helmfile.yaml.gotmpl template --skip-deps -l name=postgres,namespace="$ns" \
  --set restore.date="$day" --set restore.job="$job" --show-only templates/backup/restore-job.yaml)

echo "Open connections in $ns (stop these apps first):"
primary=$(k get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name)
k exec "$primary" -c postgres -- psql -Atc \
  "select datname || ': ' || usename || ' from ' || coalesce(client_addr::text, 'local') from pg_stat_activity where datname is not null and usename <> 'postgres' and pid <> pg_backend_pid()" || true
read -rp "Replace $ns's database with the dump from $day? [y/N] " ok
[[ $ok == [yY] ]] || { echo "Nothing changed."; exit 0; }

echo "==> Restoring $day ($job)"
k apply -f - <<< "$manifest"

until status=$(k get job "$job" -o jsonpath='{.status.succeeded}/{.status.failed}') && [[ $status != / ]]; do sleep 2; done
k logs "job/$job" || true
[[ $status == 1/* ]] || { echo "ERROR: restore failed; the database is unchanged." >&2; exit 1; }
echo "==> Done. Start the apps again."
