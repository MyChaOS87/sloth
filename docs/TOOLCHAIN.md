# Sloth Operator Toolchain & Scripts

This document catalogs the local CLI prerequisites, [`makefile`](../makefile) targets, `kubeseal` secret generation scripts, and version audit utilities in `sloth`.

---

## 1. Local CLI Prerequisites

Verify all required CLI binaries are installed locally via `make checkPrerequisites.all`:

| Binary | Purpose | Check Target |
|--------|---------|--------------|
| `kubectl` | Kubernetes cluster CLI (`context: sloth-root`) and `kustomize --enable-helm` renderer | `make checkPrerequisites.kubectl` |
| `helm` | Helm v3 chart rendering, linting, and bootstrap installation | `make checkPrerequisites.helm` |
| `yq` | YAML processor (extracts chart versions, inline values, and overlay JSON for policy/render checks) | `make checkPrerequisites.yq` |
| `jq` | JSON processor (transforms plaintext secrets and inspects rendered manifest images) | `make checkPrerequisites.jq` |
| `kubeseal` | Bitnami Sealed Secrets CLI for encrypting secrets against the cluster key | `make checkPrerequisites.kubeseal` |
| `go` | Runs pinned Go linters via `go tool` from `tools/<tool>/` cached in `$GOCACHE`, and builds `.cache/bin/lefthook` | `make hooks.install` |

Pinned GitOps tools live in isolated per-tool modules under [`tools/`](../tools/) (`lefthook`, `yamlfmt`, `conftest`, `kubeconform`, `pluto`, `gitleaks`, `crane`, `commitlint`) declared via Go `tool` directives in each `go.mod` (no `dummy.go` blank-import files) and run via Go's native `$GOCACHE`-backed `go tool` mechanism (shared by `sloth-private` via `SLOTH_DIR`); only `lefthook` is compiled to `.cache/bin/lefthook` for `.git/hooks/*`. Indirect dependency CVEs inside `tools/<tool>/go.mod` are patched surgically via version-pinned `replace <mod> <old> => <mod> <new> // fix <CVE>` directives rather than blind transitive upgrades.

---

## 2. Makefile Target Reference

[`makefile`](../makefile) provides bootstrap, validation, leak-guard, and day-2 operational targets for `sealed-secrets`, `lefthook`, linters, and `argocd`:

| Target | Description |
|--------|-------------|
| `make checkPrerequisites.all` | Verify `kubectl`, `helm`, `yq`, `jq`, and `kubeseal` are on `PATH`, and invoke `make hooks.install` to build `.cache/bin/lefthook` + install Git hooks. |
| `make hooks.install` | Build `.cache/bin/lefthook` from [`tools/lefthook`](../tools/lefthook/go.mod) and install hooks for `pre-commit`, `commit-msg`, and `pre-push`. |
| `make tools-tidy` | Run `go mod tidy` across every module under [`tools/`](../tools/). |
| `make tools-update` | Normalize each [`tools/`](../tools/) `go.mod` Go version (`major.minor`, dropping any `toolchain` line), query each module's `tool` directive via `go mod edit -json`, upgrade only those tool packages (`go get <tool>@latest` without `-u`), and run `go mod tidy`. |
| `make fmt` | Normalize YAML formatting across repository manifests in place via `yamlfmt` ([`.yamlfmt.yml`](../.yamlfmt.yml)). |
| `make check.blacklist` | Run [`scripts/check-blacklist.sh`](../scripts/check-blacklist.sh) `--all` across working-tree files, Git author/committer identities, and all reachable Git commits. |
| `make check.guard` | Run `gitleaks` ([`.gitleaks.toml`](../.gitleaks.toml)) across full Git history and working-tree changes (`--pre-commit`). |
| `make check.guard.staged` | Run `gitleaks --staged` against staged changes prior to committing. |
| `make check.yaml` | Verify YAML formatting without modifying files (`yamlfmt -lint`). |
| `make check.manifests` | Validate raw Kubernetes manifests, `.sealed.json` rules, Argo CD Application contracts, JSON ConfigMaps, and disjoint `helm.values` vs `${SLOTH_PRIVATE_DIR}/values/*.yaml` keys via `conftest` ([`policy/`](../policy/)). |
| `make check.helm` | Run [`scripts/check-helm.sh`](../scripts/check-helm.sh): `helm lint --strict` on local charts, plus cached `helm template` and `kubectl kustomize --enable-helm` rendering into `kubeconform -strict` and `pluto detect-files`. |
| `make check.images` | Opt-in online check ([`scripts/check-images.sh`](../scripts/check-images.sh)) inspecting rendered container images via `crane config --platform linux/arm64` (excluded from `make check` and Git hooks). |
| `make check` | Full pre-push validation gate: installs hooks, then runs `check.blacklist`, `check.guard`, `check.yaml`, `check.manifests`, and `check.helm`. |
| `make check.commit-msg` | Standalone conventional commit format check ([`.commitlint.yaml`](../.commitlint.yaml) via `commitlint`; pass `COMMIT_MSG_FILE=...` to check a specific message file, otherwise inspects `HEAD`; excluded from `make check`). |
| `make sealed-secrets.install` | Add `https://bitnami.github.io/sealed-secrets` and install the `sealed-secrets` chart into `sealed-secrets` using the exact version declared in [`cluster-essentials/sealed-secrets.yaml`](../cluster-essentials/sealed-secrets.yaml). |
| `make sealed-secrets.seal.sshDeployKey` | Execute `./create-and-seal-deploy-key.sh` to generate and seal the GitHub SSH deploy key for Argo CD. |
| `make sealed-secrets.uninstall` | Uninstall `sealed-secrets` from `sealed-secrets`. |
| `make argocd.install` | Extract `targetRevision` and inline `values` from `.spec.sources[0]` of [`argocd-base/argocd.yaml`](../argocd-base/argocd.yaml) (cleaning temporary `.argocd.values.yaml` via `EXIT` trap), install `argo-cd` via Helm alongside `$(SLOTH_PRIVATE_DIR)/values/argocd.yaml`, and apply `$(SLOTH_PRIVATE_DIR)/argocd-base/repository-private.sealed.json` before [`argocd-base/argocd-base.yaml`](../argocd-base/argocd-base.yaml). |
| `make argocd.password` | Decode and print the initial `argocd-initial-admin-secret` password from namespace `argocd`. |
| `make argocd.port-forward` | Port-forward `svc/argocd-server` in `argocd` to `http://localhost:8080`. |
| `make argocd.uninstall` | Delete Argo CD Applications, AppProjects, Helm release, and `*.argoproj.io` CRDs. |

---

## 3. Secret Sealing Scripts (`create-and-seal-*.sh`)

> [!CAUTION]
> **Destructive / State-Rotating Scripts**: Running any `create-and-seal-*.sh` script generates fresh random keys or passwords and refuses to overwrite an existing `.sealed.json` output (`assert_no_overwrite`). Plaintext intermediate files and `.secrets/sloth.env` live in `.secrets/` (gitignored), while sealed outputs are written directly into `SLOTH_PRIVATE_DIR` (default `../sloth-private`, configurable via `.secrets/sloth.env`).

| Script | Generated Plaintext (`.secrets/`) | Sealed Output Written to `${SLOTH_PRIVATE_DIR}` | External Manual Step Required? |
|--------|-----------------------------------|-------------------------------------------------|--------------------------------|
| [`create-and-seal-deploy-key.sh`](../create-and-seal-deploy-key.sh) | Temporary `ed25519` keypair | `argocd-base/repository-private.sealed.json`<br/>`deploy_key.pub` | **Yes**: Add `${SLOTH_PRIVATE_DIR}/deploy_key.pub` as a read-only Deploy Key on your private overlay GitHub repo. |
| [`create-and-seal-gcloud-service-accounts.sh`](../create-and-seal-gcloud-service-accounts.sh) | Temporary `.secrets/gcloud-*.key.json` & `.json` (cleaned up on exit) | `cluster-essentials/cert-manager-config/gcloud-dns01-solver.sealed.json`<br/>`cluster-essentials/external-dns-config/gcloud-external-dns.sealed.json` | **Yes**: Creates GCP IAM service account keys in `GCP_PROJECT` (from `.secrets/sloth.env` or prompt, e.g. `example-dns`) via `gcloud`. |
| [`create-and-seal-metallb-memberlist-secret.sh`](../create-and-seal-metallb-memberlist-secret.sh) | Generated inline (`openssl rand`) | `cluster-essentials/metallb-config/memberlist.sealed.json` | No. |
| [`create-and-seal-authelia-secrets.sh`](../create-and-seal-authelia-secrets.sh) | Generated inline (`openssl`) | `deployments/oidc/authelia-secrets/authelia-secret.sealed.json`<br/>`deployments/oidc/authelia-secrets/authelia-jwks-secret.sealed.json` | No (4 HMAC/encryption keys + 4096-bit RSA OIDC JWKS key). |
| [`create-and-seal-authelia-smtp-secret.sh`](../create-and-seal-authelia-smtp-secret.sh) | Interactive password prompt | `deployments/oidc/authelia-secrets/authelia-smtp-secret.sealed.json` | **Yes**: Enter outbound SMTP password for Authelia notification emails. |
| [`create-and-seal-oidc-client-secrets.sh`](../create-and-seal-oidc-client-secrets.sh) | Interactive or `openssl rand` | `argocd-base/argocd-secrets/argocd-oidc-client-secret.sealed.json`<br/>`deployments/smarthome/grafana-secrets/grafana-oidc-client-secret.sealed.json` | **Yes**: Paste the printed `$pbkdf2-sha512$...` digests into `${SLOTH_PRIVATE_DIR}/values/authelia.yaml`. |
| [`create-authelia-user-hash.sh`](../create-authelia-user-hash.sh) | Interactive password prompt (not sealed; printed to stdout) | None (operator copies `$argon2id$...` into `${SLOTH_PRIVATE_DIR}/deployments/oidc/authelia-config/users-secret.yaml`) | **Yes**: Paste user hash into `users-secret.yaml`. |
| [`create-and-seal-smarthome-secrets.sh`](../create-and-seal-smarthome-secrets.sh) | Generated inline (`openssl rand`) | `deployments/smarthome/grafana-secrets/grafana-secret.sealed.json` | No. |

---

## 4. Node Provisioning (`node-bootstrap/`)

| File | Target Hardware | Purpose |
|------|-----------------|---------|
| [`node-bootstrap/rock5b/cloud-config.yaml.tpl`](../node-bootstrap/rock5b/cloud-config.yaml.tpl) | Radxa Rock 5B (`rock5b-but`, `rock5b-first`, `rock5b-coffee`, Kairos Linux `arm64`) | Declarative Kairos `cloud-config.yaml` template configuring `kasch` SSH access, static IPv4 (`192.168.1.21–23`), persistent Longhorn `diskUUID` preservation on `COS_PERSISTENT`, and K3s HA control-plane join (`https://192.168.1.20:6443`); hardware DTB/SPI sync hooks come baked into the `kairos-rock5b` image (`/system/oem/20_rock5b_hardware.yaml`). |
| [`node-bootstrap/rock5b/render-node-config.sh`](../node-bootstrap/rock5b/render-node-config.sh) | Radxa Rock 5B (`rock5b-but`, `rock5b-first`, `rock5b-coffee`) | Renders `node-bootstrap/rock5b/build/<node>-cloud-config.yaml` (`0600`) by injecting the node's IP, preserved Longhorn `diskUUID`, `CLUSTER_DOMAIN`, and `K3S_TOKEN` from `.secrets/rock5b.env` / `.secrets/sloth.env`. |
| [`node-bootstrap/pi0-lcn/prepare-boot.sh`](../node-bootstrap/pi0-lcn/prepare-boot.sh) | Raspberry Pi Zero 2 W (`pi0-lcn`, DietPi 64-bit `ARMv8` Trixie) | Populates a mounted DietPi SD card boot partition interactively (or from an optional `.secrets/pi0-lcn.env`) with `config.txt`, `cmdline.txt`, `dietpi.txt`, `dietpi-wifi.txt`, `99-lcn-pku.rules`, `playbook.yml`, `k3s-vars.yml`, and `Automation_Custom_Script.sh`. |
| [`node-bootstrap/pi0-lcn/playbook.yml`](../node-bootstrap/pi0-lcn/playbook.yml) | Raspberry Pi Zero 2 W (`pi0-lcn`, DietPi 64-bit `ARMv8` Trixie) | Idempotent Ansible playbook (`ansible-core` / `ansible.builtin.*`) executed both locally on first boot (`ansible-playbook --connection=local -i localhost, -e @/boot/firmware/k3s-vars.yml /boot/firmware/playbook.yml`) and remotely over SSH on Day 2 (`ansible-playbook -i pi0-lcn, -u kasch --become node-bootstrap/pi0-lcn/playbook.yml`). Configures `sshd`, user `kasch` (`sudo` + `dialout`), `/dev/lcn-pku` udev rules, containerd v3 USB serial cgroup drop-in (`config-v3.toml.d/10-serial.toml`), and K3s agent (`taint: dedicated=lcn-serial:NoExecute`, 512 MB RAM reservations). Node role labels (`lcn-serial`, `monitoring`) are managed declaratively via [`nodes/pi0-lcn.yaml`](../nodes/pi0-lcn.yaml). |

---

## 5. Version Audit Script (`check-helm-chart-versions.sh`)

[`check-helm-chart-versions.sh`](../check-helm-chart-versions.sh) queries live Argo CD `Application` resources in namespace `argocd` via `kubectl` and compares each deployed Helm chart's `targetRevision` against upstream repositories:

```bash
./check-helm-chart-versions.sh
```

- **What it checks**:
  1. HTTP(S) Helm chart references (`spec.source.chart` and `spec.sources[].chart`), queried via `helm repo add --force-update temp-repo ...` and `helm search repo -o json`.
  2. OCI Helm chart references, queried via `helm show chart oci://...`.
  3. Prints `OK` or `Outdated` while normalizing leading `v` prefixes on both versions (for example `cert-manager` `v1.21.3`). For per-image ARM64 checks, use `make check.images`.

---

## 6. Leak Guard & Git Hooks (`lefthook.yml`, `.gitleaks.toml` & `scripts/check-blacklist.sh`)

[`lefthook.yml`](../lefthook.yml) wires [`scripts/check-blacklist.sh`](../scripts/check-blacklist.sh), `gitleaks` ([`.gitleaks.toml`](../.gitleaks.toml)), and the local `yamlfmt` / `conftest` / `helm` gates across Git hook stages:

* **`pre-commit`**: Runs `scripts/check-blacklist.sh --warn --staged` plus warn-only `make check.guard.staged`, `make check.yaml`, and `make check.manifests` so local/worktree WIP commits are never blocked while surfacing format, secret, and policy issues early.
* **`commit-msg`**: Runs `scripts/check-blacklist.sh --warn --commit-msg <file>` and `make check.commit-msg COMMIT_MSG_FILE=<file>` (both warn clearly and exit `0`).
* **`pre-push`**: Strictly enforces `scripts/check-blacklist.sh --pre-push` (`exit 1` on violations, `exit 2` fail-closed if `blacklist.txt` is missing) and runs `make check` (`check.blacklist`, `check.guard`, `check.yaml`, `check.manifests`, `check.helm`).
* **`make check.blacklist`**: Strictly scans working-tree files, Git author/committer identities, and all reachable commits across history via `--all`.
* **`make check.guard`**: Runs `gitleaks git` across full repository history and working-tree changes (`--pre-commit`).

Rules enforced:
1. **Private Blacklist (`${SLOTH_PRIVATE_DIR}/blacklist.txt`)**: Loaded fail-closed (errors explicitly with `CONFIGURATION ERROR (FAIL-CLOSED)` if missing or empty unless `SLOTH_ALLOW_MISSING_BLACKLIST=1` is set). Supports case-insensitive literal lines and `regex:<pattern>` rules across file paths, file contents, Git author/committer headers, and commit messages.
2. **Forbidden `.env` Files (`FORBIDDEN_ENV_FILE`)**: Blocks committing `.env`, `.env.*`, or `*.env` files (such as `.secrets/sloth.env`, `.secrets/rock5b.env`, `.secrets/pi0-lcn.env`).
3. **No User Home Paths (`HOME_PATH_LEAK`)**: Blocks hardcoded Linux home-directory paths across file paths, file contents, commit messages, and full Git history.
