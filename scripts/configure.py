#!/usr/bin/env python3
"""Write site.yaml, the per-site settings the charts are rendered with, by answering questions.

    scripts/configure.py [output]             default output: site.yaml in the site directory,
                                              $CAIRN_SITE or else the repo root (scripts/lib.sh)
    scripts/configure.py --example [output]   site.example.yaml in the repo, from the examples

The shared settings (certificates, timezone, network, NAS, LVM) are asked here. Everything else is
declared where it's used: each component's infrastructure/<name>/component.yaml and each app's
apps/<name>/app.yaml list their site settings (site:), so adding one needs no change here. Only what
is turned on gets its questions; what is turned off loses its section. Entries in apps that no
apps/<name>/ describes (a database only, a chart from elsewhere) are kept as they are.

Each question offers a default: the current site.yaml value, or one detected on this node (LAN IP
and CIDR, timezone, Zigbee USB device, cni0 gateway, LVM volume group). Enter keeps it. Answers are
validated, and the diff is shown before anything is written. Secrets are not asked here:
scripts/secret.py set <key> writes them. Afterwards: helmfile diff.
"""
import difflib
import glob
import ipaddress
import os
import pathlib
import re
import subprocess
import sys
import textwrap

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
SITE = pathlib.Path(os.environ.get("CAIRN_SITE") or REPO).resolve()
ADAPTERS = ("zstack", "ember", "deconz", "zigate", "zboss", "ezsp")
SOLVERS = ("gandi", "http01")  # names from infrastructure/base/chart/values.yaml, solvers
K3S_NETS = ipaddress.ip_network("10.42.0.0/15")  # k3s pod and service networks


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def detect_lan():
    """The node's private IPv4 and its network, skipping k3s, container and tunnel interfaces."""
    for line in sh("ip", "-4", "-o", "addr", "show", "scope", "global").splitlines():
        parts = line.split()
        if re.match(r"(cni|flannel|veth|docker|kube|ppp|tun|wg)", parts[1]):
            continue
        iface = ipaddress.ip_interface(parts[3])
        if iface.ip.is_private and iface.ip not in K3S_NETS:
            return str(iface.ip), str(iface.network)
    return None, None


def detect_pod_gateway():
    m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", sh("ip", "-4", "-o", "addr", "show", "cni0"))
    return m.group(1) if m else None


def detect_volume_groups():
    """LVM volume groups with an active logical volume, from udev: vgs needs root."""
    vgs = set()
    for dev in glob.glob("/dev/dm-*"):
        m = re.search(r"^E: DM_VG_NAME=(.+)$", sh("udevadm", "info", dev), re.M)
        if m:
            vgs.add(m.group(1))
    return sorted(vgs)


def detect_timezone():
    tz = sh("timedatectl", "show", "-p", "Timezone", "--value").strip()
    if not tz and pathlib.Path("/etc/timezone").exists():
        tz = pathlib.Path("/etc/timezone").read_text().strip()
    return tz or None


def posix_tz(tz):
    """The POSIX TZ string from the tzfile footer, e.g. Asia/Tokyo -> JST-9."""
    try:
        data = pathlib.Path("/usr/share/zoneinfo", tz).read_bytes()
    except OSError:
        return None
    footer = data.rstrip(b"\n").rsplit(b"\n", 1)[-1].decode(errors="replace")
    return footer if re.fullmatch(r"[A-Za-z<>+\-0-9,./:]+", footer) else None


def detect_serial_device():
    """The USB serial device, if there's exactly one. Lists them all for the question."""
    devices = sorted(glob.glob("/dev/serial/by-id/*"))
    print("  這台機器上的 USB 序列裝置：" + ("\n    " + "\n    ".join(devices) if devices else "（沒有）"))
    return devices[0] if len(devices) == 1 else None


# Detectors a declaration names in detect:, each returning a default or None.
DETECTS = {"serialDevice": detect_serial_device}


def valid_domain(v):
    return None if re.fullmatch(r"([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}", v) else "不是合法的網域"


def valid_hostname(v):
    return None if valid_domain(v) is None and v.count(".") >= 2 else "要是完整的主機名稱，例如 ha.example.com"


def valid_email(v):
    return None if re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", v) else "不是合法的 email"


def valid_ip(v):
    try:
        ipaddress.ip_address(v)
    except ValueError:
        return "不是合法的 IP"


def valid_cidr(v):
    try:
        ipaddress.ip_network(v, strict=True)
    except ValueError:
        return "不是合法的網段，例如 192.168.0.0/24（主機位元要是 0）"


def valid_tz(v):
    return None if pathlib.Path("/usr/share/zoneinfo", v).is_file() else "找不到這個時區，例如 Asia/Tokyo"


def valid_posix_tz(v):
    return None if re.fullmatch(r"[A-Za-z<>+\-0-9,./:]+", v) else "不是 POSIX TZ 格式，例如 JST-9"


def valid_abs_path(v):
    return None if v.startswith("/") else "要是絕對路徑"


def valid_adapter(v):
    return None if v in ADAPTERS else "可用的值：" + "、".join(ADAPTERS)


def valid_vg(v):
    return None if re.fullmatch(r"[A-Za-z0-9+_.][A-Za-z0-9+_.-]*", v) else "不是合法的 volume group 名稱"


def valid_zones(v):
    zones = [z.strip() for z in v.split(",") if z.strip()]
    bad = [z for z in zones if valid_domain(z)]
    return f"不是合法的網域：{', '.join(bad)}" if bad else None


def valid_solver(v):
    return None if v in SOLVERS else "可用的值：" + "、".join(SOLVERS)


# Validators a declaration names in check:, each returning an error message or None.
CHECKS = {
    "hostname": valid_hostname,
    "absPath": valid_abs_path,
    "ip": valid_ip,
    "cidr": valid_cidr,
    "email": valid_email,
    "zigbeeAdapter": valid_adapter,
}


def ask(label, default, validate=None):
    while True:
        try:
            v = input(f"{label} [{default or ''}]: ").strip() or (default or "")
        except EOFError:
            v = default or ""
            print()
        err = "必填" if not v else validate(v) if validate else None
        if err:
            print(f"  {err}")
            if not sys.stdin.isatty():
                sys.exit(1)
            continue
        return v


def ask_yes(label, default):
    while True:
        try:
            v = input(f"{label} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
        except EOFError:
            v = ""
            print()
        if not v:
            return default
        if v in ("y", "yes", "n", "no"):
            return v.startswith("y")
        print("  請回答 y 或 n")
        if not sys.stdin.isatty():
            sys.exit(1)


def lookup(d, dotted):
    for k in dotted.split("."):
        d = d.get(k) if isinstance(d, dict) else None
    return d


def definitions(kind, spec_file):
    """{name: spec} for each infrastructure/<name>/component.yaml or apps/<name>/app.yaml."""
    found = {}
    for path in sorted((REPO / kind).glob(f"*/{spec_file}")):
        found[path.parent.name] = yaml.safe_load(path.read_text()) or {}
    return found


def migrate(cur):
    """Read a site.yaml from before infrastructure: and apps: (components:, homeAssistant:,
    zigbee:, immich:, postgres.clusters) as the current shape, to offer its values as defaults."""
    comp = cur.get("components")
    if not isinstance(comp, dict):
        return cur
    cur = dict(cur)
    cur.pop("components")
    cur.setdefault("infrastructure", {n: comp[n] for n in ("monitoring", "postgres") if n in comp})
    apps = cur.setdefault("apps", {})
    if comp.get("home"):
        apps["home"] = {"hostname": lookup(cur, "homeAssistant.hostname"), "zigbee": cur.get("zigbee") or {}}
    if comp.get("immich"):
        apps["immich"] = {k: lookup(cur, f"immich.{k}") for k in ("hostname", "libraryPath")}
    for ns, settings in (lookup(cur, "postgres.clusters") or {}).items():
        apps[ns] = {"database": settings or {}}
    for key in ("homeAssistant", "zigbee", "immich"):
        cur.pop(key, None)
    return cur


def migrate_backup(cur):
    """Before charts/backup, home's backups went to nas.path and the dumps to postgres.backupPath."""
    if not lookup(cur, "backup.path"):
        old = lookup(cur, "nas.path") or lookup(cur, "postgres.backupPath")
        if old:
            cur = {**cur, "backup": {"path": old}}
    return cur


def q(v):
    return yaml.safe_dump(v, default_flow_style=True, allow_unicode=True, width=1000).strip().removesuffix("\n...")


def emit(node, depth=0):
    """YAML lines for a tree whose leaves are (comment, value); a dict value becomes a block."""
    out = []
    for key, v in node.items():
        pad = "  " * depth
        if isinstance(v, dict):
            out.append(f"{pad}{key}:")
            out += emit(v, depth + 1)
            continue
        comment, value = v
        if comment:
            out += [f"{pad}# {line}" for line in textwrap.wrap(comment, 100 - len(pad) - 2)]
        if isinstance(value, dict) and value:
            out.append(f"{pad}{key}:")
            out += [f"{pad}  {q(k)}: {q(x)}" for k, x in value.items()]
        else:
            out.append(f"{pad}{key}: {q(value)}")
    return out


def tree(entries):
    """A tree for emit() from [(dotted key, comment, value)]."""
    root = {}
    for key, comment, value in entries:
        *parents, leaf = key.split(".")
        node = root
        for p in parents:
            node = node.setdefault(p, {})
        node[leaf] = (comment, value)
    return root


def ask_declared(site, prefix, cur, example):
    """Ask each declared setting; [(key, comment, value)] with keys relative to prefix."""
    entries = []
    for key, d in (site or {}).items():
        if example:
            value = d["example"]
        else:
            default = lookup(cur, f"{prefix}{key}") or d.get("default")
            if default is None and d.get("detect"):
                default = DETECTS[d["detect"]]()
            value = ask(d["ask"], default, CHECKS.get(d.get("check")))
        entries.append((key, d.get("comment"), value))
    return entries


def main():
    args = sys.argv[1:]
    example = args[:1] == ["--example"]
    if example:
        args = args[1:]
    out = pathlib.Path(args[0]) if args else REPO / "site.example.yaml" if example else SITE / "site.yaml"
    components = {n: s for n, s in definitions("infrastructure", "component.yaml").items() if n != "base"}
    app_defs = definitions("apps", "app.yaml")

    if example:
        cur = {"apps": {"shop": {"database": {}}, "shop-staging": {"database": {}}, "notes": {"database": {"size": "2Gi"}}}}
    else:
        cur = migrate_backup(migrate(yaml.safe_load(out.read_text()) or {})) if out.exists() else {}
        print(f"設定 {out}：直接按 Enter 採用 [ ] 裡的值。\n")
    get = lambda key: lookup(cur, key)  # noqa: E731
    cur_apps = cur.get("apps") or {}

    if not example:
        print("要裝的元件（cert-manager、LVM LocalPV 和 infrastructure/base/chart 一定會裝）：")
    infra = {n: example or ask_yes(f"  {n}（{s.get('description', '')}）", get(f"infrastructure.{n}") is not False)
             for n, s in components.items()}
    if not example:
        print("\n要裝的 app（apps/）：")
    on_apps = [n for n, s in app_defs.items()
               if example or ask_yes(f"  {n}（{s.get('description', '')}）", n in cur_apps or not cur)]

    # Shared settings.
    zones = get("acme.zones") or {}
    if example:
        email, gandi_zones, default_solver = "you@example.com", ["example.com"], "http01"
        tz, tz_posix = "Etc/UTC", "UTC0"
        node_ip, lan_cidr, pod_cidr, pod_gw = "192.168.0.10", "192.168.0.0/24", "10.42.0.0/16", "10.42.0.1"
        nas, backup_path, vg = "192.168.0.20", "/volume1/backup", "ubuntu-vg"
    else:
        email = ask("\nLet's Encrypt 帳號 email", get("acmeEmail"), valid_email)
        print("憑證的驗證方式：gandi = DNS-01（Gandi API，可簽 wildcard）；http01 = HTTP-01（主機名稱要已經指到這台 node）")
        gandi = ask("用 gandi 驗證的 DNS zone（逗號分隔）", ", ".join(z for z, v in zones.items() if v == "gandi"), valid_zones)
        gandi_zones = [z.strip() for z in gandi.split(",") if z.strip()]
        default_solver = ask("其他 zone 的驗證方式", get("acme.defaultSolver") or "http01", valid_solver)
        tz = ask("時區", get("timezone") or detect_timezone(), valid_tz)
        tz_posix = ask("同一時區的 POSIX 格式", posix_tz(tz) or get("timezonePosix"), valid_posix_tz)

        ip, lan = detect_lan()
        print(f"\n偵測到的內網：node {ip or '?'}，網段 {lan or '?'}")
        node_ip = ask("node 的內網 IP", get("network.nodeIp") or ip, valid_ip)
        lan_cidr = ask("允許連 LAN-only 服務的網段", get("network.lanCidr") or lan, valid_cidr)
        if ipaddress.ip_address(node_ip) not in ipaddress.ip_network(lan_cidr):
            print(f"  注意：{node_ip} 不在 {lan_cidr} 裡")
        pod_cidr = ask("k3s pod 網段", get("network.podCidr") or "10.42.0.0/16", valid_cidr)
        pod_gw = ask("cni0 在 pod 網段上的位址", detect_pod_gateway() or get("network.podGateway"), valid_ip)

        nas = ask("\nNAS（NFS）的 IP", get("nas.server"), valid_ip)
        exports = sh("showmount", "-e", nas).strip()
        if exports:
            print("  NAS 上的 export：\n    " + "\n    ".join(exports.splitlines()[1:]))
        backup_path = ask("每日備份的 NFS export 路徑（每個 app 一個子目錄）", get("backup.path"), valid_abs_path)

        vgs = detect_volume_groups()
        print("\n這台機器上的 LVM volume group：" + ("、".join(vgs) if vgs else "（沒有）"))
        vg = ask("給限制大小的 volume 用的 volume group（StorageClass lvm）",
                 get("lvm.volumeGroup") or (vgs[0] if len(vgs) == 1 else None), valid_vg)

    # Each component's and app's own settings.
    component_entries = []
    for n, s in components.items():
        if infra[n] and s.get("site"):
            if not example:
                print(f"\n{n}：")
            component_entries += ask_declared(s["site"], "", cur, example)

    app_blocks = {}
    names = on_apps + [n for n in cur_apps if n not in on_apps and n not in app_defs]
    for name in names:
        entry = cur_apps.get(name) or {}
        definition = entry.get("app", name)
        entries = []
        if definition in app_defs:
            if not example:
                print(f"\napps.{name}（apps/{definition}）：")
            declared = app_defs[definition].get("site") or {}
            entries = ask_declared(declared, f"apps.{name}.", cur, example)
            top = {k.split(".")[0] for k in declared}
            entries += [(k, None, v) for k, v in entry.items() if k not in top]
        else:
            entries = [(k, None, v) for k, v in entry.items()]
        app_blocks[name] = (definition, entries)

    # The file.
    if example:
        header = """\
# Example site.yaml: copy it to site.yaml in the site directory ($CAIRN_SITE, else the repo root,
# where it's gitignored) and fill in, or run scripts/configure.py, which also writes this file
# (--example) from the examples in infrastructure/*/component.yaml and apps/*/app.yaml.
# Placeholder values only. The real ones describe a home network and stay out of the public repo.
"""
    else:
        header = """\
# Site-specific settings for this cluster: the "profile" helmfile.yaml.gotmpl renders the charts with.
# Moving to another machine, network or domain means editing this file, not the templates.
# It describes the home network, so it stays out of the public repo: gitignored there, or kept in
# a private site directory ($CAIRN_SITE, see scripts/lib.sh). Keep a copy somewhere safe.
# scripts/configure.py rewrites it from questions; site.example.yaml shows the shape.
# Secrets go in site.secret.yaml next to it (template: site.secret.example.yaml).
"""
    infra_lines = [
        "# What helmfile installs besides the base (infrastructure/base: cert-manager, LVM LocalPV, the",
        "# cluster chart). Turning one off only stops managing it: helm uninstall removes it, and keeps",
        "# its volumes.",
        "infrastructure:",
    ]
    for n, s in components.items():
        infra_lines += [f"  # {line}" for line in textwrap.wrap(f"infrastructure/{n}: {s.get('description', '')}.", 96)]
        infra_lines.append(f"  {n}: {q(infra[n])}")

    shared = [
        ("acmeEmail", "Let's Encrypt account email.", email),
        ("acme.zones", "How cert-manager proves control of each DNS zone, by solver name "
                       "(infrastructure/base/chart/values.yaml): gandi: DNS-01 through the Gandi LiveDNS API "
                       "(site.secret.yaml: gandi.pat), allows wildcards; http01: HTTP-01 through Traefik on "
                       "port 80, the hostname must already resolve to this node.",
         {z: "gandi" for z in gandi_zones}),
        ("acme.defaultSolver", "Every zone not listed above.", default_solver),
        ("timezone", None, tz),
        ("timezonePosix", "The same zone in POSIX form, for images without tzdata (the backup jobs).", tz_posix),
        ("network.lanCidr", "Clients allowed through the lan-only middleware.", lan_cidr),
        ("network.nodeIp", "The k3s node's LAN IP. Home Assistant runs on the host network, so its "
                           "traffic comes from here.", node_ip),
        ("network.podCidr", "k3s defaults: the pod network, and cni0's address on it.", pod_cidr),
        ("network.podGateway", None, pod_gw),
        ("nas.server", "NFS server for the exports in this file. Each must allow the node's IP.", nas),
        ("backup.path", "Export on nas.server for the nightly backups (charts/backup): "
                        "<path>/<app>/YYYY-MM-DD/.", backup_path),
        ("lvm.volumeGroup", "LVM volume group on the node for the size-capped volumes (StorageClass lvm). "
                            "Its unallocated space is all they can use. Ubuntu's installer names it ubuntu-vg.", vg),
    ]

    app_lines = ["# One entry per app, installed in the namespace of its name. apps/<app>/app.yaml describes it",
                 "# (app: names it, else the entry's name); an entry without one only gets what it sets itself:",
                 "# database (a Postgres cluster), or chart, version and values (a chart from elsewhere). Its",
                 "# other keys are the app's settings, and override its chart's defaults.",
                 "apps:"]
    for name, (definition, entries) in app_blocks.items():
        if definition in app_defs:
            desc = app_defs[definition].get("description", "")
            app_lines += [f"  # {line}" for line in textwrap.wrap(f"apps/{definition}: {desc}.", 96)]
        app_lines.append(f"  {name}:" if entries or definition != name else f"  {name}: {{}}")
        if definition != name:
            app_lines.append(f"    app: {q(definition)}")
        app_lines += emit(tree([e for e in entries if e[0] != "app"]), 2)

    blocks = [header, "\n".join(infra_lines) + "\n", "\n".join(emit(tree(shared))) + "\n"]
    if component_entries:
        blocks.append("\n".join(emit(tree(component_entries))) + "\n")
    blocks.append("\n".join(app_lines) + "\n")
    text = "\n".join(blocks)

    if example:
        out.write_text(text)
        return
    old = out.read_text() if out.exists() else ""
    if old == text:
        print(f"\n{out.name} 沒有變更。")
        return
    print("\n".join(difflib.unified_diff(old.splitlines(), text.splitlines(), "目前", "新的", lineterm="")))
    if input(f"\n寫入 {out}？[Y/n] ").strip().lower() in ("", "y", "yes"):
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print("已寫入。下一步：helmfile diff")
    else:
        print("沒有寫入。")


if __name__ == "__main__":
    main()
