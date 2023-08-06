#!/bin/bash
set -e +x



kubeseal --controller-namespace sealed-secrets > deployments/influx-secrets/grafana-secret.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: influxdb
data:
  admin-user: "$(echo -n root | base64)"
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF

kubeseal --controller-namespace sealed-secrets> deployments/influx-secrets/influx-secret.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: influx-secret
  namespace: influxdb
data:
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
  admin-token: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF

echo Secrets are sealed 1>&2