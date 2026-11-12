# Prepare the site and join it to ACM

On this page you check the site and import it into ACM. Set the site's name from your clusters file first:

```sh
export SITE=SITE_NAME
```

Replace `SITE_NAME` with the site's name in `clusters`, such as `site-east-1`. It becomes the site's ACM cluster name.

If the cluster was a site of another hub, first [reuse it](#reuse-a-cluster-from-another-hub).

## Reuse a cluster from another hub

Skip this section for a cluster that was never an AI Grid site.

1. On the old hub, remove the site's labels, wait for its Applications to go, then delete its ManagedCluster. Delete
   its Argo CD cluster Secret and grid identity Secret (`redhat-ai-grid/grid-site-SITE`) if they stay behind.
2. Preview the wipe of the old install:

   ```sh
   scripts/wipe-site.sh --kubeconfig ".config/$SITE/kubeconfig" --dry-run
   ```

   Read the list. It must not name your platform's identity provider, cert-manager, NFD, the GPU operator or your
   ACME ClusterIssuers; the script protects those by name. If your platform uses other names, set them,
   space-separated, in `WIPE_PROTECT_NAMESPACES` and `WIPE_PROTECT_PACKAGES` (operator package names) for both runs.
3. Run the same command without `--dry-run`. It leaves the cluster pull secret and image mirror, which the new hub
   delivers again.

You should then see no DataScienceCluster, GridNetwork, GridSite or LLMInferenceService:

```sh
scripts/with-cluster.sh "$SITE" oc get datasciencecluster,gridnetworks,gridsites,llminferenceservices -A
```

## 1. Check the site's infrastructure

```sh
scripts/check-prerequisites.sh --step spoke --cluster "$SITE"
dig AAAA router-default.$(scripts/with-cluster.sh "$SITE" oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
```

You should see `OK` for `OpenShift 4.21 or later` and `default StorageClass`, and a `dig` status other than
`NXDOMAIN`. The hub delivers the registry logins and image mirror once the site is imported. For GPU sites, see
[GPU operator and NFD](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/8a3eaabb96cdf73649aeb484c130541c7e825fb5/docs/install/spokes/openshift-ai.md#nvidia-gpu-operator-and-node-feature-discovery).

## 2. Import the site into ACM

`scripts/import-site.sh` runs the library's import script, which runs `clusteradm` against both clusters. It prints a
summary and changes nothing without `--yes`:

```sh
scripts/import-site.sh "$SITE"
```

Read the summary, then run the same command with `--yes` added.

The site joins ACM, and the hub's Argo CD registers it. Nothing AI Grid installs yet: that waits for the labels you
add on the next page.

## 3. Check the import

```sh
scripts/with-cluster.sh hub oc get managedcluster "$SITE"
scripts/with-cluster.sh hub oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster | grep "$SITE"
```

You should see the ManagedCluster with `JOINED` and `AVAILABLE` both `True`, and an Argo CD cluster Secret for the
site, within a few minutes.

## Checkpoint

- The site's ManagedCluster is joined and available, and its Argo CD cluster Secret exists on the hub.
