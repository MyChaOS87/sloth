#!/bin/bash
set -e +x

source $(dirname -- "${BASH_SOURCE[0]}")/.check.lib.sh

check_programs_available kubeseal pwgen head base64
assert_no_overwrite deployments/smarthome/grafana-secrets/grafana-secret.sealed.json
assert_no_overwrite deployments/smarthome/influxdb-secrets/influxdb-secret.sealed.json

echo -n create grafana secret... 1>&2
kubeseal --controller-namespace sealed-secrets > deployments/smarthome/grafana-secrets/grafana-secret.sealed.json << EOF
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

echo -n create influxdb secret... 1>&2
kubeseal --controller-namespace sealed-secrets> deployments/smarthome/influxdb-secrets/influxdb-secret.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  annotations:
    sealedsecrets.bitnami.com/cluster-wide: "true"
  name: influxdb-secret
data:
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
  admin-token: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF
echo done! 1>&2
