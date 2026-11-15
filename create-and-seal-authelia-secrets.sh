#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal openssl base64
load_sloth_env "${REPO_ROOT}"

SEALED_SECRET_OUT="${SLOTH_PRIVATE_DIR}/deployments/oidc/authelia-secrets/authelia-secret.sealed.json"
SEALED_JWKS_OUT="${SLOTH_PRIVATE_DIR}/deployments/oidc/authelia-secrets/authelia-jwks-secret.sealed.json"

assert_no_overwrite "${SEALED_SECRET_OUT}"
assert_no_overwrite "${SEALED_JWKS_OUT}"
ensure_parent_dir "${SEALED_SECRET_OUT}"
ensure_parent_dir "${SEALED_JWKS_OUT}"

gen_b64_secret() {
  openssl rand -hex 32 | tr -d '\n' | base64 -w0
}

tmp_secret="$(mktemp)"
tmp_jwks="$(mktemp)"
trap 'rm -f "${tmp_secret}" "${tmp_jwks}"' EXIT

echo -n "Creating authelia-secret... " 1>&2
kubeseal --controller-namespace sealed-secrets > "${tmp_secret}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: authelia-secret
  namespace: oidc
type: Opaque
data:
  identity_validation.reset_password.jwt.hmac.key: "$(gen_b64_secret)"
  session.encryption.key: "$(gen_b64_secret)"
  storage.encryption.key: "$(gen_b64_secret)"
  identity_providers.oidc.hmac.key: "$(gen_b64_secret)"
EOF
echo "done!" 1>&2

echo -n "Creating authelia-jwks-secret... " 1>&2
kubeseal --controller-namespace sealed-secrets > "${tmp_jwks}" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: authelia-jwks-secret
  namespace: oidc
type: Opaque
data:
  oidc.jwk.RS256.pem: "$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 2>/dev/null | base64 -w0)"
EOF
mv "${tmp_secret}" "${SEALED_SECRET_OUT}"
mv "${tmp_jwks}" "${SEALED_JWKS_OUT}"
echo "done!" 1>&2
