# Troubleshooting

Problems you can hit while following this guide. Each entry gives the symptom, the cause and the fix. For problems
after install, see the library's [troubleshooting](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/troubleshooting.md). The [hub](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/README.md) and [spokes](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/spokes/README.md) pages list more under **Known issues**.

## `check-deployment.sh` reports `unset inputs` or `placeholders left in your files`

**Cause:** an input in `root/inputs.env` is empty, or a value in another file is still a `REQUIRED-NAME` placeholder.

**Fix:** set each one it names ([set your names](02-repositories.md#4-set-your-names);
[inputs](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/appendix-a-inputs.md#inputs)), and run the check again.

## The hub check prints `MISSING`

**Fix:** for each `MISSING` line that a selected component doesn't install:

| Line | Fix |
|---|---|
| OpenShift version | Upgrade the cluster to 4.21 or later. |
| default StorageClass | Annotate one StorageClass `storageclass.kubernetes.io/is-default-class=true`. |
| cert-manager CRDs | Install the cert-manager Operator for Red Hat OpenShift, or select `apps/cert-manager` ([cert-manager](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/00-platform-services.md#cert-manager)). |
| quay.io/rhoai pull secret file | Log in to `quay.io` with a `quay.io/rhoai` robot token, as follows this table ([OpenShift AI prerequisites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). |
| object storage | Expected with `apps/object-storage/s4` or `odf` selected: it appears when you [install the hub components](04-hub-components.md). If you bring your own bucket, create the Secret now ([object storage](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/01-acm.md#object-storage)). |

To log in to `quay.io`:

```sh
podman login quay.io
```

## `make bootstrap` refuses a general `quay.io` login

**Cause:** the auth file holds a login for all of `quay.io`, which the hub would copy to every site.

**Fix:** use a robot token scoped to `quay.io/rhoai`, or accept the risk by allowing the general login:

```sh
make bootstrap ALLOW_GENERIC_LOGIN=1
```

## The root reports `missing input: NAME` or `invalid input: NAME`

**Cause:** your root's `values` don't set input `NAME`, or set it empty or with `"`, `'`, `\` or `@`.

**Fix:** set it in `root/inputs.env` if it's one of yours, or in `root/kustomization.yaml` ([inputs](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/appendix-a-inputs.md#inputs)), check it, and push:

```sh
scripts/check-deployment.sh
```

To read the message on the hub:

```sh
oc get applicationset apps -n openshift-gitops -o jsonpath='{.status.conditions}'
```

## Nothing installs on the hub; the Argo CD controller restarts with `OOMKilled`

**Symptom:** `make status` shows the same Applications for 10 minutes or more, or a line starting with `!!` about the
Argo CD controller: its last termination is `OOMKilled`, or it's in `CrashLoopBackOff`.

**Cause:** Argo CD's application controller runs out of memory before the hub's settings raise its limit.

**Fix:** run the bootstrap again. It sets the controller's memory, and reapplies the same root and registry logins:

```sh
make bootstrap
```

Then run `make status` again: the restarts stop and the Applications progress within a few minutes.

## Hub Applications for Submariner, `limitador-redis` or the MaaS database stay unhealthy

**Cause:** they wait for the first site to join.

**Fix:** none needed before the first site joins the grid ([install the hub components](04-hub-components.md#1-watch-the-components-install)). After a site joins, check the site's Submariner gateways ([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/01-acm.md#submariner)).

## A site's `rhoai-SITE` Application doesn't appear or doesn't render

**Cause:** an ingress or combined site has no `values/clusters/SITE/rhoai.yaml` with its MaaS hostname prefix.

**Fix:** add it ([join the site to the grid, part 1](06-join-grid.md#1-add-the-sites-values)) and push.

## Tenants get certificate errors on the MaaS hostname

**Cause:** the MaaS gateway presents its in-cluster service certificate on the public hostname.

**Fix:** give the gateway a trusted certificate through the site's values file
([join the site to the grid, part 1](06-join-grid.md#1-add-the-sites-values); [MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/spokes/maas-certificate.md)).

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

**Cause:** the dashboards come from the observability components, which you didn't select.

**Fix:** none needed if you skipped observability on purpose; see [observability](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/07-observability.md) and
[known gaps](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/known-gaps.md).

## A model's catalog Applications don't appear

**Cause:** the catalog ApplicationSets' git generator didn't pick up the catalog's first commits.

**Fix:** refresh them once ([model delivery](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/f5dfd38e2f7c949b2d198476a4e3c5602186aee7/docs/install/hub/05-console-and-model-delivery.md#model-delivery)).
