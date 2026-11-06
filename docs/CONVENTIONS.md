# Sloth Manifest, Dashboard & Query Conventions

This document defines the structural standards for Argo CD manifests, Kubernetes networking annotations, Grafana dashboard ConfigMaps, and InfluxDB Flux queries in `sloth`.

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

## 3. Grafana Dashboard & Flux Query Conventions

Grafana dashboards live in [`deployments/smarthome/grafana-dashboards/`](../deployments/smarthome/grafana-dashboards/) as Kubernetes `ConfigMap` manifests in namespace `grafana` with label `grafana_dashboard: "1"`.

### Rule 1: Telemetry Gap Protection (`integral()`)
Defunct or restarted `telegraf` pods (which tag metrics by pod `host`) can create multi-minute gaps in series data. Calling `integral()` directly over gaps causes Flux to linearly interpolate across the gap, producing huge artificial spikes or negative anomalies.

Always pre-aggregate into 1-minute windows and forward-fill missing points before integrating:
```flux
|> group(columns: ["some_tag"])
|> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
|> fill(usePrevious: true)
|> group(columns: ["some_tag", "_start", "_stop"])
|> integral(unit: 1h)
```

### Rule 2: Midnight-Aligned Daily Windows
Daily energy/cost bar charts must align their query start time to local midnight (`00:00:00`) of the earliest day so the first bar represents a full 24-hour day rather than a truncated partial day:
```flux
import "date"
today = date.truncate(t: now(), unit: 1d)
start_time = date.add(d: -14d, to: today)

from(bucket: "default")
  |> range(start: start_time)
```

### Rule 3: Clean Series & Legend Naming
Map custom human-readable series names into `_field` and group solely by `["_field"]`:
```flux
|> map(fn: (r) => ({ r with _field: "Phase A" }))
|> group(columns: ["_field"])
|> keep(columns: ["_time", "_value", "_field"])
```
In the Grafana panel JSON (`fieldConfig.defaults`), set:
```json
"displayName": "${__field.name}"
```
so legends render the clean series name without a `_value` prefix.

### Rule 4: High-Contrast Non-Repeating Panel Colors
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
