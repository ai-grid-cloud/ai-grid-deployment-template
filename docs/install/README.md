# Install AI Grid

This guide takes you from OpenShift clusters to a working AI Grid: a hub, one site, a model deployed from the
provider console, and a tenant calling it. It installs the template's tested choices; you change only the names that
must be yours. Follow the pages in order; each ends with a checkpoint that must be true before you move on.

For what AI Grid is and how its parts fit together, see [How AI Grid works](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/README.md).

## Follow these in order

| Page | What happens | Time |
|---|---|---|
| [1. Before you start](01-before-you-start.md) | Clusters, network, credentials and tools | 15 minutes |
| [2. Set up your deployment repository](02-repositories.md) | Your catalog repository and its token, your names in the inputs, checked and pushed | 20 minutes |
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
- The component reference, in the library at your pin: [How AI Grid works](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/README.md), [Hub](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/hub/README.md),
  [Sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/spokes/README.md),
  [Appendix A: inputs and values](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/appendix-a-inputs.md).
- [Appendix B: the example deployment](appendix-b-example.md) · [Appendix C: known gaps](appendix-c-gaps.md)
