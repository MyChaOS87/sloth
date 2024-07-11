#!/bin/bash
set -e +x

source $(dirname -- "${BASH_SOURCE[0]}")/.check.lib.sh

check_programs_available kubeseal head base64

function create_client_secret() {
  local client_name=$1
  local namespace=$2
  local path=$3
  local label=$4

  secret_full_path=$path/${client_name}-oidc-client-secret.sealed.json

  assert_no_overwrite $secret_full_path || return 1

  local client_secret
  read -p "Enter client secret for $client_name: " client_secret

  echo -n create client secret for $client_name... 1>&2
  kubeseal --controller-namespace sealed-secrets > $secret_full_path  << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${client_name}-client-secret
  namespace: $namespace
  labels:
    $([ -n "$label" ] && echo "  $label")
data:
  client-secret: ${client_secret}
EOF
  echo done! 1>&2
}

# create_client_secret grafana grafana deployments/smarthome/grafana-secrets || true
create_client_secret argocd argocd argocd-base/argocd-secrets "app.kubernetes.io/part-of: argocd" || true

echo done! 1>&2