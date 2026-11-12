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
apps domain, such as `scripts/add-site.sh site ISSUER_NAME`. An `inference` site needs no files.

You should see `root renders; every input is set; every repository is an input.` Then run the `git add`,
`git commit` and `git push` commands it printed. What the files do, and other ways to get the certificate:
[MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/spokes/maas-certificate.md).

## 2. Label the site

The site's labels on the hub make it a grid site, in the role and location from your `clusters.yaml`:

```sh
scripts/join-site.sh
```

The console shows the location. For `ingress` and `inference` sites, see [Sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/spokes/README.md#what-you-choose-per-site).

You should see `managedcluster.cluster.open-cluster-management.io/SITE labeled`. Within a minute the hub creates the
site's Applications:

```sh
scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops | grep -- "-$(scripts/clusters.sh --site)"
```

You should see `rhoai-SITE-…`, `cluster-config-SITE-…`, `acm-submariner-SITE`, `maas-db-SITE` and `SITE-maas-tls`.
OpenShift AI takes 45 to 60 minutes.

## 3. Verify

1. OpenShift AI is ready, and the site is in the grid:

   ```sh
   scripts/with-cluster.sh site oc get datasciencecluster -o jsonpath='{.items[0].status.phase}{"\n"}'
   scripts/with-cluster.sh site oc get gridnetworks,gridsites -A
   ```

   You should see `Ready`, the GridNetwork, and the site's GridSite `Available`. If the phase flips between `Ready`
   and not, see [troubleshooting](troubleshooting.md#kserveready-flaps-false-on-a-site).

2. Every hub Application is `Synced` and `Healthy`, including the three that waited for the first site:

   ```sh
   scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops \
     -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' \
     | grep -v ' Synced Healthy$'
   ```

   You should see no output.

3. The MaaS hostname answers with a trusted certificate:

   ```sh
   curl -sS -o /dev/null -w '%{http_code}\n' "https://maas.$APPS_DOMAIN/v1/models"
   ```

   You should see `401` (no token yet) and no certificate error.

## Checkpoint

- The site's DataScienceCluster is `Ready` and its GridSite `Available`.
- Every hub Application is `Synced` and `Healthy`.
- `https://maas.SITE_APPS_DOMAIN` answers `401` over trusted TLS.

Next: [7. First use](07-first-use.md)
