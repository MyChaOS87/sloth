#!/bin/bash
set -euo pipefail

Help() {
  echo "USAGE:"
  echo "$0 [-h] [-s <k8sHost>] [-c <cluster>] [-u <user>]"
  echo "Retrieve k3s credentials and add them to your local kubectl config"
  echo
  echo "-h                Display this help"
  echo "-s <k8sHost>      k8sHost to access for credentials (mandatory)"
  echo "-u <user>         User for ssh connection to host (default: pi)"
  echo "-c <cluster>      local clustername used for cluster, context and credentials in kube-config (default: sloth)"
}

k8sHost=""
user="pi"
cluster="sloth"

while getopts ":hs:u:c:" option; do
  case "${option}" in
    h)
      Help
      exit 0
      ;;
    s)
      k8sHost="${OPTARG}"
      ;;
    u)
      user="${OPTARG}"
      ;;
    c)
      cluster="${OPTARG}"
      ;;
    \?)
      echo "Error: Invalid option" >&2
      Help >&2
      exit 2
      ;;
  esac
done

credentials="${cluster}_root"
context="${cluster}-root"

if [[ -z "${k8sHost}" ]]; then
  echo '"k8sHost" unset (use -s flag)... no host to contact' >&2
  Help >&2
  exit 2
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.check.lib.sh
source "${REPO_ROOT}/.check.lib.sh"
check_programs_available kubectl scp base64 awk

mkdir -p "${REPO_ROOT}/.secrets"
chmod 700 "${REPO_ROOT}/.secrets"
work_dir="$(mktemp -d "${REPO_ROOT}/.secrets/kubeconfig.XXXXXX")"
chmod 700 "${work_dir}"
trap 'rm -rf "${work_dir}"' EXIT

echo "Using Host \"${k8sHost}\" to retrieve certificates"
scp "${user}@${k8sHost}:/etc/rancher/k3s/k3s.yaml" "${work_dir}/k3s.yaml"

extract_b64_field() {
  local field="$1"
  local out="$2"
  local b64=""
  b64="$(awk -v k="${field}:" '$1 == k {print $2; exit}' "${work_dir}/k3s.yaml" | tr -d '[:space:]')"
  [[ -n "${b64}" ]] || { echo "ERROR: missing ${field} in k3s.yaml" >&2; return 1; }
  printf '%s' "${b64}" | base64 -d > "${out}"
}

echo "Extracting Secrets ..."
extract_b64_field "certificate-authority-data" "${work_dir}/certificate-authority.crt"
extract_b64_field "client-certificate-data" "${work_dir}/client-certificate.crt"
extract_b64_field "client-key-data" "${work_dir}/client.key"

echo "Set the cluster ${cluster} ..."
kubectl config set-cluster "${cluster}" --server="https://${k8sHost}:6443" --embed-certs=true --certificate-authority="${work_dir}/certificate-authority.crt"

echo "Set the credentials ${credentials} ..."
kubectl config set-credentials "${credentials}" --embed-certs=true --client-certificate="${work_dir}/client-certificate.crt" --client-key="${work_dir}/client.key"

echo "Set the context ${context} ..."
kubectl config set-context "${context}" --cluster "${cluster}" --user "${credentials}"

echo "Use the context ..."
kubectl config use-context "${context}"

echo "Test the context ..."
kubectl cluster-info
