# app-cat-service-prototype

Application catalog service prototype (Redis)

## Requirements

* `kubectl`
* `helm` v3
* `go` (or alternatively `kind`)
* `docker`

## Getting started

Short version:

`make provision`

This will
1. Install a local Kubernetes cluster with kubernetes-in-docker (`kind`)
1. Install Crossplane Helm chart
1. Install Secrets Generator Helm chart (for providing random passwords)
1. Install Prometheus Operator and a Prometheus instance with AlertManager
1. Install a CompositeResourceDefinition for the prototype service
1. Install a Composition for the prototype service
1. Deploy a service instance of the prototype
1. Verify that the service is up and usable
1. Provision an S3 bucket using Minio
1. Setup backups using K8up (to be verified manually, see docs)

The prototype service is a simple Redis instance.

To uninstall, either run
- `make deprovision` to just uninstall the service instance.
- `make clean` to completely remove the cluster and all artifacts.

## Monitoring

A monitoring stack with Prometheus will also be installed and monitors the Redis instance as well as backups.
The stack can also be used for billing purposes.
In `service/billing.promql` is a sample PromQL query that can be used to count how long a certain Redis instance is "provisioned".
Enter this query in http://127.0.0.1.nip.io:8081/prometheus/ after provisioning.

## How it works

For a full overview, see the official Crossplane docs at https://crossplane.io.

Terminology overview:

- `CompositeResourceDefinition` or just `Composite` and `XRD`: This basically defines how the user-consumable spec for a service instance should look like
- `Composite`: This is the manifest that contains all the artifacts that are being deployed when a service instance is requested.
- `XRedisInstance`: In this prototype, this is the cluster-scoped service instance.
- `RedisInstance`: In this prototype, this is the namespace-scoped reference to a cluster-scoped `XRedisInstance`. This basically solves some RBAC problems in multi-tenant clusters. Also generally called a `claim`.

So when users request a service instance, they create a resource of kind `RedisInstance`, which generates a `XRedisInstance`, which references a `Composite`, defined by `CompositeResourceDefinition`.

### Custom spec

In order to support more input parameters in the service instance, we have to define the OpenAPI schema in the `CompositeResourceDefinition` and basically define each property and their types, optionally some validation and other metadata.

See `crossplane/composite.yaml` for the definition of the spec and `service/prototype-instance.yaml` for a usage example.

## Future Design Considerations

### Scaling resources

In the past we've made scaling instances possible by switching to a different composition that has different resource parameters.
For example, `redis-small` to `redis-large` (T-shirt sizes).
Meanwhile we've made the experience that this is a rather bad idea, as the data has to be migrated from one instance to the other and doesn't freely allow to scale beyond the given pre-existing compositions.

It should rather be possible to define resources within the spec of a instance.

### Self-service of major versions

In the past with a similar project we've updated every instance in a certain time window and it felt it was "forced from top".
It was very difficult handling updates which require manual upgrades (e.g. Database versions).

Instead, we should aim for a design that allows self-service for users.
They should choose which Version of a service they want and be able to do major version upgrades on their own.

### Supporting multiple major versions

Using the reasioning described before, we need to support a rolling version matrix, where users can choose between a set of supported major versions of a service.
If a new major version is released and tested, an older one may get decomissioned.
We should allow users some time to do the upgrade on their own.

To achieve this, `CompositionRevisions` (Crossplane alpha feature) and pinning a certain revision at first sounds like the solution to this, but it can easily create a mess and it doesn't allow to make changes to the deployment of an older supported major version (e.g. rollout of improved alert rules).

Instead, a more suitable alternative is to bake in a version matrix into the spec of a service instance and use a `Composition`'s `Map` transform.
Consider the following snippet:

```yaml
- fromFieldPath: spec.parameters.updatePolicy.version
  toFieldPath: spec.forProvider.chart.version
  transforms:
    - type: map
      map:
        stable: 12.9.1
        edge: 13.0.0
        stable-6: 12.9.1 # '6' refers to Redis major version
        stable-5: 11.5.5
```

If `stable-5` were to be removed from the map, instances that use this version become unready and cannot be changed anymore without selecting a supported version.
Deployments are left untouched, so that should give a last resort to either upgrade immediately, or it can be deleted if that's a business decision.

Using this approach doesn't strictly need the new `CompositionRevision` feature, but it may be useful in other cases.

This approach could also be more efficiently handled by a custom Crossplane provider.

### Deploying additional resources

Common Helm charts for apps like Redis, MariaDB etc. don't come with all the resources that are required for operating AppCat service catalog with our standards.
For example, more alert rules, backup definitions, S3 buckets, dashboards or even metrics exporters may be required.

It may be worthwhile to engineer a Helm chart just for these additional artifacts.
Whether this chart can be generic for all services or a dedicated one for each service, remains to be seen (let's gather experience first).

Also possible are so-called "umbrella" charts, which list other charts as dependency and can deploy additional resources.
For compositions that deploy the service with Helm this might be interesting, however compositions that can directly deploy cloud-provider-specific service instances using Crossplane providers this may be without dependencies.

The most flexible solution would be to write a custom Crossplane provider.

### Service Architecture Choice

The current idea is to provision multiple types of service architecture.
For example "Standalone", "Replicated", "Clustered" or "Cloud Instance".

Since it's in most cases impossible to easily switch from one type to the other, it makes sense to create a dedicated CRD for each type of architecture, for example
- `RedisStandaloneInstance`
- `RedisReplicatedInstance`
- `RedisClusteredInstance`
- `RedisCloudInstance`

instead of relying on a single CRD that offers an enum in the API specs.

This avoids having to "switch-case" specs in the CRD API scheme, or immutable fields after creation or other measures that make the API spec rather confusing ("which fields are relevant for which type...?").

And probably most importantly; it conveys a clear message to the user that architecture types cannot be changed from one to the other.
Customers would have to provision new instance and migrate their data.
