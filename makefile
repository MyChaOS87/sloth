.DEFAULT_GOAL := argocd.install

.PHONY: sealed-secrets.install
sealed-secrets.install:
	helm install sealed-secrets ./argocd/sealed-secrets --namespace kube-system

.PHONY: sealed-secrets.seal.sshRepoKey
sealed-secrets.seal.sshDeployKey:
	./create-and-seal-deploy-key.sh

.PHONY: sealed-secrets.uninstall
sealed-secrets.uninstall:
	helm uninstall sealed-secrets --namespace kube-system

.PHONY: argocd.install
argocd.install:
	helm install argocd ./argocd/argocd --namespace argocd --create-namespace
	helm install argocd-apps ./argocd/apps --namespace argocd

.PHONY: argocd.password
argocd.password:
	kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo


.PHONY: argocd.port-forward
argocd.port-forward:
	kubectl port-forward svc/argocd-server -n argocd 8080:80

.PHONY: argocd.uninstall
argocd.uninstall:
	helm uninstall argocd-apps --namespace argocd
	helm uninstall argocd --namespace argocd 
	kubectl delete ns argocd
	kubectl delete CustomResourceDefinition applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io

