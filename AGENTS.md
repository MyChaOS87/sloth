# Sloth Agent Guide

> **Executive Summary**: `sloth` (*SLightly Over-engineered "Trivial" Home automation*) is a GitOps-managed K3s high-availability Kubernetes cluster running on a 3-node Radxa Rock5B (`linux/arm64`) cluster. It reconciles core cluster infrastructure (Argo CD, Sealed Secrets, MetalLB, Traefik, Cert-Manager, ExternalDNS, Longhorn, System Upgrade Controller, Prometheus) and smarthome/SSO workloads (Keycloak, Mosquitto, Telegraf, InfluxDB, Grafana, Automqttion) via Argo CD's App-of-Apps pattern.

---

## Core Engineering Principles

1. **100% GitOps Reconciliation**: `main` is the single source of truth. All production workloads run with automated `syncPolicy` (`prune: true`, `selfHeal: true`). Never mutate cluster state out-of-band (`kubectl apply`, `kubectl patch`, `kubectl delete`) unless recovering a transient controller deadlock (e.g., stuck `OrderedReady` StatefulSet pod or corrupted `argocd-repo-server` `/tmp` cache) after explicit user confirmation.
2. **ARM64 Multi-Arch Discipline**: All nodes are `linux/arm64` (Radxa Rock5B RK3588). Every image and Helm chart upgrade must provide valid `linux/arm64` entries in its OCI manifest index.
3. **Sequential Storage & Control-Plane Safety**: Distributed block storage (`longhorn`) enforces strict sequential minor-version upgrades (`target_minor - current_minor <= 1`). Control-plane components (`sealed-secrets`, `argo-cd`) must be upgraded and healthy before upgrading downstream workloads.
4. **Encrypted Secrets at Rest**: All credentials, TLS/SSH keys, and cloud service accounts are stored as Bitnami `SealedSecret` manifests (`*.sealed.json`) encrypted against the cluster's `sealed-secrets` controller key.

---

## Knowledgebase Routing Table

Read the specific guide below that matches your current task before modifying any manifests or dashboards:

| Document | Scope & When to Read |
|----------|----------------------|
| [`CONTEXT.md`](./CONTEXT.md) | **Domain Glossary & Ubiquitous Language**: Hardware node inventory (`rock5b-but`, `rock5b-first`, `rock5b-coffee`), K3s HA control plane, App-of-Apps hierarchy (`argocd-base`, `cluster-essentials`, `deployments`), MetalLB IP pools (`192.168.1.30–99`), split-horizon DNS (`vogelherdweg.de`), SealedSecrets, and smarthome telemetry sources (Shelly Gen1/Plus/BLU, WARP2 Wallbox, Pluggit Modbus). |
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | **System Architecture**: 3-tier Argo CD App-of-Apps DAG, ingress/TLS/DNS architecture (MetalLB $\rightarrow$ Traefik $\rightarrow$ Cert-Manager + ExternalDNS on GCP Cloud DNS), Longhorn distributed block storage layout, and Smarthome MQTT/Modbus $\rightarrow$ Telegraf $\rightarrow$ InfluxDB $\rightarrow$ Grafana pipeline. |
| [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md) | **Manifest, Dashboard & Query Standards**: Argo CD `Application` single-source vs multi-source structure, `syncPolicy` rules, ExternalDNS & MetalLB annotations, Grafana dashboard ConfigMap conventions, high-contrast color palettes, and Flux query rules (telemetry gap protection, midnight alignment, legend naming). |
| [`docs/TESTING.md`](./docs/TESTING.md) | **Verification & GitOps Validation Tiers**: 3-tier validation model (Tier 1 offline `helm template` / `kubectl kustomize` / `yq` schema checks, Tier 2 staged Argo CD reconciliation & rollout checks, Tier 3 deep storage & runtime health verification), rollback playbook, and backlog tracking on GitHub Project #1. |
| [`docs/TOOLCHAIN.md`](./docs/TOOLCHAIN.md) | **Operator Toolchain & Scripts**: [`makefile`](./makefile) bootstrap/operations targets, `kubeseal` secret generation scripts (`create-and-seal-*.sh`), `check-helm-chart-versions.sh`, and local CLI requirements. |

---

## Git & Solo Linear-`main` Workflow

- **Repository Scope**: Always operate Git commands within `/home/kasch/projects/homecluster/sloth` (`git -C /home/kasch/projects/homecluster/sloth ...`).
- **Branching Strategy**: Work directly on `main` (or short-lived branches fast-forward merged into `main`) to maintain a clean linear history.
- **Pre-Commit Verification**: Always render modified Helm values or Kustomize overlays locally (`helm template` / `kubectl kustomize`) and verify `git diff` before committing.
- **No Unapproved Push**: **Never run `git push` without explicit user permission.** Because Argo CD tracks `HEAD` on `origin/main` with automated `syncPolicy`, pushing immediately mutates the live home cluster.

---

## Sandbox Execution Matrix (`BypassSandbox`)

| Command Category | `BypassSandbox` | Rationale |
|------------------|-----------------|-----------|
| `git status`, `git diff`, `git log`, `git add`, `git commit` | `false` | Local workspace repository operations run cleanly inside the standard sandbox. |
| `yq`, `jq`, Python/shell YAML inspection | `false` | Pure local file processing requires no network or external cluster access. |
| `kubectl` (any read or write against `sloth-root` `192.168.1.21:6443`) | `true` | Requires LAN network access and access to `~/.kube/config`. |
| `helm repo add/update`, `helm search repo`, `helm template` (remote chart) | `true` | Requires network access to upstream Helm registries and `~/.cache/helm`. |
| `git push`, `git fetch`, `git ls-remote` | `true` | Requires SSH/HTTPS network access to GitHub (`git@github.com:MyChaOS87/sloth.git`). |
| `./check-helm-chart-versions.sh` | `true` | Queries upstream Helm indices and GitHub Releases API over HTTPS. |

> [!TIP]
> **Keep Commands Prefix-Matchable**: Never chain sandboxed steps (`git add`, `git commit`) with unsandboxed steps (`git push`, `kubectl`) using `&&`, `;`, or process substitutions (`<(...)`). Run `git add` and `git commit` inside the sandbox (`BypassSandbox: false`), and run `git push` or `kubectl` as single standalone commands with `BypassSandbox: true`.

---

## Agent Hazards (Do Not Do)

1. **Never push to `origin/main` without asking first** — Argo CD reconciles `HEAD` automatically and will immediately roll out changes to live home infrastructure.
2. **Never skip Longhorn minor versions** — The `longhorn-pre-upgrade` job rejects upgrades where `target_minor - current_minor > 1` (e.g., `1.11.x` $\rightarrow$ `1.13.x` must step through `1.12.x` and wait for `current-longhorn-version` to settle).
3. **Never verify `kubectl` commands without checking the context** — Ensure the active context is `sloth-root` (`kubectl config current-context`).
4. **Never mutate cluster state manually (`kubectl apply/patch/delete`) without permission** — Let Argo CD reconcile declared state from Git.
5. **Never regenerate `*.sealed.json` secrets without explicit confirmation** — The `create-and-seal-*.sh` scripts generate new random credentials/keys that overwrite existing production secrets and require manual external reconfiguration (e.g., GitHub deploy keys, GCP service account keys, OIDC client secrets).
6. **Never commit unencrypted secret files** — Plaintext intermediates in `.secrets/` are gitignored and must never be staged or committed.
7. **Never use `integral()` in Grafana Flux queries without gap-filling first** — Always precede `integral(unit: 1h)` with `aggregateWindow(every: 1m, fn: mean, createEmpty: false)` and `fill(usePrevious: true)` to prevent Telegraf pod restarts from causing massive linear interpolation spikes.
8. **Never assume upstream container tags support `linux/arm64` blindly** — Verify multi-arch manifest lists when bumping major/minor chart versions (see `MyChaOS87/.projects#23` regarding `prometheus-operator` `v0.95.1`).
