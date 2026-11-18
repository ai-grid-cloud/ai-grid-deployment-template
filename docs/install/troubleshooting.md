# Troubleshooting

Problems you can hit while following this guide. Each entry gives the symptom, the cause and the fix. For what the
library's `main` branch can't do yet, see [the limits of `main`](../upstream-main-limits.md). For the library's own
reference, see its [getting started](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/README.md) page.

## The deployment check reports `unset inputs` or `placeholders left in your files`

**Cause:** an input in `root/inputs.env` is empty, or a value in another file is still a `REQUIRED-NAME` placeholder.

**Fix:** set each one it names ([set your names](02-repositories.md#4-set-your-names)), and run the check again.

## `make install` stops with `clusters.yaml has no site`

**Symptom:** `make install` stops before it reads or writes any cluster with the following error:

```text
error: clusters.yaml has no site: a hub needs at least one site; all-in-one isn't supported (docs/upstream-main-limits.md L18)
```

With `sites:` empty, `make site-status`, `make tenant-call` and the ready check report the same error, and
`make status` says to add a site.

**Cause:** `sites:` in `.config/clusters.yaml` lists no site. The supported minimum is a hub and one site on two
clusters. A hub that is also a site (all-in-one) isn't supported, so no script uses the hub as a site
([limits of `main`, L18](../upstream-main-limits.md#l18-all-in-one-unsupported)).

**Fix:** add at least one site under `sites:`, then run `make install` again. To install the hub before you have a
site, run `make install HUB_ONLY=1`, which accepts `sites: []`.

## A script stops because `clusters.yaml` uses the old format

**Cause:** your `clusters.yaml` or `.config/clusters.yaml` was written for an earlier version of the template. It has
`credentials:`, `repositories:`, `github:`, a `kubeconfig` key, a `name` on the hub, or a `role` or `location` on a
site.

**Fix:** change the file as the message says, then run the command again:

- Remove each site's `role` and `location`. You choose them in the provider console when you click **Add to AI Grid**
  ([join the site to the grid](06-join-grid.md)).
- Remove the hub's `name`: the hub is always `hub`.
- Move `repositories.catalog` to `catalog.url`, and `repositories.library`, if you set it, to `LIBRARY` under
  `options:`. Then remove `repositories:`.
- In `.config/clusters.yaml`, move `github.catalogToken` to `catalog.token`, and `github.deploymentToken`, if you set
  it, to `deployment.token`. Then remove `github:`.
- In `.config/clusters.yaml`, move each cluster's `token`, or `username` and `password`, from `credentials:` into
  `hub:` or into that site's entry under `sites:`, then remove `credentials:`. For a kubeconfig, copy it to
  `.config/NAME/kubeconfig` instead.

## A tenant can't sign in to the portal on a newly added site

**Symptom:** the Org UI's sign-in on an `ingress` or `combined` site fails with an invalid redirect URI.

**Cause:** the library's Keycloak registers a site's portal redirect, `https://maas.SITE_APPS_DOMAIN/oauth2/callback`,
with its CronJob `keycloak-redirect-uris`, which runs every five minutes. It registers only sites in the grid as
`ingress` or `combined`.

**Fix:** wait five minutes after you add the site to the grid, then sign in again. If it still fails, check the
CronJob's last Job:

```sh
scripts/with-cluster.sh hub oc get jobs -n maas-db
```

## Example organizations are missing after switching `keycloakOverlay` to `default`

**Symptom:** you installed the hub with `keycloakOverlay=core`, then set `default` and pushed. The example realms
`grid-tenant-1-idp` and `grid-tenant-2-idp` exist, but the provider console doesn't list the organizations
`grid-tenant-1` and `grid-tenant-2`, and creating them in the console fails with `409` on the identity provider's
alias.

**Cause:** the library's Keycloak imports each realm only when it doesn't exist: the Keycloak container runs
`kc.sh import --override false` before `kc.sh start`. Realm `saas` already existed, so it kept its `core` content.
The PostSync realm sync then added the example identity providers to it, but it never creates organizations
([Realm imports and Git edits](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/apps/keycloak/README.md#realm-imports-and-git-edits)).

**Fix:** re-import realm `saas`. This deletes everything in it: the organizations you created in the console, their
identity provider links, brokered users and their sessions. Tenants sign in again afterward, and you create your own
organizations again. The example organizations keep their IDs, which the realm file sets.

Do this only on a test deployment. First delete, in the console, the subscriptions of every organization you created:
re-created organizations get new IDs, and subscriptions that name the old ones stay in your catalog repository. API
keys that tenants already have aren't revoked; delete them in the tenant portal if you need to.

Run each command from your deployment repository. `scripts/with-cluster.sh hub` runs it with the hub's login.

1. Check that `keycloakOverlay=default` is pushed and that the `keycloak` Application is `Synced` and `Healthy`, so
   the realm files in ConfigMap `keycloak-realm-import` include the examples:

   ```sh
   scripts/with-cluster.sh hub oc get applications.argoproj.io keycloak -n openshift-gitops
   ```

2. Delete realm `saas`. The command signs in as Keycloak's bootstrap admin, whose username and password the
   Keycloak container reads from Secret `keycloak-secrets` in namespace `maas-db`. The single quotes keep them
   inside the pod, so they never reach your shell or your terminal:

   ```sh
   scripts/with-cluster.sh hub oc exec -n maas-db deployment/keycloak -c keycloak -- bash -c '
     kcadm=/opt/keycloak/bin/kcadm.sh cfg=/tmp/kcadm-$$.config
     "$kcadm" config credentials --config "$cfg" --server http://localhost:8080 --realm master \
       --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" &&
       "$kcadm" delete realms/saas --config "$cfg"; rc=$?; rm -f "$cfg"; exit "$rc"'
   ```

3. Restart Keycloak. The new pod imports realm `saas` again, from the example realm file, because it no longer
   exists:

   ```sh
   scripts/with-cluster.sh hub oc rollout restart deployment/keycloak -n maas-db
   scripts/with-cluster.sh hub oc rollout status deployment/keycloak -n maas-db --timeout=10m
   ```

4. Sync the `keycloak` Application, so its PostSync realm sync applies the library's settings to the new realm. The
   commands record when the last sync started, start a new one, and wait until that new sync ends, so an earlier
   sync's result doesn't count:

   ```sh
   app() { scripts/with-cluster.sh hub oc get applications.argoproj.io keycloak -n openshift-gitops -o jsonpath="$1"; }
   before=$(app '{.status.operationState.startedAt}')
   scripts/with-cluster.sh hub oc patch applications.argoproj.io keycloak -n openshift-gitops --type merge \
     -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
   until s=$(app '{.status.operationState.startedAt} {.status.operationState.phase}') &&
     [ "${s% *}" != "$before" ] && case "${s#* }" in Succeeded|Failed|Error) true ;; *) false ;; esac
   do sleep 10; done; echo "$s"
   ```

   The last line ends with `Succeeded`. If it ends with `Failed` or `Error`, run `make status` to see why.

5. Create the console backend's Keycloak user again. It was in realm `saas`:

   ```sh
   make console-secrets
   ```

The portal's sign-in redirects come back within five minutes, when CronJob `keycloak-redirect-uris` runs. You should
see `grid-tenant-1` and `grid-tenant-2` on the console's **Organizations** page.

## The hub check prints `MISSING`

**Fix:** for each `MISSING` line that a selected component doesn't install:

| Line | Fix |
|---|---|
| OpenShift version | Upgrade the cluster to 4.21 or later. |
| default StorageClass | Annotate one StorageClass `storageclass.kubernetes.io/is-default-class=true`. |
| cert-manager CRDs | Install the cert-manager Operator for Red Hat OpenShift on the hub. The root doesn't select the library's `apps/cert-manager`: the hub uses the platform's. |
| quay.io/rhoai pull secret file | Add your `quay.io/rhoai` robot account in the way that matches your guide, as the steps after this table describe. |
| object storage | Expected: `apps/odf` writes it when you [install the hub components](04-hub-components.md). ODF is the only object store on the library's `main` branch ([limits of `main`](../upstream-main-limits.md#l9-odf-is-the-only-observability-object-store)). |

To add your `quay.io/rhoai` robot account, do one of the following:

- If you follow the page-by-page guide, with a committed `clusters.yaml`, log in to `quay.io/rhoai` with the robot
  account:

  ```sh
  podman login quay.io/rhoai
  ```

  To use an auth file other than the one `podman login` writes, add `QUAY_AUTH_FILE=AUTH_FILE` to the `make`
  command.

- If you follow [Install with one command](09-hands-off.md), with `.config/clusters.yaml`, add the robot account's
  username and password to it, under `quay:`:

  ```yaml
  quay:
    username: rhoai+robot
    password: PASSWORD
  ```

## `make bootstrap` refuses a general `quay.io` login

**Cause:** the auth file holds a login for all of `quay.io`, which the hub would copy to every site.

**Fix:** use a robot token scoped to `quay.io/rhoai`, or accept the risk by allowing the general login:

```sh
make bootstrap ALLOW_GENERIC_LOGIN=1
```

## `make bootstrap` stops with no `registry.stage.redhat.io` login

**Cause:** the library mirrors the model runtime images to `registry.stage.redhat.io` with no fallback, so a site
without that login can't pull them ([limits of `main`, L20](../upstream-main-limits.md#l20-model-runtimes-pull-only-from-registrystageredhatio)).

**Fix:** add the login in the way that matches your guide:

- Page by page: `podman login registry.stage.redhat.io`, into the same auth file as your `quay.io/rhoai` login.
- [Install with one command](09-hands-off.md): add its username and password to `.config/clusters.yaml`:

  ```yaml
  stage:
    username: STAGE_USERNAME
    password: PASSWORD
  ```

  `stage:` goes with `quay:`. If your `quay.io/rhoai` login comes from an auth file instead, add the stage login to
  that file.

On a hub bootstrapped before the login was required, rerun `make bootstrap` after you add it: `make install` doesn't
bootstrap a hub that already has its pull secret.

## The root reports `missing input: NAME` or `invalid input: NAME`

**Cause:** your root's `values` don't set input `NAME`, or set it empty or with `"`, `'`, `\` or `@`.

**Fix:** set it in `root/inputs.env` ([set your names](02-repositories.md#4-set-your-names)), and push. The inputs are
`deploymentRepoURL`, `deploymentRevision`, `catalogRepoURL`, `catalogRevision` and `keycloakOverlay`.

To read the message on the hub, show the hub's status. The message is on the line that starts with
`!! The root ApplicationSet apps`:

```sh
make status
```

## A repository is private: `authentication required: Repository not found`

**Symptom:** `make prereqs` prints `FAIL` for `deployment repository` or `catalog repository` with
`is private or doesn't exist`, and `make install` stops at `inputs` (`make bootstrap` stops before it writes to the
hub). On a hub that was bootstrapped anyway, the `hub-root` gate waits until it times out (10 minutes by default),
and the `deployment-root` Application, or a catalog Application, reports
`authentication required: Repository not found`.

**Cause:** the repository is private, or its URL is wrong. The hub's Argo CD reads your deployment and catalog
repositories with no login; it has no credentials for either, so a private repository looks to it like one that
doesn't exist. Private repositories aren't supported.

**Fix:** make the repository public:

```sh
gh repo edit OWNER/REPO --visibility public --accept-visibility-change-consequences
```

Then rerun `make install` (or, page by page, `make prereqs` and `make bootstrap`).

If the line says `a network error, not a login one` instead, the repository's host didn't answer: check your network
or proxy. `make prereqs` reports that as `FAIL`; `make install` and `make bootstrap` print it as `WARN` and go on,
because the `hub-root` gate shows whether Argo CD can read the repository.

## Nothing installs on the hub; the Argo CD controller restarts with `OOMKilled`

**Symptom:** `make status` shows the same Applications for 10 minutes or more, or a line starting with `!!` about the
Argo CD controller: its last termination is `OOMKilled`, or it's in `CrashLoopBackOff`.

**Cause:** Argo CD's application controller runs out of memory before the hub's settings raise its limit.

**Fix:** run the bootstrap again, which sets the controller's memory and reapplies the same root and registry
logins, then run the install again:

```sh
make bootstrap
make install
```

The restarts stop and the Applications progress within a few minutes.

## `make site-import` stops with `timed out waiting for ManagedCluster`

**Cause:** the site still runs an old hub's klusterlet operator, which holds its lease (`klusterlet-lock`) while the
new import waits about 5 minutes for the ManagedCluster.

**Fix:** run `make site-import CONFIRM=1` again; it resumes the registration. Before the next reuse of a cluster,
run `make site-wipe CONFIRM=1` after the detach: it removes the old klusterlet operator
([reuse a cluster](05-prepare-site.md#reuse-a-cluster-from-another-hub)).

## A site imported from another hub keeps its old add-ons

**Cause:** the site was imported without a detach and wipe, so the old hub's `AppliedManifestWork` records are
still there. Each one names its hub in `spec.hubHash`. They co-own the same objects as the new hub's records, so
deleting an add-on on the new hub removes only the new owner, and the old state stays, such as Submariner's old
broker and Globalnet range.

**Fix:** list the records with their hub, on the site:

```sh
oc get appliedmanifestworks -o custom-columns=NAME:.metadata.name,HUB:.spec.hubHash
```

Records for the new hub appeared at the import; the others are the old hub's. Delete each old one, first removing
its finalizer, which only the old hub's work agent would clear:

```sh
oc patch appliedmanifestwork NAME --type merge -p '{"metadata":{"finalizers":null}}'
oc delete appliedmanifestwork NAME
```

## Hub Applications for Submariner, `limitador-redis` or the MaaS database stay unhealthy

**Cause:** they wait for the first site to join.

**Fix:** none needed before the first site joins the grid ([install the hub components](04-hub-components.md#2-verify)). After a site joins, check the Submariner gateways on the hub and on the site: two nodes on each need the label
`submariner.io/gateway=true`, which `make bootstrap` and `make site-import` add (`make install` on every run; [limits of `main`, L21](../upstream-main-limits.md#l21-nothing-labels-the-submariner-gateway-nodes)).

## A site's Submariner keeps an old broker or Globalnet range

**Cause:** the site came from another hub without a detach and wipe, so its old Submariner and the old hub's
`AppliedManifestWork` records are still there. The old Globalnet keeps its global IPs after the new broker assigns
another range, and the tunnel fails one way.

**Fix:** delete the old hub's records ([a site keeps its old add-ons](#a-site-imported-from-another-hub-keeps-its-old-add-ons)),
then reinstall Submariner by deleting the site's `submariner` ManagedClusterAddOn on the hub. Two cautions:

- The hub's Argo CD Application `acm-submariner-SITE` self-heals and recreates the add-on about 2.5 minutes after you
  delete it. If you need to change the site in between, such as its gateway labels, stop that Application's
  automated sync first, or make the change in the window between the `Submariner` object going and the reinstall.
- Submariner's uninstall finds the gateway nodes by their `submariner.io/gateway` label, so don't remove or move
  that label until the uninstall has finished.

## `maas-api` on a site fails with `password authentication failed`

**Cause:** the site's MaaS database read replica (`maas-read` in namespace `maas-db`) still replicates an old hub's
database, with that database's users. `make site-status` shows it as a `maas-db read replica` line with two different
`systemID` values.

**Fix:** on the site, delete the replica; the hub's Argo CD recreates it from the hub's database:

```sh
oc delete clusters.postgresql.cnpg.io maas-read -n maas-db
```

## Limitador stays in `CrashLoopBackOff` after the Submariner tunnel comes up

**Cause:** not known yet. It's a known issue on sites that join while Submariner sets up the tunnel.

**Fix:** delete Limitador's pods once on the site; they start again and stay up. Find them first, because their
namespace and labels depend on the install:

```sh
oc get pods -A | grep limitador
```

Then delete them, for example:

```sh
oc delete pods -n kuadrant-system -l app=limitador
```

## Tenants get certificate errors on the MaaS hostname

**Cause:** the MaaS gateway presents the cluster's internal certificate on the public hostname. Clients don't trust
it.

**Fix:** none on the library's `main` branch: a deployment repository can't give a site's MaaS gateway another
certificate ([limits of `main`](../upstream-main-limits.md#l5-the-maas-gateway-presents-the-cluster-internal-certificate)).

## The Org UI fails on every page on a new site

**Symptom:** on an `ingress` or `combined` site, every Org UI call at `https://maas.SITE_APPS_DOMAIN/maas-portal`
fails with `500` and `EOF`.

**Cause:** the Org UI (`maas-ui`) reads the MaaS gateway's address once, when it starts, and caches it. On a new
site it can start before the library sets the MaaS gateway's hostname, and it then keeps the load balancer's
address. This is a known OpenShift AI 3.6 issue, RHAI-48803.

**Fix:** after the site is **Provisioned**, restart the Org UI on the site. OpenShift AI's dashboard operator deploys
it as Deployment `maas-ui` in namespace `redhat-ods-applications`, not the library, so the restart is safe:

```sh
scripts/with-cluster.sh SITE_NAME oc rollout restart deployment/maas-ui -n redhat-ods-applications
```

## A site's cert-manager operator fails with `TooManyOperatorGroups`

**Cause:** the site already ran the platform's cert-manager, and OpenShift AI added its own OperatorGroup beside the
platform's. `make site-check` reports such a site as `FOUND` for its `cert-manager OperatorGroup`, before you import
it.

**Fix:** see [A site that already runs cert-manager](06-join-grid.md#a-site-that-already-runs-cert-manager).

## `KserveReady` flaps `False` on a site

**Symptom:** the site's DataScienceCluster turns `Not Ready` for a while, with `KserveReady` `False` and a message
naming `modelcache: cleanup` and Role `kserve-leader-election-role`; it returns to `Ready`, then flaps again. Models
keep serving.

**Cause:** a regression in the KServe module operator on RHOAI 3.6 nightlies built after 2026-11-06: it deletes and
recreates its leader-election Role. Tracked as [RHOAIENG-103272](https://redhat.atlassian.net/browse/RHOAIENG-103272);
upstream fix [opendatahub-io/kserve#2175](https://github.com/opendatahub-io/kserve/pull/2175).

**Fix:** none needed; check twice or watch for a minute. Don't pin an older nightly to avoid it: that brings back the
bug kserve#2171 fixed.

## The Monitoring page can't load dashboards

**Symptom:** the console's **Monitoring** page says it's unable to load dashboards because `redhat-ods-monitoring`
doesn't exist.

**Cause:** the observability components aren't ready yet. Either ODF or the usage-logs LokiStack is still coming up,
or the Cluster Observability Operator or Perses isn't installed.

**Fix:** check each one on the hub. `scripts/with-cluster.sh hub` runs each `oc` command with the hub's login from
`.config/hub/kubeconfig`, not with your own kubeconfig:

```sh
scripts/with-cluster.sh hub oc get lokistack usage-logs -n redhat-ods-monitoring
scripts/with-cluster.sh hub oc get persesdashboards -n redhat-ods-monitoring
make status
```

The LokiStack should report `Ready`, the dashboards should be listed, and `make status` should show the `odf`,
`ai-grid-o11y` and `ai-grid-usage-logs` Applications Synced and Healthy. Wait for any that are still progressing, then
reload the page.

## A model's catalog Applications don't appear

**Cause:** the catalog ApplicationSets' git generator didn't pick up the catalog's first commits.

**Fix:** refresh each catalog ApplicationSet once on the hub. *(Unverified.)*

```sh
for a in models ingress subscriptions; do
  scripts/with-cluster.sh hub oc -n openshift-gitops annotate applicationsets.argoproj.io acm-models-catalog-$a \
    argocd.argoproj.io/application-set-refresh=true --overwrite
done
```
