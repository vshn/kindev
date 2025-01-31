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
vshnall: vcluster=true
vshnall: vshnpostgresql vshnredis

.PHONY: converged
converged: vcluster=false
converged: vshnpostgresql vshnredis

.PHONY: vcluster
vcluster: vcluster=true
vcluster: vshnall

.PHONY: vshnpostgresql
vshnpostgresql: shared-setup stackgres-setup ## Install vshn postgres dependencies

.PHONY: vshnredis
vshnredis: shared-setup  ## Install vshn redis dependencies

.PHONY: shared-setup ## Install dependencies shared between all services
shared-setup: kind-setup-ingress certmanager-setup k8up-setup netpols-setup forgejo-setup prometheus-setup minio-setup metallb-setup argocd-setup

.PHONY: help
help: ## Show this help
	@grep -E -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## All-in-one linting
	@echo 'Check for uncommitted changes ...'
	git diff --exit-code

kind-storage: kind-setup csi-host-path-setup vcluster-setup

crossplane-setup: $(crossplane_sentinel) ## Install local Kubernetes cluster and install Crossplane

$(crossplane_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(crossplane_sentinel): kind-setup csi-host-path-setup
	helm repo add crossplane https://charts.crossplane.io/stable --force-update
	if $(vcluster); then $(vcluster_bin) connect controlplane --namespace vcluster; fi
	helm upgrade --install crossplane --create-namespace --namespace syn-crossplane crossplane/crossplane \
	--set "args[0]='--debug'" \
	--set "args[1]='--enable-environment-configs'" \
	--set "args[2]='--enable-usages'" \
	--wait
	if $(vcluster); then $(vcluster_bin) disconnect; fi
	@touch $@

stackgres-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
stackgres-setup: kind-setup csi-host-path-setup ## Install StackGres
	helm repo add stackgres-charts https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/ --force-update
	helm upgrade --install --create-namespace --namespace stackgres stackgres-operator  stackgres-charts/stackgres-operator --values stackgres/values.yaml --wait
	kubectl -n stackgres wait --for condition=Available deployment/stackgres-operator --timeout 120s

	# wait max 60 seconds for secret to be created - it takes little bit longer now for secret to appear, therefore we need a mechanism to block execution until it appears
	echo "waiting for stackgres-restapi-admin secret creation..."
	@for i in $$(seq 1 60); do \
        if kubectl get secret stackgres-restapi-admin -n stackgres > /dev/null 2>&1; then \
            break; \
        else \
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

certmanager-setup: $(certmanager-sentinel)

$(certmanager-sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(certmanager-sentinel): kind-storage
$(certmanager-sentinel):
	if $(vcluster); then \
		$(vcluster_bin) connect controlplane --namespace vcluster;\
		$(MAKE) certmanager-install; \
		$(vcluster_bin) disconnect; \
	fi
	$(MAKE) certmanager-install
	@touch $@

certmanager-install: export KUBECONFIG = $(KIND_KUBECONFIG)
certmanager-install:
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml
	kubectl -n cert-manager wait --for condition=Available deployment/cert-manager --timeout 120s
	kubectl -n cert-manager wait --for condition=Available deployment/cert-manager-webhook --timeout 120s

minio-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
minio-setup: kind-storage ## Install Minio Crossplane implementation
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
	kubectl apply -f https://github.com/k8up-io/k8up/releases/latest/download/k8up-crd.yaml --server-side
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
	if $(vcluster); then \
		$(vcluster_bin) connect controlplane --namespace vcluster; \
		$(MAKE) prometheus-install -e PROM_VALUES=prometheus/values_vcluster.yaml; \
		$(vcluster_bin) disconnect; \
	fi
	$(MAKE) prometheus-install
	kubectl apply -f prometheus/netpol.yaml
	@echo -e "***\n*** Installed Prometheus in http://prometheus.127.0.0.1.nip.io:8088/ and AlertManager in http://alertmanager.127.0.0.1.nip.io:8088/.\n***"
	@touch $@

prometheus-install: export KUBECONFIG = $(KIND_KUBECONFIG)
prometheus-install:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm upgrade --install kube-prometheus \
		--create-namespace \
		--namespace prometheus-system \
		--wait \
		--values ${PROM_VALUES} \
		prometheus-community/kube-prometheus-stack
	kubectl -n prometheus-system wait --for condition=Available deployment/kube-prometheus-kube-prome-operator --timeout 120s

load-comp-image: ## Load the appcat-comp image if it exists
	[[ "$$(docker images -q ghcr.io/vshn/appcat 2> /dev/null)" != "" ]] && kind load docker-image --name kindev ghcr.io/vshn/appcat || true

.PHONY: csi-host-path-setup
csi-host-path-setup: $(csi_sentinel) ## Setup csi-driver-host-path and set as default, this provider supports resizing

$(csi_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(csi_sentinel): unset-default-sc
	$(MAKE) csi-install
	@touch $@

csi-install: export KUBECONFIG = $(KIND_KUBECONFIG)
csi-install:
	cd csi-host-path && \
	kubectl apply -f snapshot-controller.yaml && \
	kubectl apply -f storageclass.yaml && \
	./deploy.sh
	kubectl patch storageclass csi-hostpath-fast -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

.PHONY: clean
clean: kind-clean ## Clean up local dev environment
	rm -f $(vcluster_bin)

metallb-setup: $(metallb_sentinel) ## Install metallb as loadbalancer

$(metallb_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(metallb_sentinel):
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
	kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=90s
	HOSTIP=$$(docker inspect kindev-control-plane | jq -r '.[0].NetworkSettings.Networks.kind.Gateway') && \
	export range="$${HOSTIP}00-$${HOSTIP}50" && \
	cat metallb/config.yaml | cat metallb/config.yaml| yq 'select(document_index == 0) | .spec.addresses = [strenv(range)]' | kubectl apply -f -
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

netpols-setup: $(espejo_sentinel) $(netpols_sentinel) ## Install netpols to simulate appuio's netpols

$(netpols_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(netpols_sentinel):
	kubectl apply -f netpols
	touch $@

espejo-setup: $(espejo_sentinel)

$(espejo_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(espejo_sentinel):
	kubectl apply -f espejo
	touch $@

forgejo-setup: $(forgejo_sentinel) ## Install local forgejo instance to host argocd repos

$(forgejo_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(forgejo_sentinel):
	helm upgrade --install forgejo -f forgejo/values.yaml -n forgejo --create-namespace oci://code.forgejo.org/forgejo-helm/forgejo
	@echo -e "***\n*** Installed forgejo in http://forgejo.127.0.0.1.nip.io:8088\n***"
	@echo -e "***\n*** credentials: gitea_admin:adminadmin\n***"
	touch $@

argocd-setup: $(argocd_sentinel) ## Install argocd to automagically apply our component

$(argocd_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(argocd_sentinel):
	kubectl apply -k argocd/
	# patch admin password to admin
	kubectl -n argocd patch secret argocd-secret -p '{"stringData": { "admin.password": "$$2a$$10$$gHoKL/R2B4O.Mcygfke2juEullBDdANb3e8pex8yYJkzYS7A.8vnS", "admin.passwordMtime": "'$$(date +%FT%T%Z)'" }}'
	kubectl -n argocd patch cm argocd-cmd-params-cm -p '{"data": { "server.insecure": "true" } }'
	kubectl -n argocd patch cm argocd-cm -p '{"data": { "timeout.reconciliation": "30s" } }'
	kubectl -n argocd rollout restart deployment argocd-server
	if $(vcluster); then \
		$(MAKE) argocd-vcluster-auth ; \
	fi
	@echo -e "***\n*** Installed argocd in http://argocd.127.0.0.1.nip.io:8088\n***"
	@echo -e "***\n*** credentials: admin:admin\n***"
	touch $@

.PHONY: argocd-vcluster-auth
argocd-vcluster-auth: export KUBECONFIG = $(KIND_KUBECONFIG) ## Re-create argocd authentication for the vcluster, in case it breaks
argocd-vcluster-auth: vcluster-setup
argocd-vcluster-auth: vcluster=true
argocd-vcluster-auth:
	# The usualy kubeconfig export doesn't work here for some reason...
	export KUBECONFIG=$(KIND_KUBECONFIG) ; \
	$(vcluster_bin) connect controlplane --namespace vcluster; \
	kubectl create serviceaccount argocd; \
	kubectl create clusterrolebinding argocd_admin --clusterrole=cluster-admin --serviceaccount=default:argocd ; \
	kubectl apply -f argocd/service-account-secret.yaml ; \
	sleep 1 ; \
	export token=$$(kubectl get secret argocd-token -oyaml | yq '.data.token' | base64 -d) ; \
	$(vcluster_bin) disconnect; \
	kubectl delete -f argocd/controlplanesecret.yaml ; \
	cat argocd/controlplanesecret.yaml | yq '.stringData.config = "{ \"bearerToken\":\""+ strenv(token) +"\", \"tlsClientConfig\": { \"insecure\": true }}"' | kubectl apply -f -

.PHONY: install-vcluster-bin
install-vcluster-bin: $(vcluster_bin)

$(vcluster_bin): export GOOS = $(shell go env GOOS)
$(vcluster_bin): export GOARCH = $(shell go env GOARCH)
$(vcluster_bin): export GOBIN = $(go_bin)
$(vcluster_bin): | $(go_bin)
	if $(vcluster); then \
		go install github.com/loft-sh/vcluster/cmd/vclusterctl@latest; \
	fi


.PHONY: vcluster-setup
vcluster-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
vcluster-setup: install-vcluster-bin metallb-setup
	if $(vcluster); then \
		$(vcluster_bin) create controlplane --namespace vcluster --connect=false -f vclusterconfig/values.yaml --expose || true; \
		kubectl apply -f vclusterconfig/ingress.yaml; \
		$(vcluster_bin) connect controlplane --namespace vcluster --print --server=https://vcluster.127.0.0.1.nip.io:8443 > .kind/vcluster-config; \
		kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type "json" -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}]'; \
	fi

.PHONY: vcluster-in-cluster-kubeconfig
vcluster-in-cluster-kubeconfig: export KUBECONFIG = $(KIND_KUBECONFIG) ## Prints out a kubeconfig for use within the main cluster
vcluster-in-cluster-kubeconfig:
	@export KUBECONFIG=$(KIND_KUBECONFIG) ; \
	$(vcluster_bin) connect controlplane --namespace vcluster --print --server=https://controlplane.vcluster | yq

.PHONY: vcluster-local-cluster-kubeconfig
vcluster-local-cluster-kubeconfig: export KUBECONFIG = $(KIND_KUBECONFIG) ## Prints out a kubeconfig for use on the local machine
vcluster-local-cluster-kubeconfig:
	@export KUBECONFIG=$(KIND_KUBECONFIG) ; \
	$(vcluster_bin) connect controlplane --namespace vcluster --print --server=https://vcluster.127.0.0.1.nip.io:8443 | yq

.PHONY: vcluster-host-kubeconfig
vcluster-host-kubeconfig: export KUBECONFIG = $(KIND_KUBECONFIG) ## Prints out the kube config to connect from the vcluster to the host cluster
vcluster-host-kubeconfig:
	@export KUBECONFIG=$(KIND_KUBECONFIG) ; \
	cat .kind/kind-config | yq '.clusters[0].cluster.server = "https://kubernetes-host.default.svc"' | yq '.clusters[0].cluster.insecure-skip-tls-verify = true' | yq 'del(.clusters[0].cluster.certificate-authority-data)'

.PHONY: vcluster-clean
vcluster-clean: ## If you break Crossplane hard enough just remove the whole vcluster
	$(vcluster_bin) rm controlplane || true
