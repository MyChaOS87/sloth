#!/bin/bash
set -e +x

source $(dirname -- "${BASH_SOURCE[0]}")/.check.lib.sh

check_programs_available kubeseal pwgen head base64
assert_no_overwrite deployments/dms/redis-secrets/redis-secret.sealed.json

echo -n create redis secret... 1>&2
kubeseal --controller-namespace sealed-secrets > deployments/dms/redis-secrets/redis-secret.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  annotations:
    sealedsecrets.bitnami.com/cluster-wide: "true"
  name: redis-secret
data:
  password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF
echo done! 1>&2

echo -n create postgres secret... 1>&2
kubeseal --controller-namespace sealed-secrets > deployments/dms/postgres-secrets/postgres-secret.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  annotations:
    sealedsecrets.bitnami.com/cluster-wide: "true"
  name: postgres-secret
data:
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
  user-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
  replication-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF
echo done! 1>&2
