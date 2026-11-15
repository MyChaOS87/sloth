#!/bin/bash
set -e +x

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal pwgen head base64
load_sloth_env "${REPO_ROOT}"

SEALED_OUT="${SLOTH_PRIVATE_DIR}/deployments/smarthome/grafana-secrets/grafana-secret.sealed.json"
assert_no_overwrite "${SEALED_OUT}"
ensure_parent_dir "${SEALED_OUT}"

echo -n create grafana secret... 1>&2
kubeseal --controller-namespace sealed-secrets > "${SEALED_OUT}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: grafana
data:
  admin-user: "$(echo -n root | base64)"
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF
echo done! 1>&2
