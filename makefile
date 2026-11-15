.DEFAULT_GOAL := argocd.install

DEFAULT_PRIVATE_DIR := $(abspath $(firstword $(wildcard ../../sloth-private/$(notdir $(CURDIR))) $(wildcard ../sloth-private) $(wildcard $(abspath $(shell git rev-parse --git-common-dir 2>/dev/null || echo .git)/../..)/sloth-private) ../sloth-private))
SLOTH_PRIVATE_DIR ?= $(DEFAULT_PRIVATE_DIR)

GO_MOD_VERSION := $(shell go env GOVERSION | sed -E 's/^go([0-9]+\.[0-9]+).*/\1/')
TOOLS_DIR := $(CURDIR)/tools
LEFTHOOK_BIN := $(CURDIR)/.cache/bin/lefthook
GO_TOOL = "$$(go -C "$(TOOLS_DIR)/$(1)" tool -n $(1))"

MANIFEST_DIRS := argocd-base nodes cluster-essentials deployments
CONFTEST_BASE_FILES := $(shell find $(MANIFEST_DIRS) -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/templates/*' -not -path '*/charts/*' | sort)
CONFTEST_EXAMPLE_FILES := $(shell find examples/sloth-private -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sealed.json' \) | sort)
CONFTEST_PRIVATE_DIRS := $(wildcard $(addprefix $(SLOTH_PRIVATE_DIR)/,argocd-base cluster-essentials deployments private values))
CONFTEST_PRIVATE_FILES := $(if $(CONFTEST_PRIVATE_DIRS),$(shell find $(CONFTEST_PRIVATE_DIRS) -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sealed.json' \) -not -path '*/templates/*' -not -path '*/charts/*' | sort),)

SEALEDSECRETSVERSION=$(shell yq ". | select(.kind == \"Application\") | .spec.source.targetRevision" cluster-essentials/sealed-secrets.yaml)
ARGOCDVERSION=$(shell yq ". | select(.kind == \"Application\") | .spec.sources[0].targetRevision" argocd-base/argocd.yaml)

$(LEFTHOOK_BIN): checkPrerequisites.go $(TOOLS_DIR)/lefthook/go.mod $(TOOLS_DIR)/lefthook/go.sum $(TOOLS_DIR)/lefthook/dummy.go
	@mkdir -p $(dir $@)
	@go -C "$(TOOLS_DIR)/lefthook" build -o "$@" github.com/evilmartians/lefthook/v2

.PHONY: checkPrerequisites.go
checkPrerequisites.go:
	@command -v go >/dev/null || (echo "ERROR: cannot find tool 'go'"; false)

.PHONY: checkPrerequisites.kubectl
checkPrerequisites.kubectl:
	@command -v kubectl >/dev/null || (echo "ERROR: cannot find tool 'kubectl'"; false)

.PHONY: checkPrerequisites.helm
checkPrerequisites.helm: checkPrerequisites.kubectl
	@command -v helm >/dev/null || (echo "ERROR: cannot find tool 'helm'"; false)

.PHONY: checkPrerequisites.yq
checkPrerequisites.yq:
	@command -v yq >/dev/null || (echo "ERROR: cannot find tool 'yq'"; false)

.PHONY: checkPrerequisites.jq
checkPrerequisites.jq:
	@command -v jq >/dev/null || (echo "ERROR: cannot find tool 'jq'"; false)

.PHONY: checkPrerequisites.kubeseal
checkPrerequisites.kubeseal: checkPrerequisites.kubectl
	@command -v kubeseal >/dev/null || (echo "ERROR: cannot find tool 'kubeseal'"; false)

.PHONY: checkPrerequisites.all
checkPrerequisites.all: checkPrerequisites.go checkPrerequisites.kubectl checkPrerequisites.helm checkPrerequisites.yq checkPrerequisites.jq checkPrerequisites.kubeseal hooks.install

.PHONY: hooks.install
hooks.install: checkPrerequisites.go $(LEFTHOOK_BIN)
	@PATH="$(dir $(LEFTHOOK_BIN)):$$PATH" "$(LEFTHOOK_BIN)" install

.PHONY: tools-tidy
tools-tidy: checkPrerequisites.go
	@for d in tools/* ; do \
		if [ -d "$$d" ] && [ -f "$$d/go.mod" ] ; then \
			echo "Tidying $$d..." ; \
			go -C "$$d" mod tidy || exit 1 ; \
		fi ; \
	done

.PHONY: tools-update
tools-update: checkPrerequisites.go
	@for d in tools/* ; do \
		if [ -d "$$d" ] && [ -f "$$d/go.mod" ] ; then \
			echo "Updating $$d (go $(GO_MOD_VERSION))..." ; \
			go -C "$$d" mod edit -go=$(GO_MOD_VERSION) -toolchain=none || exit 1 ; \
			( cd "$$d" && go get -u $$(go list -f '{{if not (or .Main .Indirect)}}{{.Path}}{{end}}' -m all) && go mod tidy ) || exit 1 ; \
		fi ; \
	done

.PHONY: fmt
fmt: checkPrerequisites.go
	@$(call GO_TOOL,yamlfmt) -dstar '**/*.yaml' '**/*.yml'

.PHONY: check.blacklist
check.blacklist:
	@SLOTH_PRIVATE_DIR="$(SLOTH_PRIVATE_DIR)" ./scripts/check-blacklist.sh --all

.PHONY: check.yaml
check.yaml: checkPrerequisites.go
	@$(call GO_TOOL,yamlfmt) -dstar -lint '**/*.yaml' '**/*.yml'

.PHONY: check.manifests
check.manifests: checkPrerequisites.go
	@$(call GO_TOOL,conftest) test --combine -p policy $(CONFTEST_BASE_FILES) $(CONFTEST_EXAMPLE_FILES)
	@if [ -n "$(strip $(CONFTEST_PRIVATE_FILES))" ] && \
	   [ "$$(cd "$(SLOTH_PRIVATE_DIR)" && pwd)" != "$$(cd examples/sloth-private && pwd)" ]; then \
		$(call GO_TOOL,conftest) test --combine -p policy $(CONFTEST_BASE_FILES) $(CONFTEST_PRIVATE_FILES); \
	fi

.PHONY: check.helm
check.helm: checkPrerequisites.go checkPrerequisites.helm checkPrerequisites.yq checkPrerequisites.jq
	@SLOTH_PRIVATE_DIR="$(SLOTH_PRIVATE_DIR)" ./scripts/check-helm.sh

.PHONY: check.images
check.images: checkPrerequisites.go checkPrerequisites.helm checkPrerequisites.yq checkPrerequisites.jq
	@SLOTH_PRIVATE_DIR="$(SLOTH_PRIVATE_DIR)" ./scripts/check-images.sh

.PHONY: check
check: hooks.install check.blacklist check.yaml check.manifests check.helm

.PHONY: sealed-secrets.install
sealed-secrets.install: checkPrerequisites.helm checkPrerequisites.yq
	helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
	helm install sealed-secrets --namespace sealed-secrets --create-namespace --set-string fullnameOverride=sealed-secrets-controller --version $(SEALEDSECRETSVERSION) sealed-secrets/sealed-secrets

.PHONY: sealed-secrets.seal.sshDeployKey
sealed-secrets.seal.sshDeployKey: checkPrerequisites.kubeseal
	./create-and-seal-deploy-key.sh

.PHONY: sealed-secrets.uninstall
sealed-secrets.uninstall: checkPrerequisites.helm
	helm uninstall sealed-secrets --namespace sealed-secrets

.PHONY: argocd.install
argocd.install: checkPrerequisites.helm checkPrerequisites.yq
	helm repo add argo https://argoproj.github.io/argo-helm
	yq -r ". | select(.kind == \"Application\") | .spec.sources[0].helm.values" argocd-base/argocd.yaml > .argocd.values.yaml
	helm install argocd --namespace argocd --create-namespace --version $(ARGOCDVERSION) -f $(SLOTH_PRIVATE_DIR)/values/argocd.yaml -f .argocd.values.yaml argo/argo-cd
	kubectl apply -f argocd-base/argocd-base.yaml
	kubectl apply -f $(SLOTH_PRIVATE_DIR)/argocd-base/repository-private.sealed.json
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
