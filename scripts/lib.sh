# Sourced by the scripts in this directory, not run on its own.
#
# The site directory holds what the charts are rendered with: site.yaml, site.secret.yaml, and
# optional per-release overrides values/<release>.yaml. It's $CAIRN_SITE, else the repo root, so
# a private repo (or any directory) can keep them out of this one. Source this before any cd:
# a relative $CAIRN_SITE is taken from the caller's directory.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SITE=$(cd "${CAIRN_SITE:-$REPO}" 2> /dev/null && pwd) || { echo "CAIRN_SITE is not a directory: ${CAIRN_SITE:-}" >&2; exit 1; }
# Absolute, for helmfile (which reads it) and after a cd. Pass it on through sudo, which drops the
# environment.
export CAIRN_SITE=$SITE

# Sets `values` to the helm --values for a local chart's release, in order: site.yaml,
# site.secret.yaml (with --secrets, if it exists: the templates say which keys they need), then
# values/<release>.yaml if it exists, so the override wins.
#   site_values <release> [--secrets]
site_values() {
  values=(--values "$SITE/site.yaml")
  [[ ${2:-} != --secrets || ! -f $SITE/site.secret.yaml ]] || values+=(--values "$SITE/site.secret.yaml")
  [[ ! -f $SITE/values/$1.yaml ]] || values+=(--values "$SITE/values/$1.yaml")
}
