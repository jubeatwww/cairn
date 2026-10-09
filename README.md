# cairn

Kubernetes config for my homelab k3s cluster: what runs on it, and enough to rebuild it from scratch.

## Cluster

| | |
|---|---|
| Distribution | k3s `v1.36.5+k3s1`, default install |
| CNI | flannel (VXLAN) |
| Pod CIDR | `10.42.0.0/16` (k3s default) |
| Service CIDR | `10.43.0.0/16` (k3s default) |
| Ingress | Traefik (bundled with k3s) |
| LoadBalancer | ServiceLB / Klipper (bundled with k3s) |

Host-level setup (OS, networking, firewall, k3s install flags) is out of scope for this repo. [Restore](#restore) lists what the host needs.

## Layout

```
site.yaml           gitignored site settings: DNS zones, hostnames, IPs, NAS, Zigbee device, timezone; shape: site.example.yaml
site.secret.yaml    gitignored secrets (the Gandi PAT); template: site.secret.example.yaml
charts/cluster/     local chart: Let's Encrypt ClusterIssuers, Gandi DNS-01 credentials, Traefik settings
charts/home/        local chart: Mosquitto, Zigbee2MQTT, Home Assistant, nightly backup
charts/immich/      local chart: Immich, public, with the photo library on the NAS
charts/monitoring/  local chart: Grafana's LAN-only Ingress, for the monitoring stack in helm/
helm/<release>/     third-party charts: values.yaml + install.sh (cert-manager, the Gandi webhook,
                    kube-prometheus-stack, Loki, Alloy)
scripts/            helpers you run by hand: configure, apply, Gandi setup, restore
```

The local charts hold templates only. Every site-specific value comes from `site.yaml`; versions (image tags) live in each chart's `values.yaml`. `scripts/configure.py` writes `site.yaml` from questions, offering the current values or ones detected on the node, so you don't have to edit it by hand.

`site.yaml` describes the home network, so it stays out of this public repo like the secrets do. Keep a copy of `site.yaml` and `site.secret.yaml` somewhere safe (a password manager, the NAS): after losing the node, `scripts/configure.py` can rebuild `site.yaml`, but only from what you remember.

## Apply

```sh
scripts/apply.sh --dry-run   # validate the local charts against the cluster, change nothing
scripts/apply.sh             # install or upgrade everything
```

It runs the third-party releases in `helm/` first, in dependency order: cert-manager and its Gandi webhook (their CRDs back the ClusterIssuers and Certificates), then kube-prometheus-stack (ServiceMonitor CRDs), Loki and Alloy. Then the local charts: `charts/cluster` with `site.yaml` and `site.secret.yaml`, and `charts/home`, `charts/immich` and `charts/monitoring` with `site.yaml`. For the kubeconfig it uses `$KUBECONFIG`, then `~/.kube/config`, then k3s's root-only `/etc/rancher/k3s/k3s.yaml` (run it with sudo).

To upgrade an app, bump its image in `charts/home/values.yaml` and run `scripts/apply.sh`.

## Exposing services

Only HTTP(S) on ports 80 and 443 is reachable from the internet, through Traefik. To publish an app, give it an Ingress with a `host` and point that hostname's DNS at the cluster.

Requests by bare IP get Traefik's `404 page not found`. That's expected: no Ingress matches them.

### LAN-only services

Some hosts resolve to the node's LAN IP (`network.nodeIp`) instead of the public one. DNS alone doesn't protect them: Traefik routes by `Host` header, so anyone who sends that header to the public IP reaches the service. Every LAN-only Ingress therefore attaches the namespace's `lan-only` Traefik middleware (`ipAllowList` for `network.lanCidr`), e.g. `traefik.ingress.kubernetes.io/router.middlewares: home-lan-only@kubernetescrd`. This works because Traefik's Service uses `externalTrafficPolicy: Local` (`charts/cluster`), which keeps the real client IP. Requests made from the node itself still show up with an internal IP and get 403, so test from another device.

## Restore

1. Install the same k3s version:
   ```sh
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -
   ```
2. Install the Helm CLI (v4) and an NFS client (`apt install nfs-common`). kubelet needs the NFS client to mount the backup share.
   With ufw (default deny incoming), allow the pod and service networks, which k3s needs anyway and which also covers Traefik reaching Home Assistant on the host network. Then allow HomeKit and mDNS from the LAN (`network.lanCidr`):
   ```sh
   ufw allow from 10.42.0.0/16 comment 'k3s pods'
   ufw allow from 10.43.0.0/16 comment 'k3s services'
   ufw allow from <lanCidr> to any port 21064 proto tcp comment 'HomeKit Bridge'
   ufw allow from <lanCidr> to any port 5353 proto udp comment 'mDNS'
   ```
3. Optional: give your user the kubeconfig so the scripts don't need sudo:
   ```sh
   mkdir -p ~/.kube && sudo install -m 600 -o "$USER" -g "$USER" /etc/rancher/k3s/k3s.yaml ~/.kube/config
   ```
4. Put back your saved `site.yaml`, or run `scripts/configure.py` to write it. Run it as well if the site changed (new IPs, NAS, Zigbee stick...).
5. `scripts/setup-gandi-dns01.sh`: writes `site.secret.yaml` from a Gandi PAT, installs cert-manager and `charts/cluster`, and proves issuance with a staging certificate.
6. `scripts/apply.sh`
7. Restore the home automation state from the NAS: `scripts/restore-home.sh <YYYY-MM-DD>` (see [Backups](#backups)).

## TLS

cert-manager issues Let's Encrypt certificates through the ClusterIssuers in `charts/cluster` (`issuers` in its `values.yaml`: `letsencrypt-staging` and `letsencrypt-prod`). Every Ingress, public or LAN-only, gets its own certificate: the annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` and a `tls:` section with the host and a `secretName`.

How each domain is validated is set per DNS zone in `site.yaml`, by solver name (`solvers` in `charts/cluster/values.yaml`):

```yaml
acme:
  zones:
    example.com: gandi      # DNS-01 through the Gandi API; allows wildcards
  defaultSolver: http01     # every other zone: HTTP-01 on port 80
```

- `gandi`: DNS-01 via `cert-manager-webhook-gandi`, authenticated with a Gandi Personal Access Token (`site.secret.yaml`). Works for any hostname in the zone, LAN-only ones included.
- `http01`: for zones whose DNS has no API (e.g. a domain registered at Wix). The hostname must already resolve to this node, and port 80 must reach Traefik. Let's Encrypt follows Traefik's HTTP-to-HTTPS redirect, and the challenge is answered over HTTPS.

A domain on another DNS provider with an API needs a new entry under `solvers` (any cert-manager ACME solver) and its zone mapped to it in `site.yaml`; the templates don't change.

The PAT expires. Before it does, create a new one in Gandi and run `scripts/setup-gandi-dns01.sh` again. The script checks the token, updates `site.secret.yaml` and the Secret, and proves issuance with a staging certificate. It checks the zones that use `gandi`; pass domains as arguments to check others.

**A DNS-01 challenge stuck on "not yet propagated".** cert-manager checks the challenge's TXT record through public resolvers (1.1.1.1 and 8.8.8.8, see `helm/cert-manager/values.yaml`) and needs all of them to see it. If one asked before Gandi had published the record, it caches the "doesn't exist" answer for the zone's negative TTL, about 3 hours. Compare what the resolvers return for `_acme-challenge.<hostname>` (TXT) with Gandi's own nameservers. Then either wait, or purge the stale answer: https://one.one.one.one/purge-cache/ for 1.1.1.1, https://dns.google/cache for 8.8.8.8. Renewals start 30 days before expiry, so a few hours' delay there doesn't matter.

## Backups

`charts/home` runs a CronJob every night at 04:00 that writes `YYYY-MM-DD/zigbee2mqtt.tar.gz` and `YYYY-MM-DD/home-assistant.tar.gz` to the NAS (`nas` in `site.yaml`), keeping 14 days. The Zigbee2MQTT archive holds the network key and paired devices, so restoring it avoids re-pairing everything. The Home Assistant archive holds `.storage` (users, areas, integrations, groups, HomeKit) and the automations, but not the history database.

- Back up now: `kubectl -n home create job --from=cronjob/backup backup-manual-$(date +%s)`
- Restore a day: `scripts/restore-home.sh 2026-10-09`. It stops both apps, unpacks the archives over their volumes, and starts them again.

## Immich

`charts/immich` runs Immich publicly at `https://<immich.hostname>`, so albums can be shared with people outside the LAN. Its own data (uploads, thumbnails, encoded videos, nightly database dumps) and Postgres live on the node's disk. The photos stay on the NAS: the export `immich.libraryPath` is mounted at `/mnt/library`, and the NAS keeps that export read-only. In Immich, add it under Administration > External Libraries with the import path `/mnt/library`, and set Administration > Settings > Server > External domain to the public URL so share links point there.

**First install.** The first visitor to a fresh Immich becomes its admin, so it starts without an Ingress (and so without a certificate that would announce the hostname in the CT logs). Create the admin through a tunnel, then make it public:

```sh
helm upgrade --install immich charts/immich -n immich --create-namespace -f site.yaml --set ingress=false --wait --timeout 15m
kubectl -n immich port-forward svc/immich-server 2283:2283     # then open http://localhost:2283
scripts/apply.sh                                               # adds the public Ingress
```

Run the port-forward on a computer whose kubectl reaches the cluster (the node's kubeconfig with `127.0.0.1` replaced by the node's LAN IP). Or run it on the node and tunnel to it, which leaves no cluster credentials on the computer: `ssh -N -L 2283:localhost:2283 <user>@<node>`.

**Editing metadata.** Immich writes edits to tags, descriptions, dates and ratings as `.xmp` sidecars next to the originals, and there's no setting to put them elsewhere. With the export read-only that write fails silently and Immich re-reads the file, so the edit is lost. Before editing, switch the export to read/write on the NAS (the mount in the cluster is already read-write), and back to read-only when done. Keep those sessions short: while writable, deleting an asset for good in Immich (emptying the trash, or its nightly cleanup of items trashed 30+ days ago) also deletes the original on the NAS. Read-only, those deletes fail and the originals stay.

## Monitoring

Everything runs in namespace `monitoring`:

- `helm/kube-prometheus-stack`: Prometheus (15 days, at most 18 GB), Alertmanager, Grafana, node-exporter and kube-state-metrics. Scrapes of etcd, the scheduler, the controller-manager and kube-proxy are off: k3s runs them inside its own process without exposing their metrics. Prometheus picks up ServiceMonitors, PodMonitors and rules from every namespace.
- `helm/loki`: Loki as a single binary on the node's disk, keeping 14 days of logs.
- `helm/alloy`: Grafana Alloy, shipping every pod's logs to Loki through the Kubernetes API.
- `charts/monitoring`: Grafana's LAN-only Ingress at `grafana.hostname` from `site.yaml`.

Grafana comes with Prometheus, Alertmanager and Loki as data sources, and the usual Kubernetes and node dashboards. Log in as `admin`; the password is generated on first install:

```sh
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Helm installs kube-prometheus-stack's CRDs only on the first install. After bumping its version, apply the new CRDs first, as its upgrade notes describe.

## Secrets

Kubernetes Secrets are base64, not encryption. **Plaintext secrets are never committed.**

- Secret values go in `site.secret.yaml`, which is gitignored (`*.secret.yaml`). `site.secret.example.yaml` next to it lists the keys with placeholder values.
- `scripts/apply.sh` passes it to `charts/cluster`, which turns it into the Secret. Helm also keeps a copy in its release record, a Secret in `kube-system`.
