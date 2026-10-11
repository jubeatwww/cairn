# Sourced by the scripts in this directory, not run on its own. Source it before any cd: a relative
# $CAIRN_SITE is taken from the caller's directory.

# The repo, and the site directory (README "Site directory"): $CAIRN_SITE, else the repo root.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SITE=$(cd "${CAIRN_SITE:-$REPO}" 2> /dev/null && pwd) || { echo "CAIRN_SITE is not a directory: ${CAIRN_SITE:-}" >&2; exit 1; }
# Absolute, for helmfile (which reads it) and after a cd. Pass it on through sudo, which drops the
# environment.
export CAIRN_SITE=$SITE

# The kubeconfig: $KUBECONFIG, else ~/.kube/config, else k3s's own, which only root can read.
if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi
