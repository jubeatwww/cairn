#!/usr/bin/env bash
# Install or upgrade what site.yaml turns on, in dependency order, rendered with the files in the
# site directory ($CAIRN_SITE, else the repo root; see scripts/lib.sh).
#
#   scripts/apply.sh             install/upgrade
#   scripts/apply.sh --dry-run   validate the local charts against the cluster, change nothing
#
# Always: cert-manager first (its CRDs back the ClusterIssuers and Certificates in the local
# charts), its Gandi webhook if a zone uses the gandi solver, then LVM LocalPV and charts/cluster,
# whose StorageClass lvm the other volumes need. Then each component in site.yaml's components.
# Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig (run with sudo). Idempotent.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$REPO"

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi

dry=()
case ${1:-} in
  "") ;;
  --dry-run) dry=(--dry-run=server --hide-secret) ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

[[ -f $SITE/site.yaml ]] || { echo "$SITE/site.yaml is missing: run scripts/configure.py (shape: site.example.yaml)" >&2; exit 1; }

# What to install, one per line: the components site.yaml turns on, gandi if a zone uses that
# solver, and pg:<namespace> for each Postgres cluster.
plan=$(python3 - "$SITE/site.yaml" <<'EOF'
import sys, yaml
site = yaml.safe_load(open(sys.argv[1])) or {}
names = ("home", "immich", "monitoring", "postgres")
components = site.get("components") if isinstance(site.get("components"), dict) else {}
missing = [n for n in names if not isinstance(components.get(n), bool)]
if missing:
    sys.exit("components." + ", components.".join(missing) + " must be true or false (site.yaml): run scripts/configure.py")
print("\n".join(n for n in names if components[n]))
acme = site.get("acme") or {}
if "gandi" in [*(acme.get("zones") or {}).values(), acme.get("defaultSolver")]:
    print("gandi")
for ns in (site.get("postgres") or {}).get("clusters") or {}:
    print("pg:" + ns)
EOF
)
on() { grep -qx "$1" <<< "$plan"; }

if { on gandi || on monitoring; } && [[ ! -f $SITE/site.secret.yaml ]]; then
  echo "$SITE/site.secret.yaml is missing: run scripts/setup-gandi-dns01.sh and scripts/setup-discord-alerts.sh, or copy site.secret.example.yaml and fill it in" >&2
  exit 1
fi

# A third-party release in helm/. Its install.sh has no dry-run mode, so a dry run skips it.
release() {
  if ((${#dry[@]})); then
    echo "==> $1 (skipped: dry run)"
  else
    echo "==> $1"
    "helm/$1/install.sh"
  fi
}

# A local chart, rendered with site.yaml (and site.secret.yaml with --secrets), then the release's
# override in the site directory (scripts/lib.sh).
#   chart <release> <namespace> <timeout> [--secrets]
chart() {
  site_values "$1" "${4:-}"
  echo "==> charts/$1 ($2)"
  helm upgrade --install "$1" "charts/$1" --namespace "$2" --create-namespace \
    "${values[@]}" --wait --timeout "$3" "${dry[@]}" > /dev/null
}

echo "==> Site: $SITE"
release cert-manager
if on gandi; then release cert-manager-webhook-gandi; fi
release lvm-localpv
chart cluster kube-system 5m --secrets

# Monitoring next: kube-prometheus-stack brings the ServiceMonitor/PodMonitor CRDs.
if on monitoring; then
  release kube-prometheus-stack
  release loki
  release alloy
fi
if on postgres; then release cloudnative-pg; fi

if on home; then chart home home 10m; fi
if on immich; then chart immich immich 15m; fi
if on monitoring; then chart monitoring monitoring 5m --secrets; fi

# One release per Postgres cluster in site.yaml (postgres.clusters), in the namespace of its name.
if on postgres; then
  for ns in $(sed -n 's/^pg://p' <<< "$plan"); do chart postgres "$ns" 10m; done
fi

echo "==> Done${dry:+ (dry run, nothing changed)}"
