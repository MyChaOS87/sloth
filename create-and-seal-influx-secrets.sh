#!/bin/bash
set -e +x



kubeseal > deployments/influx-secrets/grafana-secrets.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: influxdb
data:
  admin-user: "$(echo -n root | base64)"
  admin-password: "$(pwgen -sc 24  1 | head -c -1 | base64)"
EOF

echo Secrets are sealed 1>&2