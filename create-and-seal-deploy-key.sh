#!/bin/bash
set -e +x

source $(dirname -- "${BASH_SOURCE[0]}")/.check.lib.sh

check kubeseal ssh-keygen kubectl

mkdir -p .secrets/.ssh/
chmod 700 .secrets/.ssh/

echo Creating new SSH Keypair ... 1>&2
ssh-keygen -q -b4096 -N '' -t rsa -f .secrets/.ssh/id_rsa -C argocd@$(kubectl config current-context)

echo Sealing Private key into secret ... 1>&2
kubeseal --controller-namespace sealed-secrets > argocd-base/repository.sealed.json << EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo.com.github.mychaos87.sloth
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@github.com:mychaos87/sloth.git
  sshPrivateKey: |
$(cat .secrets/.ssh/id_rsa | sed 's/^/    /')
EOF

echo Storing Public Key as \"./deploy_key.pub\" ... 1>&2
mv .secrets/.ssh/id_rsa.pub ./deploy_key.pub

echo Cleanup Temporary Files 1>&2
rm .secrets/.ssh/id_rsa
rmdir .secrets/.ssh/

echo Your Public Deploy Key is, add that as a deploy key to your github repo: 1>&2
cat ./deploy_key.pub