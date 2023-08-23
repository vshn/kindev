go_bin ?= $(PWD)/.work/bin
$(go_bin):
	@mkdir -p $@

kind_dir ?= $(PWD)/.kind
kind_bin = $(go_bin)/kind

# Prepare kind binary
$(kind_bin): export GOOS = $(shell go env GOOS)
$(kind_bin): export GOARCH = $(shell go env GOARCH)
$(kind_bin): export GOBIN = $(go_bin)
$(kind_bin): | $(go_bin)
	go install sigs.k8s.io/kind@latest


.PHONY: kind
kind: export KUBECONFIG = $(KIND_KUBECONFIG)
kind: kind-setup-ingress
#kind-load-image ## All-in-one kind target

.PHONY: kind-setup
kind-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-setup: $(KIND_KUBECONFIG) ## Creates the kind cluster

.PHONY: kind-setup-ingress
kind-setup-ingress: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-setup-ingress: kind-setup ## Install NGINX as ingress controller onto kind cluster (localhost:8088)
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

.PHONY: kind-load-image
# We fix the arch to linux/amd64 since kind runs in amd64 even on Mac/arm.
kind-load-image: export GOOS = linux
kind-load-image: export GOARCH = amd64
kind-load-image: kind-setup  ## Load the container image onto kind cluster
	@$(kind_bin) load docker-image --name $(KIND_CLUSTER) $(CONTAINER_IMG)

.PHONY: kind-clean
kind-clean: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-clean: ## Removes the kind Cluster
	@$(kind_bin) delete cluster --name $(KIND_CLUSTER) || true
	rm -rf $(kind_dir) $(kind_bin)

$(KIND_KUBECONFIG): export KUBECONFIG = $(KIND_KUBECONFIG)
$(KIND_KUBECONFIG): $(kind_bin)
	$(kind_bin) create cluster \
		--name $(KIND_CLUSTER) \
		--image $(KIND_IMAGE) \
		--config kind/config.yaml
	$(kind_bin) get kubeconfig --name $(KIND_CLUSTER) > $(kind_dir)/kind-config
	@kubectl version
	@kubectl cluster-info
	@kubectl config use-context kind-$(KIND_CLUSTER)
	@echo =======
	@echo "Setup finished. To interact with the local dev cluster, set the KUBECONFIG environment variable as follows:"
	@echo "export KUBECONFIG=$$(realpath "$(KIND_KUBECONFIG)")"
	@echo =======


# install cilium via helm
.PHONY: cilium
cilium: export KUBECONFIG = $(KIND_KUBECONFIG)
cilium: kind-setup ## Install cilium
	docker pull $(cilium_image)
	kind load docker-image $(cilium_image) --name $(KIND_CLUSTER)
	helm repo add cilium https://helm.cilium.io/
	helm upgrade --install cilium cilium/cilium --version $(cilium_version) \
		--namespace kube-system \
		--set nodeinit.enabled=true \
		--set k8s.requireIPv4PodCIDR=true \
		--set kubeProxyReplacement=strict \
		--set l2announcements.enabled=true \
		--set hostFirewall.enabled=true \
		--set externalIPs.enabled=true 
	kubectl apply -f cilium/