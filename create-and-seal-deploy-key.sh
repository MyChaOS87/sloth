#!/bin/bash
set -e +x

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal ssh-keygen kubectl
load_sloth_env "${REPO_ROOT}"

SEALED_OUT="${SLOTH_PRIVATE_DIR}/argocd-base/repository-private.sealed.json"
PUB_OUT="${SLOTH_PRIVATE_DIR}/deploy_key.pub"

assert_no_overwrite "${SEALED_OUT}"
ensure_parent_dir "${SEALED_OUT}"
ensure_parent_dir "${PUB_OUT}"

mkdir -p .secrets/.ssh/
chmod 700 .secrets/.ssh/

echo Creating new SSH Keypair ... 1>&2
ssh-keygen -q -t ed25519 -N '' -f .secrets/.ssh/id_ed25519 -C "argocd@$(kubectl config current-context)"

echo Sealing Private key into secret ... 1>&2
kubeseal --controller-namespace sealed-secrets > "${SEALED_OUT}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo.com.github.mychaos87.sloth-private
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${PRIVATE_REPO_URL}
  sshPrivateKey: |
$(cat .secrets/.ssh/id_ed25519 | sed 's/^/    /')
EOF

echo "Storing Public Key as \"${PUB_OUT}\" ..." 1>&2
mv .secrets/.ssh/id_ed25519.pub "${PUB_OUT}"

echo Cleanup Temporary Files 1>&2
rm .secrets/.ssh/id_ed25519
rmdir .secrets/.ssh/

echo "Your Public Deploy Key is (add as a read-only deploy key on ${PRIVATE_REPO_URL}):" 1>&2
cat "${PUB_OUT}"
