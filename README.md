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
helmfile.yaml.gotmpl   every release, built from the components and apps below and the site's settings
infrastructure/        shared services, one directory per component
  base/                always: cert-manager, OpenEBS LVM LocalPV, and chart/ (ClusterIssuers, Gandi
                       DNS-01 credentials, Traefik settings, the StorageClass lvm)
  monitoring/          kube-prometheus-stack, Loki, Alloy, and chart/ (Grafana's Ingress, the Discord
                       webhook's Secret)
  postgres/            the CloudNativePG operator
apps/                  one directory per app
  home/                Mosquitto, Zigbee2MQTT, Home Assistant, nightly backup
  immich/              Immich, public, with the photo library on the NAS
charts/                charts the components and apps share
  app/                 the template for apps without a chart of their own
  postgres-cluster/    one app's Postgres cluster, with nightly dumps
scripts/               helpers you run by hand: configure, Gandi and Discord setup, restore,
                       Grafana's password
site.example.yaml      the shape of site.yaml; site.secret.example.yaml for site.secret.yaml
```

A component's `component.yaml` lists its releases: a third-party chart with its exact version and its values in `<release>.yaml` next to it, or the component's own `chart/`. An app's `app.yaml` says what it runs, and its `chart/` holds the templates. Charts hold templates and defaults (image tags, sizes) only: every site-specific value comes from `site.yaml`. `scripts/configure.py` writes `site.yaml` from questions, offering the current values or ones detected on the node, so you don't have to edit it by hand.

### Site directory

`site.yaml`, `site.secret.yaml` and `values/` make up the site directory: everything that turns this repo into one particular cluster. It describes the home network, so it stays out of this public repo. helmfile and the scripts find it through `$CAIRN_SITE`, or use the repo root when that's unset (the three are gitignored there). Point `CAIRN_SITE` elsewhere, e.g. a private repo, to keep them out of this one entirely:

```sh
export CAIRN_SITE=~/cairn-site   # absolute; holds site.yaml, site.secret.yaml, values/
scripts/configure.py             # writes $CAIRN_SITE/site.yaml
helmfile apply
```

To pin which version of this repo a site runs, add it to the private repo as a git submodule at a tag, and run `CAIRN_SITE=$PWD helmfile -f cairn/helmfile.yaml.gotmpl apply` from there. Think twice before committing `site.secret.yaml` in plaintext to a hosted repo, even a private one.

- **`infrastructure`** in `site.yaml` turns each optional component on or off (`monitoring`, `postgres`). The base always goes in, and its Gandi webhook whenever a zone uses the `gandi` solver.
- **`apps`** lists the apps to install, one entry each, in the namespace of the entry's name. An entry holds that app's settings (`hostname`, ...), and can override any of its chart's defaults:
  ```yaml
  apps:
    home:
      hostname: ha.example.com
      zigbee: {device: /dev/serial/by-id/usb-..., adapter: zstack}
    immich:
      hostname: immich.example.com
      libraryPath: /volume1/photos
      storage: {data: {size: 80Gi}}     # over apps/immich/chart/values.yaml
    notes:
      database: {size: 2Gi}             # only a Postgres cluster, for an app running elsewhere
  ```
  Turning something off only stops helmfile from managing it: `helm uninstall` removes it and keeps its volumes. `scripts/configure.py` only asks what the components and apps that are on need, and keeps entries it has no questions for as they are.
- **`values/<release>.yaml`** overrides a component release's chart defaults, e.g. `values/loki.yaml` over `infrastructure/monitoring/loki.yaml`. It goes last, so it wins (maps merge, lists replace). A longer Prometheus retention, say, without touching this repo:
  ```yaml
  # values/kube-prometheus-stack.yaml
  prometheus:
    prometheusSpec:
      retention: 30d
  ```

Keep a copy of the site directory somewhere safe (a private repo, a password manager, the NAS): after losing the node, `scripts/configure.py` can rebuild `site.yaml`, but only from what you remember.

### Adding an app

1. `apps/<app>/app.yaml`: its `description`, `timeout`, `database` if it needs one, and under `site` the settings it reads from its entry in `site.yaml`, each with a comment, the question `scripts/configure.py` asks, an example for `site.example.yaml`, and a validator (fields: `apps/home/app.yaml`).
2. What it runs, either way:
   - `apps/<app>/values.yaml` for the template `charts/app`: workloads (image, port, env, Ingress, volumes, the database's credentials...), documented in `charts/app/values.yaml`, example in `charts/app/examples/web.yaml`. Its hostnames are site settings: `hosts.<workload>` under `site` in `app.yaml`. Anything the template doesn't cover goes in `extraObjects`.
   - `apps/<app>/chart/`: a chart of its own. Templates read their settings from the root of `.Values` (`.Values.hostname`), and the shared ones from `site.yaml`'s sections (`.Values.network.lanCidr`).
3. `scripts/configure.py` to add its entry, then `scripts/configure.py --example` to update `site.example.yaml`.

An app whose definition lives elsewhere, e.g. in its own repo, needs nothing in `apps/`: its entry names a chart, or values files for `charts/app`, pinned, and helmfile fetches them (git over ssh uses your ssh keys; `helm registry login` for OCI registries). Its other keys go to the chart as values.

```yaml
apps:
  shop:
    chart: oci://ghcr.io/<owner>/charts/shop      # or git::ssh://git@github.com/<owner>/<repo>.git@deploy/chart?ref=v1.2.0
    version: 1.2.0
    database: {}
    hostname: shop.example.com
  blog:                                           # charts/app, with the definition from the app's repo
    values: [git::ssh://git@github.com/<owner>/blog.git@deploy/cairn.yaml?ref=v2.0.1]
    hosts: {web: blog.example.com}
```

A component works the same way: `infrastructure/<name>/component.yaml` (fields: `infrastructure/base/component.yaml`), its key under `infrastructure` in `site.yaml`, and its own settings under `site` in `component.yaml`.

## Apply

With [helmfile](https://github.com/helmfile/helmfile) v1.8 and the [helm-diff](https://github.com/databus23/helm-diff) plugin (v3.15.10 or later; Helm 4 verifies its signature, see its README), from the repo root:

```sh
helmfile diff                       # what would change in the cluster
helmfile apply                      # install or upgrade what changed
helmfile apply -l name=loki         # one release
helmfile apply -l app=immich        # an app, with its database
helmfile apply -l component=monitoring
```

`helmfile.yaml.gotmpl` builds the releases from the base, the components `infrastructure` turns on, and the entries in `apps`, and installs them in dependency order (each release's `needs`): cert-manager and its Gandi webhook (their CRDs back the ClusterIssuers and Certificates), OpenEBS LVM LocalPV, the cluster chart (the ClusterIssuers, and the StorageClass `lvm` the other volumes use), kube-prometheus-stack (ServiceMonitor and PodMonitor CRDs) before Loki, Alloy and CloudNativePG, the operator before each app's database, a database before its app. A component's chart gets `site.yaml` (and `site.secret.yaml` if it turns secrets into Secrets), a third-party chart its `<release>.yaml`, then either one its override from `values/`. An app's chart gets `site.yaml`, then its entry in `apps`. For the kubeconfig it uses `$KUBECONFIG`, else `~/.kube/config` ([Restore](#restore), step 3).

To upgrade an app, bump its image in its chart's `values.yaml` and run `helmfile apply`. To upgrade a third-party chart, bump its `version` in its `component.yaml`.

## Exposing services

Only HTTP(S) on ports 80 and 443 is reachable from the internet, through Traefik. To publish an app, give it an Ingress with a `host` and point that hostname's DNS at the cluster.

Requests by bare IP get Traefik's `404 page not found`. That's expected: no Ingress matches them.

### LAN-only services

Some hosts resolve to the node's LAN IP (`network.nodeIp`) instead of the public one. DNS alone doesn't protect them: Traefik routes by `Host` header, so anyone who sends that header to the public IP reaches the service. Every LAN-only Ingress therefore attaches the namespace's `lan-only` Traefik middleware (`ipAllowList` for `network.lanCidr`), e.g. `traefik.ingress.kubernetes.io/router.middlewares: home-lan-only@kubernetescrd`. This works because Traefik's Service uses `externalTrafficPolicy: Local` (`infrastructure/base/chart`), which keeps the real client IP. Requests made from the node itself still show up with an internal IP and get 403, so test from another device.

## Restore

1. Install the same k3s version:
   ```sh
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -
   ```
2. Install the Helm CLI (v4), helmfile with the helm-diff plugin ([Apply](#apply)), and an NFS client (`apt install nfs-common`). kubelet needs the NFS client to mount the backup share.
   With ufw (default deny incoming), allow the pod and service networks, which k3s needs anyway and which also covers Traefik reaching Home Assistant on the host network. Then allow HomeKit and mDNS from the LAN (`network.lanCidr`):
   ```sh
   ufw allow from 10.42.0.0/16 comment 'k3s pods'
   ufw allow from 10.43.0.0/16 comment 'k3s services'
   ufw allow from <lanCidr> to any port 21064:21065 proto tcp comment 'HomeKit Bridges'
   ufw allow from <lanCidr> to any port 5353 proto udp comment 'mDNS'
   ```
   Leave unallocated space in an LVM volume group (`lvm.volumeGroup`) for the size-capped volumes, at least 90 GiB plus 5 GiB per Postgres cluster with the sizes in this repo (see [Storage](#storage)). Ubuntu's installer does that by default: it gives the root logical volume only part of the disk.
3. Optional: give your user the kubeconfig so helmfile and the scripts don't need sudo:
   ```sh
   mkdir -p ~/.kube && sudo install -m 600 -o "$USER" -g "$USER" /etc/rancher/k3s/k3s.yaml ~/.kube/config
   ```
4. Put back your site directory (clone the private repo and set `CAIRN_SITE`, or copy the files into the repo root), or run `scripts/configure.py` to write `site.yaml`. Run it as well if the site changed (new IPs, NAS, Zigbee stick...).
5. `scripts/setup-gandi-dns01.sh`: writes `site.secret.yaml` from a Gandi PAT, installs cert-manager and the cluster chart, and proves issuance with a staging certificate.
6. `scripts/setup-discord-alerts.sh`: writes the Discord webhook for alerts to `site.secret.yaml` (see [Monitoring](#monitoring)). It installs kube-prometheus-stack too.
7. `helmfile apply`
8. Restore the home automation state from the NAS: `scripts/restore-home.sh <YYYY-MM-DD>` (see [Backups](#backups)).
9. Restore each Postgres database: `scripts/restore-postgres.sh <namespace> <YYYY-MM-DD>` (see [Postgres](#postgres)).

## TLS

cert-manager issues Let's Encrypt certificates through the ClusterIssuers in `infrastructure/base/chart` (`issuers` in its `values.yaml`: `letsencrypt-staging` and `letsencrypt-prod`). Every Ingress, public or LAN-only, gets its own certificate: the annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` and a `tls:` section with the host and a `secretName`.

How each domain is validated is set per DNS zone in `site.yaml`, by solver name (`solvers` in `infrastructure/base/chart/values.yaml`):

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

**A DNS-01 challenge stuck on "not yet propagated".** cert-manager checks the challenge's TXT record through public resolvers (1.1.1.1 and 8.8.8.8, see `infrastructure/base/cert-manager.yaml`) and needs all of them to see it. If one asked before Gandi had published the record, it caches the "doesn't exist" answer for the zone's negative TTL, about 3 hours. Compare what the resolvers return for `_acme-challenge.<hostname>` (TXT) with Gandi's own nameservers. Then either wait, or purge the stale answer: https://one.one.one.one/purge-cache/ for 1.1.1.1, https://dns.google/cache for 8.8.8.8. Renewals start 30 days before expiry, so a few hours' delay there doesn't matter.

## Backups

`apps/home` runs a CronJob every night at 04:00 that writes `YYYY-MM-DD/zigbee2mqtt.tar.gz` and `YYYY-MM-DD/home-assistant.tar.gz` to the NAS (`nas` in `site.yaml`), keeping 14 days. The Zigbee2MQTT archive holds the network key and paired devices, so restoring it avoids re-pairing everything. The Home Assistant archive holds `.storage` (users, areas, integrations, groups, HomeKit) and the automations, but not the history database.

- Back up now: `kubectl -n home create job --from=cronjob/backup backup-manual-$(date +%s)`
- Restore a day: `scripts/restore-home.sh 2026-10-09`. It stops both apps, unpacks the archives over their volumes, and starts them again.

## Immich

`apps/immich` runs Immich publicly at `https://<apps.immich.hostname>`, so albums can be shared with people outside the LAN. Its own data (uploads, thumbnails, encoded videos, nightly database dumps) and Postgres live on the node's disk. The photos stay on the NAS: the export `apps.immich.libraryPath` is mounted at `/mnt/library`, and the NAS keeps that export read-only. In Immich, add it under Administration > External Libraries with the import path `/mnt/library`, and set Administration > Settings > Server > External domain to the public URL so share links point there.

**First install.** The first visitor to a fresh Immich becomes its admin, so it starts without an Ingress (and so without a certificate that would announce the hostname in the CT logs). Create the admin through a tunnel, then make it public:

```sh
helmfile apply -l name=immich --set ingress=false
kubectl -n immich port-forward svc/immich-server 2283:2283     # then open http://localhost:2283
helmfile apply -l name=immich                                  # adds the public Ingress
```

Run the port-forward on a computer whose kubectl reaches the cluster (the node's kubeconfig with `127.0.0.1` replaced by the node's LAN IP). Or run it on the node and tunnel to it, which leaves no cluster credentials on the computer: `ssh -N -L 2283:localhost:2283 <user>@<node>`.

**Editing metadata.** Immich writes edits to tags, descriptions, dates and ratings as `.xmp` sidecars next to the originals, and there's no setting to put them elsewhere. With the export read-only that write fails silently and Immich re-reads the file, so the edit is lost. Before editing, switch the export to read/write on the NAS (the mount in the cluster is already read-write), and back to read-only when done. Keep those sessions short: while writable, deleting an asset for good in Immich (emptying the trash, or its nightly cleanup of items trashed 30+ days ago) also deletes the original on the NAS. Read-only, those deletes fail and the originals stay.

## Postgres

`infrastructure/postgres` runs the CloudNativePG operator. Every app entry with a `database` gets its own Postgres cluster in its namespace (`charts/postgres-cluster`, release `postgres`): one instance, on a 5 GiB `lvm` volume. Separate clusters keep projects apart: each one restarts, upgrades and restores on its own, and one project's load can't fill another's disk. An entry can be just a database, for an app that doesn't run in this cluster (yet).

In each of those namespaces:

- `postgres-rw:5432` serves the database `app`, owned by the user `app`.
- Secret `postgres-app` holds the credentials, generated on first start: `username`, `password`, `dbname`, `host`, `port`, and a ready-made `uri`. Point the app at it, e.g.
  ```yaml
  env:
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef: {name: postgres-app, key: uri}
  ```
- A NetworkPolicy lets in only that namespace's pods, plus the operator and Prometheus. Apps in other namespaces can't connect even with the password. A new pod's connections are refused for its first few seconds, until k3s adds it to the policy, so apps should retry the database on startup.

To add one, add `database: {}` to an app's entry (or an entry of its own) and run `helmfile apply`. `database` takes `size` to grow it online (`notes: {database: {size: 20Gi}}`) and `image` to pin its version. Removing it only stops helmfile from managing that cluster, and even `helm uninstall` leaves the Cluster and its data in place. Deleting it takes `kubectl -n <namespace> delete cluster postgres`, which removes the data too.

**Backups.** Every night at 04:30, each database is dumped with `pg_dump` (custom format) to the NAS, as `<postgres.backupPath>/<namespace>/YYYY-MM-DD.dump`, and kept 14 days. A failed dump shows up in Discord as `KubeJobFailed`. To restore a day, stop the apps that use the database, then run `scripts/restore-postgres.sh <namespace> <YYYY-MM-DD>`. It lists the open connections, asks before changing anything, and replaces the database's contents in one transaction; if anything fails, the database stays as it was.

**Upgrades.** For a new minor version, change `image` in `charts/postgres-cluster/values.yaml` and run `helmfile apply`; CloudNativePG restarts each instance on it. A new major version works the same way, but CloudNativePG then stops the instance and upgrades the data in place with `pg_upgrade`, which takes a few minutes. Try it on one cluster first (`database.image` in its entry, e.g. the uat one), right after a dump, and run `ANALYZE` afterwards, since `pg_upgrade` doesn't carry over the planner statistics.

Grafana has CloudNativePG's dashboard, and Prometheus scrapes every instance.

## Monitoring

`infrastructure/monitoring` runs everything in namespace `monitoring`:

- kube-prometheus-stack: Prometheus (15 days, at most 18 GB, on a 20 GiB volume), Alertmanager, Grafana, node-exporter and kube-state-metrics. Scrapes of etcd, the scheduler, the controller-manager and kube-proxy are off: k3s runs them inside its own process without exposing their metrics. Prometheus picks up ServiceMonitors, PodMonitors and rules from every namespace. Of the cluster's own metrics it keeps only what the chart's rules and dashboards read, about 18k series instead of 113k: k3s serves every component's metrics at both the apiserver and the kubelet endpoint, so each of those jobs keeps only its own, and Grafana's, cAdvisor's and kube-state-metrics' unused families are dropped (`metricRelabelings` in `kube-prometheus-stack.yaml`). A chart upgrade can bring rules or dashboards that read a dropped metric, so check them against those lists when bumping it.
- Loki: a single binary on a 10 GiB volume, keeping 14 days of logs. It takes at most 100 KB/s, so a pod stuck in a log loop can't fill the volume quickly.
- Alloy: ships every pod's logs to Loki through the Kubernetes API.
- `chart/`: Grafana's LAN-only Ingress at `grafana.hostname` from `site.yaml`, and the Discord webhook's Secret.

Grafana comes with Prometheus, Alertmanager and Loki as data sources, and the usual Kubernetes and node dashboards. Log in as `admin`; the password is generated on first install:

```sh
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Change it with `scripts/set-grafana-password.sh`, not in Grafana's UI. The sidecars that make Grafana reload dashboards and data sources log in with the Secret's copy, and the script sets both. Grafana's volume isn't backed up, so after a rebuild the password is a new generated one again; run the script to set yours.

**Alerts** go to a Discord channel: every alert from kube-prometheus-stack's default rules (a volume filling up, a pod crash-looping, a node running out of memory...), grouped by namespace, again every 12 hours while it keeps firing, and once more when it resolves. Watchdog, which always fires to prove the pipeline works, is not sent. Set up or switch the channel with `scripts/setup-discord-alerts.sh`: it takes the channel's webhook URL (channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL), checks it, stores it in `site.secret.yaml`, applies it, and sends a test alert. The routing is in `infrastructure/monitoring/kube-prometheus-stack.yaml` (`alertmanager.config`).

Helm installs kube-prometheus-stack's CRDs only on the first install. After bumping its version, apply the new CRDs first, as its upgrade notes describe.

## Storage

Two StorageClasses, both on the node's disk:

- `lvm` (`infrastructure/base/chart`, provisioned by OpenEBS LVM LocalPV): each volume is an LVM logical volume of exactly its requested size, in the volume group `lvm.volumeGroup` from `site.yaml`. The size is a hard cap: past it, writes fail with "no space left" and the root filesystem isn't touched. For volumes that keep growing: Prometheus (20 GiB), Loki (10 GiB), Immich's thumbnails and encoded videos (40 GiB), its Postgres (10 GiB) and model cache (10 GiB), each Postgres cluster (5 GiB by default).
- `local-path` (k3s's default): a directory on the root filesystem. The requested size is neither enforced nor reserved. For the small volumes that stay small: Home Assistant, Zigbee2MQTT, Grafana. Mounting them needs nothing but the node, so the home automation starts even when the LVM driver doesn't.

The `lvm` volumes can only use the volume group's unallocated space. Volumes grow online, without restarting anything:

- Immich: raise `storage.<volume>.size` (in `apps/immich/chart/values.yaml`, or `apps.immich.storage` in `site.yaml`) and run `helmfile apply`.
- Prometheus, Loki: a StatefulSet doesn't resize the PVCs it already made, so patch the PVC, e.g. `kubectl -n monitoring patch pvc storage-loki-0 -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'`. Then raise the size in `infrastructure/monitoring/<release>.yaml` too, so a rebuild gets the same. Loki's upgrade fails on that change (a StatefulSet can't change its volume template), so first delete the StatefulSet alone: `kubectl -n monitoring delete statefulset loki --cascade=orphan` (the pod keeps running), then run `helmfile apply -l name=loki`. Prometheus's operator recreates its StatefulSet by itself (Prometheus restarts).

When the volume group runs out, it needs more space from the host: a new disk added to the group, or a smaller root logical volume. Shrinking root has to happen offline (ext4 can grow while mounted but not shrink), e.g. from a live USB: `e2fsck -f`, then `lvreduce --resizefs`. Back up first.

## Secrets

Kubernetes Secrets are base64, not encryption. **Plaintext secrets are never committed.**

- Secret values go in `site.secret.yaml` in the site directory; in the repo root it's gitignored (`*.secret.yaml`). `site.secret.example.yaml` lists the keys with placeholder values.
- Any value there can instead be a reference that helmfile resolves when it renders ([vals](https://github.com/helmfile/vals), built into helmfile): `ref+sops://secrets.enc.yaml#/gandi/pat` (a SOPS-encrypted file, key from `SOPS_AGE_KEY_FILE`), `ref+op://<vault>/<item>/<field>` (1Password), `ref+envsubst://$VAR`, and more. A plain value is used as it is. A file path in a reference is relative to where you run helmfile.
- The setup scripts write it through `scripts/secret.py`, which changes one key and keeps the others.
- helmfile passes it to the cluster chart (the Gandi PAT) and the monitoring chart (the Discord webhook), and each app gets its own section, `apps.<name>` (merged over its entry; `charts/app` turns `secrets` into a Secret). The charts put secrets only in Secrets, which `helmfile diff` masks. Helm also keeps a copy in each release record, a Secret in the release's namespace.
