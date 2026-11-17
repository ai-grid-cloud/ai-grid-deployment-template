# Join the site to the grid

You add the site to the grid in the provider console. **Add to AI Grid** labels the site's ManagedCluster on the
hub with the role and location you choose, and the hub then installs OpenShift AI, MaaS, the grid and the tenant
settings in that role. Your `clusters.yaml` names no role or location: you choose them here. The `make` targets on
this page work on the only site in your `clusters.yaml`. With several sites, add the site's name, such as
`make site-status SITE=SITE_NAME`.

## Before you add the site

Two settings depend on the site and must be in your deployment repository before you add it. `make install`
([page 9](09-hands-off.md)) writes both for you. On this path, copy them from [`site-template/`](../../site-template/README.md)
to the same paths in your repository, replace its placeholders as its README says, then commit and push. The
commands here use `scripts/with-cluster.sh SITE_NAME`, which runs `oc` with the site's login from
`.config/SITE_NAME/kubeconfig`, not with your own kubeconfig.

- **A certificate for the MaaS gateway.** If the site has a cert-manager ClusterIssuer that issues publicly trusted
  certificates by DNS-01 (`scripts/with-cluster.sh SITE_NAME oc get clusterissuers`), and the site will be
  `ingress` or `combined`, copy `values/clusters/SITE/rhoai.yaml`, `sites/SITE/maas-tls/` and
  `apps/SITE-maas-tls.yaml`. Tenants' clients then trust the gateway. Without it, the gateway keeps the cluster's internal certificate
  ([MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/maas-certificate.md)).
- **The platform's cert-manager.** If the site already runs the cert-manager Operator for Red Hat OpenShift, copy
  `values/clusters/SITE/rhoai.yaml` and uncomment its three `dependencies` lines (without a certificate, leave out
  its `components:` part). Otherwise OpenShift AI adds a second OperatorGroup and OLM fails the operator with
  `TooManyOperatorGroups`. To check:

  ```sh
  scripts/with-cluster.sh SITE_NAME oc get operatorgroups -n cert-manager-operator
  ```

  An OperatorGroup named other than `openshift-cert-manager-operator` is the platform's. If you already added the
  site, see [A site that already runs cert-manager](#a-site-that-already-runs-cert-manager) instead.

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

## A site that already runs cert-manager

If you added a site that already runs the platform's cert-manager without turning off the chart's copy, its
cert-manager operator fails with `TooManyOperatorGroups`, and OpenShift AI waits on it. Argo CD has also taken over
the platform's namespace `cert-manager-operator` and its Subscription, which have the chart's names. If you turn off
the chart's copy now, Argo CD prunes both and removes the operator. Protect them first:

1. Annotate the namespace and the Subscription on the site:

   ```sh
   scripts/with-cluster.sh SITE_NAME oc annotate namespace cert-manager-operator \
     argocd.argoproj.io/sync-options=Prune=false
   scripts/with-cluster.sh SITE_NAME oc annotate subscriptions.operators.coreos.com openshift-cert-manager-operator \
     -n cert-manager-operator argocd.argoproj.io/sync-options=Prune=false
   ```

   This assumes the platform's Subscription has the chart's name, `openshift-cert-manager-operator`. If
   `scripts/with-cluster.sh SITE_NAME oc get subscriptions.operators.coreos.com -n cert-manager-operator` lists two,
   stop and ask your platform team which one to keep.

2. Turn off the chart's copy. If you installed with `make install` ([page 9](09-hands-off.md)), run it again.
   Otherwise, add the `dependencies` lines from [`site-template/`](../../site-template/README.md) to the site's
   `values/clusters/SITE/rhoai.yaml`, then commit and push.

Argo CD should then remove only the chart's OperatorGroup, and the operator recover. *(Unverified.)*

## Checkpoint

- The console shows the site with AI Grid status **Provisioned**.
- The site's DataScienceCluster is `Ready` and its GridSite `Available`.
- `make status` lists no hub Application as not `Synced` and `Healthy`.
- `make site-status` says the MaaS gateway answers (with the internal certificate, or `401` with your own).

Next: [7. First use](07-first-use.md)
