#!/bin/sh
# Executed automatically by DietPi at the end of first-boot provisioning on pi0-lcn.
# Installs lightweight ansible-core and runs playbook.yml against localhost.
set -eu

BOOT_DIR="/boot"
if [ -f /boot/firmware/playbook.yml ]; then
  BOOT_DIR="/boot/firmware"
fi

trap 'rm -f "${BOOT_DIR}/k3s-vars.yml" /boot/k3s-vars.yml /boot/firmware/k3s-vars.yml' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends ansible-core ca-certificates

ansible-playbook --connection=local -i localhost, -e "@${BOOT_DIR}/k3s-vars.yml" "${BOOT_DIR}/playbook.yml"
