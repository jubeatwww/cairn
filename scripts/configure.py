#!/usr/bin/env python3
"""Write site.yaml, the per-site settings the charts are rendered with, by answering questions.

    scripts/configure.py [output]      default output: site.yaml at the repo root

Each question offers a default: the current site.yaml value, or one detected on this node
(LAN IP and CIDR, timezone, Zigbee USB device, cni0 gateway). Enter keeps it. Answers are
validated, and the diff is shown before anything is written. Secrets are not asked here:
scripts/setup-gandi-dns01.sh takes the Gandi PAT. Afterwards: scripts/apply.sh --dry-run.
"""
import difflib
import glob
import ipaddress
import pathlib
import re
import subprocess
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "site.yaml"
ADAPTERS = ("zstack", "ember", "deconz", "zigate", "zboss", "ezsp")
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


def valid_domain(v):
    return None if re.fullmatch(r"([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}", v) else "不是合法的網域"


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


def valid_label(v):
    return None if re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", v) else "只能用小寫英數和 -"


def ask(label, default, validate=None):
    while True:
        try:
            v = input(f"{label} [{default or ''}]: ").strip() or (default or "")
        except EOFError:
            v = default or ""
            print()
        if not v:
            print("  必填")
            continue
        err = validate(v) if validate else None
        if err:
            print(f"  {err}")
            if not sys.stdin.isatty():
                sys.exit(1)
            continue
        return v


def main():
    cur = yaml.safe_load(OUT.read_text()) if OUT.exists() else {}

    def get(*keys):
        d = cur
        for k in keys:
            d = d.get(k) if isinstance(d, dict) else None
        return d

    ip, lan = detect_lan()

    print(f"設定 {OUT}：直接按 Enter 採用 [ ] 裡的值。\n")
    domain = ask("網域（Gandi LiveDNS 上的 zone）", get("domain"), valid_domain)
    email = ask("Let's Encrypt 帳號 email", get("acmeEmail"), valid_email)
    tz = ask("時區", get("timezone") or detect_timezone(), valid_tz)
    tz_posix = ask("同一時區的 POSIX 格式", posix_tz(tz) or get("timezonePosix"), valid_posix_tz)

    print(f"\n偵測到的內網：node {ip or '?'}，網段 {lan or '?'}")
    node_ip = ask("node 的內網 IP", get("network", "nodeIp") or ip, valid_ip)
    lan_cidr = ask("允許連 LAN-only 服務的網段", get("network", "lanCidr") or lan, valid_cidr)
    if ipaddress.ip_address(node_ip) not in ipaddress.ip_network(lan_cidr):
        print(f"  注意：{node_ip} 不在 {lan_cidr} 裡")
    pod_cidr = ask("k3s pod 網段", get("network", "podCidr") or "10.42.0.0/16", valid_cidr)
    pod_gw = ask("cni0 在 pod 網段上的位址", detect_pod_gateway() or get("network", "podGateway"), valid_ip)

    nas = ask("\nNAS（備份用 NFS）的 IP", get("nas", "server"), valid_ip)
    exports = sh("showmount", "-e", nas).strip()
    if exports:
        print("  NAS 上的 export：\n    " + "\n    ".join(exports.splitlines()[1:]))
    nas_path = ask("NFS export 路徑", get("nas", "path"), valid_abs_path)

    devices = sorted(glob.glob("/dev/serial/by-id/*"))
    print("\n這台機器上的 USB 序列裝置：" + ("\n  " + "\n  ".join(devices) if devices else "（沒有）"))
    device = ask("Zigbee 協調器", get("zigbee", "device") or (devices[0] if len(devices) == 1 else None), valid_abs_path)
    if not pathlib.Path(device).exists():
        print(f"  注意：{device} 目前不存在（還沒插上？）")
    adapter = ask("Zigbee adapter 類型", get("zigbee", "adapter") or "zstack", valid_adapter)

    ha_host = ask(f"\nHome Assistant 的主機名稱（<名稱>.{domain}，只限內網）", get("homeAssistant", "host") or "ha", valid_label)
    immich_host = ask(f"Immich 的主機名稱（<名稱>.{domain}，公開）", get("immich", "host") or "immich", valid_label)
    library = ask(f"照片庫在 NAS（{nas}）上的 export 路徑，Immich 會唯讀掛載", get("immich", "libraryPath"), valid_abs_path)

    q = lambda v: yaml.safe_dump(v, default_flow_style=True).strip().removesuffix("\n...")  # noqa: E731
    text = f"""\
# Site-specific settings for this cluster: the "profile" the charts in charts/ are rendered with.
# Moving to another machine, network or domain means editing this file, not the templates.
# Gitignored, so the home network's layout stays out of the public repo: keep a copy somewhere safe.
# scripts/configure.py rewrites it from questions; site.example.yaml shows the shape.
# Secrets go in site.secret.yaml (gitignored too; template: site.secret.example.yaml).

# Public DNS zone on Gandi LiveDNS. Every host is <name>.<domain> with its own Let's Encrypt cert.
domain: {q(domain)}
# Let's Encrypt account email.
acmeEmail: {q(email)}
timezone: {q(tz)}
# The same zone in POSIX form, for images without tzdata (the backup job).
timezonePosix: {q(tz_posix)}

network:
  # Clients allowed through the lan-only middleware.
  lanCidr: {q(lan_cidr)}
  # The k3s node's LAN IP. Home Assistant runs on the host network, so its traffic comes from here.
  nodeIp: {q(node_ip)}
  # k3s defaults: the pod network, and cni0's address on it.
  podCidr: {q(pod_cidr)}
  podGateway: {q(pod_gw)}

nas:
  # NFS export for the nightly backups. It must allow the node's IP.
  server: {q(nas)}
  path: {q(nas_path)}

zigbee:
  # Coordinator on the node. by-id names follow the USB chip, not the port it's plugged into.
  device: {q(device)}
  # zstack for TI chips (CC2652, CC2530). Other chips: see Zigbee2MQTT's adapter docs.
  adapter: {q(adapter)}

homeAssistant:
  # Served at https://<host>.<domain>, LAN only.
  host: {q(ha_host)}

immich:
  # Public at https://<host>.<domain>, so albums can be shared.
  host: {q(immich_host)}
  # NFS export on nas.server with the photo library. Mounted read-only as an external library.
  libraryPath: {q(library)}
"""
    old = OUT.read_text() if OUT.exists() else ""
    if old == text:
        print(f"\n{OUT.name} 沒有變更。")
        return
    print("\n".join(difflib.unified_diff(old.splitlines(), text.splitlines(), "目前", "新的", lineterm="")))
    if input(f"\n寫入 {OUT}？[Y/n] ").strip().lower() in ("", "y", "yes"):
        OUT.write_text(text)
        print("已寫入。下一步：scripts/apply.sh --dry-run")
    else:
        print("沒有寫入。")


if __name__ == "__main__":
    main()
