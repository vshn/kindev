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
# Talos module
include talos/talos.mk

## Cluster lifecycle dispatchers — delegate to the active CLUSTER_PROVIDER
.PHONY: cluster-setup
cluster-setup: $(CLUSTER_PROVIDER)-setup

.PHONY: cluster-setup-ingress
cluster-setup-ingress: $(CLUSTER_PROVIDER)-setup-ingress

.PHONY: cluster-clean
cluster-clean: kind-clean talos-clean

cluster-storage: cluster-setup csi-host-path-setup vcluster-setup

.PHONY: cluster-load-image
ifeq ($(CLUSTER_PROVIDER),talos)
cluster-load-image: talos-load-image
else
cluster-load-image: kind-load-image
endif

.PHONY: appcat-apiserver
appcat-apiserver: vshnpostgresql ## Install appcat-apiserver dependencies

.PHONY: vshnall
vshnall: vcluster=false
vshnall: vshnpostgresql vshnredis

.PHONY: spks
spks: vcluster=true
spks: spks-setup

.PHONY: non-converged
converged: vcluster=true
converged: vshnpostgresql vshnredis

.PHONY: vcluster
vcluster: vcluster=true
vcluster: vshnall

.PHONY: vshnpostgresql
vshnpostgresql: shared-setup stackgres-setup ## Install vshn postgres dependencies

.PHONY: vshnredis
vshnredis: shared-setup  ## Install vshn redis dependencies

.PHONY: shared-setup ## Install dependencies shared between all services
shared-setup: cluster-setup-ingress certmanager-setup k8up-setup netpols-setup forgejo-setup prometheus-setup minio-setup metallb-setup argocd-setup registry-setup

ifeq ($(CLUSTER_PROVIDER),talos)
shared-setup: kgateway-setup
endif

.PHONY: spks-setup ## Install dependencies for spks
spks-setup: shared-setup secret-generator-setup mariadb-operator-setup

.PHONY: help
help: ## Show this help
	@grep -E -h '\s##\s' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: lint
lint: ## All-in-one linting
	@echo 'Check for uncommitted changes ...'
	git diff --exit-code

crossplane-setup: $(crossplane_sentinel) ## Install local Kubernetes cluster and install Crossplane

$(crossplane_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(crossplane_sentinel): cluster-setup csi-host-path-setup
	helm repo add crossplane https://charts.crossplane.io/stable --force-update
	if $(vcluster); then $(vcluster_bin) connect controlplane --namespace vcluster; fi
	helm upgrade --install crossplane --create-namespace --namespace syn-crossplane crossplane/crossplane \
	--set "args[0]='--debug'" \
	--set "args[1]='--enable-environment-configs'" \
	--set "args[2]='--enable-usages'" \
	--wait
	if $(vcluster); then $(vcluster_bin) disconnect; fi
	@touch $@

stackgres-setup: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
stackgres-setup: cluster-setup csi-host-path-setup ## Install StackGres
	helm repo add stackgres-charts https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/ --force-update
	helm upgrade --version 1.18.3 --install --create-namespace --namespace stackgres stackgres-operator  stackgres-charts/stackgres-operator --values stackgres/values.yaml --wait
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

certmanager-setup: $(certmanager_sentinel)

$(certmanager_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(certmanager_sentinel): cluster-storage
$(certmanager_sentinel):
	if $(vcluster); then \
		$(vcluster_bin) connect controlplane --namespace vcluster;\
		$(MAKE) certmanager-install; \
		$(vcluster_bin) disconnect; \
	fi
	$(MAKE) certmanager-install
	@touch $@

certmanager-install: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
certmanager-install:
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
	kubectl -n cert-manager wait --for condition=Available deployment/cert-manager --timeout 120s
	kubectl -n cert-manager wait --for condition=Available deployment/cert-manager-webhook --timeout 120s

minio-setup: $(minio_sentinel)
$(minio_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(minio_sentinel): cluster-storage ## Install Minio Crossplane implementation
	helm repo add minio https://charts.min.io/ --force-update
	helm upgrade --install --create-namespace --namespace minio minio --version 5.0.7 minio/minio \
	--values minio/values.yaml
	kubectl apply -f minio/gui-ingress.yaml
	kubectl create ns syn-crossplane || true
	kubectl apply -f minio/credentials.yaml
	if $(vcluster); then \
		$(vcluster_bin) connect controlplane --namespace vcluster; \
		kubectl create ns syn-crossplane || true ; \
		kubectl apply -f minio/credentials.yaml ; \
		$(vcluster_bin) disconnect; \
	fi
	@echo -e "***\n*** Installed minio in http://minio.127.0.0.1.nip.io:8088\n***"
	@echo -e "***\n*** use with mc:\n mc alias set localnip http://minio.127.0.0.1.nip.io:8088 minioadmin minioadmin\n***"
	@echo -e "***\n*** console access http://minio-gui.127.0.0.1.nip.io:8088\n***"
	@touch $@

k8up-setup: minio-setup prometheus-setup $(k8up_sentinel) ## Install K8up operator

$(k8up_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(k8up_sentinel): cluster-setup
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

secret-generator-setup: $(secret_generator_sentinel)

$(secret_generator_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(secret_generator_sentinel):
	if $(vcluster); then \
		$(vcluster_bin) connect controlplane --namespace vcluster; \
		$(MAKE) secret-generator-install; \
		$(vcluster_bin) disconnect; \
	fi
	$(MAKE) secret-generator-install
	@touch $@

secret-generator-install: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
secret-generator-install:
	helm repo add mittwald https://helm.mittwald.de --force-update
	helm upgrade --version 3.4.1 --values secret-generator/values.yaml --namespace syn-secret-generator --create-namespace --install kubernetes-secret-generator mittwald/kubernetes-secret-generator --wait

mariadb-operator-setup: $(mariadb_operator_sentinel)

$(mariadb_operator_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(mariadb_operator_sentinel):
	helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator --force-update
	helm upgrade --install mariadb-operator-crds \
		--version 25.8.2 \
		--wait \
		mariadb-operator/mariadb-operator-crds
	helm upgrade --install mariadb-operator \
		--create-namespace \
		--namespace syn-mariadb-operator \
		--version 25.8.2 \
  		--set metrics.enabled=true \
		--set webhook.cert.certManager.enabled=true \
		--wait \
		mariadb-operator/mariadb-operator
	@touch $@

local-pv-setup: $(local_pv_sentinel) ## Installs an alternative local-pv provider, that has slightly more features

$(local_pv_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(local_pv_sentinel): unset-default-sc
	kubectl apply -f local-pv
	kubectl patch storageclass openebs-hostpath -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
	@touch $@

prometheus-setup: $(prometheus_sentinel) ## Install Prometheus stack

$(prometheus_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(prometheus_sentinel): cluster-setup-ingress
	if $(vcluster); then \
		$(vcluster_bin) connect controlplane --namespace vcluster; \
		$(MAKE) prometheus-install -e PROM_VALUES=prometheus/values_vcluster.yaml; \
		$(vcluster_bin) disconnect; \
	fi
	$(MAKE) prometheus-install
	kubectl apply -f prometheus/netpol.yaml
	@echo -e "***\n*** Installed Prometheus in http://prometheus.127.0.0.1.nip.io:8088/ and AlertManager in http://alertmanager.127.0.0.1.nip.io:8088/.\n***"
	@touch $@

prometheus-install: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
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

$(csi_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(csi_sentinel): unset-default-sc
	$(MAKE) csi-install
	@touch $@

csi-install: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
csi-install:
	cd csi-host-path && \
	kubectl apply -f snapshot-controller.yaml && \
	kubectl apply -f storageclass.yaml && \
	./deploy.sh
	kubectl patch storageclass csi-hostpath-fast -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

.PHONY: clean
clean: cluster-clean ## Clean up local dev environment
	rm -f $(vcluster_bin)

metallb-setup: $(metallb_sentinel) ## Install metallb as loadbalancer

$(metallb_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(metallb_sentinel):
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
	kubectl wait --namespace metallb-system \
		--for=condition=ready pod \
		--selector=app=metallb \
		--timeout=90s
	@echo "Waiting for metallb webhook to become ready..."
	sleep 30
	HOSTIP=$$(docker inspect $(DOCKER_CONTAINER) | jq -r '.[0].NetworkSettings.Networks["$(DOCKER_NETWORK)"].Gateway') && \
	export range="$${HOSTIP}00-$${HOSTIP}50" && \
	cat metallb/config.yaml | yq 'select(document_index == 0) | .spec.addresses = [strenv(range)]' | kubectl apply -f -
	cat metallb/config.yaml | yq 'select(document_index == 1)' | kubectl apply -f -
	touch $@

komoplane-setup: $(komoplane_sentinel) ## Install komoplane crossplane troubleshooter

$(komoplane_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(komoplane_sentinel):
	helm repo add komodorio https://helm-charts.komodor.io --force-update
	helm upgrade --install --create-namespace --namespace komoplane komoplane komodorio/komoplane
	kubectl apply -f komoplane
	touch $@

.PHONY: unset-default-sc
unset-default-sc: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
unset-default-sc:
	for sc in $$(kubectl get sc -o name) ; do \
		kubectl patch $$sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'; \
	done

netpols-setup: $(espejote_sentinel) $(netpols_sentinel) ## Install netpols to simulate appuio's netpols

$(netpols_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(netpols_sentinel):
	kubectl apply -f netpols
	touch $@

espejote-setup: $(espejote_sentinel)

$(espejote_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(espejote_sentinel):
	kubectl apply -k https://github.com/vshn/espejote/config/crd
	kubectl apply -k https://github.com/vshn/espejote/config/default
	touch $@

kgateway-setup: $(kgateway_sentinel)

$(kgateway_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(kgateway_sentinel): cluster-setup
	kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v$(GATEWAY_API_VERSION)/experimental-install.yaml
	kubectl apply -f kgateway/namespace.yaml
	helm upgrade --install kgateway oci://ghcr.io/kgateway-dev/charts/kgateway \
		--version v$(KGATEWAY_VERSION) \
		--namespace kgateway-system \
		--values kgateway/values.yaml \
		--wait
	kubectl apply -f kgateway/gateway.yaml
	kubectl wait --for=condition=Programmed gateway/ssh-gateway -n kgateway-system --timeout=2m
	kubectl wait --for=condition=Programmed gateway/http-gateway -n kgateway-system --timeout=2m
	@touch $@

forgejo-setup: $(forgejo_sentinel) ## Install local forgejo instance to host argocd repos

$(forgejo_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(forgejo_sentinel):
	helm upgrade --install forgejo -f forgejo/values.yaml -n forgejo --create-namespace oci://code.forgejo.org/forgejo-helm/forgejo
	@echo -e "***\n*** Installed forgejo in http://forgejo.127.0.0.1.nip.io:8088\n***"
	@echo -e "***\n*** credentials: gitea_admin:adminadmin\n***"
	touch $@

argocd-setup: $(argocd_sentinel) ## Install argocd to automagically apply our component

$(argocd_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(argocd_sentinel):
	kubectl apply -k argocd/ --server-side --force-conflicts
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
argocd-vcluster-auth: export KUBECONFIG = $(CLUSTER_KUBECONFIG) ## Re-create argocd authentication for the vcluster, in case it breaks
argocd-vcluster-auth: vcluster-setup
argocd-vcluster-auth: vcluster=true
argocd-vcluster-auth:
	# The usualy kubeconfig export doesn't work here for some reason...
	export KUBECONFIG=$(CLUSTER_KUBECONFIG) ; \
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
		go install github.com/loft-sh/vcluster/cmd/vclusterctl@v0.28.0; \
	fi


.PHONY: vcluster-setup
vcluster-setup: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
vcluster-setup: install-vcluster-bin metallb-setup
	if ! ($(vcluster_bin) list | grep controlplane ) && $(vcluster) ; then \
		$(vcluster_bin) create controlplane --namespace vcluster --connect=false -f vclusterconfig/values.yaml --expose --chart-version 0.28.0 ; \
		kubectl apply -f vclusterconfig/ingress.yaml; \
		$(vcluster_bin) connect controlplane --namespace vcluster --print --server=https://vcluster.127.0.0.1.nip.io:8443 > $(cluster_dir)/vcluster-config; \
		kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type "json" -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}]'; \
	fi

.PHONY: vcluster-in-cluster-kubeconfig-admin
vcluster-in-cluster-kubeconfig-admin: export KUBECONFIG = $(CLUSTER_KUBECONFIG) ## Prints a kubeconfig to use from the host cluster to the vcluster, it uses an admin account
vcluster-in-cluster-kubeconfig-admin:
	@export KUBECONFIG=$(CLUSTER_KUBECONFIG) ; \
	$(vcluster_bin) connect controlplane --namespace vcluster --print --server=https://controlplane.vcluster | yq

.PHONY: vcluster-local-cluster-kubeconfig-admin
vcluster-local-cluster-kubeconfig-admin: export KUBECONFIG = $(CLUSTER_KUBECONFIG) ## Prints out a kubeconfig for use on the local machine, it uses an admin account
vcluster-local-cluster-kubeconfig-admin:
	@export KUBECONFIG=$(CLUSTER_KUBECONFIG) ; \
	$(vcluster_bin) connect controlplane --namespace vcluster --print --server=https://vcluster.127.0.0.1.nip.io:8443 | yq

.PHONY: vcluster-host-kubeconfig-admin
vcluster-host-kubeconfig-admin: export KUBECONFIG = $(CLUSTER_KUBECONFIG) ## Prints out the kube config to connect from the vcluster to the host cluster, it uses an admin account
vcluster-host-kubeconfig-admin:
	@export KUBECONFIG=$(CLUSTER_KUBECONFIG) ; \
	cat $(CLUSTER_KUBECONFIG) | yq '.clusters[0].cluster.server = "https://kubernetes-host.default.svc"' | yq '.clusters[0].cluster.insecure-skip-tls-verify = true' | yq 'del(.clusters[0].cluster.certificate-authority-data)'

.PHONY: vcluster-in-cluster-kubeconfig
vcluster-in-cluster-kubeconfig: export KUBECONFIG = $(CLUSTER_KUBECONFIG) ## Prints a kubeconfig to use from the host cluster to the vcluster, it uses the service account provisioned by component-appcat
vcluster-in-cluster-kubeconfig:
	@export KUBECONFIG=$(CLUSTER_KUBECONFIG) ; \
	$(vcluster_bin) connect controlplane --namespace vcluster > /dev/null; \
	kubectl wait --for=create -n $(appcat_namespace) secret/appcat-service-cluster --timeout=180s > /dev/null || >&2 echo "Service account secret not available. Make sure ArgoCD is syncing and try again."; \
	kubectl view-serviceaccount-kubeconfig -n $(appcat_namespace) appcat-service-cluster | yq '.clusters[0].cluster.server = "https://controlplane.vcluster"' ; \
	$(vcluster_bin) disconnect > /dev/null

.PHONY: vcluster-host-kubeconfig
vcluster-host-kubeconfig: export KUBECONFIG = $(CLUSTER_KUBECONFIG) ## Prints out the kube config to connect from the vcluster to the host cluster, it uses the service account provisioned by component-appcat
vcluster-host-kubeconfig:
	@export KUBECONFIG=$(CLUSTER_KUBECONFIG) ; \
	kubectl view-serviceaccount-kubeconfig -n $(appcat_namespace) appcat-control-plane | yq '.clusters[0].cluster.insecure-skip-tls-verify = true' | yq 'del(.clusters[0].cluster.certificate-authority-data)' | yq '.clusters[0].cluster.server = "https://kubernetes-host.default.svc"'

.PHONY: vcluster-clean
vcluster-clean: ## If you break Crossplane hard enough just remove the whole vcluster
	$(vcluster_bin) rm controlplane || true

registry-setup: $(registry_sentinel)

$(registry_sentinel): export KUBECONFIG = $(CLUSTER_KUBECONFIG)
$(registry_sentinel):
	kubectl apply -f registry
	@touch $@
