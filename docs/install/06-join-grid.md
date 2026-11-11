# Join the site to the grid

Labels on the site's ManagedCluster make it a grid site. The hub then installs OpenShift AI, MaaS, the grid and the
tenant settings in the site's role. Use the shell variables from [prepare the site](05-prepare-site.md).

## 1. Add the site's values

A site that runs the MaaS gateway (role `combined` or `ingress`) needs three files in your deployment repository
**before** you label it: its values, and a publicly trusted certificate for its MaaS hostname,
`maas.SITE_APPS_DOMAIN`. Without the values file, the site's `rhoai` Application doesn't render. `site-template/`
holds the three files; copy them for your site:

```sh
APPS_DOMAIN=$(oc --context "$SITE_CONTEXT" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
DNS01_ISSUER=ISSUER_NAME
for f in apps/SITE-maas-tls.yaml sites/SITE/maas-tls/certificate.yaml values/clusters/SITE/rhoai.yaml; do
  mkdir -p "$(dirname "${f//SITE/$SITE}")"
  sed -e "s/SITE/$SITE/g" -e "s/APPS_DOMAIN/$APPS_DOMAIN/g" -e "s/DNS01_ISSUER/$DNS01_ISSUER/g" \
    "site-template/$f" > "${f//SITE/$SITE}"
done
../library/scripts/check-deployment.sh .
git add -A && git commit -m "site $SITE: values and MaaS certificate" && git push origin HEAD:main
```

Replace `ISSUER_NAME` with your DNS-01 ClusterIssuer on the site. You should see `root renders; every input is set;
every repository is an input.` before the commit. What the files do, and other ways to get the certificate:
[MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/spokes/maas-certificate.md).

## 2. Label the site

```sh
oc --context "$HUB_CONTEXT" label managedcluster "$SITE" ai-grid/enabled=true ai-grid/role=combined location=LOCATION
```

Replace `LOCATION` with a label for where the site is, such as `us-east`. The console shows it. For `ingress` and
`inference` sites, see [Sites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/spokes/README.md#what-you-choose-per-site).

You should see `managedcluster.cluster.open-cluster-management.io/SITE labeled`. Within a minute the hub creates the
site's Applications:

```sh
oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops | grep -- "-$SITE"
```

You should see `rhoai-SITE-…`, `cluster-config-SITE-…`, `acm-submariner-SITE`, `maas-db-SITE` and `SITE-maas-tls`.
OpenShift AI takes 45 to 60 minutes.

## 3. Verify

1. OpenShift AI is ready, and the site is in the grid:

   ```sh
   oc --context "$SITE_CONTEXT" get datasciencecluster -o jsonpath='{.items[0].status.phase}{"\n"}'
   oc --context "$SITE_CONTEXT" get gridnetworks,gridsites -A
   ```

   You should see `Ready`, the GridNetwork, and the site's GridSite `Available`. If the phase flips between `Ready`
   and not, see [troubleshooting](troubleshooting.md#kserveready-flaps-false-on-a-site).

2. Every hub Application is `Synced` and `Healthy`, including the three that waited for the first site:

   ```sh
   oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops \
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
