# AGENTS.md

Working notes for agents. Read [README.md](README.md) first for the cluster spec.

## Hard rules

- **Expose HTTP apps through an Ingress** (`ingressClassName: traefik`). Only ports 80 and 443 are reachable from the internet, so a NodePort or LoadBalancer Service on any other port won't be reachable from outside.
- **Ports 80 and 443 are already taken by Traefik's ServiceLB pods.** Another LoadBalancer Service on either port can't schedule its svclb pods (hostPort conflict) and its `EXTERNAL-IP` stays `<pending>`.
- **Every Ingress needs a `host`.** Requests by bare IP get Traefik's 404, which is expected.
- **Host-level config is out of scope.** Don't touch node networking, the firewall, k3s install flags, or anything outside the cluster. If a change needs one of those, tell the user instead.
- **Never commit plaintext secrets** (see below).
- **No hardcoded values in templates.** Site-specific ones (domains, hostnames, IPs, CIDRs, NAS paths, device paths, emails, timezones) go in `site.yaml`; the rest (versions, issuer names, schedules, sizes, solver and Traefik settings) in the chart's `values.yaml`. Templates only assemble them.
- **The repo is public; the home network's layout isn't.** `site.yaml` is gitignored. Nothing committed (templates, comments, README examples, script messages) may contain real values from it: use placeholders like `example.com`, `192.168.0.0/24` or `<lanCidr>`.

## Conventions

- `site.yaml`: every site-specific value, each with a comment saying what it's for. It's gitignored; `scripts/configure.py` generates it from questions. A new key goes in four places: `site.yaml`, `site.example.yaml` (placeholder value, same keys), a question plus the file template in `scripts/configure.py` (running it with all defaults must report no changes), and the chart template, referenced with `required "<key> is required (site.yaml)"` so a missing value fails the render with a clear message.
- `charts/<name>/`: local charts for this cluster, rendered with `site.yaml`.
  - `charts/cluster/`: cluster-wide pieces. `charts/home/`: the home automation stack in namespace `home`. `charts/immich/`: Immich in namespace `immich`, public. `charts/monitoring/`: site glue (Grafana's Ingress) for the third-party monitoring releases in `helm/`.
  - When a third-party chart needs site values (a hostname, a CIDR), keep its `helm/<release>/values.yaml` site-free and put the site-dependent objects (Ingress, Middleware) in a local chart instead.
  - `templates/<app>/`: one directory per app, one resource per file, e.g. `deployment.yaml`, `service.yaml`, `ingress.yaml`.
  - Chart defaults that don't depend on the site go in the chart's `values.yaml`, each with a comment: image versions, `certIssuer`, backup schedule and retention, PVC sizes, ACME `issuers` and `solvers`, Traefik settings.
  - Hostnames come from `site.yaml` in full (`ha.example.com`), not built from a domain: apps can live in different DNS zones.
  - Certificates: Ingresses use the annotation `cert-manager.io/cluster-issuer: {{ .Values.certIssuer }}`. Which solver validates a hostname is decided by `acme.zones` in `site.yaml`, never in the Ingress.
  - Namespaced resources set `metadata.namespace` explicitly: `{{ .Release.Namespace }}`, or a literal namespace for objects that live elsewhere (e.g. `kube-system`).
  - Keep resource names and selectors stable. Helm owns objects by name, and a Deployment's selector can't change in place.
  - PVCs carry `helm.sh/resource-policy: keep`, so uninstalling a release never deletes data.
- `helm/<release>/`: third-party charts, one directory per release, holding `values.yaml` and an idempotent `install.sh`. Example: `helm/cert-manager/`.
  - `install.sh` runs `helm upgrade --install` with `--repo` and an exact `--version`, so it needs no `helm repo add` state and gives the same result on a fresh machine.
  - Use the helm CLI (v4). Don't use k3s's `HelmChart` resource.
- `scripts/`: helpers the user runs by hand. Idempotent; read site values from `site.yaml` (or take them as arguments that default to it); find the repo root from their own path.

## Secrets

- Secret values go in `site.secret.yaml` (gitignored via `*.secret.yaml`) and are never committed.
- Keep `site.secret.example.yaml` in sync: the real keys with placeholder values, so it's clear what to fill in.

## Validate and apply

- The k3s kubeconfig is root-only. On the node, the user may have copied it to `~/.kube/config`; if it exists, agents use `KUBECONFIG=~/.kube/config` to inspect the cluster. Applying or deleting anything still needs the user's OK first.
- Before applying, check the charts. Rendering and linting need no cluster access:
  ```sh
  helm lint charts/home -f site.yaml
  helm template home charts/home -n home -f site.yaml
  ```
- See what would change in the cluster, then validate server-side:
  ```sh
  helm template home charts/home -n home -f site.yaml | kubectl diff -f -
  scripts/apply.sh --dry-run
  ```
- Apply with `scripts/apply.sh`. Third-party releases can still be installed on their own with `helm/<release>/install.sh`; render them first with `helm template <release> <chart> --repo <repo> --version <version> -f helm/<release>/values.yaml`.
