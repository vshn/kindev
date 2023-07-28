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

.PHONY: appcat-apiserver
appcat-apiserver: vshnpostgresql ## Install appcat-apiserver dependencies

.PHONY: vshnpostgresql
vshnpostgresql: certmanager-setup stackgres-setup prometheus-setup minio-setup metallb ## Install vshn postgres dependencies

.PHONY: vshnredis
vshnredis: certmanager-setup k8up-setup ## Install vshn redis dependencies

.PHONY: help
help: ## Show this help
	@grep -E -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## All-in-one linting
	@echo 'Check for uncommitted changes ...'
	git diff --exit-code

crossplane-setup: $(crossplane_sentinel) ## Install local Kubernetes cluster and install Crossplane

$(crossplane_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(crossplane_sentinel): kind-setup local-pv-setup load-comp-image
	helm repo add crossplane https://charts.crossplane.io/stable
	helm upgrade --install crossplane --create-namespace --namespace syn-crossplane crossplane/crossplane \
	--set "args[0]='--debug'" \
	--set "args[1]='--enable-composition-functions'" \
	--set "args[2]='--enable-environment-configs'" \
	--set "xfn.enabled=$(enable_xfn)" \
	--set "xfn.args[0]='--log-level'" \
	--set "xfn.args[1]='1'" \
	--set "xfn.args[2]='--devmode'" \
	--set "xfn.image.repository=ghcr.io/vshn/appcat" \
	--set "xfn.image.tag=latest" \
	--wait
	@touch $@

stackgres-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
stackgres-setup: $(crossplane_sentinel) ## Install StackGres
	helm repo add stackgres-charts https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/
	helm upgrade --install --create-namespace --namespace stackgres stackgres-operator  stackgres-charts/stackgres-operator \
	--values stackgres/values.yaml
	# Set simple credentials for development
	NEW_USER=admin &&\
	NEW_PASSWORD=password &&\
	patch=$$(kubectl create secret generic -n stackgres stackgres-restapi  --dry-run=client -o json \
	  --from-literal=k8sUsername="$$NEW_USER" \
	  --from-literal=password="$$(echo -n "$${NEW_USER}$${NEW_PASSWORD}"| sha256sum | awk '{ print $$1 }' )") &&\
	kubectl patch secret -n stackgres stackgres-restapi -p "$$patch" &&\
	kubectl patch secrets --namespace stackgres stackgres-restapi --type json -p '[{"op":"remove","path":"/data/clearPassword"}]' | true &&\
	encoded=$$(echo -n "$$NEW_PASSWORD" | base64) && \
	kubectl patch secrets --namespace stackgres stackgres-restapi --type json -p "[{\"op\":\"add\",\"path\":\"/data/clearPassword\", \"value\":\"$${encoded}\"}]" | true

certmanager-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
certmanager-setup: $(crossplane_sentinel)
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml

minio-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
minio-setup: crossplane-setup ## Install Minio Crossplane implementation
	helm repo add minio https://charts.min.io/ --force-update
	helm upgrade --install --create-namespace --namespace minio minio --version 5.0.7 minio/minio \
	--values minio/values.yaml
	kubectl apply -f minio/gui-ingress.yaml
	@echo -e "***\n*** Installed minio in http://minio.127.0.0.1.nip.io:8088\n***"
	@echo -e "***\n*** use with mc:\n mc alias set localnip http://minio.127.0.0.1.nip.io:8088 minioadmin minioadmin\n***"
	@echo -e "***\n*** console access http://minio-gui.127.0.0.1.nip.io:8088\n***"

k8up-setup: minio-setup prometheus-setup $(k8up_sentinel) ## Install K8up operator

$(k8up_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(k8up_sentinel): kind-setup
	helm repo add k8up-io https://k8up-io.github.io/k8up
	kubectl apply -f https://github.com/k8up-io/k8up/releases/latest/download/k8up-crd.yaml
	helm upgrade --install k8up \
		--create-namespace \
		--namespace k8up-system \
		--wait \
		--values k8up/values.yaml \
		k8up-io/k8up
	kubectl -n k8up-system wait --for condition=Available deployment/k8up --timeout 60s
	@touch $@

local-pv-setup: $(local_pv_sentinel) ## Installs an alternative local-pv provider, that has slightly more features

$(local_pv_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(local_pv_sentinel):
	kubectl apply -f local-pv
	kubectl patch storageclass standard -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
	kubectl patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
	@touch $@

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
	@echo -e "***\n*** Installed Prometheus in http://127.0.0.1.nip.io:8088/prometheus/ and AlertManager in http://127.0.0.1.nip.io:8088/alertmanager/.\n***"
	@touch $@

load-comp-image: ## Load the appcat-comp image if it exists
	[[ "$$(docker images -q ghcr.io/vshn/appcat 2> /dev/null)" != "" ]] && kind load docker-image --name kindev ghcr.io/vshn/appcat || true

.PHONY: clean
clean: kind-clean ## Clean up local dev environment

metallb: export KUBECONFIG = $(KIND_KUBECONFIG)
metallb:
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
	kubectl wait --namespace metallb-system \
                --for=condition=ready pod \
                --selector=app=metallb \
                --timeout=90s
	kubectl apply -f metallb/config.yaml