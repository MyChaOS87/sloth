#!/bin/bash
set -e +x

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal gcloud kubectl
load_sloth_env "${REPO_ROOT}"

if [ -z "${GCP_PROJECT:-}" ]; then
  read -r -p "Enter GCP project ID hosting Cloud DNS (e.g. example-dns): " GCP_PROJECT
fi
: "${GCP_PROJECT:?GCP_PROJECT must be set (either in .secrets/sloth.env or interactively)}"

DNS01_OUT="${SLOTH_PRIVATE_DIR}/cluster-essentials/cert-manager-config/gcloud-dns01-solver.sealed.json"
EXTDNS_OUT="${SLOTH_PRIVATE_DIR}/cluster-essentials/external-dns-config/gcloud-external-dns.sealed.json"

assert_no_overwrite "${DNS01_OUT}"
assert_no_overwrite "${EXTDNS_OUT}"
ensure_parent_dir "${DNS01_OUT}"
ensure_parent_dir "${EXTDNS_OUT}"

mkdir -p .secrets
chmod 700 .secrets

[ ! -f .secrets/gcloud-dns01-solver.key.json ] && gcloud iam service-accounts keys create .secrets/gcloud-dns01-solver.key.json \
   --iam-account "dns01-solver@${GCP_PROJECT}.iam.gserviceaccount.com"

kubectl create secret generic gcloud-dns01-solver -n cert-manager \
   --dry-run=client --from-file=.secrets/gcloud-dns01-solver.key.json \
   -o json > .secrets/gcloud-dns01-solver.json
kubeseal --controller-namespace sealed-secrets < .secrets/gcloud-dns01-solver.json > "${DNS01_OUT}"


[ ! -f .secrets/gcloud-external-dns.key.json ] && gcloud iam service-accounts keys create .secrets/gcloud-external-dns.key.json \
   --iam-account "external-dns@${GCP_PROJECT}.iam.gserviceaccount.com"

kubectl create secret generic gcloud-external-dns -n external-dns \
   --dry-run=client --from-file=.secrets/gcloud-external-dns.key.json \
   -o json > .secrets/gcloud-external-dns.json
kubeseal --controller-namespace sealed-secrets < .secrets/gcloud-external-dns.json > "${EXTDNS_OUT}"

echo Secrets are sealed 1>&2
