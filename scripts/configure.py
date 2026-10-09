#!/usr/bin/env python3
"""Write site.yaml, the per-site settings the charts are rendered with, by answering questions.

    scripts/configure.py [output]      default output: site.yaml at the repo root

Each question offers a default: the current site.yaml value, or one detected on this node
(LAN IP and CIDR, timezone, Zigbee USB device, cni0 gateway, LVM volume group). Enter keeps it. Answers are
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


def valid_vg(v):
    return None if re.fullmatch(r"[A-Za-z0-9+_.][A-Za-z0-9+_.-]*", v) else "不是合法的 volume group 名稱"



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


SOLVERS = ("gandi", "http01")  # names from charts/cluster/values.yaml, solvers


def valid_hostname(v):
    return None if valid_domain(v) is None and v.count(".") >= 2 else "要是完整的主機名稱，例如 ha.example.com"


def valid_zones(v):
    zones = [z.strip() for z in v.split(",") if z.strip()]
    bad = [z for z in zones if valid_domain(z)]
    return f"不是合法的網域：{', '.join(bad)}" if bad else None


def valid_solver(v):
    return None if v in SOLVERS else "可用的值：" + "、".join(SOLVERS)


def main():
    cur = yaml.safe_load(OUT.read_text()) if OUT.exists() else {}

    def get(*keys):
        d = cur
        for k in keys:
            d = d.get(k) if isinstance(d, dict) else None
        return d

    # Defaults from the older layout (a single `domain`, and <host>.<domain> hostnames).
    old_domain = get("domain")
    zones = get("acme", "zones") or ({old_domain: "gandi"} if old_domain else {})
    old_host = lambda app, default: f"{get(app, 'host') or default}.{old_domain}" if old_domain else None  # noqa: E731

    ip, lan = detect_lan()

    print(f"設定 {OUT}：直接按 Enter 採用 [ ] 裡的值。\n")
    email = ask("Let's Encrypt 帳號 email", get("acmeEmail"), valid_email)
    print("憑證的驗證方式：gandi = DNS-01（Gandi API，可簽 wildcard）；http01 = HTTP-01（主機名稱要已經指到這台 node）")
    gandi = ask("用 gandi 驗證的 DNS zone（逗號分隔）", ", ".join(z for z, v in zones.items() if v == "gandi"), valid_zones)
    default_solver = ask("其他 zone 的驗證方式", get("acme", "defaultSolver") or "http01", valid_solver)
    gandi_zones = [z.strip() for z in gandi.split(",") if z.strip()]
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

    vgs = detect_volume_groups()
    print("\n這台機器上的 LVM volume group：" + ("、".join(vgs) if vgs else "（沒有）"))
    vg = ask("給限制大小的 volume 用的 volume group（StorageClass lvm）", get("lvm", "volumeGroup") or (vgs[0] if len(vgs) == 1 else None), valid_vg)

    ha_host = ask("\nHome Assistant 的主機名稱（只限內網）", get("homeAssistant", "hostname") or old_host("homeAssistant", "ha"), valid_hostname)
    immich_host = ask("Immich 的主機名稱（公開）", get("immich", "hostname") or old_host("immich", "immich"), valid_hostname)
    library = ask(f"照片庫在 NAS（{nas}）上的 export 路徑", get("immich", "libraryPath"), valid_abs_path)
    grafana_host = ask("Grafana 的主機名稱（只限內網）", get("grafana", "hostname") or "grafana." + ha_host.split(".", 1)[1], valid_hostname)

    q = lambda v: yaml.safe_dump(v, default_flow_style=True).strip().removesuffix("\n...")  # noqa: E731
    zone_lines = "".join(f"    {q(z)}: gandi\n" for z in gandi_zones) or "    {}\n"
    text = f"""\
# Site-specific settings for this cluster: the "profile" the charts in charts/ are rendered with.
# Moving to another machine, network or domain means editing this file, not the templates.
# Gitignored, so the home network's layout stays out of the public repo: keep a copy somewhere safe.
# scripts/configure.py rewrites it from questions; site.example.yaml shows the shape.
# Secrets go in site.secret.yaml (gitignored too; template: site.secret.example.yaml).

# Let's Encrypt account email.
acmeEmail: {q(email)}
# How cert-manager proves control of each DNS zone, by solver name (charts/cluster/values.yaml):
#   gandi   DNS-01 through the Gandi LiveDNS API (site.secret.yaml: gandi.pat). Allows wildcards.
#   http01  HTTP-01 through Traefik on port 80. The hostname must already resolve to this node.
acme:
  zones:
{zone_lines}  # Every zone not listed above.
  defaultSolver: {q(default_solver)}
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

lvm:
  # LVM volume group on the node for the size-capped volumes (StorageClass lvm). Its unallocated
  # space is all they can use. Ubuntu's installer names it ubuntu-vg.
  volumeGroup: {q(vg)}

homeAssistant:
  # LAN only: its DNS record points at network.nodeIp.
  hostname: {q(ha_host)}

immich:
  # Public, so albums can be shared.
  hostname: {q(immich_host)}
  # NFS export on nas.server with the photo library, mounted as an external library.
  libraryPath: {q(library)}

grafana:
  # LAN only: its DNS record points at network.nodeIp.
  hostname: {q(grafana_host)}
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
