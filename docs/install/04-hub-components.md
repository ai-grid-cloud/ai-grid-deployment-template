# Install the hub components

Argo CD now installs the selected components from the library at your pinned commit, and the template's own tenant
Keycloak. On this page you create the console's secrets, which waits for the install, and check the result.

## 1. Create the console's secrets

The provider console needs your catalog token for its git writer, and an admin login for the tenant Keycloak. Neither
goes in git. Create the secrets:

```sh
make console-secrets
```

It first waits until the tenant Keycloak's Application `tenant-idp` is `Synced` and `Healthy` and the console's Route
exists, printing what it waits for, for up to 30 minutes. The install takes about 20 minutes after the bootstrap,
mostly for the tenant Keycloak. Then it reads your catalog token from `~/.ai-grid/catalog-token`
([set up your deployment repository](02-repositories.md#2-create-your-catalog-repository-and-its-token)), or from
`CATALOG_TOKEN_FILE` if you set it, uses your tenant Keycloak in `tenant-idp`, and restarts the console to read the
new Secrets. It prints no secret value. If it times out, run `make status` (next step). For every variable, and for a
hub whose ingress certificate isn't publicly trusted, see
[provider console](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/ee0eb3755609a93ff305ea3e1278bee8c96301f3/docs/install/hub/05-console-and-model-delivery.md#provider-console).

## 2. Verify

1. Check the hub:

   ```sh
   make status
   ```

   It prints the Applications that aren't `Synced` and `Healthy`, the MultiClusterHub's phase, Argo CD's application
   controller with its restarts, the tenant Keycloak's Application, and the console's address. It changes nothing.
   You should see no Application listed as not `Synced` and `Healthy`, `MultiClusterHub: Running`, no `!!` line, and
   `Console: https://CONSOLE_HOST`. For about 5 minutes after you create the secrets, `grid-bootstrap` can show
   `OutOfSync` while its root certificate is issued; run `make status` again.

   Some Applications wait for the first site to [join the grid](06-join-grid.md), and aren't a problem until then:
   `make status` lists them on one line, `Waiting for a site to join`. They're the Submariner, `limitador-redis` and
   MaaS database Applications, which need a peer cluster, and any Application whose only unhealthy resources, or only
   failed sync tasks, are ACM Placements that match no ManagedCluster yet.

   If nothing changes for 10 minutes, or `make status` prints a line starting with `!!`, see
   [troubleshooting](troubleshooting.md#nothing-installs-on-the-hub-the-argo-cd-controller-restarts-with-oomkilled).

2. Check that the console pod is up:

   ```sh
   scripts/with-cluster.sh hub oc get pods -n ai-grid-provider-console
   ```

   You should see the console pod `3/3 Running`. Open `https://CONSOLE_HOST` and sign in as a cluster admin.

## Checkpoint

- Every Application is `Synced` and `Healthy`, apart from the ones that wait for a site. After the site joins on
  page 6, those finish on their next sync retry, which can take up to 30 minutes.
- The MultiClusterHub is `Running`.
- The console opens and you can sign in.

Next: [5. Prepare the site](05-prepare-site.md)
