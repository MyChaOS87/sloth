#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=.check.lib.sh
source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal openssl
load_sloth_env "${REPO_ROOT}"

SEALED_OUT="${SLOTH_PRIVATE_DIR}/cluster-essentials/metallb-config/memberlist.sealed.json"
assert_no_overwrite "${SEALED_OUT}"
ensure_parent_dir "${SEALED_OUT}"

tmp_sealed="$(mktemp)"
trap 'rm -f "${tmp_sealed}"' EXIT

echo -n "Creating memberlist secret and sealing it ... " >&2
kubeseal --controller-namespace sealed-secrets > "${tmp_sealed}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: memberlist
  namespace: metallb
data:
  secretkey: $(openssl rand -base64 128 | tr -d "\n")
EOF

mv "${tmp_sealed}" "${SEALED_OUT}"
echo "done" >&2
