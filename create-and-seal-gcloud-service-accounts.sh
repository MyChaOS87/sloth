#!/bin/bash
set -e +x

[ ! -f .secrets/gcloud-dns01-solver.key.json ] && gcloud iam service-accounts keys create .secrets/gcloud-dns01-solver.key.json \
   --iam-account dns01-solver@vogelherd.iam.gserviceaccount.com

kubectl create secret generic gcloud-dns01-solver -n cert-manager \
   --dry-run=client --from-file=.secrets/gcloud-dns01-solver.key.json \
   -o json > .secrets/gcloud-dns01-solver.json
kubeseal --controller-namespace sealed-secrets < .secrets/gcloud-dns01-solver.json > cluster-essentials/cert-manager-config/gcloud-dns01-solver.sealed.json 


[ ! -f .secrets/gcloud-external-dns.key.json ] && gcloud iam service-accounts keys create .secrets/gcloud-external-dns.key.json \
   --iam-account external-dns@vogelherd.iam.gserviceaccount.com

kubectl create secret generic gcloud-external-dns -n external-dns \
   --dry-run=client --from-file=.secrets/gcloud-external-dns.key.json \
   -o json > .secrets/gcloud-external-dns.json
kubeseal --controller-namespace sealed-secrets < .secrets/gcloud-external-dns.json > cluster-essentials/external-dns-config/gcloud-external-dns.sealed.json 

echo Secrets are sealed 1>&2