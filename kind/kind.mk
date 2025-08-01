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
kind: kind-setup-ingress kind-load-image ## All-in-one kind target

.PHONY: kind-setup
kind-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-setup: $(KIND_KUBECONFIG) ## Creates the kind cluster

.PHONY: kind-setup-ingress
kind-setup-ingress: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-setup-ingress: kind-setup ## Install NGINX as ingress controller onto kind cluster (localhost:8088)
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx wait --for condition=Ready pods -l app.kubernetes.io/component=controller --timeout 180s
	# We need to restart nginx, because it can't properly find the endpoints otherwise...
	kubectl -n ingress-nginx rollout restart deployment ingress-nginx-controller
	kubectl -n ingress-nginx wait --for condition=Ready pods -l app.kubernetes.io/component=controller --timeout 180s

.PHONY: kind-load-image
# We fix the arch to linux/amd64 since kind runs in amd64 even on Mac/arm.
kind-load-image: export GOOS = linux
kind-load-image: export GOARCH = amd64
kind-load-image: kind-setup build-docker ## Load the container image onto kind cluster
	@$(kind_bin) load docker-image --name $(KIND_CLUSTER) $(CONTAINER_IMG)

.PHONY: kind-clean
kind-clean: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-clean: $(kind_bin)
kind-clean: ## Removes the kind Cluster
	@$(kind_bin) delete cluster --name $(KIND_CLUSTER) || true
	rm -rf $(kind_dir) $(kind_bin)

$(KIND_KUBECONFIG): export KUBECONFIG = $(KIND_KUBECONFIG)
$(KIND_KUBECONFIG): $(kind_bin)
	$(kind_bin) create cluster \
		--name $(KIND_CLUSTER) \
		--image $(KIND_IMAGE) \
		--config kind/config.yaml
	cp $(KIND_KUBECONFIG) $(kind_dir)/kind-config
	kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master- || true
	@kubectl version
	@kubectl cluster-info
	@kubectl config use-context kind-$(KIND_CLUSTER)
	@echo =======
	@echo "Setup finished. To interact with the local dev cluster, set the KUBECONFIG environment variable as follows:"
	@echo "export KUBECONFIG=$$(realpath "$(KIND_KUBECONFIG)")"
	@echo =======
