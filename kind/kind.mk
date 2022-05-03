kind_dir ?= .kind
ingress_sentinel = $(kind_dir)/ingress-sentinel

kind: export KUBECONFIG = $(KIND_KUBECONFIG)
kind: kind-setup-ingress ## All-in-one kind target

kind-setup: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-setup: $(KIND_KUBECONFIG) ## Creates the kind cluster

kind-setup-ingress: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-setup-ingress: $(ingress_sentinel) ### Install NGINX as ingress controller onto kind cluster (localhost:8081 / localhost:8443)

$(ingress_sentinel): export KUBECONFIG = $(KIND_KUBECONFIG)
$(ingress_sentinel): $(KIND_KUBECONFIG)
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl wait -n ingress-nginx --for condition=Complete jobs/ingress-nginx-admission-patch --timeout 180s
	kubectl wait -n ingress-nginx --for condition=ContainersReady --timeout 180s $$(kubectl -n ingress-nginx get pods -o name --no-headers | grep controller)
	@touch $@

# .PHONY: kind-load-image
# kind-load-image: kind-setup build-docker ### Load the container image onto kind cluster
# 	@$(KIND) load docker-image --name $(KIND_CLUSTER) $(CONTAINER_IMG)

.PHONY: kind-clean
kind-clean: export KUBECONFIG = $(KIND_KUBECONFIG)
kind-clean: ## Removes the kind Cluster
	@$(KIND_CMD) delete cluster --name $(KIND_CLUSTER) || true
	@rm -rf $(kind_dir)/*

$(KIND_KUBECONFIG): export KUBECONFIG = $(KIND_KUBECONFIG)
$(KIND_KUBECONFIG):
	$(KIND_CMD) create cluster \
		--name $(KIND_CLUSTER) \
		--image $(KIND_IMAGE) \
		--config kind/config.yaml
	@kubectl version
	@kubectl cluster-info
	@kubectl config use-context kind-$(KIND_CLUSTER)
	@echo =======
	@echo "Setup finished. To interact with the local dev cluster, set the KUBECONFIG environment variable as follows:"
	@echo "export KUBECONFIG=$$(realpath "$(KIND_KUBECONFIG)")"
	@echo =======
