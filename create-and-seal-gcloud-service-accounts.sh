#!/bin/bash
set -e +x

[ ! -f .secrets/gcloud-dns01-solver.key.json ] && gcloud iam service-accounts keys create .secrets/gcloud-dns01-solver.key.json \
   --iam-account dns01-solver@vogelherd.iam.gserviceaccount.com

kubectl create secret generic gcloud-dns01-solver -n cert-manager \
   --dry-run=client --from-file=.secrets/gcloud-dns01-solver.key.json \
   -o json > .secrets/gcloud-dns01-solver.json
kubeseal < .secrets/gcloud-dns01-solver.json > deployments/cert-manager-resources/gcloud-dns01-solver.sealed.json 

echo Secrets are sealed 1>&2