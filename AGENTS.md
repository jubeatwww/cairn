# AGENTS.md

Working notes for agents. Read [README.md](README.md) first for the cluster spec.

## Hard rules

- **Expose HTTP apps through an Ingress** (`ingressClassName: traefik`). Only ports 80 and 443 are reachable from the internet, so a NodePort or LoadBalancer Service on any other port won't be reachable from outside.
- **Ports 80 and 443 are already taken by Traefik's ServiceLB pods.** Another LoadBalancer Service on either port can't schedule its svclb pods (hostPort conflict) and its `EXTERNAL-IP` stays `<pending>`.
- **Every Ingress needs a `host`.** Requests by bare IP get Traefik's 404, which is expected.
- **Host-level config is out of scope.** Don't touch node networking, the firewall, k3s install flags, or anything outside the cluster. If a change needs one of those, tell the user instead.
- **Never commit plaintext secrets** (see below).
- **No hardcoded values in templates.** Site-specific ones (domains, hostnames, IPs, CIDRs, NAS paths, device paths, emails, timezones) go in `site.yaml`; the rest (versions, issuer names, schedules, sizes, solver and Traefik settings) in the chart's `values.yaml`. Templates only assemble them.
- **The repo is public; the home network's layout isn't.** `site.yaml` lives in the site directory: gitignored in the repo root, or outside the repo through `$CAIRN_SITE`. Nothing committed (templates, comments, README examples, script messages) may contain real values from it: use placeholders like `example.com`, `192.168.0.0/24` or `<lanCidr>`. The owner's own projects may have app directories under their names; a client's project stays out (its entry, with its chart from elsewhere, lives only in `site.yaml`), since its public domain would tie this repo to the home network.

## Conventions

- Layout (README "Layout"): `infrastructure/<component>/` for shared services, `apps/<app>/` for apps, `charts/` for charts they share, `helmfile.yaml.gotmpl` for the releases. Classify a new piece by who uses it: something apps build on (an operator, ingress, storage, monitoring) is a component; something people use is an app.
- `helmfile.yaml.gotmpl` builds every release from data: `infrastructure/<name>/component.yaml` (`releases`, `repositories`, `site`), `apps/<app>/app.yaml` (`description`, `timeout`, `needs`, `database`, `site`) and the site's `site.yaml`. Adding a component or an app doesn't touch it. A third-party release has an exact chart `version`, its values in `infrastructure/<component>/<release>.yaml`.
  - Use helmfile and the helm CLI (v4). Don't use k3s's `HelmChart` resource.
- Site directory: `site.yaml`, `site.secret.yaml` and the optional overrides `values/<release>.yaml`, in `$CAIRN_SITE` or else the repo root. Scripts source `scripts/lib.sh` (before any `cd`) for `$SITE` and `site_values`, never a path built from the repo root.
- `site.yaml`: every site-specific value, each with a comment saying what it's for. `scripts/configure.py` generates it from questions, and `site.example.yaml` with `--example`; never edit `site.example.yaml` by hand. A new setting goes in two places: a declaration under `site` in the `component.yaml` or `app.yaml` that reads it (comment, question, example, validator; fields in `apps/home/app.yaml`), and the chart template, referenced with `required "<key> is required (site.yaml)"` so a missing value fails the render with a clear message. Then run `scripts/configure.py` (with all defaults it must report no changes) and `scripts/configure.py --example`. Only shared settings (certificates, timezone, network, NAS, LVM) are asked in `configure.py` itself.
- `infrastructure` in `site.yaml`: one true/false per optional component. The base has no flag; the Gandi webhook follows `acme.zones` (`when: gandiSolver`). A template that needs another component's CRDs (a PodMonitor needs `monitoring`) renders only when `.Values.infrastructure.<name>` is true.
- `apps` in `site.yaml`: one entry per app, release and namespace named after the entry. Its keys are the app's settings, merged at the root of its chart's values: app charts read `.Values.hostname`, not a section named after the app, and say `apps.<release>.<key>` in their `required` messages. `database` adds a `charts/postgres-cluster` release `postgres` in the same namespace. An entry can name a chart from elsewhere (`chart`, `version`, `values`); helmfile refuses an `oci://` or `git::` source that isn't pinned.
- A new app uses the template `charts/app` (`apps/<app>/values.yaml`) unless it needs something the template can't express even with `extraObjects`; then it gets `apps/<app>/chart/`. Grow the template when two apps need the same thing, not for one.
- `values/<release>.yaml`: a site's override of a component release's chart defaults, passed after everything else. A script that renders a release on its own uses `helmfile template -l name=<release>,namespace=<ns>`, so it matches `helmfile apply`.
- Charts (`infrastructure/*/chart/`, `apps/*/chart/`, `charts/*/`) are rendered with `site.yaml`.
  - When a third-party chart needs site values (a hostname, a CIDR), keep its `<release>.yaml` site-free and put the site-dependent objects (Ingress, Middleware, Secret) in the component's `chart/` instead.
  - `templates/<part>/`: one directory per part of the app, one resource per file, e.g. `deployment.yaml`, `service.yaml`, `ingress.yaml`.
  - Chart defaults that don't depend on the site go in the chart's `values.yaml`, each with a comment: image versions, `certIssuer`, backup schedule and retention, PVC sizes, ACME `issuers` and `solvers`, Traefik settings.
  - Hostnames come from `site.yaml` in full (`ha.example.com`), not built from a domain: apps can live in different DNS zones.
  - Certificates: Ingresses use the annotation `cert-manager.io/cluster-issuer: {{ .Values.certIssuer }}`. Which solver validates a hostname is decided by `acme.zones` in `site.yaml`, never in the Ingress.
  - Namespaced resources set `metadata.namespace` explicitly: `{{ .Release.Namespace }}`, or a literal namespace for objects that live elsewhere (e.g. `kube-system`).
  - Keep resource names and selectors stable. Helm owns objects by name, and a Deployment's selector can't change in place.
  - PVCs carry `helm.sh/resource-policy: keep`, so uninstalling a release never deletes data.
  - Data that can't be rebuilt goes under `backup` in the `app.yaml` or `component.yaml` (its PVCs, with `exclude` or `paths` to leave out caches and what's on the NAS already); `charts/backup` puts it on the NAS nightly and `scripts/restore.sh` brings it back. A database is always included. Don't write a backup CronJob into a chart.
  - PVCs that keep growing (metrics, logs, thumbnails, databases) use the StorageClass `lvm`, which caps them at their size; small ones use `local-path`. Set the class and size in the chart's `values.yaml`. A PVC's class can't change in place (README "Storage").
  - An `lvm` volume is a fresh ext4 filesystem with `lost+found` at its root. Apps that want an empty directory (Postgres's `PGDATA`) get a subdirectory of the mount.
- `scripts/`: helpers the user runs by hand. Idempotent; read site values from the site directory's `site.yaml` (or take them as arguments that default to it); find the repo root and the site directory through `scripts/lib.sh`. A cluster command run through `sudo` passes `CAIRN_SITE=$SITE` along, since sudo drops the environment.

## Secrets

- Secret values go in `site.secret.yaml` in the site directory (gitignored in the repo root via `*.secret.yaml`) and are never committed here. A value may be a vals reference (`ref+sops://...`, `ref+op://...`), resolved by helmfile; charts never see the difference.
- Templates put secret values only in `kind: Secret` objects, never in a ConfigMap, an env `value` or an annotation: `helmfile diff` masks Secrets only.
- An app gets only its own section of `site.secret.yaml` (`apps.<name>`), never the whole file: Helm stores every release's values.
- Keep `site.secret.example.yaml` in sync: the real keys with placeholder values, so it's clear what to fill in.

## Validate and apply

- The k3s kubeconfig is root-only. On the node, the user may have copied it to `~/.kube/config`; if it exists, agents use `KUBECONFIG=~/.kube/config` to inspect the cluster. Applying or deleting anything still needs the user's OK first.
- Before applying, check the charts. Rendering and linting need no cluster access:
  ```sh
  helmfile lint -l name=home
  helmfile template -l name=home
  ```
- See what would change in the cluster (`helmfile diff` needs the helm-diff plugin), then apply:
  ```sh
  helmfile diff
  helmfile apply
  ```
  `-l name=<release>` limits either to one release.
