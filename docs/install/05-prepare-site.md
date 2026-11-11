# Prepare each site and join it to ACM

Repeat this page for every site. Set these in your shell first:

```sh
export HUB_CONTEXT=HUB_CONTEXT_NAME SITE_CONTEXT=SITE_CONTEXT_NAME SITE=SITE_NAME
```

Replace the following:

- `HUB_CONTEXT_NAME`, `SITE_CONTEXT_NAME`: the kubeconfig contexts of the hub and the site, both in one `KUBECONFIG`.
- `SITE_NAME`: the site's ACM cluster name, a stable DNS-1123 name such as `site-east-1`. You use it in labels, values
  file paths and the console.

## 1. Choose the site's role

| Role | Installs | Needs |
|---|---|---|
| `ingress` | OpenShift AI with MaaS, the Org UI, the grid consumer gateway, a MaaS database replica. Tenants enter here. No models. | A MaaS hostname and certificate ([join each site to the grid](06-join-grid.md#1-add-the-sites-values)), a load balancer *(Unverified.)* |
| `inference` | OpenShift AI without MaaS, the grid provider gateway, the models. Reached only by ingress sites, over mTLS. | Capacity, GPUs for GPU models *(Unverified.)* |
| `combined` | Both on one cluster. | Both |

The smallest grid is one combined site. A typical grid is one ingress site plus inference sites. See
[OpenShift AI with MaaS](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/spokes/openshift-ai.md#openshift-ai-with-maas).

## 2. Add a break-glass admin

If the site's only sign-in is an external identity provider, add the htpasswd admin, as on the hub
([prepare the hub](03-prepare-hub.md#1-add-a-break-glass-admin)):

```sh
oc config use-context "$SITE_CONTEXT"
../library/scripts/add-htpasswd-admin.sh --kubeconfig SITE_KUBECONFIG --password-file SITE_ADMIN_PASSWORD_FILE
```

Sign in once as `admin` with the `htpasswd` provider to confirm it.

## 3. If the cluster ran AI Grid before, wipe it

A cluster that was a site of another hub must leave that hub first, then lose its old install.

1. On the old hub, remove the site's labels and wait for its Applications to go, then delete its ManagedCluster.
   Delete its Argo CD cluster Secret and grid identity Secret if they stay behind.
2. Preview the wipe with the library's script:

   ```sh
   ../library/scripts/wipe-site.sh --kubeconfig SITE_KUBECONFIG --dry-run
   ```

   Read the list. It must not name your platform's identity provider, cert-manager, NFD, the GPU operator or your
   ACME ClusterIssuers; the script protects those by name. If your platform uses other names, add them, space-separated,
   in `WIPE_PROTECT_NAMESPACES` and `WIPE_PROTECT_PACKAGES` (operator package names) before both runs.

3. Run it without `--dry-run`. It removes models, MaaS objects, the DataScienceCluster, the grid, the gateways, their
   operators and leftover webhooks, in that order, and leaves the cluster pull secret and image mirror (removing a
   mirror drains every node, and the new hub delivers the same mirror again).

You should end with no DataScienceCluster, GridNetwork, GridSite or LLMInferenceService, and no `Terminating`
namespaces:

```sh
oc --context "$SITE_CONTEXT" get datasciencecluster,gridnetworks,gridsites,llminferenceservices -A
oc --context "$SITE_CONTEXT" get ns | grep Terminating
```

## 4. Check the site's infrastructure

```sh
bash ../library/scripts/check-prerequisites.sh --step spoke --context "$SITE_CONTEXT"
```

You should see `OK` for `OpenShift 4.21 or later` and `default StorageClass`. The hub delivers the rest: the
`quay.io/rhoai` pull secret and image mirror arrive by Policy once the site is imported, without draining or rebooting the nodes
([OpenShift AI prerequisites](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)).

Also check, for every role:

- Two worker nodes can run Submariner gateways, and the site can open a LoadBalancer Service for them, with UDP 4500 and
  4490 allowed ([Submariner](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/01-acm.md#submariner)). `cluster-config` labels the gateway nodes, except on compact
  clusters and single-node OpenShift.
- `dig AAAA router-default.apps.CLUSTER_DOMAIN` doesn't return `NXDOMAIN`.
- On inference and combined sites with GPUs: see [GPU operator and NFD](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/spokes/openshift-ai.md#nvidia-gpu-operator-and-node-feature-discovery).

## 5. Import the site into ACM

The library's import script runs `clusteradm` against both clusters. It prints a summary and changes nothing without
`--yes`:

```sh
HUB_CONTEXT="$HUB_CONTEXT" bash ../library/docs/acm/cluster-onboarding/import-managed-cluster.sh \
  --spoke-context "$SITE_CONTEXT" --cluster-name "$SITE"
```

Read the summary, then run the same command with `--yes` added.

The site joins ACM's `global` ClusterSet, and `argo-registration` registers it with the hub's Argo CD. Nothing AI Grid
installs yet: that waits for the labels you add when you [join it to the grid](06-join-grid.md).

## 6. Check the import

```sh
oc --context "$HUB_CONTEXT" get managedcluster "$SITE"
oc --context "$HUB_CONTEXT" get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster | grep "$SITE"
```

You should see the ManagedCluster with `JOINED` and `AVAILABLE` both `True`, and an Argo CD cluster Secret for the
site. On the tested site both appeared within a few minutes.

## Checkpoint

- The site's ManagedCluster is joined and available.
- Its Argo CD cluster Secret exists on the hub.
- You can sign in to the site as the break-glass admin.
