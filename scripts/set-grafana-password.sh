#!/usr/bin/env bash
# Grafana's admin password: set it in Grafana and in its Secret together.
#
#   scripts/set-grafana-password.sh
#
# Prompts for the password (enter the current one to keep it), sets it in Grafana's database
# with `grafana cli` and in the Secret kube-prometheus-stack-grafana (admin-password), restarts
# Grafana, and checks that the sidecars can log in. They read the Secret's copy to make Grafana
# reload dashboards and data sources, so a password changed only in Grafana's UI leaves them
# failing with 401. The chart keeps the Secret's value across upgrades.
# Idempotent. Uses $KUBECONFIG, else ~/.kube/config, else k3s's root-only kubeconfig through sudo.
set -euo pipefail

NS=monitoring
NAME=kube-prometheus-stack-grafana

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [[ -z ${KUBECONFIG:-} ]]; then
  if [[ -r $HOME/.kube/config ]]; then export KUBECONFIG=$HOME/.kube/config; else export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
fi
# Root-only kubeconfig: run cluster commands through sudo.
as=()
[[ -r $KUBECONFIG ]] || as=(sudo env "KUBECONFIG=$KUBECONFIG")
k() { "${as[@]}" kubectl "$@"; }

read -rsp "Grafana admin 密碼（要沿用現在的就輸入現在的）: " pw; echo
[[ ${#pw} -ge 4 ]] || die "密碼至少要 4 個字元"
read -rsp "再輸入一次: " again; echo
[[ $pw == "$again" ]] || die "兩次輸入不一樣"

((${#as[@]} == 0)) || { step "sudo 驗證"; sudo -v; }

# The password only goes through pipes (printf is a shell builtin), never argv, so `ps` can't see it.
step "設定 Grafana 資料庫裡的密碼"
printf '%s\n' "$pw" | k -n $NS exec -i deploy/$NAME -c grafana -- \
  grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini \
  admin reset-admin-password --password-from-stdin > /dev/null

step "更新 Secret $NAME"
printf '{"data":{"admin-password":"%s"}}' "$(printf '%s' "$pw" | base64 -w0)" |
  k -n $NS patch secret $NAME --type merge --patch-file /dev/stdin > /dev/null

# The sidecars get the password as an environment variable, read when the pod starts.
step "重啟 Grafana"
k -n $NS rollout restart deploy/$NAME > /dev/null
k -n $NS rollout status deploy/$NAME --timeout=3m

step "確認 sidecar 用 Secret 的密碼登得進 Grafana"
k -n $NS exec deploy/$NAME -c grafana-sc-dashboard -- python3 -c "
import base64, os, urllib.request as u
auth = base64.b64encode((os.environ['REQ_USERNAME'] + ':' + os.environ['REQ_PASSWORD']).encode()).decode()
u.urlopen(u.Request('http://localhost:3000/api/user', headers={'Authorization': 'Basic ' + auth}), timeout=10)
" || die "登不進去：kubectl -n $NS logs deploy/$NAME -c grafana-sc-dashboard"
step "完成：用 admin 和剛才的密碼登入 Grafana。"
