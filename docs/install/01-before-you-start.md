# Before you start

Gather the following before you run anything.

> **Note:** Pre-release builds only. This template installs a pre-release (nightly) OpenShift AI 3.6 build: every
> cluster pulls it from `quay.io/rhoai`, and model runtime images from `registry.stage.redhat.io`. Those registries
> need logins that Red Hat gives only to early-access partners; ask your Red Hat contact. A released OpenShift AI
> build won't need them, but the library can't install one yet ([known gaps](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/195ccd7ab783d5154549c597fef4b20dc12acd91/docs/install/known-gaps.md)).

## 1. Clusters

| Cluster | OpenShift | Needs |
|---|---|---|
| Hub | 4.21 or later | A default StorageClass; room for ACM, Argo CD, the MaaS database primary, Keycloak, Redis and the console |
| Site (combined) | 4.21 or later | A default StorageClass; capacity for its models (the CPU sample model in [first use](07-first-use.md) requests 4 CPU and 8 GiB); GPU nodes for GPU models |

Every cluster, the hub included, needs two worker nodes that Submariner can use as gateways
([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/195ccd7ab783d5154549c597fef4b20dc12acd91/docs/install/hub/01-acm.md#submariner)). On compact clusters and single-node OpenShift you label them by hand.

## 2. Network

| From | To | Port | Why |
|---|---|---|---|
| Your workstation | Every cluster's API | 6443 | `oc`, the import script |
| Hub's Argo CD | Your git host | 443 | Reads the library, deployment and catalog repositories |
| Every site | Hub, through Submariner | UDP 4500 and 4490, through a LoadBalancer Service | Grid enrollment, the MaaS database primary, Redis |
| Ingress sites | Inference sites' default router | 443 (TLS passthrough) | Grid requests over mTLS |
| Tenants | Ingress site's MaaS gateway load balancer | 443 | Model calls |
| Ingress sites | Tenant identity provider's issuer URL | 443 | Token validation |

Every router name must answer `AAAA` queries with an address or an empty answer, never `NXDOMAIN`; otherwise every
GridSite stays `Connecting` ([site networking](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/195ccd7ab783d5154549c597fef4b20dc12acd91/docs/install/spokes/networking.md#dns)).

## 3. Accounts and credentials

| What | Used in |
|---|---|
| Pre-release builds only: a container auth file with a `quay.io/rhoai` login (a robot token scoped to `quay.io/rhoai`) and a `registry.stage.redhat.io` login | [Prepare the hub](03-prepare-hub.md) |
| A cert-manager ClusterIssuer on each ingress or combined site that issues publicly trusted certificates by **DNS-01** | [Join the site to the grid](06-join-grid.md) |
| `cluster-admin` on every cluster | Every page |

## 4. Tools on your workstation

- `oc`, the OpenShift CLI, and `kubectl`, which comes with it: every page.
- `kustomize` 5 or later: renders your deployment repository's root.
- `git`: clones and pushes your repositories.
- `jq`, `curl`, `openssl` and `base64`: used by the setup scripts and in first use.
- `python3`: reads cluster state in the setup scripts.
- `htpasswd`, from `httpd-tools`: creates the break-glass admin login.
- `clusteradm`: imports the site into ACM.
- `make`: runs `make prereqs`.

You check them with `make prereqs` after you clone your repository, in
[set up your deployment repository](02-repositories.md#1-clone-your-repository-and-the-library).

## Checkpoint

- You have kubeconfig contexts with `cluster-admin` for the hub and the site.
- You have the tools in part 4.
- You have the registry logins and a DNS-01 ClusterIssuer on the site.
