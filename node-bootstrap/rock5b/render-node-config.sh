#!/usr/bin/env bash
# Render a node-specific Kairos cloud-config.yaml for a sloth Radxa Rock 5B node.
# Usage: ./node-bootstrap/rock5b/render-node-config.sh <rock5b-but|rock5b-first|rock5b-coffee> [env-file]
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MAIN_REPO_ROOT="$(cd "$(git -C "${REPO_ROOT}" rev-parse --git-common-dir)/.." && pwd)"

NODE_HOSTNAME="${1:-}"
ENV_FILE="${2:-}"

if [[ -z "${NODE_HOSTNAME}" ]]; then
  echo "Usage: $0 <rock5b-but|rock5b-first|rock5b-coffee> [path-to-env-file]" >&2
  exit 1
fi

case "${NODE_HOSTNAME}" in
  rock5b-but)
    NODE_IP="192.168.1.21"
    LONGHORN_DISK_UUID="eae07c17-83c7-482d-be6a-af565666edbd"
    ;;
  rock5b-first)
    NODE_IP="192.168.1.22"
    LONGHORN_DISK_UUID="8461184d-fba0-4b41-8a69-8166a128498f"
    ;;
  rock5b-coffee)
    NODE_IP="192.168.1.23"
    LONGHORN_DISK_UUID="e3f5fb28-9830-4482-aa19-0b17c49df2ff"
    ;;
  *)
    echo "ERROR: Unknown Rock 5B node '${NODE_HOSTNAME}'. Expected rock5b-but, rock5b-first, or rock5b-coffee." >&2
    exit 1
    ;;
esac

if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
else
  for candidate in \
    "${REPO_ROOT}/.secrets/rock5b.env" \
    "${MAIN_REPO_ROOT}/.secrets/rock5b.env" \
    "${REPO_ROOT}/.secrets/pi0-lcn.env" \
    "${MAIN_REPO_ROOT}/.secrets/pi0-lcn.env"; do
    if [[ -f "${candidate}" ]]; then
      # shellcheck disable=SC1090
      source "${candidate}"
      break
    fi
  done
fi

if [[ -z "${K3S_TOKEN:-}" ]]; then
  read -rsp "K3s Cluster Server Token (/var/lib/rancher/k3s/server/node-token): " K3S_TOKEN
  echo >&2
fi

: "${K3S_TOKEN:?K3S_TOKEN must be provided}"

if [[ "${K3S_TOKEN}" == *"::agent:"* ]]; then
  echo "ERROR: K3S_TOKEN appears to be an agent-only token (::agent:). Control-plane nodes require the server token (/var/lib/rancher/k3s/server/node-token)." >&2
  exit 1
fi

OUT_DIR="${SCRIPT_DIR}/build"
mkdir -p "${OUT_DIR}"
OUT_FILE="${OUT_DIR}/${NODE_HOSTNAME}-cloud-config.yaml"

TEMPLATE="$(<"${SCRIPT_DIR}/cloud-config.yaml.tpl")"
RENDERED="${TEMPLATE//__NODE_HOSTNAME__/"${NODE_HOSTNAME}"}"
RENDERED="${RENDERED//__NODE_IP__/"${NODE_IP}"}"
RENDERED="${RENDERED//__LONGHORN_DISK_UUID__/"${LONGHORN_DISK_UUID}"}"
RENDERED="${RENDERED//__K3S_TOKEN__/"${K3S_TOKEN}"}"

printf '%s\n' "${RENDERED}" > "${OUT_FILE}"
chmod 0600 "${OUT_FILE}"

echo ">>> Rendered Kairos cloud-config for ${NODE_HOSTNAME} (${NODE_IP}) -> ${OUT_FILE}"
