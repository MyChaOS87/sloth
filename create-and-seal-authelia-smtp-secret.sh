#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal base64
load_sloth_env "${REPO_ROOT}"

SEALED_SMTP_OUT="${SLOTH_PRIVATE_DIR}/deployments/oidc/authelia-secrets/authelia-smtp-secret.sealed.json"
assert_no_overwrite "${SEALED_SMTP_OUT}"
ensure_parent_dir "${SEALED_SMTP_OUT}"

smtp_password=""
if [ -t 0 ]; then
  read -r -s -p "Enter SMTP password for Authelia: " smtp_password
  echo 1>&2
else
  IFS= read -r smtp_password || true
fi

if [ -z "${smtp_password}" ]; then
  echo "ERROR: SMTP password must not be empty" 1>&2
  exit 1
fi

encoded_password="$(printf '%s' "${smtp_password}" | base64 -w0)"

tmp_smtp="$(mktemp)"
trap 'rm -f "${tmp_smtp}"' EXIT

echo -n "Creating authelia-smtp-secret... " 1>&2
kubeseal --controller-namespace sealed-secrets > "${tmp_smtp}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: authelia-smtp-secret
  namespace: oidc
type: Opaque
data:
  notifier.smtp.password.txt: "${encoded_password}"
EOF
mv "${tmp_smtp}" "${SEALED_SMTP_OUT}"
echo "done!" 1>&2
