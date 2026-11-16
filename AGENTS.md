# Sloth Agent Guide

> **Executive Summary**: `sloth` (*SLightly Over-engineered "Trivial" Home automation*) is a GitOps-managed K3s high-availability Kubernetes cluster running on a 3-node Radxa Rock5B (`linux/arm64`) control-plane/storage cluster plus a dedicated Raspberry Pi Zero 2 W (`pi0-lcn`, `linux/arm64`) edge serial node. It reconciles core cluster infrastructure (Argo CD, Sealed Secrets, Declarative Nodes, MetalLB, Traefik, Cert-Manager, ExternalDNS, Longhorn, System Upgrade Controller, Kairos Operator, Prometheus) and smarthome/SSO workloads (Authelia, Mosquitto, Telegraf, VictoriaMetrics, Grafana, Automqttion, reverseLCN) via Argo CD's App-of-Apps pattern.

---

## Core Engineering Principles

1. **100% GitOps Reconciliation**: `main` is the single source of truth. All production workloads run with automated `syncPolicy` (`prune: true`, `selfHeal: true`). Never mutate cluster state out-of-band (`kubectl apply`, `kubectl patch`, `kubectl delete`) unless recovering a transient controller deadlock (e.g., stuck `OrderedReady` StatefulSet pod or corrupted `argocd-repo-server` `/tmp` cache) after explicit user confirmation.
2. **ARM64 Multi-Arch Discipline**: All nodes are `linux/arm64` (Radxa Rock5B RK3588 and Raspberry Pi Zero 2 W BCM2710A1). Every image and Helm chart upgrade must provide valid `linux/arm64` entries in its OCI manifest index.
3. **Sequential Storage & Control-Plane Safety**: Distributed block storage (`longhorn`) enforces strict sequential minor-version upgrades (`target_minor - current_minor <= 1`). Control-plane components (`sealed-secrets`, `argo-cd`) must be upgraded and healthy before upgrading downstream workloads.
4. **Encrypted Secrets at Rest & Private Overlay Split**: All credentials, TLS/SSH keys, and cloud service accounts are sealed by `create-and-seal-*.sh` as Bitnami `SealedSecret` manifests (`*.sealed.json`) into the companion private repository (`sloth-private` at `SLOTH_PRIVATE_DIR=../sloth-private`). Public `sloth` holds architecture, base Helm values, sealing scripts, and `example.com` examples; real domains, GCP project IDs, `*.sealed.json` files, and `AppProject: private` workloads live exclusively in `sloth-private` (see [`docs/PRIVATE_OVERLAY.md`](./docs/PRIVATE_OVERLAY.md)).
5. **Mandatory Post-Change Cluster Monitoring**: Whenever any change is pushed to `origin/main` (or applied to the cluster), you **must** actively monitor the live cluster (`kubectl get applications -n argocd`, pod rollouts, DaemonSet scheduling, and `system-upgrade` jobs/plans) until all affected Argo CD Applications reach `Synced` + `Healthy` and all rollout/upgrade pods settle cleanly without errors or crash loops. Never consider a task complete immediately after `git push`.

---

## Paired-Repository Contract & Planning Rules (`sloth` + `sloth-private`)

1. **Both Repositories Form One System**: `sloth` (this public architecture repo) and `sloth-private` (at `SLOTH_PRIVATE_DIR`, default `../sloth-private`) belong together. Whenever working in `sloth`, agents **must** also read `${SLOTH_PRIVATE_DIR}/AGENTS.md` and `${SLOTH_PRIVATE_DIR}/CONTEXT.md` and enforce **both** repositories' rules simultaneously (disjoint Helm keys, `blacklist.txt` maintenance, secret sealing discipline, and ARM64/Longhorn/MetricsQL rules).
2. **Mandatory Per-Repository Plan Split**: Every implementation plan touching the cluster **must** explicitly partition changes into clearly labeled sections:
   * **Public Repository (`sloth`)** — portable manifests, disjoint base Helm values, scripts, hooks, `example.com` / `example-dns` docs and examples
   * **Private Repository (`sloth-private`)** — `values/*.yaml` domain/project overlays, `*.sealed.json` secrets, `blacklist.txt` updates, `private/` workloads
   * **Coordinated Rollout & Sync Order** — exact push order (`sloth-private` first vs. `sloth` first vs. `sync/<topic>` staging) and live Argo CD reconciliation checks.
3. **Fail-Closed Leak Guard (`lefthook` + `blacklist.txt`)**: `lefthook` runs [`scripts/check-blacklist.sh`](./scripts/check-blacklist.sh) across all three stages against `${SLOTH_PRIVATE_DIR}/blacklist.txt` plus no-`.env`-file and user-home-path guards (`pre-commit` and `commit-msg` run with `--warn` so local and worktree commits emit clear warnings without failing, whereas `pre-push` and `make check` strictly block violations and fail closed if `blacklist.txt` is missing). Run `make check` (which also ensures `lefthook` and git hooks are installed) before pushing.

---

## Knowledgebase Routing Table

Read the specific guide below that matches your current task before modifying any manifests or dashboards:

| Document | Scope & When to Read |
|----------|----------------------|
| [`CONTEXT.md`](./CONTEXT.md) | **Domain Glossary & Ubiquitous Language**: Hardware node inventory (`rock5b-but`, `rock5b-first`, `rock5b-coffee`, `pi0-lcn`), declarative node roles (`storage`, `speaker`, `monitoring`, `lcn-serial`), K3s HA control plane, App-of-Apps hierarchy (`argocd-base`, `nodes`, `cluster-essentials`, `deployments`, `private`), MetalLB IP pools (`192.168.1.30–99`), split-horizon DNS (`example.com`), SealedSecrets, and smarthome telemetry/bus sources (Shelly Gen1/Plus/BLU, WARP2 Wallbox, Pluggit Modbus, LCN-PKU serial via `reverseLCN`). |
| [`docs/PRIVATE_OVERLAY.md`](./docs/PRIVATE_OVERLAY.md) | **Private Overlay Contract & Multi-Repo Sync Protocol**: Exact file layout of `sloth-private`, disjoint-key Helm merge rules (`$private/values/<app>.yaml`), `AppProject: private` usage, 3-case multi-repo rollout order (`main` steady state vs. `sync/<topic>` staging), and domain replication steps (paired with [`examples/sloth-private/`](./examples/sloth-private/)). |
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | **System Architecture**: 3-tier Argo CD App-of-Apps DAG, two-repo public/private overlay flow, declarative node role scheduling (`storage`, `speaker`, `monitoring`, `lcn-serial`) & rolling OS/K3s upgrades, ingress/TLS/DNS architecture (MetalLB $\rightarrow$ Traefik $\rightarrow$ Cert-Manager + ExternalDNS on GCP Cloud DNS), Longhorn distributed block storage layout, and Smarthome LCN/MQTT/Modbus $\rightarrow$ Telegraf (HA) $\rightarrow$ VictoriaMetrics $\rightarrow$ Grafana pipeline. |
| [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md) | **Manifest, Dashboard & Query Standards**: Argo CD `Application` single-source vs multi-source structure, disjoint-key overlay rules, `syncPolicy` rules, ExternalDNS & MetalLB annotations, Grafana dashboard ConfigMap conventions, high-contrast color palettes, and MetricsQL query rules (telemetry gap protection with `integrate(keep_last_value(avg_over_time(...)))`, multi-generation meter bridging, hardware-replacement aggregation). |
| [`docs/TESTING.md`](./docs/TESTING.md) | **Verification & GitOps Validation Tiers**: 3-tier validation model (Tier 1 automated `make check` pipeline via `gitleaks`, `yamlfmt`, `conftest`, `helm`, `kubeconform`, and `pluto`, plus opt-in `make check.images` multi-arch verification, Tier 2 staged Argo CD reconciliation & rollout checks, Tier 3 deep storage & runtime health verification), rollback playbook. |
| [`docs/TOOLCHAIN.md`](./docs/TOOLCHAIN.md) | **Operator Toolchain & Scripts**: [`makefile`](./makefile) bootstrap/linting/validation targets, isolated Go linter modules under [`tools/`](./tools/), `kubeseal` secret generation scripts (`create-and-seal-*.sh` outputting to `${SLOTH_PRIVATE_DIR}`), `check-helm-chart-versions.sh`, and local CLI requirements. |
| [`docs/hardware/`](./docs/hardware/) | **Hardware & Node Bootstrap Guides**: [CM4 Single Node (Historic)](./docs/hardware/cm4-single-node.md), [Radxa Rock 5B HA Cluster & Kernel Switches](./docs/hardware/rock5b-cluster.md), and [Raspberry Pi Zero 2 W Edge Node (`pi0-lcn`) 512 MB RAM Hardening](./docs/hardware/pi0-lcn.md). |

---

## Git & Solo Linear-`main` Workflow

- **Branching Strategy**: Work directly on `main` (or short-lived branches fast-forward merged into `main`) to maintain a clean linear history.
- **Pre-Commit Verification**: Run `make check` (`check.blacklist`, `check.guard`, `check.yaml`, `check.manifests`, and `check.helm` across `gitleaks`, `yamlfmt`, `conftest`, `helm`, `kubeconform`, and `pluto`) and review `git diff` before committing; run `make check.images` when modifying image tags or upgrading charts to verify `linux/arm64` support via `crane`.
- **Coordinated Two-Repo Updates (`sloth` $\leftrightarrow$ `sloth-private`)**: Keep `targetRevision: main` in steady state; push additive changes to `sloth-private` before `sloth`, push removals to `sloth` before `sloth-private`, and use a temporary `sync/<topic>` branch/tag in `sloth-private` whenever a chart upgrade breaks existing `$private/values/<app>.yaml` keys (see [`docs/PRIVATE_OVERLAY.md`](./docs/PRIVATE_OVERLAY.md)).
- **No Unapproved Push**: **Never run `git push` without explicit user permission.** Because Argo CD tracks `HEAD` on `origin/main` with automated `syncPolicy`, pushing immediately mutates the live home cluster.
- **Post-Push Live Verification**: After every approved `git push`, refresh and monitor Argo CD applications (`kubectl get applications -n argocd -o wide`), workload rollouts, and upgrade plans until the cluster is `Synced` and `Healthy`.

---

## Agent Hazards (Do Not Do)

1. **Never push to `origin/main` without asking first** — Argo CD reconciles `HEAD` automatically and will immediately roll out changes to live home infrastructure.
2. **Never skip Longhorn minor versions** — The `longhorn-pre-upgrade` job rejects upgrades where `target_minor - current_minor > 1` (e.g., `1.11.x` $\rightarrow$ `1.13.x` must step through `1.12.x` and wait for `current-longhorn-version` to settle).
3. **Never verify `kubectl` commands without checking the context** — Ensure the active context is `sloth-root` (`kubectl config current-context`).
4. **Never mutate cluster state manually (`kubectl apply/patch/delete`) without permission** — Let Argo CD reconcile declared state from Git.
5. **Never regenerate `*.sealed.json` secrets without explicit confirmation** — The `create-and-seal-*.sh` scripts generate new random credentials/keys that overwrite existing production secrets and require manual external reconfiguration (e.g., GitHub deploy keys, GCP service account keys, OIDC client secrets).
6. **Never commit unencrypted secret files** — Plaintext intermediates in `.secrets/` are gitignored and must never be staged or committed.
7. **Never use raw metrics inside `integrate(keep_last_value(...)[range:step])` subqueries without `avg_over_time(...[step])`** — Always average raw samples across each subquery step (`integrate(keep_last_value(avg_over_time(m[1m]))[14d:1m]) / 3600`) so brief sub-minute appliance pulses (`wasser`, `kaffee`) are integrated accurately while sparse sensor gaps remain forward-filled.
8. **Never assume upstream container tags support `linux/arm64` blindly** — Always verify multi-arch manifest lists (via `make check.images`) when bumping chart versions. Note: [`cluster-essentials/prometheus.yaml`](./cluster-essentials/prometheus.yaml) is intentionally pinned to `29.41.0` (`v0.94.2`) until `prometheus-community/prometheus` adopts `prometheus-config-reloader >= v0.95.2` (`v0.95.1` lacks `linux/arm64` manifests; see `prometheus-operator/prometheus-operator#8953`).
9. **Never bypass `lefthook` (`--no-verify`)** — Fix any leak reported by `make check` / `lefthook`, and add newly created private domains, hostnames, project IDs, or private `Application` names to `${SLOTH_PRIVATE_DIR}/blacklist.txt` before adding corresponding tooling or references.
