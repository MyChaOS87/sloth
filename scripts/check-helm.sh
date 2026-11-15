#!/usr/bin/env bash
# Renders local Helm charts, Argo CD Applications, and Kustomize overlays, then
# validates Kubernetes/CRD schemas with kubeconform and K8s API deprecations with pluto.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLOTH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_CACHE="${SLOTH_ROOT}/.cache/helm-charts"
KUSTOMIZE_CACHE="${SLOTH_ROOT}/.cache/kustomize"
KUBECONFORM_CACHE="${SLOTH_ROOT}/.cache/kubeconform"

RENDER_ONLY_DIR=""
if [[ "${1:-}" == "--render-only" ]]; then
  [[ $# -eq 2 && -n "$2" ]] || { printf 'Usage: %s [--render-only <dir>]\n' "${0##*/}" >&2; exit 2; }
  mkdir -p "$2"
  RENDER_ONLY_DIR="$(cd "$2" && pwd)"
elif (( $# > 0 )); then
  printf 'Usage: %s [--render-only <dir>]\n' "${0##*/}" >&2
  exit 2
fi

for cmd in go helm kubectl yq jq; do
  command -v "${cmd}" >/dev/null 2>&1 || { printf '[helm-check] ERROR: missing "%s"\n' "${cmd}" >&2; exit 2; }
done

TMP_WORK="$(mktemp -d)"
trap 'rm -rf "${TMP_WORK}"' EXIT

yaml_json() {
  if yq --version 2>&1 | grep -qi mikefarah; then
    yq -o=json '.' "$1" | jq -c '.'
  else
    yq -c '.' "$1"
  fi
}

fetch_chart() {
  local repo_url="$1" chart="$2" version="$3"
  local cached="${CHART_CACHE}/${chart}-${version}.tgz"
  local cached_nov="${CHART_CACHE}/${chart}-${version#v}.tgz"
  [[ -f "${cached}" ]] && { printf '%s\n' "${cached}"; return 0; }
  [[ -f "${cached_nov}" ]] && { printf '%s\n' "${cached_nov}"; return 0; }

  mkdir -p "${CHART_CACHE}"
  local pull_dir="${TMP_WORK}/pull"
  rm -rf "${pull_dir}" && mkdir -p "${pull_dir}"
  echo "[helm-check] Pulling chart ${chart} ${version} from ${repo_url}..." >&2
  if [[ "${repo_url}" == oci://* || ( "${repo_url}" != http://* && "${repo_url}" != https://* ) ]]; then
    local oci_base="${repo_url#oci://}"
    helm pull "oci://${oci_base%/}/${chart}" --version "${version}" -d "${pull_dir}" >&2
  else
    helm pull --repo "${repo_url}" "${chart}" --version "${version}" -d "${pull_dir}" >&2
  fi
  local tgz
  tgz="$(find "${pull_dir}" -maxdepth 1 -name '*.tgz' | head -n 1)"
  [[ -n "${tgz}" ]] || { printf '[helm-check] ERROR: no .tgz pulled for %s:%s\n' "${chart}" "${version}" >&2; return 1; }
  mv "${tgz}" "${cached}"
  printf '%s\n' "${cached}"
}

fetch_remote_kustomize() {
  local repo_url="$1" path="$2" version="$3"
  local key cached base url
  key="$(printf '%s_%s_%s' "${repo_url}" "${path}" "${version}" | tr -cs 'A-Za-z0-9._-' '_')"
  cached="${KUSTOMIZE_CACHE}/${key}.yaml"
  [[ -s "${cached}" ]] && { printf '%s\n' "${cached}"; return 0; }

  mkdir -p "${KUSTOMIZE_CACHE}"
  base="${repo_url%.git}"
  url="${base}?ref=${version}"
  [[ -n "${path}" && "${path}" != "." ]] && url="${base}/${path#./}?ref=${version}"
  echo "[helm-check] Rendering remote Kustomize ${url}..." >&2
  kubectl kustomize "${url}" > "${cached}.tmp" && mv "${cached}.tmp" "${cached}"
  printf '%s\n' "${cached}"
}

render_helm() {
  local app_name="$1" ns="$2" chart_ref="$3" local_dir="$4" overlay_dir="$5" src_json="$6" out_file="$7"
  local release vf resolved inline_vals param
  local -a args=()
  release="$(jq -r --arg d "${app_name}" '.helm.releaseName // $d' <<< "${src_json}")"

  while IFS= read -r vf; do
    [[ -z "${vf}" ]] && continue
    if [[ "${vf}" == '$private/'* ]]; then resolved="${overlay_dir}/${vf#\$private/}"
    elif [[ -n "${local_dir}" ]]; then resolved="${local_dir}/${vf}"
    else resolved="${SLOTH_ROOT}/${vf}"
    fi
    [[ -f "${resolved}" ]] || { printf '[helm-check] ERROR: missing valueFile %s (%s)\n' "${resolved}" "${app_name}" >&2; return 1; }
    args+=(-f "${resolved}")
  done < <(jq -r '.helm.valueFiles // [] | .[]' <<< "${src_json}")

  inline_vals="$(jq -r '.helm.values // empty' <<< "${src_json}")"
  if [[ -n "${inline_vals}" ]]; then
    printf '%s\n' "${inline_vals}" > "${TMP_WORK}/inline.yaml"
    args+=(-f "${TMP_WORK}/inline.yaml")
  fi
  while IFS= read -r param; do
    [[ -n "${param}" ]] && args+=(--set "${param}")
  done < <(jq -r '.helm.parameters // [] | .[] | "\(.name)=\(.value)"' <<< "${src_json}")

  local err_file="${TMP_WORK}/helm-err.log"
  if ! helm template "${release}" "${chart_ref}" --namespace "${ns}" --include-crds --skip-tests "${args[@]}" > "${out_file}" 2> "${err_file}"; then
    if grep -qE 'failing loading "https?://' "${err_file}"; then
      printf '[helm-check] WARN: offline schema $ref failure for %s; retrying --skip-schema-validation\n' "${app_name}" >&2
      helm template "${release}" "${chart_ref}" --namespace "${ns}" --include-crds --skip-tests --skip-schema-validation "${args[@]}" > "${out_file}"
    else
      cat "${err_file}" >&2; return 1
    fi
  fi
}

render_overlay() {
  local overlay_dir="$1" out_dir="$2"
  mkdir -p "${out_dir}"

  local -a dirs=()
  local d chart_yaml count=0
  for d in "${SLOTH_ROOT}/argocd-base" "${SLOTH_ROOT}/cluster-essentials" "${SLOTH_ROOT}/deployments" \
           "${overlay_dir}/argocd-base" "${overlay_dir}/cluster-essentials" "${overlay_dir}/deployments" "${overlay_dir}/private"; do
    [[ -d "${d}" ]] && dirs+=("${d}")
  done
  (( ${#dirs[@]} > 0 )) || return 0

  if [[ -z "${RENDER_ONLY_DIR}" ]]; then
    while IFS= read -r -d '' chart_yaml; do
      local chart_dir="${chart_yaml%/Chart.yaml}" chart_name
      chart_name="$(basename "${chart_dir}")"
      local -a lint_args=()
      [[ -f "${overlay_dir}/values/${chart_name}.yaml" ]] && lint_args+=(-f "${overlay_dir}/values/${chart_name}.yaml")
      helm lint --strict "${chart_dir}" "${lint_args[@]}"
      count=$((count + 1))
    done < <(find "${dirs[@]}" -name 'Chart.yaml' -not -path '*/charts/*' -print0 | sort -z)
    echo "[helm-check] Linted ${count} local Helm chart(s) against $(basename "${overlay_dir}")"
  fi

  local app_file app_json app_name ns src_json chart repo_url version path recurse local_dir mf out_file
  local app_count=0 idx=0 fidx=0
  while IFS= read -r -d '' app_file; do
    while IFS= read -r app_json; do
      [[ -z "${app_json}" ]] && continue
      app_name="$(jq -r '.metadata.name' <<< "${app_json}")"
      ns="$(jq -r '.spec.destination.namespace // "default"' <<< "${app_json}")"
      app_count=$((app_count + 1))
      idx=0

      while IFS= read -r src_json; do
        [[ -z "${src_json}" ]] && continue
        idx=$((idx + 1))
        chart="$(jq -r '.chart // empty' <<< "${src_json}")"
        repo_url="$(jq -r '.repoURL // empty' <<< "${src_json}")"
        version="$(jq -r '.targetRevision // empty' <<< "${src_json}")"
        path="$(jq -r '.path // empty' <<< "${src_json}")"
        recurse="$(jq -r '.directory.recurse // false' <<< "${src_json}")"
        out_file="${out_dir}/${app_count}-${app_name}-${idx}.yaml"

        if [[ -n "${chart}" ]]; then
          render_helm "${app_name}" "${ns}" "$(fetch_chart "${repo_url}" "${chart}" "${version}")" "" "${overlay_dir}" "${src_json}" "${out_file}"
        elif [[ -n "${path}" ]]; then
          if [[ "${repo_url}" == *sloth-private* ]]; then local_dir="${overlay_dir}/${path#./}"
          elif [[ "${repo_url}" == *sloth* ]]; then local_dir="${SLOTH_ROOT}/${path#./}"
          else cp "$(fetch_remote_kustomize "${repo_url}" "${path}" "${version}")" "${out_file}"; continue
          fi

          if [[ ! -d "${local_dir}" ]]; then
            if [[ "$(cd "${overlay_dir}" && pwd)" == "$(cd "${SLOTH_ROOT}/examples/sloth-private" && pwd)" ]] && \
               [[ "${path#./}" =~ ^(argocd-base/argocd-secrets|cluster-essentials/metallb-config|deployments/oidc/authelia-secrets|deployments/smarthome/grafana-secrets)$ ]]; then
              continue
            fi
            printf '[helm-check] ERROR: missing source dir %s (%s)\n' "${local_dir}" "${app_name}" >&2; return 1
          fi

          if [[ -f "${local_dir}/Chart.yaml" ]]; then
            render_helm "${app_name}" "${ns}" "${local_dir}" "${local_dir}" "${overlay_dir}" "${src_json}" "${out_file}"
          elif [[ -f "${local_dir}/kustomization.yaml" || -f "${local_dir}/kustomization.yml" || -f "${local_dir}/Kustomization" ]]; then
            kubectl kustomize --enable-helm "${local_dir}" > "${out_file}"
          else
            local -a depth=(-maxdepth 1); [[ "${recurse}" == "true" ]] && depth=()
            fidx=0
            while IFS= read -r -d '' mf; do
              fidx=$((fidx + 1))
              cp "${mf}" "${out_dir}/${app_count}-${app_name}-${idx}-${fidx}-$(basename "${mf}")"
            done < <(find "${local_dir}" "${depth[@]}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print0 | sort -z)
          fi
        fi
      done < <(jq -c '(.spec.source // empty), ((.spec.sources // [])[]?)' <<< "${app_json}")
    done < <(yaml_json "${app_file}" | jq -c 'select(.kind == "Application")')
  done < <(find "${dirs[@]}" -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/templates/*' -not -path '*/charts/*' -print0 | sort -z)

  echo "[helm-check] Rendered ${app_count} Argo CD Application(s) for overlay ${overlay_dir}"
}

validate_rendered_dir() {
  local label="$1" render_dir="$2"
  mkdir -p "${KUBECONFORM_CACHE}"
  echo "[helm-check] Validating rendered schemas (${label}) with kubeconform..."
  # Skip SealedSecret because Datree's generated schema enforces additionalProperties:false
  # on x-kubernetes-preserve-unknown-fields spec.template.metadata (breaking kubeseal's
  # creationTimestamp:null); policy/secrets.rego validates .sealed.json structure instead.
  go -C "${SLOTH_ROOT}/tools/kubeconform" tool kubeconform \
    -n 6 -strict -cache "${KUBECONFORM_CACHE}" \
    -skip CustomResourceDefinition,RecurringJob,NodeOpUpgrade,SealedSecret \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -summary "${render_dir}"

  echo "[helm-check] Checking K8s v1.37.0 API deprecations (${label}) with pluto..."
  go -C "${SLOTH_ROOT}/tools/pluto" tool pluto detect-files -d "${render_dir}" --target-versions k8s=v1.37.0
}

main() {
  local priv_dir="${SLOTH_PRIVATE_DIR:-${SLOTH_ROOT}/../sloth-private}"
  [[ "${priv_dir}" != /* ]] && priv_dir="${SLOTH_ROOT}/${priv_dir}"

  local -a overlays=()
  if [[ -n "${SLOTH_ONLY_OVERLAY:-}" ]]; then
    overlays+=("${SLOTH_ONLY_OVERLAY}")
  else
    overlays+=("${SLOTH_ROOT}/examples/sloth-private")
    if [[ -d "${priv_dir}/values" ]] && [[ "$(cd "${priv_dir}" && pwd)" != "$(cd "${SLOTH_ROOT}/examples/sloth-private" && pwd)" ]]; then
      overlays+=("$(cd "${priv_dir}" && pwd)")
    fi
  fi

  local ov ov_idx=0 base_out="${RENDER_ONLY_DIR:-${TMP_WORK}}"
  for ov in "${overlays[@]}"; do
    ov_idx=$((ov_idx + 1))
    local ov_dir="${base_out}/render-${ov_idx}"
    render_overlay "${ov}" "${ov_dir}"
    if [[ -z "${RENDER_ONLY_DIR}" ]]; then
      validate_rendered_dir "$(basename "${ov}")" "${ov_dir}"
    fi
  done
}

main "$@"
