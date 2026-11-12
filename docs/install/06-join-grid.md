# Join the site to the grid

Labels on the site's ManagedCluster make it a grid site. The hub then installs OpenShift AI, MaaS, the grid and the
tenant settings in the site's role. These commands work on the only site in your `clusters.yaml`. With several sites,
give the site's name where a command says `site`, or add it after the script's name, such as
`scripts/join-site.sh SITE_NAME`.

## 1. Add the site's values

A site that runs the MaaS gateway (role `combined` or `ingress`) needs three files in your deployment repository
**before** you label it: its values, and a publicly trusted certificate for its MaaS hostname,
`maas.SITE_APPS_DOMAIN`. Without the values file, the site's `rhoai` Application doesn't render. Write them from
`site-template/`:

```sh
scripts/add-site.sh
```

It reads the site's apps domain, uses the site's DNS-01 ClusterIssuer, writes the three files, runs
`scripts/check-deployment.sh`, and prints the commands to commit and push them. If the site has several DNS-01
ClusterIssuers, it lists them: run it again with the one that issues publicly trusted certificates for the site's
apps domain, such as `scripts/add-site.sh site ISSUER_NAME`. It keeps files that already exist, and needs the
issuer only to write a missing one. An `inference` site needs no files.

You should see `root renders; every input is set; every repository is an input.` Then run the `git add`,
`git commit` and `git push` commands it printed. What the files do, and other ways to get the certificate:
[MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/spokes/maas-certificate.md).

## 2. Label the site

The site's labels on the hub make it a grid site, in the role and location from your `clusters.yaml`:

```sh
scripts/join-site.sh
```

It first checks that your commits are pushed, and waits until the hub's `deployment-root` has synced your latest
commit, up to 10 minutes, so the site's files are on the hub before its labels. If the site already has those
labels, it says `labels already set` and changes nothing. The console shows the location.
For `ingress` and `inference` sites, see [Sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/spokes/README.md#what-you-choose-per-site).

You should see `managedcluster.cluster.open-cluster-management.io/SITE labeled`. Within a minute the hub creates the
site's Applications:

```sh
scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops | grep -- "-$(scripts/clusters.sh --site)"
```

You should see `rhoai-SITE-…`, `cluster-config-SITE-…`, `acm-submariner-SITE`, `maas-db-SITE` and `SITE-maas-tls`.
OpenShift AI takes up to an hour on a new cluster, and less on one that ran OpenShift AI before.

## 3. Verify

1. Check the hub and the site:

   ```sh
   make status
   ```

   Run it again every few minutes until you see, under the site, `OpenShift AI (DataScienceCluster): Ready` and its
   GridSite `Available=True`, and on the hub no Application listed as not `Synced` and `Healthy`. If the phase flips between `Ready` and not, see
   [troubleshooting](troubleshooting.md#kserveready-flaps-false-on-a-site).

   The site's GridNetwork, in `oc get gridnetworks -A`, shows `SITES` `0`: that column counts SWIM peers, and the
   library's grid uses Local membership, which has none. Its `AVAILABLE` column is what to check.

2. The MaaS hostname answers with a trusted certificate:

   ```sh
   curl -sS -o /dev/null -w '%{http_code}\n' "https://maas.$(scripts/with-cluster.sh site oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')/v1/models"
   ```

   You should see `401` (no token yet) and no certificate error.

## Checkpoint

- The site's DataScienceCluster is `Ready` and its GridSite `Available`.
- `make status` lists no hub Application as not `Synced` and `Healthy`.
- `https://maas.SITE_APPS_DOMAIN` answers `401` over trusted TLS.

Next: [7. First use](07-first-use.md)
