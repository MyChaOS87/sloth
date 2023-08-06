.DEFAULT_GOAL := argocd.install

SEALEDSECRETSVERSION=$(shell yq ". | select(.kind == \"Application\") | .spec.source.targetRevision" cluster-essentials/sealed-secrets.yaml)
ARGOCDVERSION=$(shell yq ". | select(.kind == \"Application\") | .spec.source.targetRevision" argocd-base/argocd.yaml)

.PHONY: checkPrerequisites.kubectl
checkPrerequisites.kubectl:
	@command -v kubectl >/dev/null || (echo "ERROR: cannot find tool 'kubectl'"; false)

.PHONY: checkPrerequisites.helm
checkPrerequisites.helm: checkPrerequisites.kubectl
	@command -v helm >/dev/null || (echo "ERROR: cannot find tool 'helm'"; false)

.PHONY: checkPrerequisites.yq
checkPrerequisites.yq: 
	@command -v yq >/dev/null || (echo "ERROR: cannot find tool 'yq'"; false)

.PHONY: checkPrerequisites.kubeseal
checkPrerequisites.kubeseal: checkPrerequisites.kubectl
	@command -v kubeseal >/dev/null || (echo "ERROR: cannot find tool 'kubeseal'"; false)

.PHONY: checkPrerequisites.all
checkPrerequisites.all: checkPrerequisites.kubectl checkPrerequisites.helm checkPrerequisites.yq checkPrerequisites.kubeseal

.PHONY: sealed-secrets.install
sealed-secrets.install: checkPrerequisites.helm checkPrerequisites.yq 
	helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
	helm install sealed-secrets --namespace sealed-secrets --create-namespace --set-string fullnameOverride=sealed-secrets-controller --version $(SEALEDSECRETSVERSION) sealed-secrets/sealed-secrets

.PHONY: sealed-secrets.seal.sshRepoKey
sealed-secrets.seal.sshDeployKey: checkPrerequisites.kubeseal
	./create-and-seal-deploy-key.sh

.PHONY: sealed-secrets.uninstall
sealed-secrets.uninstall: checkPrerequisites.helm
	helm uninstall sealed-secrets --namespace sealed-secrets

.PHONY: argocd.install
argocd.install: checkPrerequisites.helm checkPrerequisites.yq
	helm repo add argo https://argoproj.github.io/argo-helm
	yq -r ". | select(.kind == \"Application\") | .spec.source.helm.values" argocd-base/argocd.yaml > .argocd.values.yaml
	helm install argocd --namespace argocd --create-namespace --version $(ARGOCDVERSION) -f .argocd.values.yaml argo/argo-cd
	kubectl create -f argocd-base/argocd-base.yaml               
	kubectl create -f repository.sealed.json
	rm .argocd.values.yaml

.PHONY: argocd.password
argocd.password: checkPrerequisites.kubectl
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo


.PHONY: argocd.port-forward
argocd.port-forward: checkPrerequisites.kubectl
	kubectl port-forward svc/argocd-server -n argocd 8080:80

.PHONY: argocd.uninstall
argocd.uninstall: checkPrerequisites.helm
	helm uninstall argocd-base --namespace argocd
	helm uninstall argocd --namespace argocd 
	kubectl delete ns argocd
	kubectl delete CustomResourceDefinition applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io

