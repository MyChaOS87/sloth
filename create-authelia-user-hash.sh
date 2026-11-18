#!/bin/bash
set -euo pipefail

IMAGE="ghcr.io/authelia/authelia:4.39.28"

if command -v argon2 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  password=""
  if [[ -t 0 ]]; then
    read -r -s -p "Enter Authelia user password: " password
    echo >&2
    read -r -s -p "Confirm Authelia user password: " confirm_password
    echo >&2
    if [[ "${password}" != "${confirm_password}" ]]; then
      echo "ERROR: passwords do not match" >&2
      exit 1
    fi
  else
    IFS= read -r password || true
  fi

  if [[ -z "${password}" ]]; then
    echo "ERROR: password must not be empty" >&2
    exit 1
  fi

  salt="$(openssl rand -hex 16)"
  printf '%s' "${password}" | argon2 "${salt}" -id -t 3 -m 16 -p 4 -l 32 -e
elif [[ -t 0 ]] && command -v podman >/dev/null 2>&1; then
  podman run -it --rm "${IMAGE}" authelia crypto hash generate argon2
elif [[ -t 0 ]] && command -v docker >/dev/null 2>&1; then
  docker run -it --rm "${IMAGE}" authelia crypto hash generate argon2
else
  echo "ERROR: non-interactive hashing requires argon2 + openssl (container CLI requires a TTY to avoid --password in argv)" >&2
  exit 1
fi
