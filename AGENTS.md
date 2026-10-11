# AGENTS.md

Working notes for agents. Read [README.md](README.md) first: "Design" says why the repo is shaped the way it is, "Components and apps" what each file holds. This file adds the rules for changing it.

## Hard rules

- **Expose HTTP apps through an Ingress** (`ingressClassName: traefik`). Only ports 80 and 443 are reachable from the internet, so a NodePort or LoadBalancer Service on any other port won't be reachable from outside.
- **Ports 80 and 443 are already taken by Traefik's ServiceLB pods.** Another LoadBalancer Service on either port can't schedule its svclb pods (hostPort conflict) and its `EXTERNAL-IP` stays `<pending>`.
- **Every Ingress needs a `host`.** Requests by bare IP get Traefik's 404, which is expected.
- **Host-level config is out of scope.** Don't touch node networking, the firewall, k3s install flags, or anything outside the cluster. If a change needs one of those, tell the user instead.
- **No hardcoded values in templates.** Site-specific ones (domains, hostnames, IPs, CIDRs, NAS paths, device paths, emails, timezones) come from `site.yaml`; the rest (versions, issuer names, schedules, sizes, solver and Traefik settings) from the chart's `values.yaml`, each with a comment. Templates only assemble them.
- **The repo is public; the home network's layout isn't.** Nothing committed (templates, comments, README examples, script messages) may contain a value from the site directory: use placeholders like `example.com`, `192.168.0.0/24` or `<lanCidr>`. The pre-commit hook blocks staged changes that do; never get around it with `--no-verify`. The owner's own projects may have app directories under their names; a client's project stays out (its entry, with its chart from elsewhere, lives only in `site.yaml`), since its public domain would tie this repo to the home network.
- **Never commit plaintext secrets**, and keep them out of plain objects (see Secrets).

## Where things go

- Classify a new piece by who uses it: what apps build on (an operator, ingress, storage, monitoring) is a component in `infrastructure/`; what people use is an app in `apps/`; a chart both need is a building block in `charts/`.
- Adding a component or an app never edits `helmfile.yaml.gotmpl`, `scripts/` or another component. If it seems to need that, the data model is missing a field: add the field, generally, rather than a special case.
- A new app uses the template `charts/app` (`apps/<app>/values.yaml`) unless it needs something the template can't express even with `extraObjects`; then it gets `apps/<app>/chart/`. Grow the template when two apps need the same thing, not for one.
- A third-party chart keeps its values in `infrastructure/<component>/<release>.yaml`, site-free, at an exact `version`. Objects that need site values (an Ingress, a Middleware, a Secret) go in the component's `chart/`.
- A new site setting goes in two places: its declaration under `site` in the `component.yaml` or `app.yaml` that reads it, and the template, as `required "<key> is required (site.yaml)"`. Shared settings (certificates, timezone, network, NAS, backup, LVM) are the only ones `scripts/configure.py` asks itself. Then run `scripts/configure.py` (with all defaults it must report no changes) and `scripts/configure.py --example`; never edit `site.example.yaml` by hand.
- An app's chart reads its settings from the root of `.Values` (`.Values.hostname`, not a section named after the app), and says `apps.<release>.<key>` in its `required` messages. A template that needs another component's CRDs (a PodMonitor needs `monitoring`) renders only when `.Values.infrastructure.<name>` is true.
- Data that can't be rebuilt goes under `backup` in the `app.yaml` or `component.yaml` (its PVCs, with `exclude` or `paths` to leave out caches and what's on the NAS already). Never write a backup CronJob into a chart.
- `scripts/` has one job per script. Extend them rather than adding a setup script per feature: a new secret's check goes in `secret.py`'s `CHECKS`, a new health check in `check.py`, a new offline check in `precommit.py`. Scripts are idempotent, source `scripts/lib.sh` (before any `cd`) for `$REPO`, `$SITE` and the kubeconfig, and render a release through `helmfile template -l name=<release>,namespace=<ns>` so it matches `helmfile apply`. A cluster command run through `sudo` passes `CAIRN_SITE=$SITE` along, since sudo drops the environment.

## Charts

- `templates/<part>/`: one directory per part of the app, one resource per file, e.g. `deployment.yaml`, `service.yaml`, `ingress.yaml`.
- Hostnames come from `site.yaml` in full (`ha.example.com`), not built from a domain: apps can live in different DNS zones.
- Certificates: Ingresses use the annotation `cert-manager.io/cluster-issuer: {{ .Values.certIssuer }}`. Which solver validates a hostname is decided by `acme.zones` in `site.yaml`, never in the Ingress.
- Namespaced resources set `metadata.namespace` explicitly: `{{ .Release.Namespace }}`, or a literal namespace for objects that live elsewhere (e.g. `kube-system`).
- Keep resource names and selectors stable. Helm owns objects by name, and a Deployment's selector can't change in place.
- PVCs carry `helm.sh/resource-policy: keep`, so uninstalling a release never deletes data.
- PVCs that keep growing (metrics, logs, thumbnails, databases) use the StorageClass `lvm`, which caps them at their size; small ones use `local-path`. Set the class and size in the chart's `values.yaml`. A PVC's class can't change in place.
- An `lvm` volume is a fresh ext4 filesystem with `lost+found` at its root. Apps that want an empty directory (Postgres's `PGDATA`) get a subdirectory of the mount.
- Use helmfile and the helm CLI (v4). Don't use k3s's `HelmChart` resource.

## Secrets

- Secret values go in `site.secret.yaml` in the site directory and are never committed here. A value may be a vals reference (`ref+sops://...`, `ref+op://...`), resolved by helmfile; charts never see the difference.
- Templates put secret values only in `kind: Secret` objects, never in a ConfigMap, an env `value` or an annotation: `helmfile diff` masks Secrets only.
- An app gets only its own section of `site.secret.yaml` (`apps.<name>`), never the whole file: Helm stores every release's values.
- Keep `site.secret.example.yaml` in sync: the real keys with placeholder values, so it's clear what to fill in.

## Validate and apply

- The k3s kubeconfig is root-only. On the node, the user may have copied it to `~/.kube/config`; if it exists, agents use `KUBECONFIG=~/.kube/config` to inspect the cluster. Applying or deleting anything still needs the user's OK first.
- Before applying, check offline: `scripts/precommit.py` lints and renders every local chart with the examples (what the hook runs), and `helmfile template -l name=<release>` renders one with the real site directory.
- Then see what would change in the cluster, and apply:
  ```sh
  helmfile diff --suppress-secrets
  helmfile apply
  ```
  `-l name=<release>`, `-l app=<name>` or `-l component=<name>` limits either. A refactor that shouldn't change the cluster must show no diff beyond comments.
- After applying, `scripts/check.py` confirms certificates, backups, targets, rules, alerts and the metrics the rules read.
