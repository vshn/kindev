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

.PHONY: vshnall
vhsnall: vshnpostgresql vshnredis

.PHONY: vshnpostgresql
vshnpostgresql: certmanager-setup stackgres-setup prometheus-setup minio-setup metallb-setup ## Install vshn postgres dependencies

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
$(crossplane_sentinel): kind-setup csi-host-path-setup load-comp-image
	helm repo add crossplane https://charts.crossplane.io/stable --force-update
	helm upgrade --install crossplane --create-namespace --namespace syn-crossplane crossplane/crossplane \
	--set "args[0]='--debug'" \
	--set "args[1]='--enable-environment-configs'" \
	--wait
	@touch $@

stackgres-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
stackgres-setup: $(crossplane_sentinel) ## Install StackGres
	helm repo add stackgres-charts https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/
	helm upgrade --install --version 1.7.0 --create-namespace --namespace stackgres stackgres-operator  stackgres-charts/stackgres-operator --values stackgres/values.yaml --wait
	kubectl -n stackgres wait --for condition=Available deployment/stackgres-operator --timeout 120s

	# wait max 60 seconds for secret to be created - it takes little bit longer now for secret to appear, therefore we need a mechanism to block execution until it appears
	@for i in $$(seq 1 60); do \
        if kubectl get secret stackgres-restapi-admin -n stackgres > /dev/null 2>&1; then \
            echo "Secret found!"; \
            break; \
        else \
            echo "Secret not found. Retrying ($$i/60)..."; \
            sleep 1; \
        fi; \
	done;
	
	# Set simple credentials for development
	NEW_USER=admin &&\
	NEW_PASSWORD=password &&\
	patch=$$(kubectl create secret generic -n stackgres stackgres-restapi-admin  --dry-run=client -o json \
		--from-literal=k8sUsername="$$NEW_USER" \
		--from-literal=password="$$(echo -n "$${NEW_USER}$${NEW_PASSWORD}"| sha256sum | awk '{ print $$1 }' )") &&\
	kubectl patch secret -n stackgres stackgres-restapi-admin -p "$$patch" &&\
	kubectl patch secrets --namespace stackgres stackgres-restapi-admin --type json -p '[{"op":"remove","path":"/data/clearPassword"}]' | true &&\
	encoded=$$(echo -n "$$NEW_PASSWORD" | base64) && \
	kubectl patch secrets --namespace stackgres stackgres-restapi-admin --type json -p "[{\"op\":\"add\",\"path\":\"/data/clearPassword\", \"value\":\"$${encoded}\"}]" | true

certmanager-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
certmanager-setup: $(crossplane_sentinel)
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml
	kubectl -n cert-manager wait --for condition=Available deployment/cert-manager --timeout 120s
	kubectl -n cert-manager wait --for condition=Available deployment/cert-manager-webhook --timeout 120s

minio-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
minio-setup: crossplane-setup ## Install Minio Crossplane implementation
	helm repo add minio https://charts.min.io/ --force-update
	helm upgrade --install --create-namespace --namespace minio minio --version 5.0.7 minio/minio \
	--values minio/values.yaml
	kubectl apply -f minio/gui-ingress.yaml
	kubectl create ns syn-crossplane || true
	kubectl apply -f minio/credentials.yaml
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
$(local_pv_sentinel): unset-default-sc
	kubectl apply -f local-pv
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

csi-host-path-setup: $(csi_sentinel) ## Setup csi-driver-host-path and set as default, this provider supports resizing

$(csi_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(csi_sentinel): unset-default-sc
	cd csi-host-path && \
	kubectl apply -f snapshot-controller.yaml && \
	kubectl apply -f storageclass.yaml && \
	./deploy.sh
	kubectl patch storageclass csi-hostpath-fast -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
	@touch $@

.PHONY: clean
clean: kind-clean ## Clean up local dev environment

metallb-setup: $(metallb_sentinel) ## Install metallb as loadbalancer

$(metallb_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(metallb_sentinel):
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
	kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=90s
	kubectl apply -f metallb/config.yaml
	touch $@

komoplane-setup: $(komoplane_sentinel) ## Install komoplane crossplane troubleshooter

$(komoplane_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(komoplane_sentinel):
	helm repo add komodorio https://helm-charts.komodor.io --force-update
	helm upgrade --install --create-namespace --namespace komoplane komoplane komodorio/komoplane
	kubectl apply -f komoplane
	touch $@

.PHONY: unset-default-sc
unset-default-sc: export KUBECONFIG = $(KIND_KUBECONFIG)
unset-default-sc:
	for sc in $$(kubectl get sc -o name) ; do \
		kubectl patch $$sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'; \
	done
