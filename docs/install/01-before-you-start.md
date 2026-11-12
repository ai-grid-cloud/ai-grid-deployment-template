# Before you start

Gather the following before you run anything. On the next page, `make prereqs` checks most of it.

## 1. Clusters

- **A hub and a site,** each on OpenShift 4.21 or later with a default StorageClass. Size the site for its models;
  GPU models need GPU nodes.
- **Two worker nodes on each cluster** that Submariner can use as gateways. On compact clusters and single-node
  OpenShift, you label them by hand ([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/d5021fa2080d013732825da29d1d2714d9eb0c54/docs/install/hub/01-acm.md#submariner)).
- **A `cluster-admin` sign-in to each cluster,** and its API URL.
- **On the site, a cert-manager ClusterIssuer** that issues publicly trusted certificates by DNS-01.

## 2. Network

- Your workstation reaches each cluster's API on port 6443, and the hub reaches your git host on 443.
- The site and the hub reach each other's Submariner gateways on UDP 4500 and 4490, through a load balancer.
- The site reaches the hub's tenant identity provider on 443, and tenants reach the site on 443.
- Every router name answers `AAAA` queries with an address or an empty answer, never `NXDOMAIN`.

For separate ingress and inference sites, see [site networking](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/d5021fa2080d013732825da29d1d2714d9eb0c54/docs/install/spokes/networking.md).

## 3. Registry logins

Pre-release builds only: this template installs a nightly OpenShift AI 3.6 build, so you need a container auth file
with logins to `quay.io/rhoai` and `registry.stage.redhat.io`. Red Hat gives them to early-access partners; ask your
Red Hat contact.

## 4. Tools on your workstation

- `oc`, the OpenShift CLI, and `kubectl`, which comes with it: every page.
- `kustomize` 5 or later: renders your deployment repository's root.
- `git`: clones and pushes your repositories.
- `jq`, `curl`, `openssl` and `base64`: used by the setup scripts and in first use.
- `python3`: reads cluster state in the setup scripts.
- `clusteradm`: imports the site into ACM.
- `make`: runs the cluster logins and the prerequisites check.

After you clone your repository in
[set up your deployment repository](02-repositories.md#1-clone-your-repository-and-log-in-to-your-clusters), check
them from its directory:

```sh
make prereqs
```

It prints each tool as `ok`, with its version, or `MISSING`, and changes nothing.

## Checkpoint

- You can sign in to the hub and the site as a `cluster-admin` user, and you have each one's API URL.
- You have the tools in part 4.
- You have the registry logins and a DNS-01 ClusterIssuer on the site.
