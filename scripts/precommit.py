#!/usr/bin/env python3
"""Checks before every commit, run by scripts/hooks/pre-commit (enable it once per clone with
`git config core.hooksPath scripts/hooks`). No network or cluster needed. Skip once with
`git commit --no-verify`.

  leaks     the staged changes contain nothing from the site directory that the examples don't
            have: no key or value of site.yaml or values/, no value of site.secret.yaml, nor the
            DNS zones, the LAN prefix or your git email they imply. Names of directories in apps/
            and infrastructure/ are fine; anything else is the home network's, or a secret.
  example   site.example.yaml is what scripts/configure.py --example writes
  render    every chart in this repo lints and renders through helmfile with the examples: all
            components on (plus an app on charts/app/examples/web.yaml), and all off
  syntax    bash -n and Python compile for scripts/; shellcheck and ruff too, if installed

    scripts/precommit.py            the checks above, on what's staged
    scripts/precommit.py --all      leaks in every tracked file, not only the staged changes
"""
import ipaddress
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
SITE = pathlib.Path(os.environ.get("CAIRN_SITE") or REPO).resolve()
failed = []


def run(*cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=REPO, **kw)


def fail(name, lines):
    failed.append(name)
    print(f"FAIL {name}")
    for line in lines:
        print(f"     {line}")


def strings(node, path="", keys=True):
    """(dotted path, string) for every scalar value in a YAML tree, and every key unless keys=False."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}" if path else str(k)
            if keys:
                yield p, str(k)
            yield from strings(v, p, keys)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, f"{path}[{i}]", keys)
    elif isinstance(node, str):
        yield path, node


def load(path):
    try:
        return yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError):
        return {}


def private_tokens():
    """{token: where it comes from} for what must not be committed."""
    found = {}
    files = [SITE / "site.yaml", SITE / "site.secret.yaml", *sorted((SITE / "values").glob("*.yaml"))]
    site = load(SITE / "site.yaml")
    for f in files:
        # site.secret.yaml's keys are field names (password, token); the app names among them are
        # site.yaml's too.
        for path, s in strings(load(f), keys=f.name != "site.secret.yaml"):
            found.setdefault(s, f"{f.name}: {path}")
    # What the values imply: each DNS zone and its name without the TLD, the LAN's prefix.
    hosts = [s for _, s in strings(site) if re.fullmatch(r"([a-z0-9-]+\.)+[a-z]{2,}", s)]
    for h in hosts + list(((site.get("acme") or {}).get("zones") or {})):
        labels = h.split(".")
        found.setdefault(".".join(labels[-2:]), f"site.yaml: the zone of {h}")
        found.setdefault(labels[-2], f"site.yaml: the zone of {h}")
    cidr = ((site.get("network") or {}).get("lanCidr")) or ""
    try:
        net = ipaddress.ip_network(cidr)
        octets = str(net.network_address).split(".")[: net.prefixlen // 8]
        if len(octets) >= 2:
            found.setdefault(".".join(octets) + ".", "site.yaml: network.lanCidr's prefix")
    except ValueError:
        pass
    email = run("git", "config", "user.email").stdout.strip()
    if email:
        found.setdefault(email, "git config user.email")
        domain = email.split("@")[-1].split(".")
        if len(domain) >= 2:
            found.setdefault(domain[0], "git config user.email's domain")
    # Public already: the examples, and what this repo names itself.
    public = {s for f in ("site.example.yaml", "site.secret.example.yaml") for _, s in strings(load(REPO / f))}
    public |= {p.name for d in ("apps", "infrastructure", "charts") for p in (REPO / d).iterdir() if p.is_dir()}
    # Too short or bare numbers would match everywhere.
    return {t: src for t, src in found.items() if t not in public and len(t) >= 4 and not t.isdigit()}


def added_lines(everything):
    """(file, line) for each line added by the staged changes, or every line of every tracked file."""
    if everything:
        for file in run("git", "ls-files").stdout.splitlines():
            yield file, file
            try:
                yield from ((file, line) for line in (REPO / file).read_text().splitlines())
            except (OSError, UnicodeDecodeError):
                pass
        return
    file = None
    for line in run("git", "diff", "--cached", "-U0", "--no-color").stdout.splitlines():
        if line.startswith("+++ "):
            file = line[6:] if line.startswith("+++ b/") else None
            if file:
                yield file, file
        elif line.startswith("+") and file:
            yield file, line


def leaks(everything=False):
    tokens = {t.lower(): src for t, src in private_tokens().items()}
    hits = {f"{file}：{src}" for file, line in added_lines(everything) for t, src in tokens.items() if t in line.lower()}
    where = "追蹤中的檔案" if everything else "staged 的變更"
    if hits:
        fail("leaks", sorted(hits) + ["把值換成佔位符（example.com、192.168.0.0/24、<lanCidr>）"])
    else:
        print(f"OK   leaks: {where}裡沒有 site 目錄的 {len(tokens)} 個值")


def example():
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp, "site.example.yaml")
        r = run(sys.executable, "scripts/configure.py", "--example", str(out))
        if r.returncode:
            fail("example", ["scripts/configure.py --example 失敗：", r.stderr.strip()])
        elif out.read_text() != (REPO / "site.example.yaml").read_text():
            fail("example", ["site.example.yaml 不是 scripts/configure.py --example 寫出來的樣子：跑它，再 git add"])
        else:
            print("OK   example: site.example.yaml 是最新的")


def render():
    if not shutil.which("helmfile"):
        print("SKIP render: 沒有 helmfile")
        return
    site = load(REPO / "site.example.yaml")
    # Entries naming an app outside the repo (a plugin, or app: /...) have nothing here to render.
    apps = {n: e for n, e in (site.get("apps") or {}).items()
            if "app" not in (e or {}) or (REPO / "apps" / str(e["app"])).is_dir()}
    on = dict(site, apps={**apps, "example-web": {"values": [str(REPO / "charts/app/examples/web.yaml")], "database": {}}})
    off = dict(site, infrastructure={k: False for k in site.get("infrastructure", {})}, apps={})
    problems = []
    for name, data in (("all on", on), ("all off", off)):
        with tempfile.TemporaryDirectory() as tmp:
            pathlib.Path(tmp, "site.yaml").write_text(yaml.safe_dump(data))
            shutil.copy(REPO / "site.secret.example.yaml", pathlib.Path(tmp, "site.secret.yaml"))
            r = run("helmfile", "-q", "lint", "--skip-deps", "-l", "local=true",
                    env=dict(os.environ, CAIRN_SITE=tmp, HELMFILE_DISABLE_VALS="true"))
            if r.returncode:
                problems.append(f"{name}：" + (r.stderr.strip() or r.stdout.strip())[-1500:])
    if problems:
        fail("render", problems)
    else:
        print("OK   render: 本 repo 的 chart 在全開、全關下都 lint、render 得過")


def syntax():
    problems = []
    shells = sorted((REPO / "scripts").glob("*.sh")) + sorted((REPO / "scripts/hooks").glob("*"))
    for f in shells:
        r = run("bash", "-n", str(f))
        if r.returncode:
            problems.append(r.stderr.strip())
    pys = sorted((REPO / "scripts").glob("*.py"))
    for f in pys:
        try:
            compile(f.read_text(), str(f), "exec")
        except SyntaxError as e:
            problems.append(f"{f.relative_to(REPO)}:{e.lineno}: {e.msg}")
    extra = []
    if shutil.which("shellcheck"):
        extra.append("shellcheck")
        r = run("shellcheck", *map(str, shells))
        if r.returncode:
            problems.append(r.stdout.strip())
    if shutil.which("ruff"):
        extra.append("ruff")
        r = run("ruff", "check", "--quiet", *map(str, pys))
        if r.returncode:
            problems.append(r.stdout.strip())
    if problems:
        fail("syntax", problems)
    else:
        print(f"OK   syntax: {len(shells)} 個 shell、{len(pys)} 個 Python" + (f"（加 {'、'.join(extra)}）" if extra else ""))


def main():
    args = sys.argv[1:]
    if args not in ([], ["--all"]):
        sys.exit(__doc__)
    if args:
        leaks(everything=True)
        sys.exit(1 if failed else 0)
    for check in (leaks, example, render, syntax):
        check()
    if failed:
        print("\n擋下 commit。修好再 commit，或確定沒問題時 git commit --no-verify。")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
