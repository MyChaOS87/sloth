# Sloth Verification & GitOps Validation Guide

Because `sloth` is an infrastructure/GitOps repository rather than a Go codebase, verification follows a **3-Tier GitOps Validation Model** before and after pushing changes to `origin/main`.

---

## 1. Three-Tier Validation Model

### Tier 1: Offline Pre-Commit Manifest, Policy & Schema Validation
Before committing or pushing any change to `argocd-base/`, `nodes/`, `cluster-essentials/`, or `deployments/`, validate formatting, GitOps policy contracts, and rendered Kubernetes schemas via [`makefile`](../makefile):

```bash
make fmt            # Optional: normalize YAML indentation and whitespace via yamlfmt
make check          # Runs check.blacklist -> check.yaml -> check.manifests -> check.helm
```

When developing in CI or without a private overlay checkout, `make check` automatically validates [`examples/sloth-private/`](../examples/sloth-private/) whenever `SLOTH_PRIVATE_DIR` is absent (when simulating CI locally alongside a private checkout, point `SLOTH_PRIVATE_DIR` at a non-existent path so `examples/sloth-private/blacklist.txt` is not loaded as an active blacklist):

```bash
SLOTH_ALLOW_MISSING_BLACKLIST=1 make check
# Or locally alongside an existing ../sloth-private checkout:
SLOTH_ALLOW_MISSING_BLACKLIST=1 SLOTH_PRIVATE_DIR=/nonexistent make check
```

What `make check` enforces:
1. **Leak Guard (`make check.blacklist`)**: Verifies no private `blacklist.txt` tokens, `.env` files, or home paths appear in working-tree files or Git history.
2. **YAML Formatting (`make check.yaml`)**: Checks formatting consistency via `yamlfmt -lint` ([`.yamlfmt.yml`](../.yamlfmt.yml)).
3. **Manifest & Overlay Policy (`make check.manifests`)**: Evaluates [`policy/`](../policy/) (`secrets.rego`, `configmaps.rego`, `argocd.rego`, `overlays.rego`) via `conftest` to enforce `.sealed.json` integrity, ban plaintext `v1/Secret` manifests (outside allowed hashed auth secrets), validate embedded `ConfigMap` JSON (Grafana dashboards), check Argo CD `Application` sync contracts (`selfHeal: true`, selective `prune`, valid `AppProject`), verify inline `helm.values` YAML syntax, and guarantee disjoint leaf/array keys between inline `helm.values` and `${SLOTH_PRIVATE_DIR}/values/<app>.yaml`.
4. **Helm & Kustomize Schema + Deprecated API Validation (`make check.helm`)**:
   - Lints local Helm charts (`deployments/smarthome/mosquitto/`) with `helm lint --strict`.
   - Renders each Helm `Application` (merging `${SLOTH_PRIVATE_DIR}/values/<app>.yaml` and inline `helm.values`, caching chart `.tgz` archives under `.cache/helm-charts/`) and Kustomize `Application` (`kubectl kustomize --enable-helm`, caching remote bases under `.cache/kustomize/`).
   - Validates all rendered resources with `kubeconform -strict` (caching CRD schemas from Datree `CRDs-catalog` under `.cache/kubeconform/`) and `pluto detect-files --target-versions k8s=v1.37.0` to catch removed/deprecated Kubernetes APIs early.
5. **Opt-In Multi-Arch Image Manifest Verification (`linux/arm64`)**:
   When upgrading major/minor chart versions or changing image tags, verify online that all rendered container image manifests include `linux/arm64` via `crane`:
   ```bash
   make check.images
   ```

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
6. **Stage 6 (SSO & Workloads)**: `authelia` $\rightarrow$ `mosquitto` $\rightarrow$ `automqttion` $\rightarrow$ `reverselcn`

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
- **Symptom**: After reverting or fixing a broken image tag on a `StatefulSet` (e.g., `prometheus-alertmanager`), the `StatefulSet` remains wedged because `pod-0` is in `ImagePullBackOff` and Kubernetes `OrderedReady` policy refuses to recreate a non-Running pod when `currentRevision != updateRevision`.
- **Resolution** (requires user confirmation):
  ```bash
  kubectl delete pod -n <namespace> <statefulset-pod-0>
  ```
  The `StatefulSet` controller immediately recreates `<statefulset-pod-0>` using the updated `updateRevision` pod template.
