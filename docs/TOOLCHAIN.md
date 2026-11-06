# Sloth Operator Toolchain & Scripts

This document catalogs the local CLI prerequisites, [`makefile`](../makefile) targets, `kubeseal` secret generation scripts, and version audit utilities in `homecluster/sloth`.

---

## 1. Local CLI Prerequisites

Verify all required CLI binaries are installed locally via `make checkPrerequisites.all`:

| Binary | Purpose | Check Target |
|--------|---------|--------------|
| `kubectl` | Kubernetes cluster CLI (`context: sloth-root`) | `make checkPrerequisites.kubectl` |
| `helm` | Helm v3 chart rendering and bootstrap installation | `make checkPrerequisites.helm` |
| `yq` | YAML processor (extracts chart versions and inline values in [`makefile`](../makefile)) | `make checkPrerequisites.yq` |
| `jq` | JSON processor (transforms plaintext secrets into `kubeseal` inputs) | `make checkPrerequisites.jq` |
| `kubeseal` | Bitnami Sealed Secrets CLI for encrypting secrets against the cluster key | `make checkPrerequisites.kubeseal` |

---

## 2. Makefile Target Reference

[`makefile`](../makefile) provides bootstrap and day-2 operational targets for `sealed-secrets` and `argocd`:

| Target | Description |
|--------|-------------|
| `make checkPrerequisites.all` | Verify `kubectl`, `helm`, `yq`, and `kubeseal` are on `PATH`. |
| `make sealed-secrets.install` | Add `https://bitnami.github.io/sealed-secrets` and install the `sealed-secrets` chart into `kube-system` using the exact version declared in [`cluster-essentials/sealed-secrets.yaml`](../cluster-essentials/sealed-secrets.yaml). |
| `make sealed-secrets.seal.sshDeployKey` | Execute `./create-and-seal-deploy-key.sh` to generate and seal the GitHub SSH deploy key for Argo CD. |
| `make sealed-secrets.uninstall` | Uninstall `sealed-secrets` from `kube-system`. |
| `make argocd.install` | Extract `targetRevision` and `valuesObject` from `.spec.sources[0]` of [`argocd-base/argocd.yaml`](../argocd-base/argocd.yaml), install `argo-cd` via Helm, and apply `argocd-base/{project,argocd,cluster-essentials,deployments}.yaml`. |
| `make argocd.password` | Decode and print the initial `argocd-initial-admin-secret` password from namespace `argocd`. |
| `make argocd.port-forward` | Port-forward `svc/argocd-server` in `argocd` to `https://localhost:8080`. |
| `make argocd.uninstall` | Delete Argo CD Applications, AppProjects, Helm release, and `*.argoproj.io` CRDs. |

---

## 3. Secret Sealing Scripts (`create-and-seal-*.sh`)

> [!CAUTION]
> **Destructive / State-Rotating Scripts**: Running any `create-and-seal-*.sh` script generates fresh random keys or passwords and overwrites the committed `.sealed.json` file. Never run these scripts without explicit user confirmation. Plaintext intermediate files are written to `.secrets/` (which is gitignored).

| Script | Generated Plaintext (`.secrets/`) | Sealed Output Committed to Git | External Manual Step Required? |
|--------|-----------------------------------|--------------------------------|--------------------------------|
| [`create-and-seal-deploy-key.sh`](../create-and-seal-deploy-key.sh) | `.secrets/deploy_key` & `.secrets/deploy_key.pub` | [`argocd-base/repository.sealed.json`](../argocd-base/repository.sealed.json) | **Yes**: Add `.secrets/deploy_key.pub` as a Deploy Key on GitHub (`MyChaOS87/sloth`). |
| [`create-and-seal-gcloud-service-accounts.sh`](../create-and-seal-gcloud-service-accounts.sh) | `.secrets/gcloud-dns01-solver.key` & `.secrets/gcloud-external-dns.key` | [`cluster-essentials/cert-manager-issuer/gcloud-dns01-solver.sealed.json`](../cluster-essentials/cert-manager-issuer/gcloud-dns01-solver.sealed.json)<br/>[`cluster-essentials/external-dns/gcloud-external-dns.sealed.json`](../cluster-essentials/external-dns/gcloud-external-dns.sealed.json) | **Yes**: Creates GCP IAM service account keys in project `vogelherd` via `gcloud`. |
| [`create-and-seal-metallb-memberlist-secret.sh`](../create-and-seal-metallb-memberlist-secret.sh) | `.secrets/metallb-memberlist` | [`cluster-essentials/metallb-config/memberlist.sealed.json`](../cluster-essentials/metallb-config/memberlist.sealed.json) | No. |
| [`create-and-seal-oidc-secrets.sh`](../create-and-seal-oidc-secrets.sh) | `.secrets/keycloak-db-secret` & `.secrets/keycloak-admin-secret` | [`deployments/oidc/keycloak-secrets/keycloak-db-secret.sealed.json`](../deployments/oidc/keycloak-secrets/keycloak-db-secret.sealed.json)<br/>[`deployments/oidc/keycloak-secrets/keycloak-admin-secret.sealed.json`](../deployments/oidc/keycloak-secrets/keycloak-admin-secret.sealed.json) | No (for fresh DB; rotating DB password on existing Postgres volume requires matching `ALTER USER`). |
| [`create-and-seal-oidc-client-secrets.sh`](../create-and-seal-oidc-client-secrets.sh) | `.secrets/argocd-oidc-client-secret` & `.secrets/grafana-oidc-client-secret` | [`argocd-base/argocd-secrets/argocd-oidc-client-secret.sealed.json`](../argocd-base/argocd-secrets/argocd-oidc-client-secret.sealed.json)<br/>[`deployments/smarthome/grafana-secrets/grafana-oidc-client-secret.sealed.json`](../deployments/smarthome/grafana-secrets/grafana-oidc-client-secret.sealed.json) | **Yes**: Configure matching client secrets in Keycloak clients (`argocd` and `grafana`). |
| [`create-and-seal-smarthome-secrets.sh`](../create-and-seal-smarthome-secrets.sh) | `.secrets/influxdb-secret` & `.secrets/grafana-admin-secret` | [`deployments/smarthome/influxdb-secrets/influxdb-secret.sealed.json`](../deployments/smarthome/influxdb-secrets/influxdb-secret.sealed.json)<br/>[`deployments/smarthome/grafana-secrets/grafana-admin-secret.sealed.json`](../deployments/smarthome/grafana-secrets/grafana-admin-secret.sealed.json)<br/>[`deployments/smarthome/grafana-secrets/grafana-influxdb-secret.sealed.json`](../deployments/smarthome/grafana-secrets/grafana-influxdb-secret.sealed.json) | No (on initial setup; InfluxDB `admin-token` is shared across `influxdb`, `telegraf`, and `grafana`). |

---

## 4. Version Audit Script (`check-helm-chart-versions.sh`)

[`check-helm-chart-versions.sh`](../check-helm-chart-versions.sh) scans all Argo CD `Application` YAML manifests across `argocd-base/`, `cluster-essentials/`, and `deployments/` and compares their `targetRevision` against upstream Helm repositories and GitHub Releases:

```bash
./check-helm-chart-versions.sh
```

- **What it checks**:
  1. All external Helm charts (`spec.source.chart` and `spec.sources[].chart`), outputting `Current` vs `Latest` chart version and `AppVersion`.
  2. Local Helm charts (`deployments/smarthome/mosquitto/Chart.yaml`).
  3. Non-Helm GitHub releases (`rancher/system-upgrade-controller` tag in `cluster-essentials/system-upgrade.yaml`).
- **Execution Note**: Requires `BypassSandbox: true` because it runs `helm repo add/update` and queries `https://api.github.com`.
