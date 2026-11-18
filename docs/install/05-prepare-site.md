# Prepare the site and join it to ACM

On this page you check the site and import it into ACM. The site's name in `clusters.yaml` becomes its ACM cluster
name. The `make` targets on this page work on the only site in your `clusters.yaml`. With several sites, add the
site's name, such as `make site-import SITE=SITE_NAME`.

If the cluster was a site of another hub, first [reuse it](#reuse-a-cluster-from-another-hub).

## Reuse a cluster from another hub

Let the site check tell you whether you need this section:

```sh
make site-check
```

If its `previous AI Grid install` line is `OK` (`none`, `leftover CRDs only; safe`, or `already a site of this hub`
when you rerun it after the import), skip to part 1. If it's
`FOUND`, it names what it found, such as a klusterlet (another hub manages the cluster) or a DataScienceCluster;
follow these steps first:

1. On the old hub, remove the site's labels, wait for its Applications to go, then delete its ManagedCluster. Delete
   its Argo CD cluster Secret and grid identity Secret (`redhat-ai-grid/grid-site-SITE`) if they stay behind.
2. Preview the wipe of the old install. It deletes nothing:

   ```sh
   make site-wipe
   ```

   Read the list. It must not name your platform's identity provider, cert-manager, NFD, the GPU operator or your
   ACME ClusterIssuers; the script protects those by name. If your platform uses other names, set them,
   space-separated, in `WIPE_PROTECT_NAMESPACES` and `WIPE_PROTECT_PACKAGES` (operator package names) for both runs.
3. Run the wipe. It leaves the cluster pull secret and image mirror, which the new hub delivers again:

   ```sh
   make site-wipe CONFIRM=1
   ```

Then run `make site-check` again. Its `previous AI Grid install` line should be `OK`.

## 1. Check the site's infrastructure

```sh
make site-check
```

You should see `OK` for `OpenShift 4.21 or later`, `default StorageClass`, `previous AI Grid install`,
`apps domain DNS` and `Submariner gateway nodes`. The last one says which nodes the import labels, or `already
labelled`. If it's `MISSING`, the site has too few workers outside the control plane, as on a compact cluster or
single-node OpenShift: run the `oc label node` command it prints with the site's login, then check again. The hub
delivers the registry logins and image mirror once the site is imported. For what a site must provide, such as GPU
nodes and the NVIDIA GPU Operator for GPU models, see the library's
[site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide).

If the check prints `FOUND` for a `cert-manager OperatorGroup`, the site already runs the platform's cert-manager
Operator, and it can't join the grid yet. On the library's `main` branch, a site's OpenShift AI values come only from
the library, so the OpenShift AI chart installs cert-manager with its own OperatorGroup next to yours. OLM then fails
the cert-manager Operator with `TooManyOperatorGroups`. Use another cluster until the library fixes this
([limits of `main`](../upstream-main-limits.md#l4-sites-that-need-per-site-values)).
For the same reason, you can't set a site's GPU settings, such as its NFD and `ClusterPolicy` values, from your
deployment repository.

## 2. Import the site into ACM

Preview the import. It prints a summary of what the library's import script will do, and changes nothing:

```sh
make site-import
```

In the summary, check that `Hub API server` is your hub's API URL and `Cluster name` is your site's name, and see
whether `Action` is `new import` or `resume registration`.

Import the site. This first labels two of the site's worker nodes `submariner.io/gateway=true` for Submariner's
gateways, preferring nodes without GPUs, because nothing in the library labels them
([limits of `main`, L21](../upstream-main-limits.md#l21-nothing-labels-the-submariner-gateway-nodes)). Then it runs
the library's import script, which runs `clusteradm` against both clusters:

```sh
make site-import CONFIRM=1
```

Run again for a site that's already joined and available, it says `already imported; nothing to do`.

The site joins ACM, and the hub's Argo CD registers it. The hub then prepares the site: it creates empty namespaces
for OpenShift AI and the grid, delivers the registry logins and starts Submariner on the gateway nodes the import
labelled. OpenShift AI and the grid wait until you add the site to the grid on the next page.

The import ends with `Import complete.` once the ManagedCluster has joined and the hub's Argo CD has its cluster
Secret for the site; the script waits for both.

To check the site again later:

```sh
make site-status
```

You should see `ManagedCluster: JOINED=True AVAILABLE=True`.

## Checkpoint

- The import printed `Import complete.`

Next: [6. Join the site to the grid](06-join-grid.md)
