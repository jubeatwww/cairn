#!/usr/bin/env python3
"""Read or set values in site.secret.yaml, keeping the others.

    scripts/secret.py get <key>    print it (nothing if unset). Keys are dotted: gandi.pat
    scripts/secret.py set <key>    asks for it without echoing it (or reads it from stdin), so it
                                   never shows up in `ps` or the shell history
    scripts/secret.py fill [name]  the secrets each app in site.yaml declares (secrets: in its
                                   app.yaml) that are still unset: generated ones are made up, the
                                   others asked for as with set. Given a name, only that entry's,
                                   or those of every entry installing that app (a plugin's name).

set and fill check the keys they know before writing them:
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
import secrets
import sys
import urllib.error
import urllib.request

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
SITE = pathlib.Path(os.environ.get("CAIRN_SITE") or REPO).resolve()
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


def lookup(data, key):
    for k in key.split("."):
        data = data.get(k) if isinstance(data, dict) else None
    return data


def ask(key, prompt=None):
    """A value for key from the terminal without echo, or from stdin; checked if CHECKS knows key."""
    try:
        value = (getpass.getpass(f"{prompt or key}: ") if sys.stdin.isatty() else sys.stdin.read()).strip()
    except (EOFError, KeyboardInterrupt):
        sys.exit("\n沒有寫入")
    if not value:
        sys.exit("是空的，沒有寫入")
    if not value.startswith("ref+") and key in CHECKS:
        err = CHECKS[key](value)
        if err:
            sys.exit(f"ERROR: {err}。沒有寫入。")
    return value


def save(data, key, value):
    *parents, leaf = key.split(".")
    node = data
    for k in parents:
        node = node.setdefault(k, {})
    node[leaf] = value
    fd = os.open(FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(HEADER + yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
    os.chmod(FILE, 0o600)


def declared(only):
    """(entry name, dotted key, declaration) for each secret the apps in site.yaml declare."""
    site = yaml.safe_load((SITE / "site.yaml").read_text()) or {}
    apps = site.get("apps") or {}
    if only and not any(only in (n, (e or {}).get("app", n)) for n, e in apps.items()):
        sys.exit(f"site.yaml 的 apps 裡沒有 {only}，也沒有 entry 裝它。entry 有：{'、'.join(apps)}")
    for name, entry in apps.items():
        app = (entry or {}).get("app", name)
        if only and only not in (name, app):
            continue
        # As helmfile looks for it: an absolute path, else apps/<app>, else plugins/<app> here.
        where = pathlib.Path(app) if app.startswith("/") else REPO / "apps" / app
        if not app.startswith("/") and not where.is_dir():
            where = SITE / "plugins" / app
        spec = where / "app.yaml"
        if spec.is_file():
            for key, d in ((yaml.safe_load(spec.read_text()) or {}).get("secrets") or {}).items():
                yield name, key, d or {}


def fill(only):
    data = (yaml.safe_load(FILE.read_text()) or {}) if FILE.exists() else {}
    missing = []
    for name, key, d in declared(only):
        full = f"apps.{name}.{key}"
        if lookup(data, full) is not None:
            print(f"已經有 {full}，不動")
        elif d.get("generate"):
            save(data, full, secrets.token_hex(32))
            print(f"產生了 {full}")
        else:
            missing.append((full, d))
    # Generated first, so a prompt left unanswered loses none of them.
    for full, d in missing:
        if not sys.stdin.isatty():
            sys.exit(f"{full} 要人輸入：在終端機重跑，或 scripts/secret.py set {full}")
        if d.get("comment"):
            print(d["comment"])
        save(data, full, ask(full, d.get("ask")))
        print(f"寫入了 {full}")
    print(f"{FILE} 都齊了。下一步：helmfile apply")


def main():
    args = sys.argv[1:]
    if args[:1] == ["fill"] and len(args) <= 2:
        return fill(args[1] if len(args) == 2 else None)
    if len(args) != 2 or args[0] not in ("get", "set"):
        sys.exit(__doc__)
    cmd, key = args
    data = (yaml.safe_load(FILE.read_text()) or {}) if FILE.exists() else {}

    if cmd == "get":
        value = lookup(data, key)
        if value is not None:
            print(value)
        return

    save(data, key, ask(key))
    print(f"已寫入 {FILE}。下一步：helmfile apply")


if __name__ == "__main__":
    main()
