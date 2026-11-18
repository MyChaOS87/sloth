# SLOTH (SLightly Over-engineered "Trivial" Home automation)

## Introduction
This is my personal home-server/cluster, built primarily for home automation and as my K3s + Argo CD GitOps playground.

I originally started running it on a [Raspberry Pi CM4 Single Node (Historic / Outdated)](#1-raspberry-pi-cm4-single-node-historic--outdated) (`date: 2022-12-16`), hit CPU, RAM, and I/O limits once Longhorn, Keycloak, InfluxDB, and Prometheus were added, and moved in August 2023 to a three-node [Radxa Rock 5B HA Cluster](#2-radxa-rock-5b-ha-cluster) (`rock5b-but`, `rock5b-first`, `rock5b-coffee`, `date: 2023-08-06`, upgraded to Mainline `6.18.y` LTS on `date: 2026-11-08` and migrated to immutable **Kairos OS** + Mainline `7.2+` kernel on `date: 2026-11-14`) complemented by a dedicated 512 MB RAM [Raspberry Pi Zero 2 W Edge Node (`pi0-lcn`)](#3-raspberry-pi-zero-2-w-edge-node-pi0-lcn) (`date: 2026-11-07`) downstairs for physical LCN-PKU USB serial bus access.

Everything in the cluster is kept as hardware-independent as possible. To deploy onto your own Kubernetes cluster, skip the [Hardware Setup](#hardware-setup) section and start directly with [Bootstrapping Secrets and Argo CD](#bootstrapping-secrets-and-argo-cd) (ensuring your storage nodes meet the Longhorn prerequisites).

### Repository Structure
* [`argocd-base/`](./argocd-base/) — Root App-of-Apps bootstrap manifests (`argocd`, `nodes`, `argocd-cluster-essentials`, `argocd-deployments`).
* [`nodes/`](./nodes/) — Declarative Server-Side Applied `v1/Node` role labels (`storage`, `speaker`, `monitoring`, `lcn-serial`) and taints.
* [`cluster-essentials/`](./cluster-essentials/) — Core platform services (`sealed-secrets`, `kube-vip`, `metallb`, `traefik`, `cert-manager`, `external-dns`, `longhorn`, `system-upgrade`, `kairos-operator`, `prometheus`, `version-checker`).
* [`deployments/`](./deployments/) — Workload stacks (`oidc/authelia` and `smarthome/{mosquitto,telegraf,victoria-metrics,grafana,automqttion,reverselcn}`).
* [`examples/sloth-private/`](./examples/sloth-private/) — Reference private overlay skeleton (`example.com`) for replicating `sloth-private`; see [`docs/PRIVATE_OVERLAY.md`](./docs/PRIVATE_OVERLAY.md).
* [`node-bootstrap/rock5b/`](./node-bootstrap/rock5b/) — Declarative Kairos `cloud-config.yaml` template and per-node config renderer for the 3 Radxa Rock 5B nodes.
* [`node-bootstrap/pi0-lcn/`](./node-bootstrap/pi0-lcn/) — Zero-touch DietPi SD card generator and idempotent Ansible playbook for `pi0-lcn`.
* [`docs/`](./docs/) — Architecture, private overlay contract, conventions, toolchain, and per-node [hardware setup guides](./docs/hardware/).
* `.secrets/` — Local temporary directory for unsealed secrets and `.secrets/sloth.env` (gitignored; never committed).

### Technology Stack
* **Kubernetes & HA API VIP**: [K3s](https://k3s.io) (`v1.37.2+k3s1`) with embedded HA `etcd` and [kube-vip](https://kube-vip.io/) (`192.168.1.20:6443` / `api.internal.k8s.example.com` / `api.rock.k8s.example.com`)
* **Immutable Node OS & Day-2 Upgrades**: [Kairos Linux](https://kairos.io/) (`v4.5.0` via [`kairos-rock5b`](https://github.com/MyChaOS87/kairos-rock5b), pure Debian 13 Trixie + `trixie-backports` `7.2+` mainline kernel + Mainline U-Boot `v2026.10` in SPI NOR) reconciled via `kairos-operator` (`0.3.0`) on the 3 Rock 5B nodes, plus Rancher `system-upgrade-controller` for `pi0-lcn`
* **GitOps & Packaging**: [Argo CD](https://argo-cd.readthedocs.io/en/stable/) + [Helm](https://helm.sh/) (App-of-Apps pattern managing all cluster state from Git)
* **Secrets Management**: [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) for committing encrypted `SealedSecret` manifests safely to Git
* **Distributed Block Storage**: [Longhorn](https://longhorn.io) across NVMe SSDs (`COS_PERSISTENT` `/var/lib/longhorn/disk0/`) on the 3 Rock 5B nodes
* **Networking, Ingress, DNS & PKI**: [MetalLB](https://metallb.universe.tf/) (L2 ARP pools `192.168.1.30–99`), [Traefik](https://traefik.io/traefik/), [cert-manager](https://cert-manager.io/) (Let's Encrypt DNS-01), and [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) (Google Cloud DNS)
* **Identity & SSO**: [Authelia](https://www.authelia.com/) OIDC + Traefik `ForwardAuth` Single Sign-On (Passkeys/WebAuthn + Argon2id) for Argo CD, Grafana, Longhorn, Prometheus, and VictoriaMetrics
* **Observability & Telemetry**: [Prometheus](https://prometheus.io/), [Grafana](https://grafana.com/), [VictoriaMetrics](https://victoriametrics.com/), and [Telegraf](https://www.influxdata.com/time-series-platform/telegraf/)
* **Smarthome & Bus Bridges**: [Mosquitto](https://mosquitto.org/) MQTT broker (`192.168.1.30:1883`), [automqttion](https://github.com/MyChaOS87/automqttion) for declarative MQTT automations, and [reverseLCN](https://github.com/MyChaOS87/reverseLCN) (`lcn2mqtt`) for bidirectional LCN-PKU USB serial $\leftrightarrow$ MQTT bridging on `pi0-lcn`

---

## Hardware Setup

Hardware installation, partitioning, kernel migration, and node bootstrap instructions live in [`docs/hardware/`](./docs/hardware/):

### 1. [Raspberry Pi CM4 Single Node (Historic / Outdated)](./docs/hardware/cm4-single-node.md) (`date: 2022-12-16` – `2023-08-06`)
* **Status**: **Retired / Historic prototype**.
* Original single-node Compute Module 4 (`cm4-01.lan` on Waveshare CM4-NANO-B) eMMC setup (`usbboot` + Raspberry Pi OS Lite 64-bit). Replaced in August 2023 after hitting CPU, RAM, and I/O limits once Longhorn, Keycloak, InfluxDB, and Prometheus were deployed.

### 2. [Radxa Rock 5B HA Cluster](./docs/hardware/rock5b-cluster.md) (`date: 2023-08-06`, migrated to immutable Kairos OS `date: 2026-11-14`)
* **Nodes**: `rock5b-but` (`192.168.1.21`), `rock5b-first` (`192.168.1.22`), `rock5b-coffee` (`192.168.1.23`) — `ROLES: control-plane,etcd,monitoring,speaker,storage`.
* **Active Setup (Kairos OS)**: Runs immutable [`kairos-rock5b`](https://github.com/MyChaOS87/kairos-rock5b) (pure Debian 13 Trixie + `trixie-backports` `7.2+` mainline kernel, K3s `v1.37.2+k3s1`, `kube-vip` HA control-plane VIP `192.168.1.20:6443`) booted directly from onboard 16 MB SPI NOR flash (Mainline U-Boot `v2026.10`) and full-disk NVMe (`COS_*` partitions), with atomic A/B Day-2 upgrades reconciled by `kairos-operator`.
* **Historical Reference (2023–2026 Armbian)**: Preserves the original Armbian NVMe installation (`date: 2023-08-06`), live Btrfs-to-`ext4` Longhorn partition shrink (`date: 2023-08-08`), and in-place kernel switches (`5.10.160-legacy` $\rightarrow$ `6.1.115-vendor` $\rightarrow$ Mainline Linux `6.18.y-current-rockchip64` LTS, `date: 2026-11-07` – `2026-11-08`).

### 3. [Raspberry Pi Zero 2 W Edge Node (`pi0-lcn`)](./docs/hardware/pi0-lcn.md) (`date: 2026-11-07` – `2026-11-08`)
* **Node**: `pi0-lcn` (`192.168.1.24`) — `ROLES: lcn-serial,monitoring`, tainted `dedicated=lcn-serial:NoExecute`.
* Dedicated Wi-Fi K3s agent node downstairs hosting the physical **LCN-PKU USB serial coupler (`/dev/lcn-pku`)** for `reverseLCN` (`lcn2mqtt`).
* Details the **512 MB RAM engineering challenges** (only `462 MiB` usable RAM; mitigating DietPi's default 50%-RAM `tmpfs` mounts with `/tmp=64M` & `/var/log=32M` caps, `systemd-journald` `16M` cap, compressed `/dev/zram0` swap with zero SD wear, kubelet eviction reservations, and `NoExecute` taint isolation to keep `longhorn`/`metallb`/`kube-vip` off the node), unprivileged containerd v3 USB serial cgroup permissions, and zero-touch DietPi + Ansible provisioning.

---

## Access K3s from Remote Workstation

Run [`./kubectl-config-remote.sh`](./kubectl-config-remote.sh) on your workstation to pull the K3s client credentials into `~/.kube/config` (context `sloth-root`), then point the cluster URL at the `kube-vip` HA virtual IP (`api.internal.k8s.example.com` / `192.168.1.20`):
```bash
./kubectl-config-remote.sh -s rock5b-but.lan -u kasch
kubectl config set-cluster sloth --server=https://api.internal.k8s.example.com:6443
```

---

## Bootstrapping Secrets and Argo CD

Domain-specific Helm overlays, ExternalDNS/Cert-Manager configs, and encrypted `SealedSecret` manifests (`*.sealed.json`) live in a separate private companion repository (`sloth-private` at `SLOTH_PRIVATE_DIR=../sloth-private`). See [`docs/PRIVATE_OVERLAY.md`](./docs/PRIVATE_OVERLAY.md) and [`examples/sloth-private/`](./examples/sloth-private/) for the full directory contract.

### Local Prerequisites
* `kubectl` (configured against your K3s cluster)
* `helm`
* `yq`
* `kubeseal` — for sealing secrets

### Prepare Private Overlay, SealedSecrets & Deploy Key
Copy [`examples/sloth-private/`](./examples/sloth-private/) to `../sloth-private`, customize your domain/project settings in `.secrets/sloth.env` and the overlay YAML files, install `sealed-secrets`, and run the sealing scripts in `sloth` (outputs write directly to `${SLOTH_PRIVATE_DIR}`):
```bash
make sealed-secrets.install
make sealed-secrets.seal.sshDeployKey
```
Add `../sloth-private/deploy_key.pub` as a read-only Deploy Key on your private overlay GitHub repository so Argo CD can pull from it, then run the remaining `create-and-seal-*.sh` scripts and commit/push your private overlay repository.

### Install Argo CD and Bootstrap the Cluster
```bash
make argocd.install
```
From this point forward, Argo CD reconciles the entire cluster (including Argo CD itself, `sealed-secrets`, `nodes`, `cluster-essentials`, and `deployments`). Retrieve the initial admin password with:
```bash
make argocd.password
```

---

## Project Scope & Disclaimer
`sloth` is a personal homelab and home-automation playground built for a single-operator residential LAN—**not** corporate or enterprise production infrastructure.

Even where components are hardened (`SealedSecrets`, Authelia Passkey/OIDC SSO, immutable Kairos nodes, and CI policy checks), configurations prioritize homelab pragmatism and experimentation over enterprise compliance, multi-tenancy, or hostile-network hardening (for example, unauthenticated LAN-local MQTT for embedded IoT sensors). Expect opinionated shortcuts and occasional breaking changes. Provided as-is under the [MIT License](./LICENSE) without warranty.

## License
[MIT License](./LICENSE)
