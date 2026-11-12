# Uninstall AI Grid

On this page you remove AI Grid from your clusters: each site first, then the hub. The uninstall returns each cluster
to how it was before you [prepared the hub](03-prepare-hub.md): OpenShift with your platform's own services. It
removes everything the install put there.

Each command reads your hub and sites from `clusters.yaml` and signs in with each cluster's login in
`.config/NAME/kubeconfig`, the same as the install. Sign in again to any cluster whose login has expired:

```sh
make login
```

The `make` targets on this page work on the only site in your `clusters.yaml`. With several sites, add the
site's name, such as `make uninstall-site SITE=SITE_NAME`.

The uninstall targets preview by default and delete nothing; `CONFIRM=1` runs them.

## What stays and what goes

| Cluster | After the uninstall | Removed |
|---|---|---|
| Hub | OpenShift; the platform's identity provider, cert-manager and certificate issuers | OpenShift GitOps, ACM and the multicluster engine, every component and your own apps, their operators and namespaces |
| Site | OpenShift; the platform's identity provider, cert-manager, NFD and GPU operator | OpenShift AI, MaaS, the grid, Submariner, the ACM agent, everything the hub's Applications applied, their operators and namespaces |

The uninstall leaves these on every cluster on purpose:

- **CustomResourceDefinitions.** A reinstall reuses them. Deleting a CRD deletes every object of its kind, including
  ones your platform owns.
- **The cluster pull secret's `quay.io/rhoai` and stage entries, and the image mirror.** A reinstall delivers the same
  again, and removing a mirror drains every node. Remove them by hand if you won't reinstall.
- **The OAuth configuration and ClusterIssuers.** The uninstall never edits them.
- **The protected namespaces and operators:** the namespaces `keycloak`, `cert-manager`, `cert-manager-operator`,
  `openshift-cert-manager-operator`, `openshift-nfd`, `nvidia-gpu-operator`, `openshift-config` and
  `openshift-authentication`, and the operator packages `rhbk-operator`, `openshift-cert-manager-operator`, `nfd` and
  `gpu-operator-certified`.
- **Your deployment and catalog repositories,** except that you empty the catalog in step 1.

The uninstall reads what to delete from Argo CD's own record of what it applied (each Application's
`status.resources`), so your own apps in `apps/` go too. Operators then remove what they created, because the
uninstall deletes their custom resources while they still run. What operators and add-ons leave outside that record
and outside the deleted namespaces (in `openshift-ingress`, `openshift-monitoring`, `kube-system` and cluster-wide:
RBAC, console entries, ACM's cluster claims and image sets) is listed in `scripts/uninstall-leftovers.tsv`, which each
step deletes last. If your own apps leave something behind, add a line for it there.

## Before you begin

- Sign in to each cluster as a user with `cluster-admin`. The script refuses a login that isn't, and a login whose
  `cluster-admin` comes only from a binding or group that the uninstall deletes, because you'd lose access partway.
- Make sure you can still sign in after the uninstall. The script warns you which identity providers your cluster's
  sign-in uses. It never edits OAuth, but it deletes whatever isn't protected: if an identity provider's server runs
  on the cluster outside the protected namespaces, protect it before you start. Set its namespaces in
  `WIPE_PROTECT_NAMESPACES` and its operator packages in `WIPE_PROTECT_PACKAGES`, space-separated, for every command
  on this page:

  ```sh
  export WIPE_PROTECT_NAMESPACES="my-idp" WIPE_PROTECT_PACKAGES="my-idp-operator"
  ```

  Replace `my-idp` and `my-idp-operator` with your identity provider's namespace and operator package.

## 1. Empty the catalog

So a reinstall starts with no models or subscriptions, remove them from your catalog repository. In the provider
console, delete each subscription, then each model
([remove a subscription, model or organization](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/operate.md#remove-a-subscription-model-or-organization)).
Or empty it in git:

```sh
git clone CATALOG_REPO_URL catalog && cd catalog
git rm -r -q -- $(git ls-files | grep -vx README.md)
git commit -m "catalog: empty for uninstall" && git push origin HEAD:main && cd ..
```

Replace `CATALOG_REPO_URL` with your catalog repository's clone URL.

Within a few minutes the hub deletes the catalog's Applications, and with them the subscriptions, auth policies and
MaaS model entries, so no access outlives them. The models themselves keep running: the models ApplicationSet keeps
its resources when a site's folder goes. The site step deletes them first, while KServe still runs.

## 2. Preview each step

Preview a site's uninstall. It deletes nothing:

```sh
make uninstall-site
```

The output starts with the checks, then lists every step and every object it would delete, in order:

```none
== checks
hub: signed in as USER, cluster-admin.
SITE: signed in as USER, cluster-admin.
warning: SITE signs in through: IDP_NAMES. ...
...
== done (dry run: nothing deleted)
```

Read the list. Nothing protected may be in it, and objects the script keeps because they're protected show as
`kept (protected namespace)` or `kept (protected package)`. If your platform's own services are in the delete list,
protect them as in [before you begin](#before-you-begin), and preview again.

Preview the hub the same way:

```sh
make uninstall-hub
```

Until every site is uninstalled, the hub's preview warns `sites are still managed`.

The script refuses, and deletes nothing, in these cases:

- A login's API server isn't the cluster's `api` in `clusters.yaml`. Run `make login NAME=NAME` against the right
  cluster.
- A login isn't `cluster-admin`, or is only through objects the uninstall deletes.
- The site's ACM agent says it's a different cluster.
- The site is `local-cluster`: a hub that is also a site isn't supported yet.

## 3. Uninstall each site

For each site, run the site step:

```sh
make uninstall-site CONFIRM=1
```

It saves its plan in `.uninstall/SITE-plan.tsv`, because the plan comes from the site's Applications on the hub,
which the first steps remove. If the run stops partway, run the same command again to resume from that plan.

The site step does the following:

1. Removes the site's `ai-grid/enabled` and `ai-grid/role` labels, and waits for its Applications to go.
2. Removes the site's Submariner add-on, detaches the site from ACM, deletes the Argo CD cluster Secret and grid
   identity that the detach leaves on the hub, and waits for ACM to remove the site's agent.
3. Runs `scripts/wipe-site.sh`, which deletes from the site, in order: models while KServe runs; MaaS objects,
   including `MaaSTenantConfig` and `AITenant`, before the DataScienceCluster; the DataScienceCluster and its
   components; the grid's `GridNetwork` and `GridSite`; the AI Grid gateways and their EnvoyFilters; the operators;
   their leftover webhooks; their namespaces.
4. Deletes everything else the hub's Applications applied to the site.
5. Deletes the ACM `Klusterlet`, then the namespaces that Argo CD's record doesn't list: the ACM agent's and policy
   namespaces, the site's own policy namespace, Submariner's, and the operator-created `ai-tenants` and
   `redhat-ai-gateway-infra`, each only if it's still there.
6. Deletes webhooks left pointing at deleted namespaces, the leftovers in `scripts/uninstall-leftovers.tsv`, and
   console plugins whose backend is gone.
7. Checks that your login still works and is `cluster-admin`.

A site takes about 15 minutes, most of it removing the DataScienceCluster and the operators. The output ends with
`== done`.

## 4. Uninstall the hub

After every site is uninstalled, run the hub step:

```sh
make uninstall-hub CONFIRM=1
```

As with a site, if the run stops partway, run the same command again; its plan is in `.uninstall/hub-plan.tsv`.
It refuses while any site is still managed.

The hub step does the following:

1. Stops Argo CD: deletes the ApplicationSets without cascading, then removes each Application's finalizer and
   deletes it. Deleting the root alone would delete nothing, because the root keeps its resources when it's removed.
2. Deletes, in order: the hub's ACM Policies and Placements; custom resources while their operators run (databases,
   ExternalSecrets, S4); MultiClusterObservability, then MultiClusterHub, then the multicluster engine; other objects;
   cluster-scoped objects; operator subscriptions with their CSVs; namespaces.
3. Deletes ACM's documented leftovers (admission APIServices and webhooks), then the namespaces that ACM's add-ons,
   the multicluster engine and the operators leave outside Argo CD's record, such as `default-broker`,
   `submariner-operator`, `external-secrets`, `hive` and `local-cluster`, each only if it's still there.
4. Deletes OpenShift GitOps last. It first tells the operator to stop recreating its default Argo CD instance
   (`DISABLE_DEFAULT_ARGOCD_INSTANCE`), so the operator removes the instance itself.
5. Deletes webhook configurations whose services all lived in deleted namespaces, because they'd reject a reinstall's
   writes; then the leftovers in `scripts/uninstall-leftovers.tsv` and dangling console plugins.
6. Checks that your login still works and is `cluster-admin`.

A hub takes about 25 minutes, most of it removing MultiClusterHub, the multicluster engine and OpenShift GitOps.

## 5. Verify

Check each cluster's Argo CD Application kind, the install's namespaces and your sign-in:

```sh
make uninstall-check
```

For each cluster you should see `Argo CD Application kind: gone`, `Install namespaces left: none`, and your platform's
identity providers. Then sign in once to the cluster's web console.

To reinstall, start again at [set up your deployment repository](02-repositories.md), with the same or new
repositories.

## Checkpoint

- Every site's and the hub's uninstall ended with `== done`.
- No cluster has the Argo CD Application kind or a namespace from the list in [verify](#5-verify).
- You can sign in to each cluster's web console.
