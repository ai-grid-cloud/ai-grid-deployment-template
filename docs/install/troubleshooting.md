# Troubleshooting

Problems you can hit while following this guide. Each entry gives the symptom, the cause and the fix. For what the
library's `main` branch can't do yet, see [the limits of `main`](../upstream-main-limits.md). For the library's own
reference, see its [getting started](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/README.md) page.

## The deployment check reports `unset inputs` or `placeholders left in your files`

**Cause:** an input in `root/inputs.env` is empty, or a value in another file is still a `REQUIRED-NAME` placeholder.

**Fix:** set each one it names ([set your names](02-repositories.md#4-set-your-names)), and run the check again.

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

## The root reports `missing input: NAME` or `invalid input: NAME`

**Cause:** your root's `values` don't set input `NAME`, or set it empty or with `"`, `'`, `\` or `@`.

**Fix:** set it in `root/inputs.env` ([set your names](02-repositories.md#4-set-your-names)), and push. The inputs are
`deploymentRepoURL`, `deploymentRevision`, `catalogRepoURL`, `catalogRevision` and `keycloakOverlay`.

To read the message on the hub, show the hub's status. The message is on the line that starts with
`!! The root ApplicationSet apps`:

```sh
make status
```

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

## Hub Applications for Submariner, `limitador-redis` or the MaaS database stay unhealthy

**Cause:** they wait for the first site to join.

**Fix:** none needed before the first site joins the grid ([install the hub components](04-hub-components.md#2-verify)). After a site joins, check the site's Submariner gateways: two of its nodes need the label
`submariner.io/gateway=true` ([site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide)).

## Tenants get certificate errors on the MaaS hostname

**Cause:** the MaaS gateway presents the cluster's internal certificate on the public hostname. Clients don't trust
it.

**Fix:** none on the library's `main` branch: a deployment repository can't give a site's MaaS gateway another
certificate ([limits of `main`](../upstream-main-limits.md#l5-the-maas-gateway-presents-the-cluster-internal-certificate)).

## The Org UI fails on every page on a new site

**Symptom:** on an `ingress` or `combined` site, every Org UI call at `https://maas.SITE_APPS_DOMAIN/maas-portal`
fails with `500` and `EOF`.

**Cause:** the Org UI reads the MaaS URL once, when it starts. On a new site it can start before the library sets
the MaaS gateway's hostname, and it then keeps the load balancer's name. This is a known OpenShift AI 3.6 issue,
RHAI-48803.

**Fix:** after the site is **Provisioned**, restart the Org UI on the site:

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
