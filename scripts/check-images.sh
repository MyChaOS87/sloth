#!/usr/bin/env bash
# Verifies that all container images across rendered Helm/Kustomize/static manifests
# publish a linux/arm64 OCI/Docker manifest via crane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLOTH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for cmd in go yq jq sort; do
  command -v "${cmd}" >/dev/null 2>&1 || { printf '[image-check] ERROR: missing "%s"\n' "${cmd}" >&2; exit 2; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

yaml_json() {
  if yq --version 2>&1 | grep -qi mikefarah; then yq -o=json '.' "$1" | jq -c '.'
  else yq -c '.' "$1"
  fi
}

"${SCRIPT_DIR}/check-helm.sh" --render-only "${TMP_DIR}" >&2

mapfile -t images < <(
  while IFS= read -r -d '' rf; do
    yaml_json "${rf}" | jq -r '
      (select(.kind != "CustomResourceDefinition" and .kind != "Plan") | .. | objects | (.image? // empty) | select(type == "string" and length > 0)),
      (select(.kind == "NodeOpUpgrade") | .spec.image // empty),
      (select(.kind == "Plan") | (.spec.version // "") as $ver | ((.spec.upgrade.image? // empty), (.spec.prepare.image? // empty)) | select(length > 0) | if contains(":") then . elif ($ver != "") then (. + ":" + ($ver | sub("\\+"; "-"))) else empty end)
    '
  done < <(find "${TMP_DIR}" -type f -print0) | grep -v '^$' | sort -u
)

if (( ${#images[@]} == 0 )); then
  echo "[image-check] PASS: 0 container images discovered."
  exit 0
fi

failures=0
for img in "${images[@]}"; do
  if ! arch="$(go -C "${SLOTH_ROOT}/tools/crane" tool crane config --platform linux/arm64 "${img}" 2>/dev/null | jq -r '"\(.os // "?")/\(.architecture // "?")"' 2>/dev/null)"; then
    printf 'FAIL\t%s\tmissing or unreachable linux/arm64 manifest\n' "${img}"
    failures=$((failures + 1))
    continue
  fi
  if [[ "${arch}" == "linux/arm64" ]]; then
    printf 'OK\t%s\t%s\n' "${img}" "${arch}"
  else
    printf 'FAIL\t%s\tresolved %s (expected linux/arm64)\n' "${img}" "${arch}"
    failures=$((failures + 1))
  fi
done

(( failures == 0 )) || { printf '[image-check] FAILED: %d image(s) lack linux/arm64 support.\n' "${failures}" >&2; exit 1; }
echo "[image-check] PASS: verified ${#images[@]} unique container image(s) for linux/arm64."
