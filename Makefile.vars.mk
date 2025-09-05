## These are some common variables for Make
crossplane_sentinel = $(kind_dir)/crossplane_sentinel
certmanager_sentinel = $(kind_dir)/certmanager_sentinel
k8up_sentinel = $(kind_dir)/k8up_sentinel
prometheus_sentinel = $(kind_dir)/prometheus_sentinel
local_pv_sentinel = $(kind_dir)/local_pv_sentinel
csi_sentinel = $(kind_dir)/csi_provider_sentinel
metallb_sentinel = $(kind_dir)/metallb_sentinel
komoplane_sentinel = $(kind_dir)/komoplane_sentinel
netpols_sentinel = $(kind_dir)/netpols_sentinel
espejo_sentinel = $(kind_dir)/espejo_sentinel
forgejo_sentinel = $(kind_dir)/forgejo_sentinel
argocd_sentinel = $(kind_dir)/argocd_sentinel
secret_generator_sentinel = $(kind_dir)/secret_generator_sentinel
mariadb_operator_sentinel = $(kind_dir)/mariadb-operator_sentinel
minio_sentinel = $(kind_dir)/minio_sentinel

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
