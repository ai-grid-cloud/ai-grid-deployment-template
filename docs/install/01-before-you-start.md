# Before you start

You need the following. On the next page, `make prereqs` checks most of it for you.

- **Two clusters on OpenShift 4.21 or later:** a hub and a site, each with a default StorageClass and two worker
  nodes Submariner can use as gateways ([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/d5021fa2080d013732825da29d1d2714d9eb0c54/docs/install/hub/01-acm.md#submariner)). Size the site for its models;
  GPU models need GPU nodes.
- **A `cluster-admin` sign-in to each cluster,** and its API URL.
- **On the site, a cert-manager ClusterIssuer** that issues publicly trusted certificates by DNS-01.
- **Network:** the site reaches the hub on UDP 4500 and 4490 through a load balancer, and every router name answers
  `AAAA` queries without `NXDOMAIN` ([site networking](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/d5021fa2080d013732825da29d1d2714d9eb0c54/docs/install/spokes/networking.md)).
- **Pre-release builds only:** a container auth file with `quay.io/rhoai` and `registry.stage.redhat.io` logins,
  which Red Hat gives to early-access partners; ask your Red Hat contact.
- **Tools:** `oc`, `kustomize` 5 or later, `git`, `jq`, `curl`, `openssl`, `python3`, `clusteradm` and `make`.

## Checkpoint

- You have everything in the list. Page 2 checks it.
