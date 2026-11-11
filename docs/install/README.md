# Install AI Grid

This guide takes you from OpenShift clusters to a working AI Grid: a hub, one site, a model deployed from the
provider console, and a tenant calling it. Start after you've created your deployment repository
([start here](../../README.md#start-here)), and follow the pages in order. Each page ends with a checkpoint that must
be true before you move on.

The guide installs the template's choices, which were tested end to end: the components selected in
`root/kustomization.yaml`, S4 object storage, the template's own Keycloak for tenants (`tenant-idp/`), the provider
console, and one combined site. You change only the names that must be yours. To change a choice, see
[Hub components](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/README.md) and [Sites](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/spokes/README.md).

## What AI Grid is

AI Grid serves models from many OpenShift clusters as one service. Tenants call one endpoint, Models-as-a-Service
(MaaS) checks their identity and subscription, and the grid routes each request to a site that runs the model. A hub
cluster runs Red Hat Advanced Cluster Management (ACM), Argo CD and the provider console, and delivers everything else
to the sites.

```text
                tenants (OIDC tokens or API keys)
                              |
                              v
   +---------------- ingress site ----------------+       +---- inference site ----+
   | MaaS gateway, Org UI, grid consumer gateway  | mTLS  | grid provider gateway, |
   | (a combined site is ingress + inference)     |------>| models                 |
   +----------------------------------------------+       +------------------------+
                  ^                                                  ^
                  |  ACM policies, Argo CD applications, Submariner  |
                  +---------------------- hub -----------------------+
        ACM, Argo CD, grid enrollment, site and model delivery, provider console,
        MaaS database and Redis, tenant identity provider
```

Your hub's Argo CD reads three repositories: the **library** (the components, pinned at one commit), your
**deployment repository** (this one: which components run, the inputs, each site's files), and your **catalog
repository** (models and subscriptions, written only by the provider console).

## Follow these in order

| Page | What happens | Time |
|---|---|---|
| [1. Before you start](01-before-you-start.md) | Clusters, network, credentials and tools | 15 minutes |
| [2. Set up your deployment repository](02-repositories.md) | Your names in the inputs, checked and pushed | 15 minutes |
| [3. Prepare the hub](03-prepare-hub.md) | Infrastructure check, OpenShift GitOps, your root applied | 15 minutes |
| [4. Install the hub components](04-hub-components.md) | Argo CD installs ACM, the grid, the MaaS database, Keycloak, the console | 30 minutes |
| [5. Prepare the site](05-prepare-site.md) | Infrastructure check, import into ACM | 15 minutes |
| [6. Join the site to the grid](06-join-grid.md) | The site's files, then labels that install OpenShift AI and enrol it | 45 to 60 minutes |
| [7. First use](07-first-use.md) | A model from the provider console, a tenant calling it | 30 minutes |

To add more sites, repeat pages 5 and 6 for each.

## Reference

- [Operate](operate.md): upgrade, add and remove sites, reuse a cluster, rotate credentials, uninstall.
- [Tenant access](tenant-access.md): API keys, refusal checks, revoking a key.
- [Troubleshooting](troubleshooting.md).
- The component reference, in the library at your pin: [Hub](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/README.md),
  [Sites](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/spokes/README.md),
  [Appendix A: inputs and values](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/appendix-a-inputs.md).
- [Appendix B: the example deployment](appendix-b-example.md) · [Appendix C: known gaps](appendix-c-gaps.md)
