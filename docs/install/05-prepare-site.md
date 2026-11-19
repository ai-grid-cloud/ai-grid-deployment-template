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

1. Detach the site from its old hub.
   - If you can still sign in to the old hub, detach the site there: remove the site's labels, wait for its
     Applications to go, then delete its ManagedCluster. Delete its Argo CD cluster Secret and grid identity Secret
     (`redhat-ai-grid/grid-site-SITE`) if they stay behind.
   - If the old hub is gone, detach the site on the site itself. Preview the detach; it deletes nothing:

     ```sh
     make site-detach
     ```

     Then run it:

     ```sh
     make site-detach CONFIRM=1
     ```

     It deletes the site's ACM `Klusterlet`, waits up to 10 minutes for the klusterlet operator to remove the
     namespaces `open-cluster-management-agent` and `open-cluster-management-agent-addon`, then deletes the old
     hub's `AppliedManifestWork` records. Left in place, those records co-own objects with the new hub's, so the new
     hub could never remove the old add-ons. The output ends with `Detached:`. If it stops with `still present`, check
     that the klusterlet operator's pod runs (`oc get pods -n open-cluster-management`), then run it again. It refuses
     a site that is still a ManagedCluster on your hub (use `make uninstall-site` for that), and stops if your hub's
     login doesn't work, because it can't check that.
2. Preview the wipe of the old install. It deletes nothing:

   ```sh
   make site-wipe
   ```

   Read the list. It must not name your platform's identity provider, cert-manager, NFD, the GPU operator or your
   ACME ClusterIssuers; the script protects those by name. If your platform uses other names, set them,
   space-separated, in `WIPE_PROTECT_NAMESPACES` and `WIPE_PROTECT_PACKAGES` (operator package names) for both runs.
   Besides OpenShift AI, MaaS and the grid, the list includes the stateful leftovers that a new hub only adds to and
   never replaces:

   - The old hub's klusterlet operator: Deployment `klusterlet`, its lease `klusterlet-lock` and its namespace
     `open-cluster-management`. Left running, that operator can delay a new import until it times out.
   - Submariner: its `Submariner` and `ServiceDiscovery` objects, removed while its operator runs so that it
     uninstalls the gateway, route agent and Globalnet from the nodes; every other `submariner.io` object, such as
     Globalnet's egress and ingress IPs; its operator; the namespace `submariner-operator`; and last, the
     `submariner.io/gateway` node labels. Left in place, the old Globalnet keeps its old global IPs after the new hub's
     broker assigns another range, and the tunnel fails one way. `make site-import` labels two workers again. On a
     compact cluster or single-node OpenShift, label two nodes by hand again: `make site-check` prints the command.
   - The MaaS database read replica: the CloudNativePG `Cluster` `maas-read`, its volumes and the namespace `maas-db`.
     Left in place, it keeps replicating the old hub's database, and `maas-api` fails to sign in to it. The wipe
     refuses if `maas-db` holds a database that isn't a read replica, because only a hub runs the primary.
   - The Argo CD tracking label `app.kubernetes.io/instance` and annotation `argocd.argoproj.io/tracking-id` on your
     `ClusterPolicy`, `NodeFeatureDiscovery` and `ClusterIssuer` objects, when an earlier install created them. The
     wipe changes nothing else on those objects, and keeps the tracking when it names an Argo CD Application on the
     site itself, which means your platform's own Argo CD manages the object. Left in place, an old install's tracking
     makes the new hub's Application of the same name take the objects for its own and delete them.
3. Run the wipe. It leaves the cluster pull secret and image mirror, which the new hub delivers again:

   ```sh
   make site-wipe CONFIRM=1
   ```

Then run `make site-check` again. Its `previous AI Grid install` line should be `OK`.

## 1. Check the site's infrastructure

On the library's `main` branch, your platform sets up a GPU site's GPU stack before the import: Node Feature
Discovery with a `NodeFeatureDiscovery`, and the NVIDIA GPU Operator with a `ClusterPolicy`. The library doesn't
install them.

```sh
make site-check
```

You should see `OK` for `OpenShift 4.21 or later`, `default StorageClass`, `previous AI Grid install`,
`apps domain DNS` and `Submariner gateway nodes`. The last one says which nodes the import labels, or `already
labelled`. If it's `MISSING`, the site has too few workers outside the control plane, as on a compact cluster or
single-node OpenShift: run the `oc label node` command it prints with the site's login, then check again. A `WARN`
for `GPU stack` means the site has GPU nodes without a `ClusterPolicy` or a `NodeFeatureDiscovery`: set those up
before you deploy GPU models there. The hub delivers the registry logins and image mirror once the site is imported.
For what a site must provide, such as GPU nodes and the NVIDIA GPU Operator for GPU models, see the library's
[site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide).

If the check prints `FOUND` for a `cert-manager OperatorGroup`, the site already runs the platform's cert-manager
Operator, and it can't join the grid yet. On the library's `main` branch, a site's OpenShift AI values come only from
the library, so the OpenShift AI chart installs cert-manager with its own OperatorGroup next to yours. OLM then fails
the cert-manager Operator with `TooManyOperatorGroups`. Use another cluster until the library fixes this
([limits of `main`](../upstream-main-limits.md#l4-sites-that-need-per-site-values)).
For the same reason, you can't set a site's GPU settings, such as its NFD and `ClusterPolicy` values, from your
deployment repository.

A `WARN` for the `cert-manager OperatorGroup` means one named `openshift-cert-manager-operator` that another hub's OpenShift AI
Application created: expected on a site that joined an earlier grid, but the platform's if this site never joined one
([how the check decides](../upstream-main-limits.md#l17-the-hubs-cert-manager-is-the-librarys-or-the-platforms-not-both)).

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
