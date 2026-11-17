# Before you start

You need the following. On the next page, `make prereqs` checks most of it for you, but not the network or the
Submariner gateway nodes: check those yourself.

- **Two clusters on OpenShift 4.21 or later:** a hub and a site, each with a default StorageClass and two nodes for
  Submariner's gateways. Any two worker nodes do: the hub labels them. On a compact cluster or single-node OpenShift,
  you label two nodes `submariner.io/gateway=true` by hand
  ([site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide)). Size the site for its
  models; GPU models need GPU nodes.
- **No platform cert-manager Operator on the site.** On the library's `main` branch, a site that already runs the
  cert-manager Operator for Red Hat OpenShift can't join the grid
  ([limits of `main`](../upstream-main-limits.md#l4-sites-that-need-per-site-values)).
  `make site-check` checks it on [page 5](05-prepare-site.md).
- **A `cluster-admin` sign-in to each cluster,** and its API URL.
- **Network:** Submariner creates a LoadBalancer Service on each cluster for its gateways, so each cluster needs a
  load-balancer provider. Each cluster reaches the other's load balancer on UDP 4500 and 4490, and every router name
  answers `AAAA` queries without `NXDOMAIN`
  ([site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide)).
- **A `quay.io/rhoai` login:** this template installs a pre-release (nightly) OpenShift AI 3.6 build from
  `quay.io/rhoai`, so you need a container auth file with a login for it. Red Hat gives `quay.io/rhoai` robot tokens
  to early-access partners; ask your Red Hat contact. A general `quay.io` login also works
  ([general `quay.io` login](troubleshooting.md#make-bootstrap-refuses-a-general-quayio-login)).
- **Tools:** `oc`, `kubectl` (it comes with `oc`), `git`, `jq`, `curl`, `openssl`, `python3`, `clusteradm` and `make`.

## Checkpoint

- You have everything in the list. Page 2 checks most of it; you checked the network and the gateway nodes.

Next: [2. Set up your deployment repository](02-repositories.md)
