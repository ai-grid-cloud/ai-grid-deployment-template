# Install AI Grid

This guide takes you from OpenShift clusters to a working AI Grid: a hub, one site, a model deployed from the
provider console, and a tenant calling it. It installs the template's tested choices; you change only the names that
must be yours. Follow the pages in order; each ends with a checkpoint that must be true before you move on.

Tested on 2026-11-10: a hub on OpenShift 4.22 with ACM 2.17, and one combined site on OpenShift 4.21, on AWS.

> **This branch installs from the library's `main` branch** and hasn't been run on a cluster. Where these pages
> differ from [what `main` can do](../upstream-main-limits.md), that page wins: no tenant IdP of your own, no
> per-site values, and no publicly trusted MaaS certificate.

For what AI Grid is and how its parts fit together, see the library's [getting started](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/README.md).

## Follow these in order

| Page | What happens | Time |
|---|---|---|
| [1. Before you start](01-before-you-start.md) | Clusters, network, credentials and tools | 15 minutes |
| [2. Set up your deployment repository](02-repositories.md) | Your catalog repository and its token, your names in the inputs, checked and pushed | 20 minutes |
| [3. Prepare the hub](03-prepare-hub.md) | Infrastructure check, OpenShift GitOps, your root applied | 15 minutes |
| [4. Install the hub components](04-hub-components.md) | Argo CD installs ACM, the grid, the MaaS database, Keycloak, the console | 30 minutes |
| [5. Prepare the site](05-prepare-site.md) | Infrastructure check, import into ACM | 15 minutes |
| [6. Join the site to the grid](06-join-grid.md) | Add the site in the provider console, which installs OpenShift AI and enrols it | 45 to 60 minutes |
| [7. First use](07-first-use.md) | A model from the provider console, a tenant calling it | 30 minutes |
| [8. Uninstall](08-uninstall.md) | Only when you remove AI Grid: each site, then the hub | 15 minutes per site, 25 for the hub |

To add more sites, repeat pages 5 and 6 for each.

To install the hub and import your sites with one unattended command instead of pages 2 to 5, for a test suite or a
CI job, see [9. Install with one command](09-hands-off.md).

## Upgrade from an earlier template

Earlier versions of this template installed the library from a branch of their own. This version installs the
library's `main` branch, which reads less from your deployment repository
([limits](../upstream-main-limits.md)). Check these before you push the update that `make update` merges:

1. **Per-site files.** If your repository has `values/clusters/`, `apps/SITE-maas-tls.yaml` or `sites/SITE/maas-tls/`,
   `make check` fails and names them. The library's `main` branch doesn't read them, so the sites they configure would
   lose those values: a site that runs the platform's cert-manager would fail its cert-manager Operator, and a site
   with its own MaaS certificate would go back to the cluster's internal one. Don't update such a deployment until
   you've removed those sites from the grid in the provider console. Then delete the files.
2. **The hub's cert-manager.** Earlier versions used the hub's own cert-manager. `make inputs` writes
   `hubCertManager=library`, which installs the library's beside it and fails both. If
   `oc get operatorgroups -n cert-manager-operator` on the hub shows an OperatorGroup other than
   `openshift-cert-manager-operator`, set `hubCertManager=platform` in `root/inputs.env` before you push.
   `make install` checks this and stops; a push without it doesn't.
3. **The template's own tenant Keycloak.** Earlier versions ran it in namespace `tenant-idp`. After the push, the hub
   drops its Application but keeps what it deployed, because the root preserves resources when an Application goes,
   so that Keycloak keeps serving its realm and users until you remove it:

   1. Point the provider console at the library's Keycloak:

      ```sh
      make console-secrets
      ```

   2. Check that `make status` shows the `keycloak` Application `Synced` and `Healthy`.
   3. Remove the old Keycloak and its client Secret's namespace on the hub:

      ```sh
      scripts/with-cluster.sh hub oc delete namespace tenant-idp tenant-idp-client --ignore-not-found
      ```

   The organizations, users and subscriptions you made in the old Keycloak don't move: create them again in the
   provider console.
4. **The `registry.stage.redhat.io` login.** Sites now pull model runtimes only from `registry.stage.redhat.io`
   ([limits of `main`, L20](../upstream-main-limits.md#l20-model-runtimes-pull-only-from-registrystageredhatio)).
   Add the login (`stage:` in `.config/clusters.yaml`, or in your auth file), then rerun `make bootstrap` once:
   `make install` skips the bootstrap on a hub that already has its pull secret, so it doesn't add the login there.

## Reference

- [Troubleshooting](troubleshooting.md): problems while following this guide.
- [Uninstall](08-uninstall.md): remove AI Grid from each site, then the hub.
- [Limits of the library's `main` branch](../upstream-main-limits.md): what this template can't do yet, and the
  library change that would fix each limit.
- The library's own docs, at the commit these pages were written against: [getting started](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/README.md),
  [the hub](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/hub-onboarding/README.md), [sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md),
  [Keycloak](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/apps/keycloak/README.md), [the provider console](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/apps/console/README.md) and
  [organization identity providers](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/organization-identity-providers/README.md).
