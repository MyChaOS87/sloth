# Sloth Operator Toolchain & Scripts

This document catalogs the local CLI prerequisites, [`makefile`](../makefile) targets, `kubeseal` secret generation scripts, and version audit utilities in `sloth`.

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
| `lefthook` | Git hook runner enforcing the `sloth-private/blacklist.txt` leak guard (auto-installed via `go install github.com/evilmartians/lefthook/v2@latest` when missing) | `make hooks.install` |

---

## 2. Makefile Target Reference

[`makefile`](../makefile) provides bootstrap, leak-guard, and day-2 operational targets for `sealed-secrets`, `lefthook`, and `argocd`:

| Target | Description |
|--------|-------------|
| `make checkPrerequisites.all` | Verify `kubectl`, `helm`, `yq`, `jq`, and `kubeseal` are on `PATH`, and invoke `make hooks.install` to install `lefthook` (via `go install` if missing) + Git hooks. |
| `make hooks.install` | Install `github.com/evilmartians/lefthook/v2@latest` via `go install` if `lefthook` is missing, then run `lefthook install` for `pre-commit`, `commit-msg`, and `pre-push`. |
| `make check` | Ensure hooks are installed (`hooks.install`), then run `./scripts/check-blacklist.sh --all` across working-tree files (tracked + non-ignored untracked) and all reachable Git commits. |
| `make sealed-secrets.install` | Add `https://bitnami.github.io/sealed-secrets` and install the `sealed-secrets` chart into `kube-system` using the exact version declared in [`cluster-essentials/sealed-secrets.yaml`](../cluster-essentials/sealed-secrets.yaml). |
| `make sealed-secrets.seal.sshDeployKey` | Execute `./create-and-seal-deploy-key.sh` to generate and seal the GitHub SSH deploy key for Argo CD. |
| `make sealed-secrets.uninstall` | Uninstall `sealed-secrets` from `kube-system`. |
| `make argocd.install` | Extract `targetRevision` and inline `values` from `.spec.sources[0]` of [`argocd-base/argocd.yaml`](../argocd-base/argocd.yaml), install `argo-cd` via Helm alongside `$(SLOTH_PRIVATE_DIR)/values/argocd.yaml`, and apply [`argocd-base/argocd-base.yaml`](../argocd-base/argocd-base.yaml) + `$(SLOTH_PRIVATE_DIR)/argocd-base/repository-private.sealed.json`. |
| `make argocd.password` | Decode and print the initial `argocd-initial-admin-secret` password from namespace `argocd`. |
| `make argocd.port-forward` | Port-forward `svc/argocd-server` in `argocd` to `https://localhost:8080`. |
| `make argocd.uninstall` | Delete Argo CD Applications, AppProjects, Helm release, and `*.argoproj.io` CRDs. |

---

## 3. Secret Sealing Scripts (`create-and-seal-*.sh`)

> [!CAUTION]
> **Destructive / State-Rotating Scripts**: Running any `create-and-seal-*.sh` script generates fresh random keys or passwords and refuses to overwrite an existing `.sealed.json` output (`assert_no_overwrite`). Plaintext intermediate files and `.secrets/sloth.env` live in `.secrets/` (gitignored), while sealed outputs are written directly into `SLOTH_PRIVATE_DIR` (default `../sloth-private`, configurable via `.secrets/sloth.env`).

| Script | Generated Plaintext (`.secrets/`) | Sealed Output Written to `${SLOTH_PRIVATE_DIR}` | External Manual Step Required? |
|--------|-----------------------------------|-------------------------------------------------|--------------------------------|
| [`create-and-seal-deploy-key.sh`](../create-and-seal-deploy-key.sh) | Temporary `ed25519` keypair | `argocd-base/repository-private.sealed.json`<br/>`deploy_key.pub` | **Yes**: Add `${SLOTH_PRIVATE_DIR}/deploy_key.pub` as a read-only Deploy Key on your private overlay GitHub repo. |
| [`create-and-seal-gcloud-service-accounts.sh`](../create-and-seal-gcloud-service-accounts.sh) | `.secrets/gcloud-dns01-solver.key.json` & `.secrets/gcloud-external-dns.key.json` | `cluster-essentials/cert-manager-config/gcloud-dns01-solver.sealed.json`<br/>`cluster-essentials/external-dns-config/gcloud-external-dns.sealed.json` | **Yes**: Creates GCP IAM service account keys in `GCP_PROJECT` (from `.secrets/sloth.env` or prompt, e.g. `example-dns`) via `gcloud`. |
| [`create-and-seal-metallb-memberlist-secret.sh`](../create-and-seal-metallb-memberlist-secret.sh) | Generated inline (`openssl rand`) | `cluster-essentials/metallb-config/memberlist.sealed.json` | No. |
| [`create-and-seal-authelia-secrets.sh`](../create-and-seal-authelia-secrets.sh) | Generated inline (`openssl`) | `deployments/oidc/authelia-secrets/authelia-secret.sealed.json`<br/>`deployments/oidc/authelia-secrets/authelia-jwks-secret.sealed.json` | No (4 HMAC/encryption keys + 4096-bit RSA OIDC JWKS key). |
| [`create-and-seal-authelia-smtp-secret.sh`](../create-and-seal-authelia-smtp-secret.sh) | Interactive password prompt | `deployments/oidc/authelia-secrets/authelia-smtp-secret.sealed.json` | **Yes**: Enter outbound SMTP password for Authelia notification emails. |
| [`create-and-seal-oidc-client-secrets.sh`](../create-and-seal-oidc-client-secrets.sh) | Interactive or `openssl rand` | `argocd-base/argocd-secrets/argocd-oidc-client-secret.sealed.json`<br/>`deployments/smarthome/grafana-secrets/grafana-oidc-client-secret.sealed.json` | **Yes**: Paste the printed `$pbkdf2-sha512$...` digests into `${SLOTH_PRIVATE_DIR}/values/authelia.yaml`. |
| [`create-authelia-user-hash.sh`](../create-authelia-user-hash.sh) | Interactive password prompt (not sealed; printed to stdout) | None (operator copies `$argon2id$...` into `${SLOTH_PRIVATE_DIR}/deployments/oidc/authelia-config/users-secret.yaml`) | **Yes**: Paste user hash into `users-secret.yaml`. |
| [`create-and-seal-smarthome-secrets.sh`](../create-and-seal-smarthome-secrets.sh) | Generated inline (`pwgen`) | `deployments/smarthome/grafana-secrets/grafana-secret.sealed.json` | No. |

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

[`check-helm-chart-versions.sh`](../check-helm-chart-versions.sh) scans all Argo CD `Application` YAML manifests across `argocd-base/`, `cluster-essentials/`, and `deployments/` and compares their `targetRevision` against upstream Helm repositories and GitHub Releases:

```bash
./check-helm-chart-versions.sh
```

- **What it checks**:
  1. All external Helm charts (`spec.source.chart` and `spec.sources[].chart`), outputting `Current` vs `Latest` chart version and `AppVersion`.
  2. Local Helm charts (`deployments/smarthome/mosquitto/Chart.yaml`).
  3. Non-Helm GitHub releases (`rancher/system-upgrade-controller` tag in `cluster-essentials/system-upgrade.yaml`).

---

## 6. Leak Guard (`lefthook.yml` & `scripts/check-blacklist.sh`)

[`lefthook.yml`](../lefthook.yml) wires [`scripts/check-blacklist.sh`](../scripts/check-blacklist.sh) into Git hooks across all stages:

* **`pre-commit` (`--warn --staged`)**: Scans staged file paths and staged blob contents before committing; warns clearly and exits `0` so local and worktree WIP commits never fail.
* **`commit-msg` (`--warn --commit-msg <file>`)**: Scans the commit message before finalizing the commit; warns clearly and exits `0`.
* **`pre-push` (`--pre-push`)**: Strictly blocks outgoing commit messages, changed/added files, and the tracked `HEAD` tree before pushing (`exit 1` on violations, `exit 2` fail-closed if `blacklist.txt` is missing).
* **`make check` (`--all`)**: Installs `lefthook` + hooks if missing, then strictly scans working-tree files (tracked + non-ignored untracked) and all reachable commits across history (`exit 1` / `exit 2`).

Rules enforced:
1. **Private Blacklist (`${SLOTH_PRIVATE_DIR}/blacklist.txt`)**: Loaded fail-closed (errors explicitly with `CONFIGURATION ERROR (FAIL-CLOSED)` if missing or empty unless `SLOTH_ALLOW_MISSING_BLACKLIST=1` is set). Supports case-insensitive literal lines and `regex:<pattern>` rules.
2. **Forbidden `.env` Files (`FORBIDDEN_ENV_FILE`)**: Blocks committing `.env`, `.env.*`, or `*.env` files (such as `.secrets/sloth.env`, `.secrets/rock5b.env`, `.secrets/pi0-lcn.env`).
3. **No User Home Paths (`HOME_PATH_LEAK`)**: Blocks hardcoded Linux home-directory paths in file paths, file contents, and commit messages.
