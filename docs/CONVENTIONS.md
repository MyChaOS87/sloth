# Sloth Manifest, Dashboard & Query Conventions

This document defines the structural standards for Argo CD manifests, Kubernetes networking annotations, Grafana dashboard ConfigMaps, and VictoriaMetrics MetricsQL queries in `sloth`.

---

## 1. Argo CD Application Manifest Conventions

### Single-Source vs. Multi-Source Applications
- **Single-Source (`spec.source`)**: Use when deploying an upstream Helm chart or in-repo chart/Kustomize path that needs no companion in-repo manifests:
  ```yaml
  spec:
    project: cluster-essentials
    source:
      repoURL: https://bitnami.github.io/sealed-secrets
      chart: sealed-secrets
      targetRevision: 2.22.0
      helm:
        releaseName: sealed-secrets
  ```
- **Multi-Source (`spec.sources`)**: Use when combining an upstream Helm chart (`spec.sources[0]`) with in-repo `SealedSecret`, `ConfigMap`, or CRD manifests (`spec.sources[1]`):
  ```yaml
  spec:
    project: cluster-essentials
    sources:
      - repoURL: https://charts.jetstack.io
        chart: cert-manager
        targetRevision: v1.21.3
        helm:
          releaseName: cert-manager
          values: |
            crds:
              enabled: true
      - repoURL: git@github.com:MyChaOS87/sloth.git
        targetRevision: HEAD
        path: cluster-essentials/cert-manager-issuer
  ```
  - **Bootstrap Rule**: In [`argocd-base/argocd.yaml`](../argocd-base/argocd.yaml), the Helm chart **must** remain at `spec.sources[0]` because [`makefile`](../makefile) extracts `.spec.sources[0].targetRevision` and `.spec.sources[0].helm.valuesObject` via `yq`.

### Sync Policy Standards
All production `Application` manifests must enable automated reconciliation with both `prune` and `selfHeal`:
```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```
- **CRD Workloads**: Charts installing large CRDs (`prometheus`, `argo-cd`, `cert-manager`) should include `ServerSideApply=true` or `Replace=true` under `syncOptions` as needed to avoid annotation size limits.

### Chart Version String Discipline
- Always match the exact `version` string published in the upstream Helm repository's `index.yaml`:
  - Jetstack charts (`cert-manager`, `version-checker`) require a leading `v` prefix (e.g., `v1.21.3`, `v0.11.0`).
  - Most other Helm repositories (`argo-cd`, `traefik`, `longhorn`, `prometheus`, `telegraf`, `keycloakx`) omit the `v` prefix (e.g., `10.14.0`, `1.13.0`, `29.41.0`).

---

## 2. Networking, DNS & TLS Annotations

### Ingress Resources
All internal web UIs exposed via Traefik must use the `letsencrypt` `ClusterIssuer`:
```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt
```
Provide a matching `tls` block with `secretName: <service>-tls` and `hosts: [<service>.rock.k8s.vogelherdweg.de]`.

### Static LoadBalancer Services (MetalLB + ExternalDNS)
Services exposed directly via MetalLB `LoadBalancer` (such as [`mosquitto`](../deployments/smarthome/mosquitto/values.yaml)) must declare:
1. `metallb.universe.tf/loadBalancerIPs: "192.168.1.30"` (from `metallb-reserved-pool`: `192.168.1.30–49`).
2. Both ExternalDNS hostname annotations (`external-dns.kubernetes.io/hostname` and `external-dns.alpha.kubernetes.io/hostname`) for compatibility with ExternalDNS `1.23.0+` configured with `--enable-legacy-annotation-prefix`:
   ```yaml
   annotations:
     external-dns.kubernetes.io/hostname: mqtt.internal.k8s.vogelherdweg.de,mqtt.rock.k8s.vogelherdweg.de
     external-dns.alpha.kubernetes.io/hostname: mqtt.internal.k8s.vogelherdweg.de,mqtt.rock.k8s.vogelherdweg.de
     metallb.universe.tf/loadBalancerIPs: 192.168.1.30
   ```

---

## 3. Grafana Dashboard & MetricsQL Query Conventions

Grafana dashboards live in [`deployments/smarthome/grafana-dashboards/`](../deployments/smarthome/grafana-dashboards/) as Kubernetes `ConfigMap` manifests in namespace `grafana` with label `grafana_dashboard: "1"` and query the `VictoriaMetrics` datasource (`type: prometheus`, `uid: victoriametrics`).

### Rule 1: Telemetry Gap Protection & Window-Mean Integration (`integrate(keep_last_value(avg_over_time(...)))`)
Shelly relays and BLE sensors report on state changes or sparse intervals, creating multi-minute gaps between raw samples, while appliances like boiling-water heaters (`wasser`) or espresso machines (`kaffee`) draw power in brief 20–35 second pulses.
- Inside a subquery `[range:step]`, always average raw samples across each `step` with `avg_over_time(m[step])` before applying `< 5000` spike filtering and `keep_last_value(...)` forward-filling (converting Watt-seconds to Watt-hours via `/ 3600`):
  ```promql
  integrate(keep_last_value(avg_over_time(power_value{shelly_type="relay"}[1m]) < 5000)[14d:1m]) / 3600
  ```
  Evaluating raw `power_value` directly inside `[range:step]` without `avg_over_time(...[step])` point-samples once per step boundary and either misses sub-minute pulses (`wasser`, `kaffee`) or stretches a single instant across a multi-minute `$__interval`.
- **Sparse Sensor Line Continuity (`spanNulls: true`)**:
  - For battery-powered room sensors (`Temperature`, `Humidity` in [`grafana-dashboard-environment.yaml`](../deployments/smarthome/grafana-dashboards/grafana-dashboard-environment.yaml)), set `"spanNulls": true` in `fieldConfig.defaults.custom` so Grafana connects consecutive sample points across empty `$__interval` steps.
- **Subquery Step Sizing (`-search.maxPointsSubqueryPerTimeseries=100000`)**:
  - Use `[1d:1m]`, `[14d:1m]`, or `[30d:1m]` (`1,440` to `43,200` points) for fixed 1–30 day windows.
  - Use `[90d:2m]` with `avg_over_time(...[2m])` (`64,800` points) for 90-day windows so the subquery never exceeds VictoriaMetrics' 100,000-point limit.
  - Use `[$__range:$__interval]` with `avg_over_time(...[$__interval])` for dynamic dashboard-range integrals so the step scales automatically with the user's selected time range.

### Rule 2: Daily Cost Bar Charts (`interval: "1d"`)
Daily energy/cost bar charts (`drawStyle: "bars"`) set `"interval": "1d"` on the Prometheus target alongside a `[1d:1m]` integral subquery so each bar integrates a full 24-hour day:
```promql
label_set((integrate(keep_last_value(power_power{wallbox_name="22hg"})[1d:1m]) / 3600 / 1000) * 0.2727, "_field", "Wallbox Daily Cost")
```

### Rule 3: Clean Series & Legend Naming (`label_replace` / `label_set`) and Hardware-Replacement Aggregation (`avg by` / `sum by`)
Strip hardware prefixes (`shellyplugs-`, `shellyplugm-`, `shellyplug-`, `shellyplusht-`, `shellyhtblue-`, `shellyht-`) using `label_replace` with non-capturing groups (`(?:...)`) so `$1` captures the clean room/outlet identifier, and wrap with `avg by (shelly_id)` (for instantaneous gauges) or `sum by (shelly_id)` / `sum by (_field)` (for integrated energy/cost) so leftover `topic`/`shelly_type` labels are stripped and replaced sensors in the same room merge into a single continuous historical series:
```promql
avg by (shelly_id) (label_replace(avg_over_time(temperature_value{shelly_type!="relay"}[$__interval]), "shelly_id", "$1", "shelly_id", "^(?:shelly(?:plugs|plugm|plug|plusht|htblue|ht)-)?(.*)"))
```
For current-value stat panels (`Last Temperatures`), use a bounded lookback (`last_over_time(...[6h])`) rather than `[$__range]` so long-retired sensors are not resurrected when zooming out to multi-year ranges.
For synthetic or multi-series unions (`Phase A..C`, `Total`, `30 Day Basis`), assign `_field` via `label_set(..., "_field", "<Name>")`, combine with `union(...)`, and set `"legendFormat": "{{_field}}"`.

### Rule 4: Multi-Generation Meter Bridging (`or on()`)
When hardware upgrades change the underlying metric or schema across historical eras, bridge both series with `or on()` so multi-year queries remain continuous:
- **House 3-Phase Meter (April 2025 Shelly 3EM $\rightarrow$ Shelly Pro 3EM Upgrade)**:
  - Phase A: `em:0_a_act_power or on() power_value{shelly_type="emeter",sub_id="0"}`
  - Phase B: `em:0_b_act_power or on() power_value{shelly_type="emeter",sub_id="1"}`
  - Phase C: `em:0_c_act_power or on() power_value{shelly_type="emeter",sub_id="2"}`
- **Per-Phase Wallbox Load Subtraction (May 2026 Per-Phase Meter Upgrade)**:
  - Subtract actual per-phase Wallbox active power (`power_l1_power`, `power_l2_power`, `power_l3_power`) with fallback to `power_power{wallbox_name="22hg"} / 3` prior to May 2026:
    `power_l1_power{wallbox_name="22hg"} or on() (power_power{wallbox_name="22hg"} / 3)`

### Rule 5: High-Contrast Non-Repeating Panel Colors
When multiple series appear in the same panel (or across adjacent panels in [`grafana-dashboard-power.yaml`](../deployments/smarthome/grafana-dashboards/grafana-dashboard-power.yaml) and [`grafana-dashboard-environment.yaml`](../deployments/smarthome/grafana-dashboards/grafana-dashboard-environment.yaml)), bind explicit `fixed-color` overrides (`fieldConfig.overrides`) using distinct, high-contrast named Grafana palette colors (e.g., `red`, `blue`, `green`, `orange`, `purple`, `yellow`, `light-blue`, `super-light-purple`) rather than relying on auto-assigned palette rotation.

---

## 4. Commit Message Conventions

All commits in `sloth` follow the workspace convention:
```text
feat[(<topic>)]: <description>
chore[(<topic>)]: <description>
bugfix[(<topic>)]: <description>
```
- Use active present tense and a single subject line heading.
- Use `*` for bullet points in the commit body.
- Escape backticks when passing commit messages via shell flags.
