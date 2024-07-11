#!/bin/bash
set -e +x

source $(dirname -- "${BASH_SOURCE[0]}")/.check.lib.sh

check_programs_available kubeseal pwgen head base64
assert_no_overwrite deployments/oidc/keycloak-secrets/keycloak-admin-secret.sealed.json

echo -n create keycloak admin secret... 1>&2
kubeseal --controller-namespace sealed-secrets > deployments/oidc/keycloak-secrets/keycloak-admin-secret.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin-secret
  namespace: keycloak-oidc
data:
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF
echo done! 1>&2

