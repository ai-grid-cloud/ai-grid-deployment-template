# Before you start

Gather the following before you run anything. Each item names the section that needs it.

> **Important:** This release installs pre-release OpenShift AI 3.6 builds. Every cluster pulls them from
> `quay.io/rhoai`, and the image mirror the library delivers sends every `registry.redhat.io/rhaii*` image, model
> runtimes included, to `registry.stage.redhat.io` with `NeverContactSource`. You need logins for both registries,
> which Red Hat gives only to early-access partners; ask your Red Hat contact. Without a stage login, model images fail
> to pull on every site. What changes at general availability (the catalog source, the mirror, which logins you need)
> isn't decided in the library yet ([known gaps](appendix-c-gaps.md)).

## 1. Clusters

| Cluster | OpenShift | Needs | Verified with |
|---|---|---|---|
| Hub | 4.21 or later (`check-prerequisites.sh` enforces it) | A default StorageClass; room for ACM, Argo CD, the MaaS database primary, Keycloak, Redis and the console | 4.22.18, ACM 2.17.4 |
| Ingress site | 4.21 or later | A default StorageClass (OpenShift AI monitoring claims 20 GiB and 10 GiB; the MaaS database replica claims 20 GiB) | as combined |
| Inference site | 4.21 or later | A default StorageClass; capacity for its models; GPU nodes for GPU models | as combined |
| Combined site | 4.21 or later | Both of the preceding | 4.21.37, 6 nodes, CPU model only |

- Every cluster, the hub included, needs two worker nodes that Submariner can use as gateways
  ([Submariner](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/01-acm.md#submariner)). On compact clusters and single-node OpenShift you label them by hand.
- A model's size sets a site's capacity. The CPU sample model in [first use](08-first-use.md) requests 4 CPU and
  8 GiB.
- With more than one site, give the hub's Argo CD application controller 8 GiB of memory
  ([OpenShift GitOps](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/00-platform-services.md#openshift-gitops)).
- Managed OpenShift (OSD, ROSA) needs extra namespaces created by hand
  ([OpenShift AI prerequisites](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). *(Unverified.)*

Exact CPU and memory sizing for a hub isn't established yet ([known gaps](appendix-c-gaps.md)).

## 2. Network

| From | To | Port | Why |
|---|---|---|---|
| Your workstation | Every cluster's API | 6443 | `oc`, the import script |
| Hub's Argo CD | Your git host | 443 | Reads the library, deployment and catalog repositories |
| Every site | Hub, through Submariner | UDP 4500 and 4490 (Submariner IPsec and NAT discovery), through a LoadBalancer Service | Grid enrollment, the MaaS database primary, Redis |
| Ingress sites | Inference sites' default router | 443 (TLS passthrough) | Grid requests over mTLS |
| Tenants | Ingress site's MaaS gateway load balancer | 443 | Model calls |
| Ingress sites | Tenant identity provider's issuer URL | 443 | Token validation (OIDC discovery and keys) |

DNS:

- Each ingress site's MaaS hostname, `PREFIX.apps.CLUSTER_DOMAIN`, resolves to the MaaS gateway's load balancer.
  OpenShift creates this record; you choose `PREFIX` when you [join each site to the grid](06-join-grid.md).
- Every router name answers `AAAA` queries with an address or an empty answer, never `NXDOMAIN`. Check with
  `dig AAAA router-default.apps.CLUSTER_DOMAIN`. An `NXDOMAIN` answer leaves every GridSite `Connecting`.

## 3. Accounts and credentials

| What | Used in | Notes |
|---|---|---|
| A `quay.io/rhoai` login, and a `registry.stage.redhat.io` login, in a container auth file (pre-release access, see the preceding note) | [Prepare the hub](03-prepare-hub.md) | Prefer a robot token scoped to `quay.io/rhoai`. A general `quay.io` login is copied to every site, so the bootstrap script refuses it unless you set `RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1`. |
| A git host the hub can read | [Repositories](02-repositories.md) | The templates are GitHub repositories (**Use this template**); the example uses public GitHub repositories. |
| A token that can write only the catalog repository | [Install the hub components](04-hub-components.md) | A GitHub fine-grained token with `contents: write` on that one repository. The console's git writer uses it. |
| A tenant identity provider | [Repositories](02-repositories.md), [tenant identity provider](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/04-tenant-identity.md#tenant-identity-provider) | An OIDC issuer, a confidential client, and Keycloak Organizations if you use the console to create organizations. |
| A cert-manager ClusterIssuer that can issue publicly trusted certificates by **DNS-01** on every ingress or combined site, or your own certificate for each site's MaaS hostname | [Join each site to the grid](06-join-grid.md#1-add-the-sites-values), [MaaS gateway certificate](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/spokes/maas-certificate.md) | The MaaS gateway's load balancer serves its hostname directly, so HTTP-01 can't solve, and without a trusted certificate tenants get a certificate error. |
| `cluster-admin` on every cluster | Every page | |

## 4. Tools on your workstation

`oc`, `kubectl`, `kustomize` (5.x), `jq`, `git`, `curl`, `openssl`, `base64`, `python3` with PyYAML, `htpasswd`
(from `httpd-tools`) and `clusteradm` (for the import when you [prepare each site](05-prepare-site.md)).

Check them:

```sh
for c in oc kubectl kustomize jq git curl openssl base64 python3 htpasswd clusteradm; do command -v "$c" >/dev/null || echo "missing: $c"; done
python3 -c "import yaml" || echo "missing: PyYAML"
```

You should see no output.

## 5. Sign-in safety

Before you change anything on a cluster whose only sign-in is an external identity provider (for example a platform
Keycloak), add a break-glass htpasswd admin and confirm it works. If you lose the external provider later, this is the
only way back in. See [cluster sign-in and admins](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/00-platform-services.md#cluster-sign-in-and-admins).

Never delete an identity provider, or the namespace that runs it, that your platform's sign-in depends on.

## Checkpoint

- You have kubeconfig contexts with `cluster-admin` for the hub and every site.
- Your tools check prints nothing.
- You have the `quay.io/rhoai` and `registry.stage.redhat.io` logins, a git host, an identity provider plan, and a
  DNS-01 ClusterIssuer (or certificates) for each ingress site.
