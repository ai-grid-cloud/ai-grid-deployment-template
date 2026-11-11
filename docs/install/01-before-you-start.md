# Before you start

Gather the following before you run anything.

> **Important:** This release installs pre-release OpenShift AI 3.6 builds. Every cluster pulls them from
> `quay.io/rhoai`, and model runtime images from `registry.stage.redhat.io`. You need logins for both registries,
> which Red Hat gives only to early-access partners; ask your Red Hat contact. Without a stage login, model images fail
> to pull on every site.

## 1. Clusters

| Cluster | OpenShift | Needs |
|---|---|---|
| Hub | 4.21 or later | A default StorageClass; room for ACM, Argo CD, the MaaS database primary, Keycloak, Redis and the console |
| Site (combined) | 4.21 or later | A default StorageClass; capacity for its models (the CPU sample model in [first use](07-first-use.md) requests 4 CPU and 8 GiB); GPU nodes for GPU models |

Every cluster, the hub included, needs two worker nodes that Submariner can use as gateways
([Submariner](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/01-acm.md#submariner)). On compact clusters and single-node OpenShift you label them by hand.

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
GridSite stays `Connecting` ([site networking](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/spokes/networking.md#dns)).

## 3. Accounts and credentials

| What | Used in |
|---|---|
| A container auth file with a `quay.io/rhoai` login (a robot token scoped to `quay.io/rhoai`) and a `registry.stage.redhat.io` login | [Prepare the hub](03-prepare-hub.md) |
| A GitHub fine-grained token with **Contents: Read and write** on your catalog repository only, saved to a file | [Install the hub components](04-hub-components.md) |
| A cert-manager ClusterIssuer on each ingress or combined site that issues publicly trusted certificates by **DNS-01** | [Join the site to the grid](06-join-grid.md) |
| `cluster-admin` on every cluster | Every page |

## 4. Tools on your workstation

`oc`, `kubectl`, `kustomize` (5.x), `jq`, `git`, `curl`, `openssl`, `base64`, `python3` with PyYAML, `htpasswd`
(from `httpd-tools`) and `clusteradm`.

Check them:

```sh
for c in oc kubectl kustomize jq git curl openssl base64 python3 htpasswd clusteradm; do command -v "$c" >/dev/null || echo "missing: $c"; done
python3 -c "import yaml" || echo "missing: PyYAML"
```

You should see no output.

## Checkpoint

- You have kubeconfig contexts with `cluster-admin` for the hub and the site.
- Your tools check prints nothing.
- You have the registry logins, the catalog token, and a DNS-01 ClusterIssuer on the site.
