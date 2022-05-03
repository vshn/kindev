# Set Shell to bash, otherwise some targets fail with dash/zsh etc.
SHELL := /bin/bash

# Disable built-in rules
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
.SUFFIXES:
.SECONDARY:
.DEFAULT_GOAL := help

# General variables
include Makefile.vars.mk
# KIND module
include kind/kind.mk
# Docs module
include docs/antora-preview.mk docs/antora-build.mk

.PHONY: help
help: ## Show this help
	@grep -E -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## All-in-one linting
	@echo 'Check for uncommitted changes ...'
	git diff --exit-code

.PHONY: .service-definition
.service-definition: crossplane-setup k8up-setup prometheus-setup
	kubectl apply -f crossplane/composite.yaml
	kubectl apply -f crossplane/composition.yaml
	kubectl wait --for condition=Offered compositeresourcedefinition/xredisinstances.syn.tools

.PHONY: provision
provision: export KUBECONFIG = $(KIND_KUBECONFIG)
provision: .service-definition ## Install local Kubernetes cluster and provision the service instance
	kubectl apply -f service/prototype-instance.yaml
	kubectl wait -n my-app --for condition=Ready RedisInstance.syn.tools/redis1 --timeout 180s
	kubectl apply -f service/test-job.yaml
	kubectl wait -n my-app --for condition=Complete job/service-connection-verify

.PHONY: deprovision
deprovision: export KUBECONFIG = $(KIND_KUBECONFIG)
deprovision: kind-setup ## Uninstall the service instance
	kubectl delete -f service/prototype-instance.yaml

.PHONY: crossplane-setup
crossplane-setup: $(crossplane_sentinel) ## Install local Kubernetes cluster and install Crossplane

$(crossplane_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(crossplane_sentinel): kind-setup
	helm repo add crossplane https://charts.crossplane.io/stable
	helm repo add mittwald https://helm.mittwald.de
	helm upgrade --install crossplane --create-namespace --namespace crossplane-system crossplane/crossplane --set "args[0]='--debug'" --set "args[1]='--enable-composition-revisions'" --wait
	helm upgrade --install secret-generator --create-namespace --namespace secret-generator mittwald/kubernetes-secret-generator --wait
	kubectl apply -f crossplane/provider.yaml
	kubectl wait --for condition=Healthy provider.pkg.crossplane.io/provider-helm --timeout 60s
	kubectl apply -f crossplane/provider-config.yaml
	kubectl create clusterrolebinding crossplane:provider-helm-admin --clusterrole cluster-admin --serviceaccount crossplane-system:$$(kubectl get sa -n crossplane-system -o custom-columns=NAME:.metadata.name --no-headers | grep provider-helm)
	kubectl create clusterrolebinding crossplane:cluster-admin --clusterrole cluster-admin --serviceaccount crossplane-system:crossplane
	@touch $@

.PHONY: minio-setup
minio-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
minio-setup: crossplane-setup ## Install Minio Crossplane implementation
	kubectl apply -f minio/s3-composite.yaml
	kubectl apply -f minio/s3-composition.yaml
	kubectl wait --for condition=Offered compositeresourcedefinition/xs3buckets.syn.tools

.PHONY: k8up-setup
k8up-setup: minio-setup prometheus-setup $(k8up_sentinel) ## Install K8up operator

$(k8up_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(k8up_sentinel): kind-setup
	helm repo add appuio https://charts.appuio.ch
	kubectl apply -f https://github.com/k8up-io/k8up/releases/latest/download/k8up-crd.yaml
	helm upgrade --install k8up \
		--create-namespace \
		--namespace k8up-system \
		--wait \
		--values k8up/values.yaml \
		appuio/k8up
	kubectl -n k8up-system wait --for condition=Available deployment/k8up --timeout 60s
	@touch $@

.PHONY: prometheus-setup
prometheus-setup: $(prometheus_sentinel) ## Install Prometheus stack

$(prometheus_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(prometheus_sentinel): kind-setup-ingress
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm upgrade --install kube-prometheus \
		--create-namespace \
		--namespace prometheus-system \
		--wait \
		--values prometheus/values.yaml \
		prometheus-community/kube-prometheus-stack
	kubectl -n prometheus-system wait --for condition=Available deployment/kube-prometheus-kube-prome-operator --timeout 120s
	@echo -e "***\n*** Installed Prometheus in http://127.0.0.1.nip.io:8081/prometheus/ and AlertManager in http://127.0.0.1.nip.io:8081/alertmanager/.\n***"
	@touch $@

.PHONY: clean
clean: kind-clean ## Clean up local dev environment
