## These are some common variables for Make

go_bin ?= $(PWD)/.work/bin
$(go_bin):
	@mkdir -p $@

## Cluster provider: kind (default) or talos
CLUSTER_PROVIDER ?= kind

## Sentinel directory (shared across providers)
cluster_dir ?= $(PWD)/.kind

crossplane_sentinel = $(cluster_dir)/crossplane_sentinel
certmanager_sentinel = $(cluster_dir)/certmanager_sentinel
k8up_sentinel = $(cluster_dir)/k8up_sentinel
prometheus_sentinel = $(cluster_dir)/prometheus_sentinel
local_pv_sentinel = $(cluster_dir)/local_pv_sentinel
csi_sentinel = $(cluster_dir)/csi_provider_sentinel
metallb_sentinel = $(cluster_dir)/metallb_sentinel
komoplane_sentinel = $(cluster_dir)/komoplane_sentinel
netpols_sentinel = $(cluster_dir)/netpols_sentinel
espejote_sentinel = $(cluster_dir)/espejote_sentinel
forgejo_sentinel = $(cluster_dir)/forgejo_sentinel
argocd_sentinel = $(cluster_dir)/argocd_sentinel
secret_generator_sentinel = $(cluster_dir)/secret_generator_sentinel
mariadb_operator_sentinel = $(cluster_dir)/mariadb-operator_sentinel
minio_sentinel = $(cluster_dir)/minio_sentinel
kgateway_sentinel = $(cluster_dir)/kgateway_sentinel
registry_sentinel = $(cluster_dir)/registry
master_openbao_sentinel = $(cluster_dir)/master_openbao_sentinel

KGATEWAY_VERSION ?= 2.2.3
GATEWAY_API_VERSION ?= 1.4.0
KGATEWAY_PORT_START ?= 10000
KGATEWAY_PORT_END ?= 10019

enable_xfn = true

PROJECT_ROOT_DIR = .
PROJECT_NAME ?= kindev
PROJECT_OWNER ?= vshn

## BUILD:docker
DOCKER_CMD ?= docker

## KIND:setup

# https://hub.docker.com/r/kindest/node/tags
KIND_NODE_VERSION ?= v1.33.4
KIND_IMAGE ?= docker.io/kindest/node:$(KIND_NODE_VERSION)
KIND_CMD ?= go run sigs.k8s.io/kind
KIND_KUBECONFIG ?= $(cluster_dir)/kind-kubeconfig-$(KIND_NODE_VERSION)
KIND_CLUSTER ?= $(PROJECT_NAME)

## TALOS:setup
TALOS_VERSION ?= v1.12.6
TALOS_CLUSTER_NAME ?= kindev-talos
TALOS_IMAGE ?= ghcr.io/siderolabs/talos:$(TALOS_VERSION)
TALOS_K8S_VERSION ?= 1.35.1
TALOS_SUBNET ?= 10.5.0.0/24
TALOS_KUBECONFIG ?= $(cluster_dir)/talos-kubeconfig
TALOS_K8S_API_PORT ?= 36377

## Provider-specific settings
ifeq ($(CLUSTER_PROVIDER),talos)
  CLUSTER_KUBECONFIG ?= $(TALOS_KUBECONFIG)
  DOCKER_CONTAINER ?= $(TALOS_CLUSTER_NAME)-controlplane-1
  DOCKER_NETWORK ?= $(TALOS_CLUSTER_NAME)
else
  CLUSTER_KUBECONFIG ?= $(KIND_KUBECONFIG)
  DOCKER_CONTAINER ?= kindev-control-plane
  DOCKER_NETWORK ?= kind
endif

## PROMETHEUS
PROM_VALUES=prometheus/values.yaml


## VCLUSTER
vcluster_bin = $(go_bin)/vclusterctl
# enable or disable vcluster provisioning
vcluster=false

appcat_namespace ?= syn-appcat
