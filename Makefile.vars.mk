## These are some common variables for Make
crossplane_sentinel = $(kind_dir)/crossplane-sentinel
certmanager-sentinel = $(kind_dir)/certmanager-sentinel
k8up_sentinel = $(kind_dir)/k8up-sentinel
prometheus_sentinel = $(kind_dir)/prometheus-sentinel
local_pv_sentinel = $(kind_dir)/local_pv
csi_sentinel = $(kind_dir)/csi_provider
metallb_sentinel = $(kind_dir)/metallb
komoplane_sentinel = $(kind_dir)/komoplane
netpols_sentinel = $(kind_dir)/netpols
espejo_sentinel = $(kind_dir)/espejo
forgejo_sentinel = $(kind_dir)/forgejo
argocd_sentinel = $(kind_dir)/argocd
enable_xfn = true

PROJECT_ROOT_DIR = .
PROJECT_NAME ?= kindev
PROJECT_OWNER ?= vshn

## BUILD:docker
DOCKER_CMD ?= docker

## KIND:setup

# https://hub.docker.com/r/kindest/node/tags
KIND_NODE_VERSION ?= v1.31.9
KIND_IMAGE ?= docker.io/kindest/node:$(KIND_NODE_VERSION)
KIND_CMD ?= go run sigs.k8s.io/kind
KIND_KUBECONFIG ?= $(kind_dir)/kind-kubeconfig-$(KIND_NODE_VERSION)
KIND_CLUSTER ?= $(PROJECT_NAME)

## PROMETHEUS
PROM_VALUES=prometheus/values.yaml


## VCLUSTER
vcluster_bin = $(go_bin)/vclusterctl
# enable or disable vcluster provisioning
vcluster=false
