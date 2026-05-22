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
