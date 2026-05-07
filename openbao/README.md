# Master OpenBao instance

## Deploy Master OpenBao instance

Below there are instructions how to install OpenBao manually. However, faster and recommended way is to use Makefile.

```bash
make vshnpostgresql
make vshnopenbao
```

**By default, Master OpenBao is not installed as part of `vshnpostgresql` nor `vshnall`.**

### Setup OpenBao Helm Repository

Add the OpenBao Helm repository (required for all OpenBao deployments):

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
```

### Create Helm release

Deploy the OpenBao instance using Helm:

```bash
helm upgrade --install openbao openbao/openbao --namespace openbao --values ./openbao/values.yml --create-namespace
```

### Initialize OpenBao instance

The `values.yml` includes an `openbao-init` Job (via `extraObjects`) that automatically initializes and unseals OpenBao, enables the Transit secrets engine, and creates the `autounseal` transit key and policy.

After the Job completes, the credentials are stored in the `openbao-init-credentials` secret:

- `root-token` — root token for administrative access
- `unseal-key` — unseal key for manual unsealing

The UI is accessible at http://openbao.127.0.0.1.nip.io:8088.

### Generate new token for auto-unseal operation

```bash
# Connect to OpenBao instance
export VAULT_ADDR=http://openbao.127.0.0.1.nip.io:8088
export VAULT_TOKEN=$(kubectl -n openbao get secret openbao-init-credentials -o jsonpath='{.data.root-token}' | base64 -d)
bao status

# Generate token required for auto-unseal of another OpenBao instance
bao token create -orphan -policy="autounseal" -no-default-policy -format=json > auto-unseal.json
```

## Cleanup

Delete namespace and helm chart

```bash
helm -n openbao uninstall openbao
kubectl delete ns openbao
rm .kind/openbao_sentinel
```

## Side notes

### Manual initialization

The Helm chart's built-in `initialize` stanza cannot be used here because it requires auto-unseal to already be configured. This instance provides auto-unseal for other OpenBao instances, so it must be initialized manually — which the `openbao-init` Job handles.
