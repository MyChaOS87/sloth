#!/bin/bash
set -e +x

source $(dirname -- "${BASH_SOURCE[0]}")/.check.lib.sh

check_programs_available kubeseal openssl
assert_no_overwrite cluster-essentials/metallb-config/memberlist.sealed.json

echo -n Creating memberlist secret and sealing it ... 1>&2
kubeseal --controller-namespace sealed-secrets > cluster-essentials/metallb-config/memberlist.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: memberlist
  namespace: metallb
data:
  secretkey: $(openssl rand -base64 128 | tr -d "\n")
EOF

echo done 1>&2