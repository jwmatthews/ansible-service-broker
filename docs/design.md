# Ansible Service Broker Design

An [OpenServiceBroker](https://github.com/openservicebrokerapi/servicebroker) (OSB) implementation.


> The [ServiceCatalog] is the source of truth for service instances and bindings.
> Service brokers are expected to have successfully provisioned all the instances
> and bindings ServiceCatalog knows about, and none that it doesn't.

---

![Design](design.png)

---

### Definitions

* **Ansible Playbook Bundle (APB)**: Containerized application implementing APB spec (forthcoming)
to be deployed and managed via the Service Broker.

* **Ansible Service Broker (ASB)**: Responsible for AA lifecycle management as well as exposure
of available APBs found in backing registries.

* **Registry**: Container image registry.  Requirements:

  1.) Registry must allow the ASB to query for available APBs, and filter containers that are not APBs.

  2.) ASB must be able to retrieve full set of Spec Files representing the APBs available *without*
      having to pull the full images.

* **Ansible Playbook Bundle Spec File**: Metadata file, apb.yml, packaged within an APB containing required set of
attributes to make it available via the Service Catalog.

### Guiding principles

* Delegate specifics to APBs when appropriate. APBs define what
`bind` or `provision` mean in the context of their domain.

* Shared behavior between apps should be pushed into APB execution environment,
or the ServiceBroker.

### Flow

**Pre-broker install**

It's possible to have registries containing ~15k APBs. On ASB's installation,
`/catalog` will be called by the Service Catalog, and the ASB needs to respond with
the inventory of known spec files in the form of Service objects (defined by OSB spec).

Shouldn't be done at installation; ASB needs to be bootstrapped so spec files
can be downloaded and cached in a store prior to installation.

> TODO: Upgrades? Cache misses? L1 vs L2?

`POST /bootstrap` loads apps from registry into local store.

Spec includes:

* Bindable?

* Async? Required, Optional, Unsupported

* Parameters - Schema representing configuration params available to user


**Install/Catalog**

ASB pulls inventory of spec files from local store, converts to []Service, sends to Service Catalog

Note: Parameter handling is still a [topic of discussion](https://github.com/openservicebrokerapi/servicebroker/pull/74)
Configurable parameters for an APB should be defined within the spec file. Param
schema is passed to the Service Catalog via the `/catalog` response as metadata.
Purpose of this is to inform Catalog Clients of the configuration parameters that
can be set by a user at provision time.

> TODO: Discussion re: pagination? How does the /catalog handle large amounts of data? [RFC](#)

**Provision**

User provides parameter configuration, which is passed back to the ASB by
the Service Catalog in the form of `parameters` during a provision call.

provision == `PUT /v2/service_instances/:instance_id`

Because the Service Catalog is the source of truth for service instances and bindings,
it provides the ASB with an ID for a desired service instance. The ASB is responsible
for whatever bookkeeping is necessary to make sure it can perform the requested operations
when given this ID. Likely needs to be some kind of GUID.

Puts a record of the instance in its store with whatever bookkeeping
data is required, then tells the relevant APB to `provision` itself with the
user provided parameters given to the ASB via the provision request. APB is responsible
for actually instantiating itself and defining what it means to be `provisioned`.

**Deprovision**

delete == `DELETE /v2/service_instances/:instance_id`

Service Catalog will request a deprovision, ASB must lookout the instances that
it knows about within its data store, will probably extract some about of
parameters as to how that was originally provisioned, and run the APB `deprovision`
action with some amount of parameters as arguments. APB is responsible for taking
itself down.

> TODO: What to do about outstanding bindings? [RFC](#)

**Bind**

> TODO

**Unbind**

> TODO

### Registry Adapter

To enable bootstrapping and apb discoverability, the ASB is designed to
query a registry for available apbs via a Registry Adapter. This is an
interface that can be implemented. Its most important method, `LoadSpecs() []*Spec`,
is responsible for returning a slice of `Spec` structs representing the available
apbs that were discovered. It is called when a broker is bootstrapped.
A registry is instantiated as part of the
application's initialization process. The specific registry adapter used is
configured via the broker [configuration file](../etc/ex.dev.config.yaml) under
the name field.

#### DockerHubRegistry Adapter

The `DockerHubRegistry` (name: dockerhub) is a useful adapter that enables
a broker to be bootstrapped from the Docker Hub registry via the standard
Docker Registry API. First, it will retrieve the list of images that a specified
registry contains. Next, it will inspect each of the images and [retrieve
their associated metadata](https://github.com/containers/image). The API queries
are critical to apb discoverability because it allows the broker to retrieve
the `com.redhat.apb.spec` label containing an apb's base64
encoded spec information. The adapter filters any non-apb images
based on the presence of these labels, decodes each of their specs, and loads
the specs into etcd via the `Registry::LoadSpecs` method.

The `DockerHubRegistry` requires a `user`, `pass`, and `org` field
to be set inside the `registry` section of the configuration file. The user
credentials are used to authenticate API queries, and the organization is the
target org that apbs will be loaded from.
