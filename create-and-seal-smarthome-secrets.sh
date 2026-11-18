#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=.check.lib.sh
source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal openssl base64
load_sloth_env "${REPO_ROOT}"

SEALED_OUT="${SLOTH_PRIVATE_DIR}/deployments/smarthome/grafana-secrets/grafana-secret.sealed.json"
assert_no_overwrite "${SEALED_OUT}"
ensure_parent_dir "${SEALED_OUT}"

tmp_sealed="$(mktemp)"
trap 'rm -f "${tmp_sealed}"' EXIT

echo -n "create grafana secret... " >&2
kubeseal --controller-namespace sealed-secrets > "${tmp_sealed}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: grafana
data:
  admin-user: "$(printf 'root' | base64 | tr -d '\n')"
  admin-password: "$(openssl rand -base64 24 | tr -d '\n' | base64 | tr -d '\n')"
EOF

mv "${tmp_sealed}" "${SEALED_OUT}"
echo "done!" >&2
