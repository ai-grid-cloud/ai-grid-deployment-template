# Before you start

You need the following. On the next page, `make prereqs` checks most of it for you, but not the network or the
Submariner gateway nodes: check those yourself.

- **Two clusters on OpenShift 4.21 or later:** a hub and a site, each with a default StorageClass and two nodes for
  Submariner's gateways. Any two worker nodes do: the hub labels them. On a compact cluster or single-node OpenShift,
  you label them by hand ([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/9cb50e9afcc069669aff57d2bf25d0b759b85ece/docs/install/hub/01-acm.md#submariner)). Size the site for its models; GPU models need
  GPU nodes.
- **A `cluster-admin` sign-in to each cluster,** and its API URL.
- **On the site, a cert-manager ClusterIssuer** that issues publicly trusted certificates by DNS-01. Note its name:
  page 6 asks for it, and `make prereqs` lists it.
- **Network:** Submariner creates a LoadBalancer Service on each cluster for its gateways, so each cluster needs a
  load-balancer provider. Each cluster reaches the other's load balancer on UDP 4500 and 4490, and every router name
  answers `AAAA` queries without `NXDOMAIN` ([site networking](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/9cb50e9afcc069669aff57d2bf25d0b759b85ece/docs/install/spokes/networking.md)).
- **A `quay.io/rhoai` login:** this template installs a pre-release (nightly) OpenShift AI 3.6 build from
  `quay.io/rhoai`, so you need a container auth file with a login for it. Red Hat gives `quay.io/rhoai` robot tokens
  to early-access partners; ask your Red Hat contact. A general `quay.io` login also works
  ([general `quay.io` login](troubleshooting.md#bootstrap-hubsh-refuses-a-general-quayio-login)).
- **Tools:** `oc`, `git`, `jq`, `curl`, `openssl`, `python3`, `clusteradm` and `make`.

## Checkpoint

- You have everything in the list. Page 2 checks most of it; you checked the network and the gateway nodes.

Next: [2. Set up your deployment repository](02-repositories.md)
