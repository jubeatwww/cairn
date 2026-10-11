#!/usr/bin/env python3
"""Check that the cluster is doing what this repo sets up. Read-only, except --test-alert.

    scripts/check.py                 every check below
    scripts/check.py --test-alert    also send a test alert to Discord; it resolves by itself
                                     (after scripts/secret.py set discord.webhookUrl)

  certificates  every cert-manager Certificate is Ready, with more than 14 days left
  backups       every CronJob backup (charts/backup) succeeded in the last 26 hours
  targets       every Prometheus target is up
  rules         every Prometheus rule evaluates without errors
  alerts        nothing fires besides Watchdog and InfoInhibitor
  metrics       every metric a rule or a Grafana dashboard reads, and a target exposes, is kept:
                after bumping kube-prometheus-stack, this catches one that the metricRelabelings
                in infrastructure/monitoring/kube-prometheus-stack.yaml drop

Exits 1 if a check fails. Uses $KUBECONFIG, else ~/.kube/config.
"""
import datetime
import json
import os
import re
import subprocess
import sys

import yaml

ENV = dict(os.environ)
ENV.setdefault("KUBECONFIG", os.path.expanduser("~/.kube/config"))
PROM = "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1"
ALERTMANAGER_POD = "alertmanager-kube-prometheus-stack-alertmanager-0"
NOW = datetime.datetime.now(datetime.timezone.utc)
# Metrics that are read but dropped on purpose, and why.
ACCEPTED = {
    "container_memory_swap": "kube-prometheus-stack's own default cAdvisor rules drop it; its swap panel stays empty",
}
failed = []


def kubectl(*args):
    return subprocess.run(["kubectl", *args], env=ENV, check=True, capture_output=True, text=True).stdout


def kget(*args):
    return json.loads(kubectl("get", *args, "-o", "json"))["items"]


def prom(path):
    return json.loads(kubectl("get", "--raw", PROM + path))["data"]


def when(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def report(name, problems, ok):
    """Print one check's result: its problems, or what it found fine."""
    if problems:
        failed.append(name)
        print(f"FAIL {name}")
        for p in problems:
            print(f"     {p}")
    else:
        print(f"OK   {name}: {ok}")


def certificates():
    certs = kget("certificates", "-A")
    problems = []
    for c in certs:
        name = f"{c['metadata']['namespace']}/{c['metadata']['name']}"
        ready = next((x for x in c.get("status", {}).get("conditions", []) if x["type"] == "Ready"), {})
        if ready.get("status") != "True":
            problems.append(f"{name}：沒有 Ready（{ready.get('message', '沒有狀態')}）")
        elif "notAfter" in c["status"] and when(c["status"]["notAfter"]) - NOW < datetime.timedelta(days=14):
            problems.append(f"{name}：{c['status']['notAfter']} 到期，沒有自動更新")
    report("certificates", problems, f"{len(certs)} 張都有效")


def backups():
    jobs = [j for j in kget("cronjobs", "-A") if j["metadata"]["name"] == "backup"]
    problems, waiting = [], 0
    for j in jobs:
        ns = j["metadata"]["namespace"]
        last = j.get("status", {}).get("lastSuccessfulTime")
        if last and NOW - when(last) < datetime.timedelta(hours=26):
            continue
        if not last and NOW - when(j["metadata"]["creationTimestamp"]) < datetime.timedelta(hours=26):
            waiting += 1
            continue
        problems.append(f"{ns}：上次成功是 {last or '從來沒有'}（kubectl -n {ns} get jobs）")
    report("backups", problems, f"{len(jobs)} 個都在 26 小時內成功" + (f"（{waiting} 個新的還沒排到）" if waiting else ""))


def targets():
    active = prom("/targets?state=active")["activeTargets"]
    down = [f"{t['labels'].get('job')} {t['scrapeUrl']}：{t.get('lastError') or t['health']}" for t in active if t["health"] != "up"]
    report("targets", down, f"{len(active)} 個都 up")


def rules():
    groups = prom("/rules")["groups"]
    bad = [f"{g['name']} / {r['name']}：{r.get('lastError', r['health'])}" for g in groups for r in g["rules"] if r["health"] != "ok"]
    report("rules", bad, f"{sum(len(g['rules']) for g in groups)} 條都正常")


def alerts():
    firing = [a for a in prom("/alerts")["alerts"] if a["state"] == "firing"
              and a["labels"]["alertname"] not in ("Watchdog", "InfoInhibitor")]
    report("alerts", [f"{a['labels']['alertname']} {a['labels'].get('namespace', '')}".strip() for a in firing], "沒有")


def metrics():
    exprs = [r["expr"] for item in kget("prometheusrules", "-A") for g in item["spec"]["groups"] for r in g["rules"]]

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k in ("expr", "query", "definition") and isinstance(v, str):
                    exprs.append(v)
                else:
                    walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    for cm in kget("configmaps", "-A", "-l", "grafana_dashboard=1"):
        for text in (cm.get("data") or {}).values():
            try:
                walk(json.loads(text))
            except ValueError:
                pass
    tokens = {t for e in exprs for t in re.findall(r"[a-zA-Z_:][a-zA-Z0-9_:]*", e)}

    # Each scrape pool's metric_relabel_configs that drop whole metrics (by __name__ alone).
    config = yaml.safe_load(prom("/status/config")["yaml"])
    name_rules = {s["job_name"]: [r for r in s.get("metric_relabel_configs") or []
                                  if r.get("source_labels") == ["__name__"] and r.get("action") in ("keep", "drop")]
                  for s in config["scrape_configs"]}
    pools = {frozenset(t["labels"].items()): t["scrapePool"] for t in prom("/targets?state=active")["activeTargets"]}

    def kept(pool, name):
        for r in name_rules.get(pool, []):
            if (re.fullmatch(r.get("regex", "(.*)"), name) is not None) != (r["action"] == "keep"):
                return False
        return True

    # What each target exposes, before relabeling: the scrape cache keeps every family's metadata.
    # A histogram's or summary's family name only shows up in its series' suffixes.
    exposed, survives = set(), set()
    for m in prom("/targets/metadata"):
        names = [m["metric"]]
        if m.get("type") in ("histogram", "summary"):
            names = [m["metric"] + s for s in ("_bucket", "_sum", "_count")]
        pool = pools.get(frozenset(m["target"].items()))
        for n in names:
            exposed.add(n)
            if pool and kept(pool, n):
                survives.add(n)
    read = tokens & exposed
    dropped = sorted(read - survives - set(ACCEPTED))
    report("metrics", [f"{n}：有規則或 dashboard 在讀，但每個 scrape job 都把它丟掉" for n in dropped],
           f"規則和 dashboard 讀的 {len(read)} 個指標都有保留")


def test_alert():
    end = (NOW + datetime.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
    kubectl("-n", "monitoring", "exec", ALERTMANAGER_POD, "-c", "alertmanager", "--",
            "amtool", "--alertmanager.url=http://localhost:9093", "alert", "add",
            "alertname=CairnTestAlert", "severity=warning", "namespace=monitoring",
            '--annotation=description="scripts/check.py 的測試警報，幾分鐘後會自己解除。"', f"--end={end}")
    print("SENT test alert：Discord 約 30 秒內收到 [FIRING:1] CairnTestAlert，約 5–7 分鐘後收到 [RESOLVED]。")


def main():
    args = sys.argv[1:]
    if args not in ([], ["--test-alert"]):
        sys.exit(__doc__)
    for check in (certificates, backups, targets, rules, alerts, metrics):
        try:
            check()
        except subprocess.CalledProcessError as e:
            failed.append(check.__name__)
            print(f"FAIL {check.__name__}：{e.stderr.strip() or e}")
    if args:
        test_alert()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
