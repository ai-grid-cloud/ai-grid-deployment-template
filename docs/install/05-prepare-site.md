# Prepare the site and join it to ACM

On this page you check the site and import it into ACM. Set these first:

```sh
export SITE_CONTEXT=SITE_CONTEXT_NAME SITE_KUBECONFIG=SITE_KUBECONFIG_FILE SITE=SITE_NAME
```

Replace the following:

- `SITE_CONTEXT_NAME`: the site's kubeconfig context, in the same `KUBECONFIG` as the hub's.
- `SITE_KUBECONFIG_FILE`: a kubeconfig file whose current context is the site.
- `SITE_NAME`: the site's ACM cluster name, a stable DNS-1123 name such as `site-east-1`.

If the cluster was a site of another hub, first [reuse it](#reuse-a-cluster-from-another-hub).

## Reuse a cluster from another hub

Skip this section for a cluster that was never an AI Grid site.

1. On the old hub, remove the site's labels, wait for its Applications to go, then delete its ManagedCluster. Delete
   its Argo CD cluster Secret and grid identity Secret (`redhat-ai-grid/grid-site-SITE`) if they stay behind.
2. Preview the wipe of the old install:

   ```sh
   ../library/scripts/wipe-site.sh --kubeconfig "$SITE_KUBECONFIG" --dry-run
   ```

   Read the list. It must not name your platform's identity provider, cert-manager, NFD, the GPU operator or your
   ACME ClusterIssuers; the script protects those by name. If your platform uses other names, set them,
   space-separated, in `WIPE_PROTECT_NAMESPACES` and `WIPE_PROTECT_PACKAGES` (operator package names) for both runs.
3. Run the same command without `--dry-run`. It leaves the cluster pull secret and image mirror, which the new hub
   delivers again.

You should then see no DataScienceCluster, GridNetwork, GridSite or LLMInferenceService:

```sh
oc --context "$SITE_CONTEXT" get datasciencecluster,gridnetworks,gridsites,llminferenceservices -A
```

## 1. Add a break-glass admin

```sh
oc config use-context "$SITE_CONTEXT"
../library/scripts/add-htpasswd-admin.sh --kubeconfig "$SITE_KUBECONFIG" --password-file SITE_ADMIN_PASSWORD_FILE
```

Replace `SITE_ADMIN_PASSWORD_FILE` with a path outside any repository. Sign in once as `admin` with the `htpasswd`
provider to confirm it.

## 2. Check the site's infrastructure

```sh
bash ../library/scripts/check-prerequisites.sh --step spoke --context "$SITE_CONTEXT"
dig AAAA router-default.$(oc --context "$SITE_CONTEXT" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
```

You should see `OK` for `OpenShift 4.21 or later` and `default StorageClass`, and a `dig` status other than
`NXDOMAIN`. The hub delivers the registry logins and image mirror once the site is imported. For GPU sites, see
[GPU operator and NFD](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f0449f154708ee9ba2eac50a1a921d8c5718dd9b/docs/install/spokes/openshift-ai.md#nvidia-gpu-operator-and-node-feature-discovery).

## 3. Import the site into ACM

The library's import script runs `clusteradm` against both clusters. It prints a summary and changes nothing without
`--yes`:

```sh
HUB_CONTEXT="$HUB_CONTEXT" bash ../library/docs/acm/cluster-onboarding/import-managed-cluster.sh \
  --spoke-context "$SITE_CONTEXT" --cluster-name "$SITE"
```

Read the summary, then run the same command with `--yes` added.

The site joins ACM, and the hub's Argo CD registers it. Nothing AI Grid installs yet: that waits for the labels you
add on the next page.

## 4. Check the import

```sh
oc --context "$HUB_CONTEXT" get managedcluster "$SITE"
oc --context "$HUB_CONTEXT" get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster | grep "$SITE"
```

You should see the ManagedCluster with `JOINED` and `AVAILABLE` both `True`, and an Argo CD cluster Secret for the
site, within a few minutes.

## Checkpoint

- The site's ManagedCluster is joined and available, and its Argo CD cluster Secret exists on the hub.
- You can sign in to the site as the break-glass admin.
