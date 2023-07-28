## These are some common variables for Make
crossplane_sentinel = $(kind_dir)/crossplane-sentinel
k8up_sentinel = $(kind_dir)/k8up-sentinel
prometheus_sentinel = $(kind_dir)/prometheus-sentinel
local_pv_sentinel = $(kind_dir)/local_pv
csi_sentinel = $(kind_dir)/csi_provider
enable_xfn = true

PROJECT_ROOT_DIR = .
PROJECT_NAME ?= kindev
PROJECT_OWNER ?= vshn

## BUILD:docker
DOCKER_CMD ?= docker

## KIND:setup

# https://hub.docker.com/r/kindest/node/tags
KIND_NODE_VERSION ?= v1.24.4
KIND_IMAGE ?= docker.io/kindest/node:$(KIND_NODE_VERSION)
KIND_CMD ?= go run sigs.k8s.io/kind
KIND_KUBECONFIG ?= $(kind_dir)/kind-kubeconfig-$(KIND_NODE_VERSION)
KIND_CLUSTER ?= $(PROJECT_NAME)
