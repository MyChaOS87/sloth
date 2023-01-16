#!/bin/bash
set -e +x

echo Trying to find the AWS IOT Certificates ... 1>&2
[ ! -f .secrets/awsiot.ca.pem ] && echo .ssh/awsiot.cert.pem does not exist 1>&2 && exit 1
[ ! -f .secrets/awsiot.cert.crt ] && echo .ssh/awsiot.cert.crt does not exist 1>&2 && exit 1
[ ! -f .secrets/awsiot.public.key ] && echo .ssh/awsiot.public.key does not exist 1>&2 && exit 1
[ ! -f .secrets/awsiot.private.key ] && echo .ssh/awsiot.private.key does not exist 1>&2 && exit 1

echo Sealing certificates/keys into secret ... 1>&2

kubeseal > deployments/mosquitto/templates/awsiot.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: awsiot-certificates
  namespace: mosquitto
data:
  awsiot.ca.pem: |
$(cat .secrets/awsiot.ca.pem | base64 | sed 's/^/    /')
  awsiot.cert.crt: |
$(cat .secrets/awsiot.cert.crt | base64 | sed 's/^/    /')
  awsiot.public.key: | 
$(cat .secrets/awsiot.public.key | base64 | sed 's/^/    /')
  awsiot.private.key: |
$(cat .secrets/awsiot.private.key | base64 | sed 's/^/    /')
EOF

echo Secrets are sealed 1>&2