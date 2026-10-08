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
site.yaml           gitignored site settings: domain, IPs, NAS, Zigbee device, timezone; shape: site.example.yaml
site.secret.yaml    gitignored secrets (the Gandi PAT); template: site.secret.example.yaml
charts/cluster/     local chart: Let's Encrypt ClusterIssuers, Gandi DNS-01 credentials, Traefik settings
charts/home/        local chart: Mosquitto, Zigbee2MQTT, Home Assistant, nightly backup
helm/<release>/     third-party charts: values.yaml + install.sh (cert-manager, the Gandi webhook)
scripts/            helpers you run by hand: configure, apply, Gandi setup, restore
```

The local charts hold templates only. Every site-specific value comes from `site.yaml`; versions (image tags) live in each chart's `values.yaml`. `scripts/configure.py` writes `site.yaml` from questions, offering the current values or ones detected on the node, so you don't have to edit it by hand.

`site.yaml` describes the home network, so it stays out of this public repo like the secrets do. Keep a copy of `site.yaml` and `site.secret.yaml` somewhere safe (a password manager, the NAS): after losing the node, `scripts/configure.py` can rebuild `site.yaml`, but only from what you remember.

## Apply

```sh
scripts/apply.sh --dry-run   # validate the local charts against the cluster, change nothing
scripts/apply.sh             # install or upgrade everything
```

It runs `helm/cert-manager` and `helm/cert-manager-webhook-gandi` first (their CRDs back the ClusterIssuers and Certificates), then `charts/cluster` with `site.yaml` and `site.secret.yaml`, then `charts/home` with `site.yaml`. For the kubeconfig it uses `$KUBECONFIG`, then `~/.kube/config`, then k3s's root-only `/etc/rancher/k3s/k3s.yaml` (run it with sudo).

To upgrade an app, bump its image in `charts/home/values.yaml` and run `scripts/apply.sh`.

## Exposing services

Only HTTP(S) on ports 80 and 443 is reachable from the internet, through Traefik. To publish an app, give it an Ingress with a `host` and point that hostname's DNS at the cluster.

Requests by bare IP get Traefik's `404 page not found`. That's expected: no Ingress matches them.

### LAN-only services

Some hosts resolve to the node's LAN IP (`network.nodeIp`) instead of the public one. DNS alone doesn't protect them: Traefik routes by `Host` header, so anyone who sends that header to the public IP reaches the service. Every LAN-only Ingress therefore:

- attaches the namespace's `lan-only` Traefik middleware (`ipAllowList` for `network.lanCidr`), e.g. `traefik.ingress.kubernetes.io/router.middlewares: home-lan-only@kubernetescrd`. This works because Traefik's Service uses `externalTrafficPolicy: Local` (`charts/cluster`), which keeps the real client IP. Requests made from the node itself still show up with an internal IP and get 403, so test from another device.
- uses the namespace's wildcard `*.<domain>` certificate instead of a per-host one, so the hostname doesn't show up in public Certificate Transparency logs.

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

cert-manager issues Let's Encrypt certificates through two ClusterIssuers, `letsencrypt-staging` and `letsencrypt-prod`. Both use DNS-01 on Gandi LiveDNS (so wildcards work) via `cert-manager-webhook-gandi`, authenticated with a Gandi Personal Access Token.

For a public host, give the Ingress the annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` and a `tls:` section with the host and a `secretName`.

The PAT expires. Before it does, create a new one in Gandi and run `scripts/setup-gandi-dns01.sh` again. The script checks the token, updates `site.secret.yaml` and the Secret, and proves issuance with a staging certificate. To check domains other than `site.yaml`'s, pass them as arguments.

## Backups

`charts/home` runs a CronJob every night at 04:00 that writes `YYYY-MM-DD/zigbee2mqtt.tar.gz` and `YYYY-MM-DD/home-assistant.tar.gz` to the NAS (`nas` in `site.yaml`), keeping 14 days. The Zigbee2MQTT archive holds the network key and paired devices, so restoring it avoids re-pairing everything. The Home Assistant archive holds `.storage` (users, areas, integrations, groups, HomeKit) and the automations, but not the history database.

- Back up now: `kubectl -n home create job --from=cronjob/backup backup-manual-$(date +%s)`
- Restore a day: `scripts/restore-home.sh 2026-10-09`. It stops both apps, unpacks the archives over their volumes, and starts them again.

## Secrets

Kubernetes Secrets are base64, not encryption. **Plaintext secrets are never committed.**

- Secret values go in `site.secret.yaml`, which is gitignored (`*.secret.yaml`). `site.secret.example.yaml` next to it lists the keys with placeholder values.
- `scripts/apply.sh` passes it to `charts/cluster`, which turns it into the Secret. Helm also keeps a copy in its release record, a Secret in `kube-system`.
