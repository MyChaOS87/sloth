#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal openssl base64 python3
load_sloth_env "${REPO_ROOT}"

function create_client_secret() {
  local client_name=$1
  local namespace=$2
  local path=$3
  local label=${4:-}

  local secret_full_path="${path}/${client_name}-oidc-client-secret.sealed.json"

  assert_no_overwrite "${secret_full_path}" || return 1
  ensure_parent_dir "${secret_full_path}"

  local client_secret=""
  if [ -t 0 ]; then
    read -r -s -p "Enter client secret for ${client_name} (leave empty to auto-generate): " client_secret || true
    echo 1>&2
  fi
  if [ -z "${client_secret}" ]; then
    client_secret="$(openssl rand -hex 32)"
  fi

  local encoded_secret
  encoded_secret="$(printf '%s' "${client_secret}" | base64 -w0)"

  local labels_block=""
  if [ -n "${label}" ]; then
    labels_block=$'\n  labels:\n    '"${label}"
  fi

  echo -n "Creating client secret for ${client_name}... " 1>&2
  local tmp_sealed
  tmp_sealed="$(mktemp)"
  if kubeseal --controller-namespace sealed-secrets > "${tmp_sealed}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${client_name}-client-secret
  namespace: ${namespace}${labels_block}
data:
  client-secret: ${encoded_secret}
EOF
  then
    mv "${tmp_sealed}" "${secret_full_path}"
  else
    rm -f "${tmp_sealed}"
    return 1
  fi
  echo "done!" 1>&2

  local phc_hash
  phc_hash="$(printf '%s' "${client_secret}" | python3 -c '
import base64, hashlib, os, sys
secret = sys.stdin.buffer.read()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha512", secret, salt, 310000, dklen=64)
b64 = lambda b: base64.b64encode(b).decode("ascii").replace("+", ".").rstrip("=")
print(f"$pbkdf2-sha512$310000${b64(salt)}${b64(dk)}")
')"
  echo "${client_name} PHC digest for values/authelia.yaml:" 1>&2
  echo "${phc_hash}"
}

create_client_secret grafana grafana "${SLOTH_PRIVATE_DIR}/deployments/smarthome/grafana-secrets" || [ -f "${SLOTH_PRIVATE_DIR}/deployments/smarthome/grafana-secrets/grafana-oidc-client-secret.sealed.json" ]
create_client_secret argocd argocd "${SLOTH_PRIVATE_DIR}/argocd-base/argocd-secrets" "app.kubernetes.io/part-of: argocd" || [ -f "${SLOTH_PRIVATE_DIR}/argocd-base/argocd-secrets/argocd-oidc-client-secret.sealed.json" ]

echo "done!" 1>&2
