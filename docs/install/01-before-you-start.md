# Before you start

You need the following. On the next page, `make prereqs` checks most of it for you, but not the network: check that
yourself.

- **Two clusters on OpenShift 4.21 or later:** a hub and a site, each with a default StorageClass and two nodes for
  Submariner's gateways. Any two worker nodes outside the control plane do: `make bootstrap` labels two of the hub's
  workers `submariner.io/gateway=true`, and `make site-import` two of the site's, preferring nodes without GPUs. On a
  compact cluster or single-node OpenShift, they stop and print the `oc label` command for you to run instead
  ([limits of `main`, L21](../upstream-main-limits.md#l21-nothing-labels-the-submariner-gateway-nodes);
  [site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide)). Size the site for its
  models; GPU models need GPU nodes. For a test, one cluster can be both hub and site
  ([all-in-one](09-hands-off.md#all-in-one-one-cluster)).
- **No platform cert-manager Operator on the site.** On the library's `main` branch, a site that already runs the
  cert-manager Operator for Red Hat OpenShift can't join the grid
  ([limits of `main`](../upstream-main-limits.md#l4-sites-that-need-per-site-values)).
  `make site-check` checks it on [page 5](05-prepare-site.md).
- **A `cluster-admin` sign-in to each cluster,** and its API URL.
- **The CA of a cluster whose certificates aren't publicly trusted.** On a new cluster, the API server and the
  ingress router, which serves the OAuth server, often present self-signed certificates, so `make login` stops with
  `self signed certificate in certificate chain`. Give each such cluster a `ca:` in `clusters.yaml`: run
  `make fetch-ca NAME=hub`, or a site's name, which writes the certificates the cluster presents there, and compare
  the fingerprints it prints with the ones a cluster admin sees
  ([an untrusted cluster certificate](09-hands-off.md#an-untrusted-cluster-certificate)).
- **Network:** Submariner creates a LoadBalancer Service on each cluster for its gateways, so each cluster needs a
  load-balancer provider. Each cluster reaches the other's load balancer on UDP 4500 and 4490, and every router name
  answers `AAAA` queries without `NXDOMAIN`
  ([site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide)).
- **A `quay.io/rhoai` login:** this template installs a pre-release (nightly) OpenShift AI 3.6 build from
  `quay.io/rhoai`, so you need a container auth file with a login for it. Red Hat gives `quay.io/rhoai` robot tokens
  to early-access partners; ask your Red Hat contact. A general `quay.io` login also works
  ([general `quay.io` login](troubleshooting.md#make-bootstrap-refuses-a-general-quayio-login)).
- **A `registry.stage.redhat.io` login:** the library mirrors the model runtime images
  (`registry.redhat.io/rhaii*`) to `registry.stage.redhat.io`, with no fallback, so sites pull them only with this
  login. Put it in the same auth file, or, for [Install with one command](09-hands-off.md), under `stage:` in
  `.config/clusters.yaml` ([limits of `main`, L20](../upstream-main-limits.md#l20-model-runtimes-pull-only-from-registrystageredhatio)).
- **Tools:** `oc`, `kubectl` (it comes with `oc`), `git`, `jq`, `curl`, `openssl`, `python3`, `clusteradm` and `make`.

## Checkpoint

- You have everything in the list. Page 2 checks most of it; you checked the network.

Next: [2. Set up your deployment repository](02-repositories.md)
