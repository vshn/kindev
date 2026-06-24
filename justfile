# kindev justfile

kind_node_version := env_var_or_default('KIND_NODE_VERSION', 'v1.31.9')
kind_image := "docker.io/kindest/node:" + kind_node_version
kind_cluster := env_var_or_default('KIND_CLUSTER', 'kindev')
kind_dir := justfile_directory() + "/.kind"
kind_kubeconfig := kind_dir + "/kind-config"
go_bin := env_var_or_default('GOBIN', `go env GOPATH` + "/bin")
vcluster_bin := go_bin + "/vclusterctl"
appcat_namespace := env_var_or_default('appcat_namespace', 'syn-appcat')

# Default recipe to display help
default:
    @just --list

# Show this help
help:
    @just --list

# Install appcat-apiserver dependencies
appcat-apiserver: vshnpostgresql

# Install vshn postgres and redis dependencies (single cluster mode)
vshnall: vshnpostgresql vshnredis

# Setup spks environment with vcluster
spks: spks-setup

# Setup converged mode with vcluster
converged: vshnpostgresql vshnredis

# Setup vcluster with vshnall
vcluster: vshnall

# Install vshn postgres dependencies
vshnpostgresql: shared-setup stackgres-setup

# Install vshn redis dependencies
vshnredis: shared-setup

# Install dependencies shared between all services
shared-setup: kind-setup-ingress certmanager-setup k8up-setup netpols-setup forgejo-setup prometheus-setup minio-setup metallb-setup argocd-setup registry-setup

# Install dependencies for spks
spks-setup: shared-setup secret-generator-setup mariadb-operator-setup

# All-in-one linting
lint:
    @echo 'Check for uncommitted changes ...'
    git diff --exit-code

# Setup kind cluster with storage
kind-storage: kind-setup csi-host-path-setup vcluster-setup

# Install Crossplane
crossplane-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just kind-setup
    just csi-host-path-setup
    helm repo add crossplane https://charts.crossplane.io/stable --force-update
    if [ -f {{vcluster_bin}} ]; then
        {{vcluster_bin}} connect controlplane --namespace vcluster || true
    fi
    helm upgrade --install crossplane --create-namespace --namespace syn-crossplane crossplane/crossplane \
        --set "args[0]='--debug'" \
        --set "args[1]='--enable-environment-configs'" \
        --set "args[2]='--enable-usages'" \
        --wait
    if [ -f {{vcluster_bin}} ]; then
        {{vcluster_bin}} disconnect || true
    fi
    touch {{kind_dir}}/crossplane_sentinel

# Install StackGres
stackgres-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just kind-setup
    just csi-host-path-setup
    helm repo add stackgres-charts https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/ --force-update
    helm upgrade --version 1.17.4 --install --create-namespace --namespace stackgres stackgres-operator stackgres-charts/stackgres-operator --values stackgres/values.yaml --wait
    kubectl -n stackgres wait --for condition=Available deployment/stackgres-operator --timeout 120s
    echo "waiting for stackgres-restapi-admin secret creation..."
    for i in $(seq 1 60); do
        if kubectl get secret stackgres-restapi-admin -n stackgres > /dev/null 2>&1; then
            break
        else
            sleep 1
        fi
    done
    NEW_USER=admin
    NEW_PASSWORD=password
    patch=$(kubectl create secret generic -n stackgres stackgres-restapi-admin --dry-run=client -o json \
        --from-literal=k8sUsername="$NEW_USER" \
        --from-literal=password="$(echo -n "${NEW_USER}${NEW_PASSWORD}"| sha256sum | awk '{ print $1 }' )")
    kubectl patch secret -n stackgres stackgres-restapi-admin -p "$patch"
    kubectl patch secrets --namespace stackgres stackgres-restapi-admin --type json -p '[{"op":"remove","path":"/data/clearPassword"}]' || true
    encoded=$(echo -n "$NEW_PASSWORD" | base64)
    kubectl patch secrets --namespace stackgres stackgres-restapi-admin --type json -p "[{\"op\":\"add\",\"path\":\"/data/clearPassword\", \"value\":\"${encoded}\"}]" || true

# Install cert-manager
certmanager-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just kind-storage
    just certmanager-install
    if [ -f {{vcluster_bin}} ]; then
        {{vcluster_bin}} connect controlplane --namespace vcluster || true
        just certmanager-install
        {{vcluster_bin}} disconnect || true
    fi
    touch {{kind_dir}}/certmanager_sentinel

# Install cert-manager components
certmanager-install:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml
    kubectl -n cert-manager wait --for condition=Available deployment/cert-manager --timeout 120s
    kubectl -n cert-manager wait --for condition=Available deployment/cert-manager-webhook --timeout 120s

# Install Minio
minio-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just kind-storage
    helm repo add minio https://charts.min.io/ --force-update
    helm upgrade --install --create-namespace --namespace minio minio --version 5.0.7 minio/minio \
        --values minio/values.yaml
    kubectl apply -f minio/gui-ingress.yaml
    kubectl create ns syn-crossplane || true
    kubectl apply -f minio/credentials.yaml
    if [ -f {{vcluster_bin}} ]; then
        {{vcluster_bin}} connect controlplane --namespace vcluster || true
        kubectl create ns syn-crossplane || true
        kubectl apply -f minio/credentials.yaml
        {{vcluster_bin}} disconnect || true
    fi
    echo -e "***\n*** Installed minio in http://minio.127.0.0.1.nip.io:8088\n***"
    echo -e "***\n*** use with mc:\n mc alias set localnip http://minio.127.0.0.1.nip.io:8088 minioadmin minioadmin\n***"
    echo -e "***\n*** console access http://minio-gui.127.0.0.1.nip.io:8088\n***"
    touch {{kind_dir}}/minio_sentinel

# Install K8up operator
k8up-setup: minio-setup prometheus-setup
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just kind-setup
    helm repo add k8up-io https://k8up-io.github.io/k8up
    kubectl apply -f https://github.com/k8up-io/k8up/releases/latest/download/k8up-crd.yaml --server-side
    helm upgrade --install k8up \
        --create-namespace \
        --namespace k8up-system \
        --wait \
        --values k8up/values.yaml \
        k8up-io/k8up
    kubectl -n k8up-system wait --for condition=Available deployment/k8up --timeout 60s
    touch {{kind_dir}}/k8up_sentinel

# Install secret generator
secret-generator-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just secret-generator-install
    if [ -f {{vcluster_bin}} ]; then
        {{vcluster_bin}} connect controlplane --namespace vcluster || true
        just secret-generator-install
        {{vcluster_bin}} disconnect || true
    fi
    touch {{kind_dir}}/secret_generator_sentinel

# Install secret generator components
secret-generator-install:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    helm repo add mittwald https://helm.mittwald.de --force-update
    helm upgrade --version 3.4.1 --values secret-generator/values.yaml --namespace syn-secret-generator --create-namespace --install kubernetes-secret-generator mittwald/kubernetes-secret-generator --wait

# Install MariaDB operator
mariadb-operator-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator --force-update
    helm upgrade --install mariadb-operator-crds \
        --version 25.8.2 \
        --wait \
        mariadb-operator/mariadb-operator-crds
    helm upgrade --install mariadb-operator \
        --create-namespace \
        --namespace syn-mariadb-operator \
        --version 25.8.2 \
        --set metrics.enabled=true \
        --set webhook.cert.certManager.enabled=true \
        --wait \
        mariadb-operator/mariadb-operator
    touch {{kind_dir}}/mariadb-operator_sentinel

# Install Prometheus stack
prometheus-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just kind-setup-ingress
    if [ -f {{vcluster_bin}} ]; then
        {{vcluster_bin}} connect controlplane --namespace vcluster || true
        PROM_VALUES=prometheus/values_vcluster.yaml just prometheus-install
        {{vcluster_bin}} disconnect || true
    fi
    just prometheus-install
    kubectl apply -f prometheus/netpol.yaml
    echo -e "***\n*** Installed Prometheus in http://prometheus.127.0.0.1.nip.io:8088/ and AlertManager in http://alertmanager.127.0.0.1.nip.io:8088/.\n***"
    touch {{kind_dir}}/prometheus_sentinel

# Install Prometheus components
prometheus-install:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    PROM_VALUES=${PROM_VALUES:-prometheus/values.yaml}
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm upgrade --install kube-prometheus \
        --create-namespace \
        --namespace prometheus-system \
        --wait \
        --values $PROM_VALUES \
        prometheus-community/kube-prometheus-stack
    kubectl -n prometheus-system wait --for condition=Available deployment/kube-prometheus-kube-prome-operator --timeout 120s

# Load the appcat-comp image if it exists
load-comp-image:
    #!/usr/bin/env bash
    if [[ "$(docker images -q ghcr.io/vshn/appcat 2> /dev/null)" != "" ]]; then
        kind load docker-image --name kindev ghcr.io/vshn/appcat
    fi

# Setup csi-driver-host-path and set as default
csi-host-path-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    just unset-default-sc
    just csi-install
    touch {{kind_dir}}/csi_provider_sentinel

# Install CSI driver
csi-install:
    #!/usr/bin/env bash
    set -euxo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    cd csi-host-path
    kubectl apply -f snapshot-controller.yaml
    kubectl apply -f storageclass.yaml
    ./deploy.sh
    kubectl patch storageclass csi-hostpath-fast -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Clean up local dev environment
clean: kind-clean
    rm -f {{vcluster_bin}}

# Install metallb as loadbalancer
metallb-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
    kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=90s
    HOSTIP=$(docker inspect kindev-control-plane | jq -r '.[0].NetworkSettings.Networks.kind.Gateway')
    export range="${HOSTIP}00-${HOSTIP}50"
    cat metallb/config.yaml | yq 'select(document_index == 0) | .spec.addresses = [strenv(range)]' | kubectl apply -f -
    cat metallb/config.yaml | yq 'select(document_index == 1)' | kubectl apply -f -
    touch {{kind_dir}}/metallb_sentinel

# Unset default storage class
unset-default-sc:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    for sc in $(kubectl get sc -o name); do
        kubectl patch $sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    done

# Install netpols to simulate appuio's netpols
netpols-setup: espejo-setup
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -f netpols
    touch {{kind_dir}}/netpols_sentinel

# Install espejo
espejo-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -f espejo
    touch {{kind_dir}}/espejo_sentinel

# Install local forgejo instance to host argocd repos
forgejo-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    helm upgrade --install forgejo -f forgejo/values.yaml -n forgejo --create-namespace oci://code.forgejo.org/forgejo-helm/forgejo
    echo -e "***\n*** Installed forgejo in http://forgejo.127.0.0.1.nip.io:8088\n***"
    echo -e "***\n*** credentials: gitea_admin:adminadmin\n***"
    touch {{kind_dir}}/forgejo_sentinel

# Install argocd to automagically apply our component
argocd-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -k argocd/
    kubectl -n argocd patch secret argocd-secret -p '{"stringData": { "admin.password": "$2a$10$gHoKL/R2B4O.Mcygfke2juEullBDdANb3e8pex8yYJkzYS7A.8vnS", "admin.passwordMtime": "'$(date +%FT%T%Z)'" }}'
    kubectl -n argocd patch cm argocd-cmd-params-cm -p '{"data": { "server.insecure": "true" } }'
    kubectl -n argocd patch cm argocd-cm -p '{"data": { "timeout.reconciliation": "30s" } }'
    kubectl -n argocd rollout restart deployment argocd-server
    if [ -f {{vcluster_bin}} ]; then
        just argocd-vcluster-auth || true
    fi
    echo -e "***\n*** Installed argocd in http://argocd.127.0.0.1.nip.io:8088\n***"
    echo -e "***\n*** credentials: admin:admin\n***"
    touch {{kind_dir}}/argocd_sentinel

# Re-create argocd authentication for the vcluster
argocd-vcluster-auth: vcluster-setup
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    {{vcluster_bin}} connect controlplane --namespace vcluster
    kubectl create serviceaccount argocd || true
    kubectl create clusterrolebinding argocd_admin --clusterrole=cluster-admin --serviceaccount=default:argocd || true
    kubectl apply -f argocd/service-account-secret.yaml
    sleep 1
    export token=$(kubectl get secret argocd-token -oyaml | yq '.data.token' | base64 -d)
    {{vcluster_bin}} disconnect
    kubectl delete -f argocd/controlplanesecret.yaml || true
    cat argocd/controlplanesecret.yaml | yq '.stringData.config = "{ \"bearerToken\":\""+ strenv(token) +"\", \"tlsClientConfig\": { \"insecure\": true }}"' | kubectl apply -f -

# Install vcluster binary
install-vcluster-bin:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f {{vcluster_bin}} ]; then
        export GOBIN={{go_bin}}
        go install github.com/loft-sh/vcluster/cmd/vclusterctl@v0.28.0
    fi

# Setup vcluster
vcluster-setup: install-vcluster-bin metallb-setup
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    if ! ({{vcluster_bin}} list | grep controlplane); then
        {{vcluster_bin}} create controlplane --namespace vcluster --connect=false -f vclusterconfig/values.yaml --expose --chart-version 0.28.0
        kubectl apply -f vclusterconfig/ingress.yaml
        {{vcluster_bin}} connect controlplane --namespace vcluster --print --server=https://vcluster.127.0.0.1.nip.io:8443 > {{kind_dir}}/vcluster-config
        kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type "json" -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-ssl-passthrough"}]'
    fi

# Prints a kubeconfig to use from the host cluster to the vcluster (service account based)
vcluster-in-cluster-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    {{vcluster_bin}} connect controlplane --namespace vcluster > /dev/null
    kubectl wait --for=create -n {{appcat_namespace}} secret/appcat-service-cluster --timeout=180s > /dev/null || echo "Service account secret not available. Make sure ArgoCD is syncing and try again." >&2
    kubectl view-serviceaccount-kubeconfig -n {{appcat_namespace}} appcat-service-cluster | yq '.clusters[0].cluster.server = "https://controlplane.vcluster"'
    {{vcluster_bin}} disconnect > /dev/null

# Prints out the kube config to connect from the vcluster to the host cluster (service account based)
vcluster-host-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl view-serviceaccount-kubeconfig -n {{appcat_namespace}} appcat-control-plane | yq '.clusters[0].cluster.insecure-skip-tls-verify = true' | yq 'del(.clusters[0].cluster.certificate-authority-data)' | yq '.clusters[0].cluster.server = "https://kubernetes-host.default.svc"'

# Remove the whole vcluster if broken
vcluster-clean:
    {{vcluster_bin}} rm controlplane || true

# Install registry
registry-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -f registry
    touch {{kind_dir}}/registry

# Install kind binary
install-kind-bin:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{go_bin}}
    if [ ! -f {{go_bin}}/kind ]; then
        GOBIN={{go_bin}} go install sigs.k8s.io/kind@latest
    fi

# Creates the kind cluster
kind-setup: install-kind-bin
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    if ! {{go_bin}}/kind get clusters | grep -q {{kind_cluster}}; then
        {{go_bin}}/kind create cluster \
            --name {{kind_cluster}} \
            --image {{kind_image}} \
            --config kind/config.yaml
        cp {{kind_kubeconfig}} {{kind_dir}}/kind-config
        kubectl taint nodes --all node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master- || true
        kubectl version
        kubectl cluster-info
        kubectl config use-context kind-{{kind_cluster}}
        echo "======="
        echo "Setup finished. To interact with the local dev cluster, set the KUBECONFIG environment variable as follows:"
        echo "export KUBECONFIG=$(realpath {{kind_kubeconfig}})"
        echo "======="
    fi

# Install NGINX as ingress controller onto kind cluster (localhost:8088)
kind-setup-ingress: kind-setup
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
    kubectl -n ingress-nginx wait --for condition=Ready pods -l app.kubernetes.io/component=controller --timeout 180s
    # We need to restart nginx, because it can't properly find the endpoints otherwise...
    kubectl -n ingress-nginx rollout restart deployment ingress-nginx-controller
    kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=180s

# Removes the kind Cluster
kind-clean: install-kind-bin
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG={{kind_kubeconfig}}
    {{go_bin}}/kind delete cluster --name {{kind_cluster}} || true
    rm -rf {{kind_dir}} {{go_bin}}/kind
