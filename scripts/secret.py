#!/usr/bin/env python3
"""Read or set one value in site.secret.yaml, keeping the others.

    scripts/secret.py get <key>    print it (nothing if unset). Keys are dotted: gandi.pat
    scripts/secret.py set <key>    asks for it without echoing it (or reads it from stdin), so it
                                   never shows up in `ps` or the shell history

set checks the keys it knows before writing them:
    gandi.pat            the token can manage the LiveDNS zone of every zone in site.yaml's acme.zones
                         that uses gandi
    discord.webhookUrl   Discord knows the webhook (a GET, which posts nothing)
A vals reference (ref+sops://..., README "Secrets") is written as it is, unchecked.
Afterwards: helmfile apply, then scripts/check.py (--test-alert for the webhook).

The file is in the site directory: $CAIRN_SITE, else the repo root (scripts/lib.sh). It's created
if missing and stays readable only by you (mode 600).
"""
import getpass
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

import yaml

SITE = pathlib.Path(os.environ.get("CAIRN_SITE") or pathlib.Path(__file__).resolve().parent.parent).resolve()
FILE = SITE / "site.secret.yaml"
HEADER = "# Gitignored. Never commit. Template: site.secret.example.yaml. Written by scripts/secret.py\n"


def http(url, headers=None):
    """(status, body) for a GET; status 0 if the server can't be reached."""
    req = urllib.request.Request(url, headers={"User-Agent": "cairn", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        print(f"連不到 {url.split('/')[2]}：{e.reason}")
        return 0, b""


def check_gandi(pat):
    site = yaml.safe_load((SITE / "site.yaml").read_text()) or {}
    zones = [z for z, s in ((site.get("acme") or {}).get("zones") or {}).items() if s == "gandi"]
    if not zones:
        return "site.yaml 的 acme.zones 裡沒有用 gandi 的 zone，沒得檢查"
    for zone in zones:
        code, _ = http(f"https://api.gandi.net/v5/livedns/domains/{zone}", {"Authorization": f"Bearer {pat}"})
        if code == 200:
            print(f"OK：PAT 能管理 {zone}")
        elif code in (401, 403):
            return f"Gandi 回 {code}：PAT 錯誤、已過期，或沒有「Manage domain name technical configurations」權限、範圍不含 {zone}"
        elif code == 404:
            return f"Gandi 回 404：這個 PAT 看不到 {zone} 的 LiveDNS zone（PAT 要建在擁有它的 organization）"
        else:
            return f"Gandi 回了預期外的 HTTP {code}"


def check_discord(url):
    if not re.fullmatch(r"https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+", url):
        return "看起來不是 Discord webhook URL（https://discord.com/api/webhooks/<id>/<token>）"
    code, body = http(url)
    if code == 200:
        print(f"OK：webhook「{json.loads(body).get('name', '?')}」")
    elif code in (401, 404):
        return f"Discord 回 {code}：這個 webhook 不存在或已被刪除，請重新複製 URL"
    else:
        return f"Discord 回了預期外的 HTTP {code}"


CHECKS = {"gandi.pat": check_gandi, "discord.webhookUrl": check_discord}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("get", "set"):
        sys.exit(__doc__)
    cmd, key = sys.argv[1], sys.argv[2]
    keys = key.split(".")
    data = (yaml.safe_load(FILE.read_text()) or {}) if FILE.exists() else {}

    if cmd == "get":
        value = data
        for k in keys:
            value = value.get(k) if isinstance(value, dict) else None
        if value is not None:
            print(value)
        return

    value = (getpass.getpass(f"{key}: ") if sys.stdin.isatty() else sys.stdin.read()).strip()
    if not value:
        sys.exit("是空的，沒有寫入")
    if not value.startswith("ref+") and key in CHECKS:
        err = CHECKS[key](value)
        if err:
            sys.exit(f"ERROR: {err}。沒有寫入。")

    node = data
    for k in keys[:-1]:
        node = node.setdefault(k, {})
    node[keys[-1]] = value
    fd = os.open(FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(HEADER + yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
    os.chmod(FILE, 0o600)
    print(f"已寫入 {FILE}。下一步：helmfile apply")


if __name__ == "__main__":
    main()
