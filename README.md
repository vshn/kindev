# kindev

Crossplane development environment using kind (Kubernetes-in-Docker).

## Requirements

* `kubectl`
* `helm` v3
* `go` (or alternatively `kind`)
* `docker`

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

- Promethues: http://127.0.0.1.nip.io:8088/prometheus/
- Alertmanager: http://127.0.0.1.nip.io:8088/alertmanager/
- Minio: http://minio.127.0.0.1.nip.io:8088/

For minio access from the localhost just use this alias:

```
mc alias set localnip http://minio.127.0.0.1.nip.io:8088 minioadmin minioadmin
```

Minio console access: http://minio-gui.127.0.0.1.nip.io:8088

## Integration into other projects

kindev is intended to be used by Crossplane providers as a developement and test environment. It can be tied into other projects via a git submodule.

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
