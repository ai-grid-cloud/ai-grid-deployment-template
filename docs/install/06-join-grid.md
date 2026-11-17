# Join the site to the grid

You add the site to the grid in the provider console. **Add to AI Grid** labels the site's ManagedCluster on the
hub with the role and location you choose, and the hub then installs OpenShift AI, MaaS, the grid and the tenant
settings in that role. Your `clusters.yaml` names no role or location: you choose them here. The `make` targets on
this page work on the only site in your `clusters.yaml`. With several sites, add the site's name, such as
`make site-status SITE=SITE_NAME`.

## 1. Add the site in the console

1. Open `https://CONSOLE_HOST` (from [install the hub components](04-hub-components.md#2-verify)) and sign in as a
   user with `cluster-admin` on the hub.
2. Click **Clusters**. Your site shows **Not added**.
3. Click **Add to AI Grid** for your site. Choose the role **combined**, so tenants enter and models run on the same
   cluster, and the site's location, such as `us-east`. Confirm.
   For `ingress` and `inference` sites, see [Sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/README.md#what-you-choose-per-site).

The hub then creates the site's Applications. Show them:

```sh
make site-status
```

Under `Applications` you should see `rhoai-SITE-…`, `cluster-config-SITE-…`, `acm-submariner-SITE` and
`maas-db-SITE`. Most appear within a couple of minutes. `rhoai-SITE-…` can take up to 30 minutes: the hub's
`rhoai` Application creates it on its next sync retry after the site joins (page 4).
OpenShift AI takes up to an hour on a new cluster, and less on one that ran OpenShift AI before.

## 2. Verify

1. Check the hub and the site:

   ```sh
   make status
   ```

   Run it again every few minutes until you see, under the site, `OpenShift AI (DataScienceCluster): Ready` and its
   GridSite `Available=True`, and on the hub no Application listed as not `Synced` and `Healthy`. If the phase
   flips between `Ready` and not, see
   [troubleshooting](troubleshooting.md#kserveready-flaps-false-on-a-site).

   If you look at the site's GridNetwork, its `SITES` column shows `0`: that column counts SWIM peers, and the
   library's grid uses Local membership, which has none. Its `AVAILABLE` column is what to check.

2. The MaaS hostname answers:

   ```sh
   make site-status
   ```

   You should see `MaaS https://maas.SITE_APPS_DOMAIN/v1/models: answers with the cluster's internal certificate,
   which isn't publicly trusted`. The MaaS gateway is up, but it uses the cluster's internal certificate, so
   tenants' clients don't trust it until you add your own
   ([MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/maas-certificate.md)). With your own certificate, you see `401`
   instead: no token yet.

## Checkpoint

- The console shows the site with AI Grid status **Provisioned**.
- The site's DataScienceCluster is `Ready` and its GridSite `Available`.
- `make status` lists no hub Application as not `Synced` and `Healthy`.
- `make site-status` says the MaaS gateway answers (with the internal certificate, or `401` with your own).

Next: [7. First use](07-first-use.md)
