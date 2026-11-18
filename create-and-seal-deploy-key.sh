#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=.check.lib.sh
source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal ssh-keygen kubectl
load_sloth_env "${REPO_ROOT}"

derive_repo_secret_name() {
  local url="${1#*://}"
  url="${url#*@}"
  url="${url/://}"
  url="${url%.git}"
  local host="${url%%/*}"
  local path="${url#*/}"
  local reversed_host="" seg=""
  local -a host_parts=()
  IFS='.' read -r -a host_parts <<< "${host}"
  for (( i=${#host_parts[@]}-1; i>=0; i-- )); do
    seg="${host_parts[$i]}"
    reversed_host+="${reversed_host:+.}${seg}"
  done
  printf 'repo.%s.%s\n' "${reversed_host}" "${path//\//.}" | tr '[:upper:]' '[:lower:]'
}

PRIVATE_REPO_SECRET_NAME="${PRIVATE_REPO_SECRET_NAME:-$(derive_repo_secret_name "${PRIVATE_REPO_URL}")}"

SEALED_OUT="${SLOTH_PRIVATE_DIR}/argocd-base/repository-private.sealed.json"
PUB_OUT="${SLOTH_PRIVATE_DIR}/deploy_key.pub"

assert_no_overwrite "${SEALED_OUT}"
ensure_parent_dir "${SEALED_OUT}"
ensure_parent_dir "${PUB_OUT}"

mkdir -p "${REPO_ROOT}/.secrets"
chmod 700 "${REPO_ROOT}/.secrets"
tmp_dir="$(mktemp -d "${REPO_ROOT}/.secrets/deploy-key.XXXXXX")"
chmod 700 "${tmp_dir}"
tmp_sealed="$(mktemp)"
trap 'rm -rf "${tmp_dir}" "${tmp_sealed}"' EXIT

echo "Creating new SSH Keypair ..." >&2
ssh-keygen -q -t ed25519 -N '' -f "${tmp_dir}/id_ed25519" -C "argocd@$(kubectl config current-context)"

echo "Sealing Private key into secret (${PRIVATE_REPO_SECRET_NAME}) ..." >&2
kubeseal --controller-namespace sealed-secrets > "${tmp_sealed}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PRIVATE_REPO_SECRET_NAME}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${PRIVATE_REPO_URL}
  sshPrivateKey: |
$(sed 's/^/    /' "${tmp_dir}/id_ed25519")
EOF

mv "${tmp_sealed}" "${SEALED_OUT}"
echo "Storing Public Key as \"${PUB_OUT}\" ..." >&2
mv "${tmp_dir}/id_ed25519.pub" "${PUB_OUT}"

echo "Your Public Deploy Key is (add as a read-only deploy key on ${PRIVATE_REPO_URL}):" >&2
cat "${PUB_OUT}"
