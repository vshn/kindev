talosctl_bin = $(go_bin)/talosctl

$(talosctl_bin): | $(go_bin)
	curl -fsSL "https://github.com/siderolabs/talos/releases/download/$(TALOS_VERSION)/talosctl-$(shell go env GOOS)-$(shell go env GOARCH)" -o $(talosctl_bin)
	chmod +x $(talosctl_bin)

NUM_CORES := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)

.PHONY: talos-setup
talos-setup: $(TALOS_KUBECONFIG)

$(TALOS_KUBECONFIG): $(talosctl_bin) talos-iptables-setup
	@mkdir -p $(cluster_dir)
	@set -e; \
	$(talosctl_bin) cluster create docker \
		--name $(TALOS_CLUSTER_NAME) \
		--image $(TALOS_IMAGE) \
		--kubernetes-version $(TALOS_K8S_VERSION) \
		--host-ip 0.0.0.0 \
		--workers 1 \
		--memory-controlplanes 8GiB \
		--memory-workers 8GiB \
		--cpus-workers $(NUM_CORES) \
		--cpus-controlplanes $(NUM_CORES) \
		-p 8088:80/tcp,8443:443/tcp,5000:5000/tcp,$$(seq $(KGATEWAY_PORT_START) $(KGATEWAY_PORT_END) | sed 's/.*/&:&\/tcp/' | paste -sd,) \
		--config-patch-controlplanes @talos/config-patch-controlplane.yaml \
		--config-patch-workers @talos/config-patch-worker.yaml & \
	talos_pid=$$!; \
	echo "Waiting for Talos API..."; \
	until $(talosctl_bin) kubeconfig --force --nodes 10.5.0.2 $(TALOS_KUBECONFIG) 2>/dev/null; do sleep 2; done; \
	echo "Waiting for Kubernetes API..."; \
	until kubectl --kubeconfig=$(TALOS_KUBECONFIG) get nodes >/dev/null 2>&1; do sleep 2; done; \
	echo "Installing Cilium CNI..."; \
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true; \
	helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--kubeconfig $(TALOS_KUBECONFIG) \
		--set ipam.mode=kubernetes \
		--set kubeProxyReplacement=true \
		--set k8sServiceHost=localhost \
		--set k8sServicePort=7445 \
		--set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
		--set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
		--set cgroup.autoMount.enabled=false \
		--set cgroup.hostRoot=/sys/fs/cgroup \
		--wait; \
	echo "Waiting for cluster readiness..."; \
	rm -f $(TALOS_KUBECONFIG)
	$(talosctl_bin) kubeconfig --force --nodes 10.5.0.2 $(TALOS_KUBECONFIG)
	cat $(TALOS_KUBECONFIG) | yq '.clusters[0].cluster.server = "https://127.0.0.1:$(TALOS_K8S_API_PORT)"' > $(cluster_dir)/kind-config
	wait $$talos_pid
	@echo =======
	@echo "Setup finished. To interact with the local dev cluster, set the KUBECONFIG environment variable as follows:"
	@echo "export KUBECONFIG=$$(realpath "$(TALOS_KUBECONFIG)")"
	@echo =======

.PHONY: talos-iptables-setup
talos-iptables-setup:
	@echo "Adding iptables DNAT rules to expose API server on 127.0.0.1:36377..."
	@sudo iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport 36377 -j DNAT --to-destination 10.5.0.2:6443 2>/dev/null || \
		sudo iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport 36377 -j DNAT --to-destination 10.5.0.2:6443
	@sudo iptables -t nat -C PREROUTING -p tcp --dport 36377 -j DNAT --to-destination 10.5.0.2:6443 2>/dev/null || \
		sudo iptables -t nat -A PREROUTING -p tcp --dport 36377 -j DNAT --to-destination 10.5.0.2:6443
	@sudo iptables -t nat -C POSTROUTING -d 10.5.0.2 -p tcp --dport 6443 -j MASQUERADE 2>/dev/null || \
		sudo iptables -t nat -A POSTROUTING -d 10.5.0.2 -p tcp --dport 6443 -j MASQUERADE
	@sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null

.PHONY: talos-cilium-setup
talos-cilium-setup:
	helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
	helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--kubeconfig $(TALOS_KUBECONFIG) \
		--set ipam.mode=kubernetes \
		--set kubeProxyReplacement=true \
		--set k8sServiceHost=localhost \
		--set k8sServicePort=7445 \
		--set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
		--set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
		--set cgroup.autoMount.enabled=false \
		--set cgroup.hostRoot=/sys/fs/cgroup \
		--wait

.PHONY: talos-setup-ingress
talos-setup-ingress: export KUBECONFIG = $(CLUSTER_KUBECONFIG)
talos-setup-ingress: talos-setup
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json -p '[{"op":"add","path":"/spec/template/spec/nodeSelector/ingress-ready","value":"true"}]'
	kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=180s

.PHONY: talos-clean
talos-clean:
	$(talosctl_bin) cluster destroy --name $(TALOS_CLUSTER_NAME) --force || true
	rm -rf $(cluster_dir)
	-sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 36377 -j DNAT --to-destination 10.5.0.2:6443 2>/dev/null || true
	-sudo iptables -t nat -D PREROUTING -p tcp --dport 36377 -j DNAT --to-destination 10.5.0.2:6443 2>/dev/null || true
	-sudo iptables -t nat -D POSTROUTING -d 10.5.0.2 -p tcp --dport 6443 -j MASQUERADE 2>/dev/null || true

.PHONY: talos-load-image
talos-load-image: talos-setup build-docker
	docker tag $(CONTAINER_IMG) localhost:5000/$(CONTAINER_IMG)
	docker push localhost:5000/$(CONTAINER_IMG)
