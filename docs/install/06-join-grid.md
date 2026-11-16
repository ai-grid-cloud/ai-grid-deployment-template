# Join the site to the grid

Labels on the site's ManagedCluster make it a grid site. The hub then installs OpenShift AI, MaaS, the grid and the
tenant settings in the site's role. The `make` targets on this page work on the only site in your `clusters.yaml`.
With several sites, add the site's name, such as `make site-join SITE=SITE_NAME`.

## 1. Label the site

The site's labels on the hub make it a grid site, in the role and location from your `clusters.yaml`:

```sh
make site-join
```

It first checks that your commits are pushed, and waits until the hub's `deployment-root` has synced your latest
commit, up to 10 minutes. If the site already has those labels, it says `labels already set` and changes nothing.
The console shows the location.
For `ingress` and `inference` sites, see [Sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/README.md#what-you-choose-per-site).

You should see `managedcluster.cluster.open-cluster-management.io/SITE labeled`. The hub then creates the site's
Applications. Show them:

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

   You should see `MaaS https://maas.SITE_APPS_DOMAIN/v1/models: 401`: no token yet. The MaaS gateway uses the
   cluster's internal certificate, so tenants' clients don't trust it until you add your own
   ([MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/maas-certificate.md)).

## Checkpoint

- The site's DataScienceCluster is `Ready` and its GridSite `Available`.
- `make status` lists no hub Application as not `Synced` and `Healthy`.
- `https://maas.SITE_APPS_DOMAIN` answers `401`.

Next: [7. First use](07-first-use.md)
