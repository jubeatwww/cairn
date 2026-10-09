#!/usr/bin/env bash
# Let's Encrypt DNS-01 via Gandi LiveDNS: set up, rotate the PAT, or check a new domain.
#
#   scripts/setup-gandi-dns01.sh [domain...]      default: site.yaml's acme.zones that use gandi
#
# Prompts for a Gandi Personal Access Token, checks it can manage every domain, writes it to the
# gitignored site.secret.yaml, installs cert-manager, the Gandi webhook and charts/cluster, then
# issues a staging cert for <domain> + *.<domain> and deletes it again.
# Idempotent. Run as your normal user (site.secret.yaml must stay yours). Uses $KUBECONFIG, else
# ~/.kube/config, else k3s's root-only kubeconfig through sudo.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SECRET_FILE=$REPO/site.secret.yaml
TEST_NS=default
TEST_LABEL=cairn/dns01-test

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "請用一般使用者執行，不要加 sudo（否則 site.secret.yaml 會變成 root 的）"

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi
# Root-only kubeconfig: run cluster commands through sudo.
as=()
[[ -r $KUBECONFIG ]] || as=(sudo env "KUBECONFIG=$KUBECONFIG")
k() { "${as[@]}" kubectl "$@"; }

if (( $# == 0 )); then
  gandi_zones=$(python3 -c 'import sys, yaml; z = (yaml.safe_load(open(sys.argv[1])).get("acme") or {}).get("zones") or {}; print(" ".join(k for k, v in z.items() if v == "gandi"))' "$REPO/site.yaml") ||
    die "讀不到 site.yaml 的 acme.zones（需要 python3-yaml），或改成直接帶網域參數"
  [[ -n $gandi_zones ]] || die "site.yaml 的 acme.zones 裡沒有用 gandi 的 zone，請直接帶網域參數"
  # shellcheck disable=SC2086
  set -- $gandi_zones
fi
domains=()
for d in "$@"; do
  d=${d,,}
  [[ $d =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $d == *.* ]] || die "不是合法的網域：$d"
  domains+=("$d")
done

# 1. PAT
if [[ -f $SECRET_FILE ]]; then
  read -rsp "貼上 Gandi PAT（直接按 Enter 沿用現有的）: " pat; echo
  if [[ -z $pat ]]; then
    pat=$("$REPO/scripts/secret.py" get gandi.pat)
  fi
else
  read -rsp "貼上 Gandi PAT: " pat; echo
fi
pat=${pat//[[:space:]]/}
[[ -n $pat ]] || die "PAT 是空的"
bad='["\\]'
[[ ! $pat =~ $bad ]] || die "PAT 含有 \" 或 \\，看起來不是 Gandi token"

# 2. Check the token against Gandi before touching the cluster.
#    The header goes through stdin so the token never shows up in `ps`.
for d in "${domains[@]}"; do
  step "檢查 PAT 能不能存取 $d 的 LiveDNS"
  code=$(printf 'Authorization: Bearer %s\n' "$pat" |
    curl -sS -o /dev/null -w '%{http_code}' -H @- "https://api.gandi.net/v5/livedns/domains/$d") ||
    die "連不到 api.gandi.net"
  case $code in
    200) echo "OK" ;;
    401|403) die "Gandi 回 $code：PAT 錯誤、已過期，或權限不足。權限要有「Manage domain name technical configurations」，範圍要包含 $d" ;;
    404) die "Gandi 回 404：這個 PAT 看不到 $d 的 LiveDNS zone。要傳網域本身（例如 example.com，不是子網域），且 PAT 要建在擁有它的 organization" ;;
    *) die "Gandi 回了預期外的 HTTP $code" ;;
  esac
done

# 3. Secret values file: gitignored, readable only by you. Other secrets in it are kept.
step "寫入 site.secret.yaml"
printf '%s' "$pat" | "$REPO/scripts/secret.py" set gandi.pat

# 4. cert-manager and the webhook first (CRDs), then the chart with the ClusterIssuers and the Secret
((${#as[@]} == 0)) || { step "sudo 驗證"; sudo -v; }
step "安裝 cert-manager"
"${as[@]}" "$REPO/helm/cert-manager/install.sh"
step "安裝 cert-manager-webhook-gandi"
"${as[@]}" "$REPO/helm/cert-manager-webhook-gandi/install.sh"
step "安裝 charts/cluster（ClusterIssuer、Gandi Secret）"
"${as[@]}" helm upgrade --install cluster "$REPO/charts/cluster" --namespace kube-system \
  --values "$REPO/site.yaml" --values "$SECRET_FILE" --wait --timeout 5m > /dev/null

step "等待 webhook API 與 ClusterIssuer 就緒"
k wait --for=condition=Available apiservice/v1alpha1.acme.bwolf.me --timeout=2m
k wait --for=condition=Ready clusterissuer/letsencrypt-staging clusterissuer/letsencrypt-prod --timeout=2m

# 5. Prove it end to end with staging certs. Leftovers from a failed run are removed first,
#    since a Certificate that already failed sits in backoff and wouldn't retry right away.
#    Apex and wildcard share one TXT name, so cert-manager solves them one after the other.
step "用 letsencrypt-staging 簽測試憑證：${domains[*]}（各含 wildcard，大約 2–5 分鐘）"
k -n "$TEST_NS" delete certificate,secret -l "$TEST_LABEL" --ignore-not-found
for d in "${domains[@]}"; do
  name=dns01-test-${d//./-}
  k apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $name
  namespace: $TEST_NS
  labels:
    $TEST_LABEL: "true"
spec:
  secretName: $name-tls
  secretTemplate:
    labels:
      $TEST_LABEL: "true"
  dnsNames:
    - $d
    - "*.$d"
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
EOF
done

failed=()
for d in "${domains[@]}"; do
  k -n "$TEST_NS" wait --for=condition=Ready "certificate/dns01-test-${d//./-}" --timeout=10m || failed+=("$d")
done

if (( ${#failed[@]} )); then
  step "除錯資訊"
  k -n "$TEST_NS" describe certificate -l "$TEST_LABEL" | grep -A15 '^Status:' || true
  k -n "$TEST_NS" describe challenges || true
  k -n cert-manager logs deploy/cert-manager-webhook-gandi --tail=30 || true
  die "測試憑證沒簽成功：${failed[*]}。資源先保留方便除錯，清除指令：kubectl -n $TEST_NS delete certificate,secret -l $TEST_LABEL"
fi

k -n "$TEST_NS" delete certificate,secret -l "$TEST_LABEL"
step "完成：${domains[*]} 都能用 Gandi DNS-01 簽憑證，測試憑證已刪除。"
echo "之後在 Ingress 加 annotation cert-manager.io/cluster-issuer: letsencrypt-prod 就能拿到正式憑證。"
