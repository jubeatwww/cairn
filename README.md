# cairn

Kubernetes config for my single-node k3s homelab: what runs on it, and everything needed to rebuild it from scratch. The repo is the template; one cluster's specifics live outside it, in a site directory, so the same repo can run another cluster with another site directory.

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

## Design

- **The repo is the template, the site directory is the cluster.** Every value that describes one place (hostnames, IPs, NAS paths, devices, secrets) lives in the site directory. The repo, which is public, holds charts, defaults and placeholders only, and a pre-commit hook keeps it that way.
- **Everything is data, built in one place.** Each component and app describes itself in a `component.yaml` or `app.yaml`; `site.yaml` says which ones are on and holds their settings; `helmfile.yaml.gotmpl` turns both into releases. Adding a component or an app means adding its directory and its entry, never editing helmfile, the scripts or another component.
- **Classified by who uses it.** `infrastructure/` is what apps build on (certificates, storage, monitoring, the database operators), `apps/` is what people use, `charts/` holds the building blocks both share (the app template, a database, a ClickHouse server, a backup).
- **Third-party charts stay as published.** Each runs at an exact version with its values next to its `component.yaml`; whatever needs site values (an Ingress, a Secret) goes in the component's own chart instead.
- **Everything is pinned.** Chart versions, image tags, and charts or values fetched from other repos: an unpinned source fails the render.
- **Data outlives its release.** PVCs are kept when a release is uninstalled; data that keeps growing gets a size-capped `lvm` volume; whatever can't be rebuilt is listed under `backup` and copied to the NAS every night, and one command restores it.
- **Secrets stay out of the repo and out of plain objects.** They live in `site.secret.yaml`, or in a secret store it references; charts put them only in Secrets, and each app sees only its own.
- **One job per script, and checks instead of care.** `configure.py` writes the settings, `secret.py` the secrets, helmfile installs, `restore.sh` restores. `precommit.py` checks every commit offline; `check.py` checks the running cluster.

## Layout

```
helmfile.yaml.gotmpl   every release, built from the components, the apps and the site's settings
infrastructure/        shared services, one directory per component
  base/                always: cert-manager, OpenEBS LVM LocalPV, and chart/ (ClusterIssuers, Gandi
                       DNS-01 credentials, Traefik settings, the StorageClass lvm)
  monitoring/          kube-prometheus-stack, Loki, Alloy, and chart/ (Grafana's Ingress, the Discord
                       webhook's Secret)
  postgres/            the CloudNativePG operator
  clickhouse/          Altinity's ClickHouse operator
apps/                  one directory per app
  aetherium/           market-tap, collecting Taiwan stock and futures quotes into ClickHouse
  home/                Mosquitto, Zigbee2MQTT, Home Assistant
  immich/              Immich, public, with the photo library on the NAS
charts/                building blocks the components and apps share
  app/                 the template for apps without a chart of their own
  backup/              an app's or component's nightly backup to the NAS, and its restore
  clickhouse/          an app's ClickHouse server
  postgres-cluster/    an app's Postgres cluster
scripts/               configure.py, secret.py, check.py, restore.sh, set-grafana-password.sh;
                       precommit.py and hooks/ for commits
site.example.yaml      the shape of site.yaml; site.secret.example.yaml for site.secret.yaml
```

## Site directory

`site.yaml`, `site.secret.yaml`, `values/` and `plugins/` (apps cloned from their own repos) make up the site directory. helmfile and the scripts find it through `$CAIRN_SITE` (absolute), or use the repo root when that's unset; all four are gitignored there. To keep them out of this repo entirely, put them in a private one:

```sh
export CAIRN_SITE=~/cairn-site   # holds site.yaml, site.secret.yaml, values/, plugins/
scripts/configure.py             # writes $CAIRN_SITE/site.yaml
helmfile apply
```

To pin which version of this repo a site runs, add it to the private repo as a git submodule at a tag, and run `CAIRN_SITE=$PWD helmfile -f cairn/helmfile.yaml.gotmpl apply` from there. Think twice before committing `site.secret.yaml` in plaintext to a hosted repo, even a private one ([Secrets](#secrets) has alternatives).

`scripts/configure.py` writes `site.yaml` from questions, offering the current values or ones detected on the node (LAN IP and network, timezone, Zigbee stick, LVM volume group), and shows the diff before writing. Its sections:

- the shared settings: `acmeEmail` and `acme` ([TLS](#tls)), `timezone`, `network`, `nas`, `backup`, `lvm`
- `infrastructure`: each optional component, on or off. The base always goes in.
- each component's own settings, e.g. `grafana.hostname`
- `apps`: one entry per app to install, holding its settings ([Components and apps](#components-and-apps))

```yaml
infrastructure: {monitoring: true, postgres: true}
apps:
  home:
    hostname: ha.example.com
    zigbee: {device: /dev/serial/by-id/usb-..., adapter: zstack}
  immich:
    hostname: immich.example.com
    libraryPath: /volume1/pictures
    storage: {data: {size: 80Gi}}     # over apps/immich/chart/values.yaml
  notes:
    database: {size: 2Gi}             # only a Postgres cluster, for an app running elsewhere
```

Turning a component off or removing an entry only stops helmfile from managing it: `helm uninstall` removes it, and keeps its volumes.

`values/<release>.yaml` overrides a component release's defaults without touching this repo, e.g. a longer Prometheus retention:

```yaml
# values/kube-prometheus-stack.yaml
prometheus:
  prometheusSpec:
    retention: 30d
```

Keep a copy of the site directory somewhere safe (a private repo, a password manager, the NAS): after losing the node, `scripts/configure.py` can rebuild `site.yaml`, but only from what you remember.

## Components and apps

**`infrastructure/<name>/component.yaml`**, for the base and every component `infrastructure.<name>` turns on:

| Field | |
|---|---|
| `description` | what it runs; `configure.py` shows it |
| `repositories` | `name: url` of the Helm repositories its releases use |
| `releases` | a list: `name`, `namespace`, `chart` (`repo/chart`, or `./chart` for the component's own), `version` (exact), `timeout` (seconds, default 300), `needs` (`namespace/release` installed first, if it's installed at all), `site` (`site`: gets `site.yaml`; `secrets`: `site.secret.yaml` too), `when` (`gandiSolver`: only if a zone uses gandi) |
| `backup` | like an app's, plus the `namespace` and `needs` of its release |
| `site` | the settings it reads from `site.yaml` (below) |

**`apps/<app>/app.yaml`**, for every entry in `apps` named after it, or naming it with `app:`:

| Field | |
|---|---|
| `description`, `timeout`, `needs` | as for a release |
| `database` | `{}`, or `{size, image}`: a Postgres cluster in its namespace ([Postgres](#postgres)) |
| `clickhouse` | `{}`, or `{size, image}`: a ClickHouse server in its namespace ([ClickHouse](#clickhouse)) |
| `backup` | `volumes` (`<pvc>: {exclude, paths}`), `schedule`, `keepDays`; or `false`. The database and ClickHouse are always included ([Backups](#backups)); `database: {}` (or `{image}`, its `pg_dump`) includes a CloudNativePG cluster `postgres` that the app's own chart makes. |
| `site` | the settings it reads from its entry (below) |
| `secrets` | the secrets it reads from its section of `site.secret.yaml`, for `scripts/secret.py fill` (below) |

What it runs is either `apps/<app>/values.yaml` for the template `charts/app` (workloads with image, port, env, Ingress, volumes and the database's credentials; reference in `charts/app/values.yaml`, example in `charts/app/examples/web.yaml`), or `apps/<app>/chart/`, a chart of its own.

**An entry in `apps`** can set or override any of those fields, and:

| Field | |
|---|---|
| `app` | the app it installs, if not its own name: a directory in `apps/`, else in `plugins/` in the site directory; several entries can install one app (`shop`, `shop-staging`). Or the absolute path of a directory shaped like one. |
| `chart`, `version` | a chart from elsewhere: `oci://...` with an exact `version`, `git::ssh://...@path?ref=<tag>`, or the absolute path of a checkout |
| `values` | values files for its chart or for `charts/app`: from elsewhere (`git::...?ref=<tag>`, or absolute paths), or relative to the app's directory |
| anything else | its settings, at the root of its chart's values (`hostname`, `hosts`, and any chart default to override) |

An app defined in its own repo needs nothing in `apps/`. Either its repo is shaped like `apps/<app>/` (`app.yaml`, `chart/`, a values file per environment), a plugin: clone it into `plugins/` in the site directory and name the clone with `app:`. Its entry picks the branch's values file, and `git pull` there updates it. If only a directory of the repo is shaped like that (`deploy/`, next to the app's source), clone just that directory and name it by its path: `git clone --filter=blob:none --sparse <url> plugins/<dir>`, `git -C plugins/<dir> sparse-checkout set deploy`, `app: <dir>/deploy`. Or helmfile fetches what its entry names (git over ssh uses your ssh keys; `helm registry login` for OCI registries).

```yaml
apps:
  shop:
    chart: oci://ghcr.io/<owner>/charts/shop
    version: 1.2.0
    database: {}
    hostname: shop.example.com
  blog:                                    # charts/app, defined in the app's own repo
    values: [git::ssh://git@github.com/<owner>/blog.git@deploy/cairn.yaml?ref=v2.0.1]
    hosts: {web: blog.example.com}
  store:                                   # a plugin: git clone <url> plugins/store-deploy
    app: store-deploy
    values: [staging.yaml]                 # in plugins/store-deploy
```

**A setting under `site`** is declared by its dotted key (under `apps.<name>` for an app) with `comment` (written above it in `site.yaml`), `ask` (the question), `example` (for `site.example.yaml`), and optionally `check` (a validator in `configure.py`: `hostname`, `absPath`, `ip`, `cidr`, `email`, `zigbeeAdapter`), `default`, and `detect` (`serialDevice`). Templates read it with `required "<key> is required (site.yaml)"`.

**A secret under `secrets`** is declared the same way, by its dotted key under `apps.<name>` in `site.secret.yaml`, with `comment` and either `generate: true` (a random 64-character hex string, for what only the app itself uses: a signing key, an internal password) or `ask` (the question, for what comes from elsewhere: a registry token). `scripts/secret.py fill` sets each one that's still unset, for every entry, or one (`fill <entry>`), or every entry installing an app (`fill <app>`, e.g. a plugin's directory name). While one is unset, helmfile stops before rendering anything (`apps.<name>.<key> is missing (site.secret.yaml): scripts/secret.py fill <name>`), as it does for a mistake in `site.yaml`, so a chart needn't check for it itself.

**What a chart gets**, later ones winning (maps merge, lists replace):

- a component's chart: `site.yaml`, `site.secret.yaml` with `site: secrets`, then `values/<release>.yaml`
- a third-party chart: `<release>.yaml` next to `component.yaml`, then `values/<release>.yaml`
- an app's chart: `site.yaml`, `apps/<app>/values.yaml`, the entry's `values` files, the entry itself, then its section of `site.secret.yaml` (`apps.<name>`)

**Adding an app**: write `apps/<app>/app.yaml` and `values.yaml` (or `chart/`), run `scripts/configure.py` to add its entry, then `scripts/configure.py --example` to update `site.example.yaml`. **Installing a plugin**: `git clone <url> plugins/<dir>`, add its entry (`app: <dir>` and `values:`), then `scripts/secret.py fill <name>` and `helmfile apply -l app=<name>`. **Adding a component**: the same with `infrastructure/<name>/component.yaml`; `configure.py` asks whether to turn it on.

## Apply

With [helmfile](https://github.com/helmfile/helmfile) v1.8 and the [helm-diff](https://github.com/databus23/helm-diff) plugin (v3.15.10 or later; Helm 4 verifies its signature, see its README), from the repo root:

```sh
helmfile diff                            # what would change in the cluster
helmfile apply                           # install or upgrade what changed
helmfile apply -l name=loki              # one release
helmfile apply -l app=immich             # an app, with its database and backup
helmfile apply -l component=monitoring
```

Releases install in dependency order (each one's `needs`): cert-manager first, since its CRDs back every certificate; LVM LocalPV and the cluster chart, which defines the StorageClass `lvm`; kube-prometheus-stack before whatever brings ServiceMonitors or PodMonitors; the operator before each database, a database before its app. helmfile uses `$KUBECONFIG`, else `~/.kube/config` ([Restore](#restore), step 3).

To upgrade an app, bump its image in `apps/<app>/chart/values.yaml` (or `apps/<app>/values.yaml`) and run `helmfile apply`. To upgrade a third-party chart, bump its `version` in its `component.yaml`, then run `scripts/check.py`.

## Checks

**Before a commit**, `scripts/precommit.py` runs offline in a few seconds. Turn it on once per clone as the pre-commit hook:

```sh
git config core.hooksPath scripts/hooks
```

It stops the commit if:

- the staged changes contain a value from the site directory that the examples don't have: a hostname, IP, NAS path, secret, the DNS zones and LAN prefix they imply, your git email. Names of directories in `apps/` and `infrastructure/` are fine; anything else is the home network's.
- `site.example.yaml` isn't what `scripts/configure.py --example` writes
- a chart in this repo fails to lint or render with the examples, every component on or all off
- a script has a syntax error (or `shellcheck` and `ruff` complain, if installed)

`git commit --no-verify` skips it once. `scripts/precommit.py --all` looks for those values in every tracked file instead, e.g. after adding a site setting.

**On the cluster**, `scripts/check.py`, read-only:

- every certificate is Ready, with more than 14 days left
- every backup succeeded in the last 26 hours
- every Prometheus target is up, every rule evaluates, nothing fires but Watchdog
- every metric a rule or a Grafana dashboard reads is kept by the scrapes' `metricRelabelings`, which matters after bumping kube-prometheus-stack ([Monitoring](#monitoring))

`scripts/check.py --test-alert` also sends a test alert to Discord, which resolves by itself.

## Exposing services

Only HTTP(S) on ports 80 and 443 is reachable from the internet, through Traefik. To publish an app, give it an Ingress with a `host` (in `charts/app`: `ingress: {}` and a hostname under `hosts`) and point that hostname's DNS at the cluster.

Requests by bare IP get Traefik's `404 page not found`. That's expected: no Ingress matches them.

### LAN-only services

Some hosts resolve to the node's LAN IP (`network.nodeIp`) instead of the public one. DNS alone doesn't protect them: Traefik routes by `Host` header, so anyone who sends that header to the public IP reaches the service. Every LAN-only Ingress therefore attaches the namespace's `lan-only` Traefik middleware (`ipAllowList` for `network.lanCidr`), e.g. `traefik.ingress.kubernetes.io/router.middlewares: home-lan-only@kubernetescrd`; `charts/app` does it for `ingress: {lanOnly: true}`. This works because Traefik's Service uses `externalTrafficPolicy: Local` (`infrastructure/base/chart`), which keeps the real client IP. Requests made from the node itself still show up with an internal IP and get 403, so test from another device.

## Restore

1. Install the same k3s version:
   ```sh
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.36.5+k3s1 sh -
   ```
2. Install the Helm CLI (v4), helmfile with the helm-diff plugin ([Apply](#apply)), and an NFS client (`apt install nfs-common`), which kubelet needs to mount the NAS.
   With ufw (default deny incoming), allow the pod and service networks, which k3s needs anyway and which also covers Traefik reaching Home Assistant on the host network. Then allow HomeKit and mDNS from the LAN (`network.lanCidr`):
   ```sh
   ufw allow from 10.42.0.0/16 comment 'k3s pods'
   ufw allow from 10.43.0.0/16 comment 'k3s services'
   ufw allow from <lanCidr> to any port 21064:21065 proto tcp comment 'HomeKit Bridges'
   ufw allow from <lanCidr> to any port 5353 proto udp comment 'mDNS'
   ```
   Leave unallocated space in an LVM volume group (`lvm.volumeGroup`) for the size-capped volumes, at least 100 GiB plus 5 GiB per Postgres cluster and 30 GiB per ClickHouse server with the sizes in this repo (see [Storage](#storage)). Ubuntu's installer does that by default: it gives the root logical volume only part of the disk.
3. Optional: give your user the kubeconfig so helmfile and the scripts don't need sudo:
   ```sh
   mkdir -p ~/.kube && sudo install -m 600 -o "$USER" -g "$USER" /etc/rancher/k3s/k3s.yaml ~/.kube/config
   ```
4. Put back the site directory (clone the private repo and set `CAIRN_SITE`, or copy the files into the repo root). Without it, `scripts/configure.py` writes `site.yaml`, and `scripts/secret.py set gandi.pat`, `scripts/secret.py set discord.webhookUrl` and `scripts/secret.py fill` (the apps') write `site.secret.yaml` ([Secrets](#secrets)). Run `configure.py` as well if the site changed (new IPs, NAS, Zigbee stick...).
5. `helmfile apply`
6. For each app, and `monitoring` (Grafana): `scripts/restore.sh <name> <YYYY-MM-DD>` ([Backups](#backups)).
7. `scripts/check.py`, and `scripts/check.py --test-alert` to see alerts reach Discord.

## TLS

cert-manager issues Let's Encrypt certificates through the ClusterIssuers in `infrastructure/base/chart` (`issuers` in its `values.yaml`: `letsencrypt-staging` and `letsencrypt-prod`). Every Ingress, public or LAN-only, gets its own certificate: the annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` and a `tls:` section with the host and a `secretName`.

How each domain is validated is set per DNS zone in `site.yaml`, by solver name (`solvers` in `infrastructure/base/chart/values.yaml`):

```yaml
acme:
  zones:
    example.com: gandi      # DNS-01 through the Gandi API; allows wildcards
  defaultSolver: http01     # every other zone: HTTP-01 on port 80
```

- `gandi`: DNS-01 via `cert-manager-webhook-gandi`, authenticated with a Gandi Personal Access Token (`site.secret.yaml`). Works for any hostname in the zone, LAN-only ones included. The webhook is installed only while a zone uses it.
- `http01`: for zones whose DNS has no API (e.g. a domain registered at Wix). The hostname must already resolve to this node, and port 80 must reach Traefik. Let's Encrypt follows Traefik's HTTP-to-HTTPS redirect, and the challenge is answered over HTTPS.

A domain on another DNS provider with an API needs a new entry under `solvers` (any cert-manager ACME solver) and its zone mapped to it in `site.yaml`; the templates don't change.

The PAT expires. Before it does, create a new one in Gandi (permission "Manage domain name technical configurations", scoped to your domains), then:

```sh
scripts/secret.py set gandi.pat        # checks it can manage every zone that uses gandi, then writes it
helmfile apply -l name=cluster         # updates the Secret
scripts/check.py                       # certificates still Ready
```

**A DNS-01 challenge stuck on "not yet propagated".** cert-manager checks the challenge's TXT record through public resolvers (1.1.1.1 and 8.8.8.8, see `infrastructure/base/cert-manager.yaml`) and needs all of them to see it. If one asked before Gandi had published the record, it caches the "doesn't exist" answer for the zone's negative TTL, about 3 hours. Compare what the resolvers return for `_acme-challenge.<hostname>` (TXT) with Gandi's own nameservers. Then either wait, or purge the stale answer: https://one.one.one.one/purge-cache/ for 1.1.1.1, https://dns.google/cache for 8.8.8.8. Renewals start 30 days before expiry, so a few hours' delay there doesn't matter.

## Backups

Every app or component with a `backup`, and every app with a database or ClickHouse, gets a CronJob `backup` in its namespace (`charts/backup`). Every night at 04:00 it writes to the NAS export `backup.path` (`site.yaml`), under `<name>/YYYY-MM-DD/`:

- `<pvc>.tar.gz` for each volume under `backup.volumes`
- `database.dump`, `pg_dump` in custom format, if it has a database
- `clickhouse-full/` or `clickhouse-diff/`, if it has ClickHouse: the server's own `BACKUP` of its database, in full on Sundays (and the first night), and on the other nights only the parts that changed since that full one. A part rewritten by a merge counts as changed, so a night's increment can reach the size of the current month's partitions.

It keeps 14 days (`keepDays`; `schedule` sets the time), and with ClickHouse, the full backup the oldest kept nights build on: about three full ones at a time. A failed backup shows up in Discord as `KubeJobFailed`, and in `scripts/check.py`. What's in them:

- aetherium: market-tap's quotes (ClickHouse) and task log (Postgres); not its working directory, which only holds a day's quotes until they're uploaded, nor the monthly archive, which is on the NAS already
- home: Zigbee2MQTT's data (the network key and paired devices, so restoring it avoids re-pairing everything) and Home Assistant's `.storage` (users, areas, integrations, groups, HomeKit) and automations, but not the history database
- immich: Immich's own nightly database dumps, uploads from the apps and user files; not the thumbnails and encoded videos, which Immich rebuilds from the originals, nor the library, which is on the NAS already
- monitoring: Grafana's database (users, preferences, dashboards made in the UI)
- each app with a database, including entries that are only a database: its dump

Back up now: `kubectl -n <namespace> create job --from=cronjob/backup backup-manual-$(date +%s)`.

Restore a day with `scripts/restore.sh <name> <YYYY-MM-DD>`. It lists what it will restore and the workloads it will stop (those mounting the volumes, and with a database or ClickHouse, those using its credentials), and asks first. Then it stops them, restores the database in one transaction (if anything fails, it stays as it was), replaces the ClickHouse database with that night's backup (an increment brings in its full backup by itself; this one isn't a transaction: if it fails, run it again), unpacks the archives over the volumes, and starts them again.

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

## Aetherium

`apps/aetherium` runs market-tap (from the Aetherium-Trader repos), which collects Taiwan stock and futures quotes:

- `amt-server` takes the stocks from SinoTrade's web feed. It schedules everything itself, in Taiwan time and on trading days only: at 08:00 it starts a Job that signs in with the account and TWCA certificate from `site.secret.yaml`, then collects the stocks' order books over the day session and their trades after it, and hands them to amt-collector (`market_quotes` and `market_trades`, source `moneydj`): the books as they're written, every 10 seconds, the trades from the post-market replay. Its files stay on its volume until the collector's counts match them. Once a month moves the partitions older than a year to Parquet files on the NAS (`apps.aetherium.archivePath`). From the same feed it keeps the futures' intraday open interest, day and night sessions, which no API has (`futures_oi`, uploaded to ClickHouse itself at 06:00).
- `amt-futures` takes the futures (TX, MX, TMF) from SinoPac's Shioaji API, with an API key: always running, it subscribes before each session, hands their trades and order books to amt-collector (`market_trades`, `market_quotes`, asset `futures`, source `sinopac`), and after the day session writes the day's complete trades from Shioaji's history, which the views prefer to the stream. Until market-tap's P2 it wrote tables of its own, `tick_fut_sj` and `book_fut_sj`, copied over then.
- `amt-collector` is the one writer of `market_trades` and `market_quotes`, every source's trades and books in one shape, which the sources move to one at a time (market-tap's `docs/collector-design.md`). A source hands it its quotes over gRPC: a stream, acknowledged once it's in a write-ahead log on the collector's volume, or a day's complete data, which replaces what's there.
- `amt-stock-trades` takes the stocks' trades from Fubon's Neo API, with an API key and certificate. A CronJob, it runs three passes after each trading day's session (14:40, 17:40, 20:40) and hands the day's trades of every common stock to amt-collector (`market_trades`, source `fubon`); each pass finishes what the earlier left. The web feed keeps collecting them too until the two are compared (market-tap's `docs/stock-tick-api-eval.md`).
- `amt-sinopac-stock-trades` takes the same trades from Shioaji's history, with amt-futures' API key, to compare with Fubon's (which misses some trades shortly after the open). A CronJob, it runs two passes the morning after each trading day (05:10 and 06:10, once the futures' night session is over: Shioaji allows only 10 history queries during a session) and hands every common stock's trades of the last three trading days that aren't written yet to amt-collector (source `sinopac`). It stops before 08:00, and before the account's daily query quota gets near the floor amt-futures keeps.

Until the cutover of 2026-10-23 the web feed collected the futures' books and trades too; those are in `tick_futures_mdj` and `orderbook_futures_mdj`. The old names, `tick_futures` and `orderbook_futures`, are views across both sources in the old shape (MoneyDJ's symbols, prices × 100), so the consumers didn't change. Two CronJobs read them every morning: `kbar-tick-agg` (06:40, 1-minute bars from the futures trades) and `replay-segments` (06:50, the sessions complete enough to replay, in Postgres). Design and the parallel run before the cutover: market-tap's `docs/futures-api-design.md`. The stocks' tables went the same way at market-tap's P3: what amt-server uploaded itself is in `orderbook_mdj` and `tick_data_mdj`, and `orderbook` and `tick_data` are views across them and the new tables, in the old shape. The quotes live in the namespace's [ClickHouse](#clickhouse), the task log in its [Postgres](#postgres) (schema `amt`).

A day not collected is lost for good, so `AmtOrderbookSilent` (collecting but no push received for 10 minutes) and `AmtFuturesSilent` (a contract's book quiet for 5 minutes in a session) are critical alerts, as are `amt-collector`'s for data it holds but can't write, and `AmtStockTradesFailed` (Fubon serves the latest day's trades only); the rest of the `amt`, `amt-futures` and `amt-collector` groups are warnings, and so is `AmtSinopacStockTradesFailed` (Shioaji keeps the history, and the next passes take the last days again).

**Install.** The certificates go in from their files: TWCA's is a JSON file (market-tap's `export-twca` writes it, private key included), Fubon's a .pfx, so in base64:

```sh
scripts/secret.py set apps.aetherium.twcaLocalStorage < twca-local-storage.json
base64 < <cert>.pfx | scripts/secret.py set apps.aetherium.fubon.cert
scripts/secret.py fill aetherium          # ghcr.token, the SinoTrade account and password, the Shioaji API key pair, Fubon's ID, API key and certificate password
helmfile apply -l app=aetherium           # ClickHouse, Postgres, market-tap, the backup
```

Fubon's certificate is valid for a year: before it expires, set `fubon.cert` and `fubon.certPassword` again and apply.

After every install and upgrade, the Job `clickhouse-schema` creates what's missing of the tables and views in `apps/aetherium/chart/files/clickhouse/` (a table that exists is left alone; changing one is an `ALTER` by hand). The views are redefined each time. `orderbook_mdj` and `tick_data_mdj` were rebuilt from market-tap's upload code, which had no DDL for them. `tick_fut_sj` and `book_fut_sj` are amt-futures' tables before P2, kept until it's clear nothing reads them. `market_trades` and `market_quotes` are copies of market-tap's `schema/market.sql`; amt-collector doesn't create them, it checks their columns when it starts.

**Images.** All are built from market-tap's repo and pushed by hand; the node is linux/amd64:

```sh
docker buildx build --platform linux/amd64 --target login -t ghcr.io/jubeatwww/amt-login:latest --push .
```

The login Job pulls its image each morning. The others have a version tag, so a restart never picks up a new build: build the root's `core` target as `ghcr.io/jubeatwww/amt:<version>` (`--target core`), `providers/` as `ghcr.io/jubeatwww/amt-providers:<version>` (amt-futures, amt-stock-trades and amt-sinopac-stock-trades) or `collector/` as `ghcr.io/jubeatwww/amt-collector:<version>` (`-f <dir>/Dockerfile`, from the repo's root), then set `images.amt`, `images.amtProviders` or `images.amtCollector` in the chart's `values.yaml` and apply.

**Trading calendar.** ConfigMap `amt-trading-calendar` lists the weekdays the market is closed, one `YYYY-MM-DD` per line. It's written from `holidays` in the chart's `values.yaml` on the first install only; after that it's edited in the cluster, and helmfile keeps it as it is: `kubectl -n aetherium edit configmap amt-trading-calendar`. Add a typhoon day the morning it's announced, and next year's closures when TWSE publishes them (https://openapi.twse.com.tw/v1/holidaySchedule/holidaySchedule, usually in December).

## Postgres

`infrastructure/postgres` runs the CloudNativePG operator. Every app with a `database` gets its own Postgres cluster in its namespace (`charts/postgres-cluster`, release `postgres`): one instance, on a 5 GiB `lvm` volume. Separate clusters keep projects apart: each one restarts, upgrades and restores on its own, and one project's load can't fill another's disk. An entry can be just a database, for an app that doesn't run in this cluster (yet).

In each of those namespaces:

- `postgres-rw:5432` serves the database `app`, owned by the user `app`.
- Secret `postgres-app` holds the credentials, generated on first start: `username`, `password`, `dbname`, `host`, `port`, and a ready-made `uri`. `charts/app` hands them to a workload with `database: true`; another chart can read them itself, e.g.
  ```yaml
  env:
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef: {name: postgres-app, key: uri}
  ```
- A NetworkPolicy lets in only that namespace's pods, plus the operator and Prometheus. Apps in other namespaces can't connect even with the password. A new pod's connections are refused for its first few seconds, until k3s adds it to the policy, so apps should retry the database on startup.

`database` takes `size` to grow it online (`notes: {database: {size: 20Gi}}`) and `image` to pin its version. Removing it only stops helmfile from managing that cluster, and even `helm uninstall` leaves the Cluster and its data in place. Deleting it takes `kubectl -n <namespace> delete cluster postgres`, which removes the data too. Each database is dumped nightly with its app's [backup](#backups).

**Upgrades.** For a new minor version, change `image` in `charts/postgres-cluster/values.yaml` and run `helmfile apply`; CloudNativePG restarts each instance on it. A new major version works the same way, but CloudNativePG then stops the instance and upgrades the data in place with `pg_upgrade`, which takes a few minutes. Try it on one cluster first (`database.image` in its entry, e.g. the uat one), right after a backup, and run `ANALYZE` afterwards, since `pg_upgrade` doesn't carry over the planner statistics.

Grafana has CloudNativePG's dashboard, and Prometheus scrapes every instance.

## ClickHouse

`infrastructure/clickhouse` runs Altinity's ClickHouse operator in namespace `clickhouse-system`. Every app with `clickhouse` gets its own server in its namespace (`charts/clickhouse`, release `clickhouse`): a ClickHouseInstallation `clickhouse` with one replica and no Keeper, on a 30 GiB `lvm` volume. Like the Postgres clusters, separate servers keep projects apart.

In each of those namespaces:

- `clickhouse:8123` (HTTP) and `clickhouse:9000` (native) serve the database `app` to the user `app`. The image creates the database on the server's first start.
- Secret `clickhouse-app` holds the credentials: `username`, `password` (generated on the first install, then kept), `database`, `host`, `port` (HTTP) and `url`.
- A NetworkPolicy lets in only that namespace's pods, plus the operator, which signs in as `clickhouse_operator` from its own pod's IP only.

`clickhouse` takes `size` to grow the volume and `image` to pin the version. Removing it only stops helmfile from managing the server; `helm uninstall` leaves it running, and deleting it (`kubectl -n <namespace> delete chi clickhouse`) still leaves its volume (`reclaimPolicy: Retain`). It's backed up nightly with its app's [backup](#backups): the server writes the backup itself, to `<backup.path>/<app>/` on the NAS, which it mounts at `/backups`. Like every pod that mounts the NAS, it can't start while the NAS is unreachable, and does once it's back.

**Upgrades.** Change `image` in `charts/clickhouse/values.yaml` (an LTS release, `YY.3` or `YY.8`) and run `helmfile apply`; the operator restarts the server on it. Read ClickHouse's changelog for backward-incompatible changes first, and try it on one app (`clickhouse.image` in its entry) right after a backup.

## Monitoring

`infrastructure/monitoring` runs everything in namespace `monitoring`:

- kube-prometheus-stack: Prometheus (15 days, at most 18 GB, on a 20 GiB volume), Alertmanager, Grafana, node-exporter and kube-state-metrics. Scrapes of etcd, the scheduler, the controller-manager and kube-proxy are off: k3s runs them inside its own process without exposing their metrics. Prometheus picks up ServiceMonitors, PodMonitors and rules from every namespace.
- Loki: a single binary on a 10 GiB volume, keeping 14 days of logs. It takes at most 100 KB/s, so a pod stuck in a log loop can't fill the volume quickly.
- Alloy: ships every pod's logs to Loki through the Kubernetes API.
- `chart/`: Grafana's LAN-only Ingress at `grafana.hostname` from `site.yaml`, and the Discord webhook's Secret.

**What Prometheus keeps.** Of the cluster's own metrics, only what the chart's rules and dashboards read: about 18k series instead of 113k. k3s serves every component's metrics at both the apiserver and the kubelet endpoint, so each of those jobs keeps only its own, and Grafana's, cAdvisor's and kube-state-metrics' unused families are dropped (`metricRelabelings` in `kube-prometheus-stack.yaml`). A chart upgrade can bring rules or dashboards that read a dropped metric: `scripts/check.py` names them. Helm installs the chart's CRDs only on the first install, so after bumping its version, apply the new CRDs first, as its upgrade notes describe.

**Grafana** comes with Prometheus, Alertmanager and Loki as data sources, and the usual Kubernetes and node dashboards. Log in as `admin`; the password is generated on first install:

```sh
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

Change it with `scripts/set-grafana-password.sh`, not in Grafana's UI: the sidecars that make Grafana reload dashboards and data sources log in with the Secret's copy, and the script sets both. After a rebuild, `scripts/restore.sh monitoring <YYYY-MM-DD>` brings back Grafana's database with your password, while the Secret holds a newly generated one: run the script once more so both match.

**Alerts** go to a Discord channel: every alert from kube-prometheus-stack's default rules (a volume filling up, a pod crash-looping, a node running out of memory...), grouped by namespace, again every 12 hours while it keeps firing, and once more when it resolves. Watchdog, which always fires to prove the pipeline works, is not sent. The routing is in `infrastructure/monitoring/kube-prometheus-stack.yaml` (`alertmanager.config`). To set up or switch the channel, copy its webhook URL (channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL), then:

```sh
scripts/secret.py set discord.webhookUrl          # checks it with Discord, then writes it
helmfile apply -l component=monitoring            # the Secret; Alertmanager reloads it
scripts/check.py --test-alert                     # [FIRING] in ~30 s, [RESOLVED] in 5-7 min
```

## Storage

Two StorageClasses, both on the node's disk:

- `lvm` (`infrastructure/base/chart`, provisioned by OpenEBS LVM LocalPV): each volume is an LVM logical volume of exactly its requested size, in the volume group `lvm.volumeGroup` from `site.yaml`. The size is a hard cap: past it, writes fail with "no space left" and the root filesystem isn't touched. Like `local-path`, a volume can be mounted by more than one pod on the node (`shared`), so the nightly backup reads it while its app runs. For volumes that keep growing: Prometheus (20 GiB), Loki (10 GiB), Immich's data (40 GiB), its Postgres (10 GiB) and model cache (10 GiB), market-tap's working directory (10 GiB), each Postgres cluster (5 GiB by default) and ClickHouse server (30 GiB by default).
- `local-path` (k3s's default): a directory on the root filesystem. The requested size is neither enforced nor reserved. For the volumes that stay small: Home Assistant, Zigbee2MQTT, Grafana. Mounting them needs nothing but the node, so the home automation starts even when the LVM driver doesn't.

A PVC's class can't change in place: moving a volume to another class means a new PVC and copying the data. The `lvm` volumes can only use the volume group's unallocated space, and grow online, without restarting anything:

- Immich: raise `storage.<volume>.size` (in `apps/immich/chart/values.yaml`, or under `apps.immich` in `site.yaml`) and run `helmfile apply`.
- Prometheus, Loki: a StatefulSet doesn't resize the PVCs it already made, so patch the PVC, e.g. `kubectl -n monitoring patch pvc storage-loki-0 -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'`. Then raise the size in `infrastructure/monitoring/<release>.yaml` too, so a rebuild gets the same. Loki's upgrade fails on that change (a StatefulSet can't change its volume template), so first delete the StatefulSet alone: `kubectl -n monitoring delete statefulset loki --cascade=orphan` (the pod keeps running), then run `helmfile apply -l name=loki`. Prometheus's operator recreates its StatefulSet by itself (Prometheus restarts).

When the volume group runs out, it needs more space from the host: a new disk added to the group, or a smaller root logical volume. Shrinking root has to happen offline (ext4 can grow while mounted but not shrink), e.g. from a live USB: `e2fsck -f`, then `lvreduce --resizefs`. Back up first.

## Secrets

Kubernetes Secrets are base64, not encryption. **Plaintext secrets are never committed.**

- Secret values go in `site.secret.yaml` in the site directory; in the repo root it's gitignored (`*.secret.yaml`). `site.secret.example.yaml` lists the keys with placeholder values.
- `scripts/secret.py set <key>` writes one key and keeps the others, asking for the value without echoing it. It checks the Gandi PAT and the Discord webhook with their services before writing them.
- `scripts/secret.py fill` writes what the apps declare under `secrets` in their `app.yaml` and is still missing: it makes up the ones marked `generate` and asks for the rest. Run it again any time; it leaves set values alone.
- Any value can instead be a reference that helmfile resolves when it renders ([vals](https://github.com/helmfile/vals), built into helmfile): `ref+sops://secrets.enc.yaml#/gandi/pat` (a SOPS-encrypted file, key from `SOPS_AGE_KEY_FILE`), `ref+op://<vault>/<item>/<field>` (1Password), `ref+envsubst://$VAR`, and more. A file path in a reference is relative to where you run helmfile.
- The cluster chart gets the Gandi PAT and the monitoring chart the Discord webhook; each app gets only its own section, `apps.<name>` (`charts/app` turns its `secrets` into a Secret). Templates put secrets only in Secrets, which `helmfile diff` masks. Helm also keeps a copy in each release record, a Secret in the release's namespace.
