# Sloth Verification & GitOps Validation Guide

Because `sloth` is an infrastructure/GitOps repository rather than a Go codebase, verification follows a **3-Tier GitOps Validation Model** before and after pushing changes to `origin/main`.

---

## 1. Three-Tier Validation Model

### Tier 1: Offline Pre-Commit Manifest & Schema Validation
Before committing any change to `argocd-base/`, `nodes/`, `cluster-essentials/`, or `deployments/`, validate that the chart or overlay renders cleanly and passes JSON Schema validation:

1. **Helm Chart Rendering & Schema Check**:
   Extract inline `values` (or use `valuesObject` / `values.yaml`) and run `helm template`:
   ```bash
   yq '.spec.source.helm.values' cluster-essentials/<app>.yaml > /tmp/<app>-values.yaml
   helm template <release-name> <repo>/<chart> --version <version> -n <namespace> -f /tmp/<app>-values.yaml > /dev/null
   ```
   - *Why this matters*: Upstream charts (such as `external-dns` `1.23.0+`) ship strict `values.schema.json` validators that reject missing required fields (`policy: sync`) at template time.
2. **Local Helm Chart Linting**:
   For in-repo charts (`deployments/smarthome/mosquitto/`):
   ```bash
   helm lint deployments/smarthome/mosquitto
   helm template mosquitto deployments/smarthome/mosquitto -n mosquitto > /dev/null
   ```
3. **Kustomize Overlay Validation**:
   For Kustomize-sourced applications (`cluster-essentials/system-upgrade.yaml`):
   ```bash
   kubectl kustomize https://github.com/rancher/system-upgrade-controller?ref=v0.21.0 > /dev/null
   ```
4. **Multi-Arch Image Manifest Verification (`linux/arm64`)**:
   When upgrading major/minor chart versions on `linux/arm64`, verify the container image tags include an `arm64` manifest in their OCI index before committing.

---

### Tier 2: Staged GitOps Sync & Mandatory Live Cluster Monitoring
> [!IMPORTANT]
> **Mandatory Live Cluster Monitoring Rule**: Whenever any change is pushed to `origin/main` (or applied to the cluster), you **must** actively monitor the cluster until all affected Argo CD Applications reach `Synced` + `Healthy` and all pod rollouts, DaemonSets, and `system-upgrade` jobs settle cleanly without crash loops. Never consider a change complete right after `git push`.

When upgrading multiple components, push and verify in dependency order rather than all at once:
1. **Stage 1 (Control Plane, Nodes & Secrets)**: `nodes` $\rightarrow$ `sealed-secrets` $\rightarrow$ `argocd`
2. **Stage 2 (Networking & PKI)**: `metallb` $\rightarrow$ `traefik` $\rightarrow$ `cert-manager` $\rightarrow$ `external-dns`
3. **Stage 3 (Cluster Operations)**: `system-upgrade` $\rightarrow$ `version-checker`
4. **Stage 4 (Storage — Strictly Sequential Minor Versions)**: `longhorn` (`1.11.x` $\rightarrow$ `1.12.x` $\rightarrow$ `1.13.x`)
5. **Stage 5 (Observability)**: `prometheus` $\rightarrow$ `victoria-metrics` $\rightarrow$ `telegraf` $\rightarrow$ `grafana`
6. **Stage 6 (SSO & Workloads)**: `keycloak` $\rightarrow$ `mosquitto` $\rightarrow$ `automqttion` $\rightarrow$ `reverselcn`

#### Triggering & Inspecting Reconciliation
```bash
# Force immediate Argo CD refresh after git push
kubectl annotate application -n argocd <app-name> argocd.argoproj.io/refresh=normal --overwrite

# Check sync and health status across all Applications
kubectl get applications -n argocd -o wide
```
Every modified `Application` must reach `SYNC STATUS: Synced` and `HEALTH STATUS: Healthy`.

---

### Tier 3: Deep Runtime & Storage Health Checks

#### Longhorn Upgrade Verification
Never proceed to the next Longhorn minor version until all four checks pass:
```bash
# 1. Confirm Longhorn internal version setting matches target minor version
kubectl get settings.longhorn.io -n longhorn current-longhorn-version

# 2. Confirm all manager, driver, CSI, and engine-image DaemonSets/Deployments are Ready
kubectl get daemonset,deployment -n longhorn

# 3. Confirm EngineImage CRD is fully deployed
kubectl get engineimages.longhorn.io -n longhorn

# 4. Confirm all PVCs/Volumes are attached and healthy
kubectl get volumes.longhorn.io -n longhorn -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,ENGINE:.spec.image
```

#### Grafana Sidecar Dashboard Verification
After modifying `deployments/smarthome/grafana-dashboards/*.yaml`:
```bash
kubectl logs -n grafana deployment/grafana -c grafana-sc-dashboard --tail=30
```
Confirm the sidecar logged `200 OK` from `/api/admin/provisioning/dashboards/reload`.

---

## 2. Operational Recovery Playbooks

### Playbook A: Corrupted `.git/index` in `argocd-repo-server`
- **Symptom**: Multiple Git-sourced Argo CD Applications report `ComparisonError: rpc error: code = Unknown desc = fatal: .git/index: index file smaller than expected`.
- **Root Cause**: Transient corruption of the shallow Git cache inside `argocd-repo-server`'s ephemeral `/tmp` volume.
- **Resolution** (requires user confirmation):
  ```bash
  kubectl rollout restart deployment/argocd-repo-server -n argocd
  kubectl rollout status deployment/argocd-repo-server -n argocd
  ```

### Playbook B: Stuck `OrderedReady` StatefulSet Pod on Bad Image Tag
- **Symptom**: After reverting or fixing a broken image tag on a `StatefulSet` (e.g., `prometheus-alertmanager` or `keycloak`), the `StatefulSet` remains wedged because `pod-0` is in `ImagePullBackOff` and Kubernetes `OrderedReady` policy refuses to recreate a non-Running pod when `currentRevision != updateRevision`.
- **Resolution** (requires user confirmation):
  ```bash
  kubectl delete pod -n <namespace> <statefulset-pod-0>
  ```
  The `StatefulSet` controller immediately recreates `<statefulset-pod-0>` using the updated `updateRevision` pod template.

---

## 3. Backlog & Issue Tracking

All `sloth` bugs, blocked chart upgrades, and planned enhancements are tracked on the workspace GitHub Project board:
- **Project Board**: [GitHub Project #1](https://github.com/users/MyChaOS87/projects/1) (`MyChaOS87/.projects`, filtered by `Project: sloth` / label `project:sloth`).
