#!/usr/bin/env bash
# Populate a mounted DietPi (ARMv8 64-bit) SD card boot partition for zero-touch pi0-lcn provisioning.
# Usage: ./node-bootstrap/pi0-lcn/prepare-boot.sh <boot-mount-path> [env-file]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BOOT_DIR="${1:-}"
ENV_FILE="${2:-${REPO_ROOT}/.secrets/pi0-lcn.env}"

if [[ -z "${BOOT_DIR}" || ! -d "${BOOT_DIR}" ]]; then
  echo "Usage: $0 <mounted-boot-partition-path> [path-to-pi0-lcn.env]" >&2
  echo "Example: $0 /run/media/$USER/boot" >&2
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${K3S_URL:=https://192.168.1.20:6443}"
: "${K3S_VERSION:=v1.37.2+k3s1}"

if [[ -z "${WIFI_SSID:-}" ]]; then
  read -rp "Wi-Fi SSID: " WIFI_SSID
fi
if [[ -z "${WIFI_KEY:-}" ]]; then
  read -rsp "Wi-Fi Password: " WIFI_KEY
  echo >&2
fi
if [[ -z "${DIETPI_PASSWORD:-}" ]]; then
  read -rsp "DietPi Root/Global Password: " DIETPI_PASSWORD
  echo >&2
fi
if [[ -z "${K3S_TOKEN:-}" ]]; then
  read -rsp "K3s Node Token: " K3S_TOKEN
  echo >&2
fi

: "${K3S_TOKEN:?K3S_TOKEN must be provided}"
: "${K3S_VERSION:?K3S_VERSION must be provided (e.g. v1.37.2+k3s1) to match cluster servers}"
: "${WIFI_SSID:?WIFI_SSID must be provided}"
: "${WIFI_KEY:?WIFI_KEY must be provided}"
: "${DIETPI_PASSWORD:?DIETPI_PASSWORD must be provided}"

# 1. Preserve DietPi's existing config.txt while appending/updating the sloth pi0-lcn block
MARKER_BEGIN="# BEGIN sloth pi0-lcn"
MARKER_END="# END sloth pi0-lcn"
if [[ -f "${BOOT_DIR}/config.txt" ]]; then
  BASE_CONFIG="$(awk -v b="${MARKER_BEGIN}" -v e="${MARKER_END}" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }
  ' "${BOOT_DIR}/config.txt")"
  if [[ -n "${BASE_CONFIG}" ]]; then
    printf '%s\n\n' "${BASE_CONFIG}" > "${BOOT_DIR}/config.txt"
  else
    : > "${BOOT_DIR}/config.txt"
  fi
else
  : > "${BOOT_DIR}/config.txt"
fi
{
  echo "${MARKER_BEGIN}"
  cat "${SCRIPT_DIR}/config.txt"
  echo "${MARKER_END}"
} >> "${BOOT_DIR}/config.txt"

# 2. Preserve DietPi's existing cmdline.txt while ensuring cgroup flags are present on line 1
if [[ -f "${BOOT_DIR}/cmdline.txt" ]]; then
  CMDLINE="$(head -n 1 "${BOOT_DIR}/cmdline.txt" | tr -d '\r\n')"
  for flag in cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1; do
    if [[ " ${CMDLINE} " != *" ${flag} "* ]]; then
      CMDLINE="${CMDLINE} ${flag}"
    fi
  done
  printf '%s\n' "${CMDLINE}" > "${BOOT_DIR}/cmdline.txt"
else
  cp "${SCRIPT_DIR}/cmdline.txt" "${BOOT_DIR}/cmdline.txt"
fi

# 3. Copy udev rule, Ansible playbook, and first-boot wrapper script
cp "${SCRIPT_DIR}/99-lcn-pku.rules" "${BOOT_DIR}/99-lcn-pku.rules"
cp "${SCRIPT_DIR}/playbook.yml" "${BOOT_DIR}/playbook.yml"
cp "${SCRIPT_DIR}/Automation_Custom_Script.sh" "${BOOT_DIR}/Automation_Custom_Script.sh"
chmod +x "${BOOT_DIR}/Automation_Custom_Script.sh"

# 4. Render dietpi.txt using quoted bash replacement (disables patsub_replacement & and \ expansion)
DIETPI_TEMPLATE="$(<"${SCRIPT_DIR}/dietpi.txt")"
printf '%s\n' "${DIETPI_TEMPLATE//__DIETPI_PASSWORD__/"${DIETPI_PASSWORD}"}" > "${BOOT_DIR}/dietpi.txt"

# 5. Render dietpi-wifi.txt (escaping single quotes if present)
ESCAPED_SSID="${WIFI_SSID//\'/\'\\\'\'}"
ESCAPED_WIFI_KEY="${WIFI_KEY//\'/\'\\\'\'}"
cat <<EOF > "${BOOT_DIR}/dietpi-wifi.txt"
aWIFI_SSID[0]='${ESCAPED_SSID}'
aWIFI_KEY[0]='${ESCAPED_WIFI_KEY}'
aWIFI_KEYMGR[0]='WPA-PSK'
EOF

# 6. Render temporary k3s-vars.yml using jq for safe JSON/YAML string escaping
jq -n \
  --arg k3s_url "${K3S_URL}" \
  --arg k3s_token "${K3S_TOKEN}" \
  --arg k3s_version "${K3S_VERSION}" \
  '{k3s_url: $k3s_url, k3s_token: $k3s_token, k3s_version: $k3s_version}' > "${BOOT_DIR}/k3s-vars.yml"
chmod 0600 "${BOOT_DIR}/k3s-vars.yml" 2>/dev/null || true

sync
echo "Successfully prepared DietPi zero-touch boot partition at ${BOOT_DIR} for pi0-lcn."
