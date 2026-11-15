#!/bin/bash
set -e +x

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal openssl
load_sloth_env "${REPO_ROOT}"

SEALED_OUT="${SLOTH_PRIVATE_DIR}/cluster-essentials/metallb-config/memberlist.sealed.json"
assert_no_overwrite "${SEALED_OUT}"
ensure_parent_dir "${SEALED_OUT}"

echo -n Creating memberlist secret and sealing it ... 1>&2
kubeseal --controller-namespace sealed-secrets > "${SEALED_OUT}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: memberlist
  namespace: metallb
data:
  secretkey: $(openssl rand -base64 128 | tr -d "\n")
EOF

echo done 1>&2
