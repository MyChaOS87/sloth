# Private Overlay Contract & Replication Guide

`sloth` separates **reusable cluster architecture** (public `MyChaOS87/sloth`) from **environment-specific private state** (private companion overlay repository `sloth-private`). This keeps real domains, cloud project IDs, encrypted `SealedSecret` manifests, and private workloads out of public Git history while keeping every Helm chart and Argo CD `Application` 100% declarative and reproducible.

---

## 1. Public vs. Private Responsibility Boundary

| Artifact | Repository | Purpose |
|----------|------------|---------|
| Core infrastructure & smarthome `Application` manifests, base Helm values, Grafana dashboards, MetalLB L2 pools (`192.168.1.30–99`), Kairos/DietPi node bootstrappers, sealing scripts | **`sloth` (Public HTTPS)** | Portable cluster architecture and operator tooling; uses `example.com` / `example-dns` in documentation and examples. |
| Real domain Helm overlays (`values/*.yaml`), Cert-Manager issuers/certs, ExternalDNS VIP records, all `*.sealed.json` manifests, SSH deploy key (`repository-private.sealed.json`), and `AppProject/private` workloads (`private/`) | **`sloth-private` (Private SSH)** | Environment-specific values injected via Argo CD Multi-Source `$private/values/<app>.yaml` or dedicated path sources. |
| Operator SSH public keys (`ssh-ed25519`), RFC 1918 LAN IPs (`192.168.1.0/24`) | **`sloth` (Public)** | Non-secret topology and cryptographic public keys retained directly in templates and node documentation. |

---

## 2. Expected Private Overlay Directory Contract

Clone your private overlay repository alongside `sloth` (by default `SLOTH_PRIVATE_DIR=../sloth-private`):

```text
sloth-private/
├── .gitignore
├── AGENTS.md                                                     # Paired-repository agent rules and rollout order
├── CONTEXT.md                                                    # Private domain context, overlay map, and secret inventory
├── blacklist.txt                                                 # Private tokens/regexes enforced by sloth lefthook hooks
├── argocd-base/
│   ├── private.yaml                                              # Root Application: private (path: private/)
│   ├── repository-private.sealed.json                            # Dedicated SSH deploy key for private overlay repo
│   └── argocd-secrets/
│       └── argocd-oidc-client-secret.sealed.json                 # Argo CD OIDC client secret
├── values/                                                       # Loaded BEFORE sloth inline values ($private/values/<app>.yaml)
│   ├── argocd.yaml                                               # configs.cm.{url,oidc.config}, server.ingress.{hostname,extraHosts,extraTls}
│   ├── authelia.yaml                                             # ingress.rulesOverride, configMap.{session,notifier,access_control,identity_providers.oidc}
│   ├── automqttion.yaml                                          # config (declarative MQTT automation rules)
│   ├── external-dns.yaml                                         # extraArgs (--google-project=..., --enable-legacy-annotation-prefix)
│   ├── grafana.yaml                                              # ingress.{hosts,tls}, grafana.ini.{server,auth.generic_oauth URLs}
│   ├── longhorn.yaml                                             # ingress.{host,tlsSecret}
│   ├── mosquitto.yaml                                            # service.annotations (external-dns hostnames)
│   ├── prometheus.yaml                                           # server.ingress.{hosts,tls}
│   └── victoria-metrics.yaml                                     # server.ingress.{hosts,tls}
├── cluster-essentials/
│   ├── cert-manager-config/
│   │   ├── certificates.yaml
│   │   ├── cluster-issuers.yaml
│   │   └── gcloud-dns01-solver.sealed.json
│   ├── external-dns-config/
│   │   ├── gcloud-external-dns.sealed.json
│   │   └── k8s-api-dns.yaml
│   └── metallb-config/
│       └── memberlist.sealed.json
├── deployments/
│   ├── oidc/
│   │   ├── authelia-secrets/
│   │   │   ├── authelia-secret.sealed.json
│   │   │   ├── authelia-jwks-secret.sealed.json
│   │   │   └── authelia-smtp-secret.sealed.json
│   │   └── authelia-config/
│   │       └── users-secret.yaml
│   └── smarthome/
│       └── grafana-secrets/
│           ├── grafana-oidc-client-secret.sealed.json
│           └── grafana-secret.sealed.json
└── private/
    └── private.yaml                                              # AppProject: private (wildcard namespaces/cluster resources)
```

Starter templates for every YAML file above live in [`examples/sloth-private/`](../examples/sloth-private/).

### Disjoint-Key Helm Precedence Rule
Argo CD passes inline `helm.values` (`sloth`) *after* `helm.valueFiles` (`$private/values/<app>.yaml`). Because Helm replaces YAML lists completely rather than appending to them:
* Never re-declare a list key in both files (e.g., `external-dns` `extraArgs` lives exclusively in `values/external-dns.yaml`).
* Keep private overlay keys (`hosts`, `host`, `tls`, `extraTls`, `rules`, `hostname`, `extraHosts`, `configs.cm`, `grafana.ini.server`, OAuth endpoint URLs, and ExternalDNS annotations) strictly disjoint from the base keys owned by `sloth`.
* `make check.manifests` ([`policy/overlays.rego`](../policy/overlays.rego) via `conftest`) statically enforces disjoint leaf/array keys between inline `helm.values` and `${SLOTH_PRIVATE_DIR}/values/<app>.yaml` whenever both declare keys under the same Helm path.

---

## 3. Private `AppProject` (`private`) for Isolated Workloads

`argocd-base/argocd-base.yaml` combines `sloth` (`argocd-base/`) and `sloth-private` (`argocd-base/`) via multi-source reconciliation:
1. `sloth-private/argocd-base/private.yaml` registers `Application/private` (`project: argocd-base`) pointing at `path: private`.
2. `sloth-private/private/private.yaml` defines `AppProject/private` permitting any destination namespace (`*`) and cluster resource (`*/*`).
3. Any additional `Application` YAML placed under `sloth-private/private/` (referencing `project: private`) is reconciled entirely from the private repo without appearing in public `sloth`.

---

## 4. Coordinating Changes Across Both Repositories

In steady state, all Git references pin `targetRevision: main`. Use the appropriate rollout order for cross-repo edits:

1. **Private-Only Changes** (`private/`, secrets rotation, ingress host additions):
   * Push `sloth-private` (`main`) only; no commit in `sloth` is required.
2. **Additive or Removal Changes**:
   * **Additions** (new `$private/values/<app>.yaml` file, new secret, new key): Push `sloth-private` (`main`) **first** (inert until referenced), then push `sloth` (`main`).
   * **Removals**: Remove the reference in `sloth` (`main`) **first**, wait for Argo CD to sync and prune, then delete the unused file from `sloth-private` (`main`).
3. **Lockstep / Breaking Schema Upgrades** (e.g., a major Helm chart upgrade renaming or restructuring keys inside `$private/values/<app>.yaml`):
   * Push the updated overlay structure to a staging branch or tag `sync/<topic>` in `sloth-private` while leaving `sloth-private` `main` untouched.
   * In a single atomic commit in `sloth`, bump both the Helm chart `targetRevision` and the `private` source `targetRevision: sync/<topic>`.
   * Verify all affected Argo CD `Application`s reach `Synced` + `Healthy`, then fast-forward `sloth-private` `main` $\leftarrow$ `sync/<topic>`, reset `targetRevision: main` in `sloth`, and delete `sync/<topic>`.

---

## 5. Replicating `sloth` on Your Own Domain & Cluster

1. **Fork `sloth` and create a private overlay repository** (e.g., `sloth-private`):
   * Copy [`examples/sloth-private/`](../examples/sloth-private/) into `../sloth-private` and replace `example.com`, `example-dns`, and `git@github.com:<you>/sloth-private.git` with your domain, DNS project ID, and private repo URL.
   * Update `repoURL` references in your fork of `sloth` to match your public fork and private overlay URLs.
2. **Create `.secrets/sloth.env`** (gitignored):
   ```bash
   SLOTH_PRIVATE_DIR="../sloth-private"
   PRIVATE_REPO_URL="git@github.com:<you>/sloth-private.git"
   CLUSTER_DOMAIN="example.com"
   GCP_PROJECT="example-dns"
   ```
3. **Bootstrap `sealed-secrets` and seal all secrets into `sloth-private`**:
   ```bash
   make sealed-secrets.install
   ./create-and-seal-deploy-key.sh
   ./create-and-seal-gcloud-service-accounts.sh
   ./create-and-seal-metallb-memberlist-secret.sh
   ./create-and-seal-authelia-secrets.sh
   ./create-and-seal-authelia-smtp-secret.sh
   ./create-and-seal-oidc-client-secrets.sh
   ./create-and-seal-smarthome-secrets.sh
   ```
   Also populate `../sloth-private/deployments/oidc/authelia-config/users-secret.yaml` with Argon2id hashes generated by `./create-authelia-user-hash.sh`, and paste the `$pbkdf2-sha512$...` OIDC client secret digests into `../sloth-private/values/authelia.yaml`.
   Register `../sloth-private/deploy_key.pub` as a read-only Deploy Key on your private overlay GitHub repository and push `sloth-private` (`main`).
4. **Install `lefthook` & validate the paired overlay before pushing**:
   ```bash
   make check
   ```
   This builds `.cache/bin/lefthook`, wires `.git/hooks/{pre-commit,commit-msg,pre-push}`, enforces the leak guard fail-closed against `../sloth-private/blacklist.txt`, and runs pinned Go linters from `tools/` alongside `helm`, `kubeconform`, and `pluto` across manifests.
5. **Install Argo CD and trigger GitOps reconciliation**:
   ```bash
   make argocd.install
   ```
   Argo CD immediately authenticates to `sloth-private` using `repository-private.sealed.json` and reconciles the entire cluster.
