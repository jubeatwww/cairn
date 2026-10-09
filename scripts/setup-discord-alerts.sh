#!/usr/bin/env bash
# Alertmanager notifications in a Discord channel: set up, or switch to another webhook.
#
#   scripts/setup-discord-alerts.sh
#
# Prompts for a Discord webhook URL, checks it with Discord, writes it to the gitignored
# site.secret.yaml, installs charts/monitoring (the Secret) and kube-prometheus-stack
# (Alertmanager's config), then sends a test alert to the channel.
# Idempotent. Run as your normal user (site.secret.yaml must stay yours). Uses $KUBECONFIG, else
# ~/.kube/config, else k3s's root-only kubeconfig through sudo.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SECRET_FILE=$REPO/site.secret.yaml
AM_API=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:9093/proxy/api/v2

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "請用一般使用者執行，不要加 sudo（否則 site.secret.yaml 會變成 root 的）"
[[ -f $REPO/site.yaml ]] || die "沒有 site.yaml：先跑 scripts/configure.py"

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi
# Root-only kubeconfig: run cluster commands through sudo.
as=()
[[ -r $KUBECONFIG ]] || as=(sudo env "KUBECONFIG=$KUBECONFIG")
k() { "${as[@]}" kubectl "$@"; }

# 1. Webhook URL: in Discord, channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL
current=$("$REPO/scripts/secret.py" get discord.webhookUrl)
if [[ -n $current ]]; then
  read -rsp "貼上 Discord webhook URL（直接按 Enter 沿用現有的）: " url; echo
  url=${url:-$current}
else
  read -rsp "貼上 Discord webhook URL: " url; echo
fi
url=${url//[[:space:]]/}
[[ $url =~ ^https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] ||
  die "看起來不是 Discord webhook URL（https://discord.com/api/webhooks/<id>/<token>）"

# 2. Check it before touching the cluster. GET returns the webhook's details and posts nothing.
#    The URL goes through stdin so its token never shows up in `ps`.
step "向 Discord 確認 webhook"
resp=$(printf 'url = "%s"\n' "$url" | curl -sS -K - -w '\n%{http_code}') || die "連不到 Discord"
code=${resp##*$'\n'}
case $code in
  200) echo "OK：webhook「$(printf '%s' "${resp%$'\n'*}" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("name", "?"))')」" ;;
  401|404) die "Discord 回 $code：這個 webhook 不存在或已被刪除，請重新複製 URL" ;;
  *) die "Discord 回了預期外的 HTTP $code" ;;
esac

# 3. Secret values file: gitignored, readable only by you. Other secrets in it are kept.
step "寫入 site.secret.yaml"
printf '%s' "$url" | "$REPO/scripts/secret.py" set discord.webhookUrl

# 4. The Secret first: Alertmanager's pod mounts it.
((${#as[@]} == 0)) || { step "sudo 驗證"; sudo -v; }
step "安裝 charts/monitoring（webhook 的 Secret）"
"${as[@]}" helm upgrade --install monitoring "$REPO/charts/monitoring" --namespace monitoring --create-namespace \
  --values "$REPO/site.yaml" --values "$SECRET_FILE" --wait --timeout 5m > /dev/null
step "安裝 kube-prometheus-stack（Alertmanager 設定）"
"${as[@]}" "$REPO/helm/kube-prometheus-stack/install.sh" > /dev/null

step "等待 Alertmanager 載入新設定"
k -n monitoring rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=3m
for _ in $(seq 1 24); do
  k get --raw "$AM_API/status" | grep -q webhook_url_file && break
  sleep 5
done
k get --raw "$AM_API/status" | grep -q webhook_url_file || die "Alertmanager 兩分鐘內沒載入 Discord 設定：kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0"

# 5. A test alert that ends by itself, so the channel gets both messages. Sent with amtool inside
#    the pod: the API server's service proxy can't POST JSON to Alertmanager.
step "送測試警報"
k -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert add \
  alertname=CairnTestAlert severity=warning namespace=monitoring \
  --annotation='description="scripts/setup-discord-alerts.sh 的測試警報，幾分鐘後會自己解除。"' \
  --end="$(date -u -d '+2 min' +%FT%TZ)"
step "完成：Discord 約 30 秒內會收到 [FIRING:1] CairnTestAlert，約 5–7 分鐘後收到 [RESOLVED]。"
echo "沒收到的話：kubectl -n monitoring logs alertmanager-kube-prometheus-stack-alertmanager-0 | grep -i discord"
