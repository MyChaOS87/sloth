# Sloth Domain Context & Ubiquitous Language

This document defines the domain model, hardware inventory, network topology, and ubiquitous language of the `sloth` home cluster.

---

## 1. Hardware & Operating System Domain

| Term | Definition |
|------|------------|
| **Radxa Rock5B Nodes** | 3-node single-board computer (SBC) cluster powered by Rockchip RK3588 (`linux/arm64`, 8-core Cortex-A76/A55) running Armbian Linux (`6.1.x-rk35xx`) on NVMe SSDs:<ul><li>`rock5b-but` (`192.168.1.21`) — `control-plane,etcd,master,monitoring,speaker,storage`</li><li>`rock5b-first` (`192.168.1.22`) — `control-plane,etcd,master,monitoring,speaker,storage`</li><li>`rock5b-coffee` (`192.168.1.23`) — `control-plane,etcd,master,monitoring,speaker,storage`</li></ul> |
| **Declarative Node Roles (`nodes/`)** | Server-Side Applied `v1/Node` manifests ([`argocd-base/nodes.yaml`](./argocd-base/nodes.yaml), dedicated `AppProject: nodes`, `sync-wave: "-1"`, `prune: false`) that declaratively assign single-purpose scheduling roles (`node-role.kubernetes.io/storage: "true"`, `node-role.kubernetes.io/speaker: "true"`, `node-role.kubernetes.io/monitoring: "true"`) without manual `kubectl label` steps. Only already-joined nodes are declared in [`nodes/`](./nodes/). |
| **NVMe Partition Layout** | Each Rock5B node's NVMe drive (`/dev/nvme0n1`) is partitioned into:<ul><li>`/dev/nvme0n1p1`: `btrfs` root filesystem (`/`) for OS and K3s containerd runtime (with 50 GiB reserved in Longhorn via `storageReserved: 53687091200`).</li><li>Dedicated `ext4` partition mounted at `/var/lib/longhorn/disk0/` for Longhorn distributed block storage replicas.</li></ul> |
| **K3s HA Control Plane** | Lightweight Kubernetes distribution (`v1.36.5+k3s1`) initialized with embedded HA `etcd` (`--cluster-init` on `192.168.1.21`) and with bundled `traefik` and `servicelb` disabled (`--disable traefik --disable servicelb`) so Argo CD manages MetalLB and Traefik declaratively. |
| **System Upgrade Controller** | Rancher [`system-upgrade-controller`](./cluster-essentials/system-upgrade.yaml) deployed in `system-upgrade` namespace. Executes automated rolling K3s upgrades via `Plan` CRDs (`server-plan` with `concurrency: 1`, `cordon: true`, tracking `https://update.k3s.io/v1-release/channels/stable`). |

---

## 2. GitOps & Argo CD Domain

| Term | Definition |
|------|------------|
| **App-of-Apps Pattern** | Hierarchical Argo CD reconciliation topology rooted in [`argocd-base/`](./argocd-base/):<ol><li>`argocd` self-manages the Argo CD installation in `argocd`.</li><li>`nodes` reconciles declarative `v1/Node` labels and taints in [`nodes/`](./nodes/) (`AppProject: nodes`).</li><li>`argocd-cluster-essentials` reconciles [`cluster-essentials/`](./cluster-essentials/) (`AppProject: cluster-essentials`).</li><li>`argocd-deployments` reconciles [`deployments/`](./deployments/), which fans out to [`deployments/oidc/oidc.yaml`](./deployments/oidc/oidc.yaml) (`AppProject: oidc`) and [`deployments/smarthome/smarthome.yaml`](./deployments/smarthome/smarthome.yaml) (`AppProject: smarthome`).</li></ol> |
| **Multi-Source Application** | An Argo CD `Application` specifying `spec.sources` (plural) to combine an upstream Helm chart (`spec.sources[0]`) with in-repo Kubernetes manifests such as `SealedSecret` or `ConfigMap` resources (`spec.sources[1]`). Used by `argocd`, `cert-manager`, `external-dns`, `longhorn`, `metallb`, `traefik`, `keycloak`, `grafana`, and `influxdb`. |
| **Single-Source Application** | An Argo CD `Application` specifying `spec.source` (singular) pointing either to an upstream Helm chart (`sealed-secrets`, `prometheus`, `version-checker`, `telegraf`, `automqttion`), a local Helm chart or manifest directory in Git (`nodes`, `mosquitto`), or a Kustomize overlay in Git (`system-upgrade`). |
| **SealedSecret (`*.sealed.json`)** | Asymmetric-encrypted Kubernetes secret resource (`bitnami.com/v1alpha1`) safe to commit to Git. Decrypted exclusively inside the cluster by the `sealed-secrets` controller in `kube-system`. |

---

## 3. Networking, DNS & PKI Domain

| Term | Definition |
|------|------------|
| **MetalLB L2 Address Pools** | Bare-metal ARP/NDP Layer-2 load balancer ([`cluster-essentials/metallb-config/`](./cluster-essentials/metallb-config/)) managing two IP ranges on the `192.168.1.0/24` LAN:<ul><li>`metallb-reserved-pool` (`192.168.1.30–192.168.1.49`, `autoAssign: false`): Reserved for static service bindings via `metallb.universe.tf/loadBalancerIPs` (e.g., `mosquitto` at `192.168.1.30`).</li><li>`metallb-auto-pool` (`192.168.1.50–192.168.1.99`, `autoAssign: true`): Dynamically assigned to `LoadBalancer` services such as `traefik`.</li></ul> |
| **Split-Horizon Internal Domains** | Internal services are exposed on LAN IP addresses under `vogelherdweg.de` subdomains:<ul><li>`*.rock.k8s.vogelherdweg.de` (e.g., `argocd.rock.k8s.vogelherdweg.de`, `longhorn.rock.k8s.vogelherdweg.de`, `prometheus.rock.k8s.vogelherdweg.de`, `grafana.rock.k8s.vogelherdweg.de`, `influxdb.rock.k8s.vogelherdweg.de`, `keycloak.rock.k8s.vogelherdweg.de`, `mqtt.rock.k8s.vogelherdweg.de`)</li><li>`*.internal.k8s.vogelherdweg.de` (e.g., `mqtt.internal.k8s.vogelherdweg.de`)</li></ul> |
| **ExternalDNS (`google` provider)** | Watches Kubernetes `Service` and `Ingress` resources and synchronizes `A` and `TXT` ownership records (`txtOwnerId: k8s`) to Google Cloud DNS (`project: vogelherd`) using `policy: sync`. |
| **Cert-Manager (`letsencrypt` ClusterIssuer)** | Provisions public Let's Encrypt TLS certificates for internal domains using ACME **DNS-01** challenges against Google Cloud DNS (`project: vogelherd`), avoiding the need to expose ports 80/443 to the public internet. |
| **Keycloak OIDC SSO** | Central Identity Provider (`keycloak.rock.k8s.vogelherdweg.de/auth/realms/master`) providing Single Sign-On for Argo CD (`oidc.keycloak.cli`) and Grafana (`generic_oauth`). |

---

## 4. Smarthome & Telemetry Domain

| Term | Definition |
|------|------------|
| **Mosquitto (`192.168.1.30:1883`)** | Eclipse Mosquitto MQTT broker deployed in `mosquitto` namespace (`deployments/smarthome/mosquitto/`), bound to static IP `192.168.1.30` and DNS names `mqtt.internal.k8s.vogelherdweg.de,mqtt.rock.k8s.vogelherdweg.de`. |
| **Shelly Gen1 (`shellies/#`)** | 1st-generation Shelly relays and sensors publishing raw payloads to `shellies/<device_type>-<device_id>/...` topics, parsed by Telegraf into the `shellies` measurement (`power`, `energy`, `temperature`, `overtemperature`). |
| **Shelly Plus (`shellies_plug/#`)** | Gen2/Plus Shelly smart plugs publishing JSON status objects to `shellies_plug/<device_type>-<device_id>/status/switch:0`, parsed by Telegraf into `shellies_plug` (`apower`, `voltage`, `current`, `temperature_tC`). |
| **Shelly BLU (`shellies_blu/BLE/ht/#`)** | Bluetooth Low Energy temperature/humidity/illuminance sensors forwarded via Shelly gateways to `shellies_blu/BLE/ht/<device>`, parsed into `shellies_blu` (`temperature`, `humidity`, `illuminance`, `battery`). |
| **WARP2 Wallbox (`warp2/22hg/#`)** | Tinkerforge WARP2 EV charger publishing JSON meter values and charging states to `warp2/<id>/<type>` and `warp2/<id>/<type>/<subtype>`, parsed by Telegraf into `wallbox` (`power`, `energy_abs`, `energy_rel`, per-phase currents/voltages). |
| **Pluggit Ventilation (`192.168.1.19:502`)** | Pluggit residential heat-recovery ventilation unit polled over **Modbus TCP** (`slave_id = 1`) by Telegraf every 10 seconds into `pluggit_modbus` (`prmRamIdxT1` outdoor, `T2` supply, `T3` extract, `T4` exhaust temperatures, `prmHALTaho1`/`2` fan speeds, bypass state, VOC, filter remaining time). |
| **Telegraf (`telegraf`)** | Metric collector in `telegraf` namespace combining 4 MQTT consumer inputs, 1 Modbus TCP input, Starlark/Eval/Enum processors, and an `outputs.influxdb_v2` writer targeting `http://influxdb-influxdb2.influxdb:80`. |
| **InfluxDB 2.x (`influxdb`)** | Time-series database in `influxdb` namespace (`organization: influxdata`, `bucket: default`) backed by a 32 GiB Longhorn PVC, queried via **Flux**. |
| **Grafana Sidecar Dashboards** | Declarative Grafana dashboards stored as Kubernetes `ConfigMap` manifests labeled `grafana_dashboard: "1"` in [`deployments/smarthome/grafana-dashboards/`](./deployments/smarthome/grafana-dashboards/), hot-reloaded by the `grafana-sc-dashboard` sidecar container. |
