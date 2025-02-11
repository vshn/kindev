# kindev

Crossplane development environment using kind (Kubernetes-in-Docker).

## Requirements

* `kubectl`
* `helm` v3
* `go` (or alternatively `kind`)
* `docker`
* `yq` (The [Go variant](https://archlinux.org/packages/extra/x86_64/go-yq/) of it)

## Getting started

Short version:

`make vshnpostgresql`

This will
1. Install a local Kubernetes cluster with kubernetes-in-docker (`kind`)
1. Install Crossplane Helm chart
1. Install Secrets Generator Helm chart (for providing random passwords)
1. Install StackGres Operator
1. Install Prometheus Operator and a Prometheus instance with AlertManager

To uninstall the cluster:

`make clean`

## Access resources on the kind cluster

The kind cluster features an ingress controller, that listens on `:8088`.

Currently following apps are configured to use the ingress:

- Prometheus: http://prometheus.127.0.0.1.nip.io:8088/
- Alertmanager: http://alertmanager.127.0.0.1.nip.io:8088/
- Minio: http://minio.127.0.0.1.nip.io:8088/
- [Komoplane](https://github.com/komodorio/komoplane) (make komoplane-setup): http://komoplane.127.0.0.1.nip.io:8088/
- Forgejo: http://forgejo.127.0.0.1.nip.io:8088/
- ArgoCD: http://argocd.127.0.0.1.nip.io:8088/
- Vcluster: https://vcluster.127.0.0.1.nip.io:8443/

For minio access from the localhost just use this alias:

```
mc alias set localnip http://minio.127.0.0.1.nip.io:8088 minioadmin minioadmin
```

Minio console access: http://minio-gui.127.0.0.1.nip.io:8088

## Vcluster

`vshnall` will now run in a non-converged setup by default. If you want to have a converged setup, please run the target `converged`.

There are also some helper targets for the vcluster:
* vcluster-clean: will remove the vluster. Helpful if Crossplane broke completely
* vcluster-host-kubeconfig: generates a kubeconfig that points from the vcluster to the host cluster. Used mainly for development in the component.
* vcluster-in-cluster-kubeconfig: generates a kubeconfig that can be used from within the main cluster. E.g. when deploying the controller or sli-exporter so it can connect to the control plane.
* vcluster-local-cluster-kubeconfig: same as the above, but will point to the vcluster ingress endpoint. Useful for development as claims need to be applied to the service instance.

### How to use it in make

If you need to install something in the control cluster in make, you can do it like this:

```make
.PHONY: app-setup
app-setup:
  $(vcluster_bin) connect controlplane --namespace vcluster
  $install what you need
  $(vcluster_bin) disconnect
```

### Access vcluster

If you need access to the vcluster from outside make (for example, when applying the AppCat component or other things). Export the kind config and then:

```bash
kubectl config get-contexts
# get the vcluster context
# it's the one starting with vcluster_*
kubectl config use-context vcluster_*...
```

## Integration into other projects

kindev is intended to be used by Crossplane providers as a development and test environment. It can be tied into other projects via a git submodule.

Run inside the git repository of your project:

`git submodule add https://github.com/vshn/kindev.git`

It is built to work in CI/CD environments. This is an example GitHub workflow to show kindev usage in your project.

```yaml
name: Demo

on:
  push:
    branches:
      - master

env:
  KIND_CMD: kind # kind is pre-installed in GitHub runners
  KUBECONFIG: 'kindev/.kind/kind-kubeconfig-v1.23.0'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: true # required for submodules

      - name: Crossplane setup
        working-directory: kindev
        run: make crossplane-setup

      - name: Your test
        run: kubectl ...
```

## Arch Linux rootless Podman

As outlined in [the kind documentation](https://kind.sigs.k8s.io/docs/user/rootless/) set `KIND_EXPERIMENTAL_PROVIDER=podman` if rootless Podman is in use.
