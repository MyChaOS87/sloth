# homecluster Agent Guide

This document describes homecluster-specific (sloth) conventions and tooling.

---

## Project Overview

`sloth` (SLightly Over engineered "Trivial" Home automation) is a Kubernetes (k3s) and ArgoCD playground for home-server / cluster management and home automation.

---

## Safeguards & Crucial Rules

> [!WARNING]
> **GitOps Impact**: Since the cluster is GitOps-driven, any pushed configuration changes are automatically applied by ArgoCD and can potentially break or kill the cluster.

- **Check Kubectl Context**: Always double check that you are using the correct/appropriate `kubectl` context before running commands (verify using `kubectl config current-context`).
- **Assume Cluster Exists**: Do not assume you need to bootstrap or recreate the cluster from scratch; always assume the `sloth` cluster exists and operates in its current state.
- **Verify via ArgoCD**: Use the ArgoCD UI or CLI to check/validate status and sync progress of pushed changes.
- **Sealed Secrets Generation**: Sealed secrets should only be regenerated after explicit user confirmation.
- **No Destructive Operations**: Never perform any destructive operation without explicit user confirmation.

---

## Common Patterns

```bash
make checkPrerequisites.all  # Check all local prerequisites (kubectl, helm, yq, kubeseal)
make sealed-secrets.install  # Install sealed-secrets controller
make sealed-secrets.seal.sshDeployKey  # Generate and seal SSH deploy key for GitHub access
make argocd.install          # Install ArgoCD and bootstrap the cluster
make argocd.password         # Retrieve admin password from the cluster
make argocd.port-forward     # Port-forward the ArgoCD UI to localhost:8080
make argocd.uninstall        # Uninstall ArgoCD and clean up CRDs
make sealed-secrets.uninstall # Uninstall sealed-secrets controller
```

---

## What Makes homecluster Different

| Aspect | Speciality |
|--------|------------|
| **Deployment Model** | GitOps-driven using ArgoCD for continuous delivery |
| **Cluster Setup** | Runs on K3s (single-node CM4 or multi-node Rock5b HA cluster) |
| **Secrets Sealing** | Uses `sealed-secrets` to store encrypted secrets safely in Git |
| **Persistent Storage** | Longhorn (requires unformatted ext4 partitions and open-iscsi on nodes) |
| **Networking & LB** | MetalLB (replaces Traefik/ServiceLB) for internal load balancing |

**Secret Sealing Scripts**:
The repository includes scripts to generate and seal secrets:
- `./create-and-seal-deploy-key.sh` - Generates SSH keypair, seals private key to `argocd-base/repository.sealed.json`, outputs public key.
- `./create-and-seal-metallb-memberlist-secret.sh` - Generates memberlist secret key, seals to `cluster-essentials/metallb-config/memberlist.sealed.json`.
- Other scripts cover `gcloud-service-accounts`, `oidc-client-secrets`, `oidc-secrets`, and `smarthome-secrets`.

**Key Locations**:
- `argocd-base/` - ArgoCD base bootstrap application definitions.
- `cluster-essentials/` - Base infrastructure charts (Sealed Secrets, Longhorn, MetalLB).
- `deployments/` - Applications and home automation services managed by ArgoCD.

---

## Telemetry Stack: InfluxDB, Grafana & Telegraf

The telemetry data flow in `sloth` is structured as follows:
- **Telegraf**: Runs as collector pods/daemonsets collecting metrics from smarthome devices (e.g. Shelly plugs, Wallbox) and system telemetry, publishing them to InfluxDB.
  - **Telemetry Gaps**: Defunct or restarted telegraf pods (grouped by the `host` tag) can leave large gaps in telemetry. Standard functions like `integral()` will linearly interpolate across these gaps and return incorrect or negative values unless the data is pre-aggregated and filled.
- **InfluxDB**: InfluxDB 2.x acts as the timeseries database.
  - **Namespace**: `influxdb`
  - **Query Language**: Flux
  - **Credentials**: Secret `influxdb-secret` in namespace `influxdb` holds the admin token (`admin-token`).
- **Grafana**: Visualizes the metrics.
  - **Namespace**: `grafana`
  - **Dashboard Provisioning**: Dashboards are managed GitOps-style as Kubernetes `ConfigMap` resources inside `deployments/smarthome/grafana-dashboards/`.
  - **Dashboard Reloading**: The `grafana-sc-dashboard` sidecar container watches for ConfigMap updates, writes dashboard JSONs to `/tmp/dashboards/`, and automatically triggers Grafana API reloading (`/api/admin/provisioning/dashboards/reload`), returning `200 OK`.

### Flux & Dashboard Query Conventions
1. **Telemetry Gap Protection**: When using `integral()` over ranges with potential gaps, always pre-aggregate data in 1-minute windows and fill missing values from the previous record first:
   ```flux
   |> group(columns: ["some_tag"])
   |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
   |> fill(usePrevious: true)
   |> group(columns: ["some_tag", "_start", "_stop"])
   |> integral(unit: 1h)
   ```
2. **Midnight-Aligned Ranges**: Daily cost graphs must align their time ranges to midnight of the first day to prevent the first day from appearing as a partial, suspiciously low value. Use the `date` package:
   ```flux
   import "date"
   today = date.truncate(t: now(), unit: 1d)
   start_time = date.add(d: -14d, to: today)
   // in query:
   |> range(start: start_time)
   ```
3. **Series & Legend Naming**: Control legend labels by mapping the `_field` column and ensuring it is the sole group key in the final output:
   ```flux
   |> map(fn: (r) => ({ r with _field: "Phase A" }))
   |> group(columns: ["_field"])
   |> keep(columns: ["_time", "_value", "_field"])
   ```
   In the Grafana panel's `fieldConfig.defaults`, set `"displayName": "${__field.name}"` to display the custom legend name clean of any `_value` prefix.

---

## Git Workflow

**Scope**: This is an independent git repository. Operate git commands within `homecluster/sloth` directory only.

**Branching**: Prefer feature branches for changes:
```bash
git checkout -b feature/description
git checkout -b bugfix/description
```

**Testing Changes**: Confirm chart syntax or configuration edits prior to commit:
- Use `helm template` or `kubectl diff` where applicable.

**CRITICAL**: Never push to remote without explicit user command.
