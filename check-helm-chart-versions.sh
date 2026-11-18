#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.check.lib.sh
source "${REPO_ROOT}/.check.lib.sh"
check_programs_available kubectl jq helm awk

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

cleanup_temp_repo() {
  helm repo remove temp-repo >/dev/null 2>&1 || true
}
trap cleanup_temp_repo EXIT

versioncheck() {
  local app="$1"
  local chart="$2"
  local repo_url="$3"
  local version="$4"

  local latest_version=""
  if [[ "${repo_url}" == http://* || "${repo_url}" == https://* ]]; then
    helm repo add --force-update temp-repo "${repo_url}" >/dev/null 2>&1
    helm repo update temp-repo >/dev/null 2>&1
    latest_version="$(
      helm search repo "temp-repo/${chart}" -o json |
        jq -r --arg n "temp-repo/${chart}" 'map(select(.name == $n))[0].version // empty'
    )"
    helm repo remove temp-repo >/dev/null 2>&1 || true
  else
    local oci_base="${repo_url#oci://}"
    latest_version="$(
      helm show chart "oci://${oci_base%/}/${chart}" 2>/dev/null |
        awk '/^version:[[:space:]]*/ {print $2; exit}' || true
    )"
  fi

  local norm_latest="${latest_version#v}"
  local norm_version="${version#v}"

  if [[ -z "${norm_latest}" ]]; then
    echo -e "${RED}Error${NC}: ${app} (${repo_url} ${chart}): ${RED}${version}${NC} [lookup failed]"
  elif [[ "${norm_latest}" != "${norm_version}" ]]; then
    echo -e "${RED}Outdated${NC}: ${app} (${repo_url} ${chart}): ${RED}${version}${NC} [${latest_version}]"
  else
    echo -e "${GREEN}OK${NC}: ${app} (${repo_url} ${chart}): ${GREEN}${version}${NC}"
  fi
}

apps_json="$(kubectl get -n argocd applications.argoproj.io -o json)"

while IFS=$'\t' read -r app chart repo_url version; do
  versioncheck "${app}" "${chart}" "${repo_url}" "${version}"
done < <(
  jq -r '
    .items[] |
    .metadata.name as $name |
    ((if .spec.source then [.spec.source] else [] end) + (.spec.sources // []))[] |
    select(.chart != null) |
    [$name, .chart, .repoURL, .targetRevision] |
    @tsv
  ' <<< "${apps_json}"
)
