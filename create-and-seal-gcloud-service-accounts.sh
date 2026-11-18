#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=.check.lib.sh
source "${REPO_ROOT}/.check.lib.sh"

check_programs_available kubeseal gcloud kubectl
load_sloth_env "${REPO_ROOT}"

if [[ -z "${GCP_PROJECT:-}" ]]; then
  read -r -p "Enter GCP project ID hosting Cloud DNS (e.g. example-dns): " GCP_PROJECT
fi
: "${GCP_PROJECT:?GCP_PROJECT must be set (either in .secrets/sloth.env or interactively)}"

DNS01_OUT="${SLOTH_PRIVATE_DIR}/cluster-essentials/cert-manager-config/gcloud-dns01-solver.sealed.json"
EXTDNS_OUT="${SLOTH_PRIVATE_DIR}/cluster-essentials/external-dns-config/gcloud-external-dns.sealed.json"

assert_no_overwrite "${DNS01_OUT}"
assert_no_overwrite "${EXTDNS_OUT}"
ensure_parent_dir "${DNS01_OUT}"
ensure_parent_dir "${EXTDNS_OUT}"

mkdir -p "${REPO_ROOT}/.secrets"
chmod 700 "${REPO_ROOT}/.secrets"

tmp_dns01="$(mktemp)"
tmp_extdns="$(mktemp)"
cleanup() {
  rm -f \
    "${tmp_dns01}" \
    "${tmp_extdns}" \
    "${REPO_ROOT}/.secrets/gcloud-dns01-solver.key.json" \
    "${REPO_ROOT}/.secrets/gcloud-dns01-solver.json" \
    "${REPO_ROOT}/.secrets/gcloud-external-dns.key.json" \
    "${REPO_ROOT}/.secrets/gcloud-external-dns.json"
}
trap cleanup EXIT

if [[ ! -f "${REPO_ROOT}/.secrets/gcloud-dns01-solver.key.json" ]]; then
  gcloud iam service-accounts keys create "${REPO_ROOT}/.secrets/gcloud-dns01-solver.key.json" \
    --iam-account "dns01-solver@${GCP_PROJECT}.iam.gserviceaccount.com"
fi

kubectl create secret generic gcloud-dns01-solver -n cert-manager \
  --dry-run=client --from-file="${REPO_ROOT}/.secrets/gcloud-dns01-solver.key.json" \
  -o json > "${REPO_ROOT}/.secrets/gcloud-dns01-solver.json"
kubeseal --controller-namespace sealed-secrets < "${REPO_ROOT}/.secrets/gcloud-dns01-solver.json" > "${tmp_dns01}"

if [[ ! -f "${REPO_ROOT}/.secrets/gcloud-external-dns.key.json" ]]; then
  gcloud iam service-accounts keys create "${REPO_ROOT}/.secrets/gcloud-external-dns.key.json" \
    --iam-account "external-dns@${GCP_PROJECT}.iam.gserviceaccount.com"
fi

kubectl create secret generic gcloud-external-dns -n external-dns \
  --dry-run=client --from-file="${REPO_ROOT}/.secrets/gcloud-external-dns.key.json" \
  -o json > "${REPO_ROOT}/.secrets/gcloud-external-dns.json"
kubeseal --controller-namespace sealed-secrets < "${REPO_ROOT}/.secrets/gcloud-external-dns.json" > "${tmp_extdns}"

mv "${tmp_dns01}" "${DNS01_OUT}"
mv "${tmp_extdns}" "${EXTDNS_OUT}"

echo "Secrets are sealed" >&2
