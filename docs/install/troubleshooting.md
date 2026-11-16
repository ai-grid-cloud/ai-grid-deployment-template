# Troubleshooting

Problems you can hit while following this guide. Each entry gives the symptom, the cause and the fix. For problems
after install, see the library's [troubleshooting](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/troubleshooting.md). The [hub](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/README.md) and [spokes](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/README.md) pages list more under **Known issues**.

## The deployment check reports `unset inputs` or `placeholders left in your files`

**Cause:** an input in `root/inputs.env` is empty, or a value in another file is still a `REQUIRED-NAME` placeholder.

**Fix:** set each one it names ([set your names](02-repositories.md#4-set-your-names);
[inputs](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/appendix-a-inputs.md#inputs)), and run the check again.

## The hub check prints `MISSING`

**Fix:** for each `MISSING` line that a selected component doesn't install:

| Line | Fix |
|---|---|
| OpenShift version | Upgrade the cluster to 4.21 or later. |
| default StorageClass | Annotate one StorageClass `storageclass.kubernetes.io/is-default-class=true`. |
| cert-manager CRDs | Install the cert-manager Operator for Red Hat OpenShift, or select `apps/cert-manager` ([cert-manager](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/00-platform-services.md#cert-manager)). |
| quay.io/rhoai pull secret file | Add your `quay.io/rhoai` robot account in the way that matches your guide, as the steps after this table describe ([OpenShift AI prerequisites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). |
| object storage | Expected with `apps/object-storage/s4` or `odf` selected: it appears when you [install the hub components](04-hub-components.md). If you bring your own bucket, create the Secret now ([object storage](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/01-acm.md#object-storage)). |

To add your `quay.io/rhoai` robot account, do one of the following:

- If you follow the page-by-page guide, with a committed `clusters.yaml`, log in to `quay.io/rhoai` with the robot
  account:

  ```sh
  podman login quay.io/rhoai
  ```

  To use an auth file other than the one `podman login` writes, add `QUAY_AUTH_FILE=AUTH_FILE` to the `make`
  command. Don't run `make secrets` here: it moves your settings to `.config/clusters.yaml`, and the scripts then
  ignore your committed `clusters.yaml`.

- If you follow [Install with one command](09-hands-off.md), with `.config/clusters.yaml`, add the robot account's
  username and password to it:

  ```sh
  make secrets NAME=quay
  ```

## `make bootstrap` refuses a general `quay.io` login

**Cause:** the auth file holds a login for all of `quay.io`, which the hub would copy to every site.

**Fix:** use a robot token scoped to `quay.io/rhoai`, or accept the risk by allowing the general login:

```sh
make bootstrap ALLOW_GENERIC_LOGIN=1
```

## The root reports `missing input: NAME` or `invalid input: NAME`

**Cause:** your root's `values` don't set input `NAME`, or set it empty or with `"`, `'`, `\` or `@`.

**Fix:** set it in `root/inputs.env` if it's one of yours, or in `root/kustomization.yaml` ([inputs](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/appendix-a-inputs.md#inputs)), and push.

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

**Fix:** none needed before the first site joins the grid ([install the hub components](04-hub-components.md#2-verify)). After a site joins, check the site's Submariner gateways ([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/01-acm.md#submariner)).

## Tenants get certificate errors on the MaaS hostname

**Cause:** the MaaS gateway presents the cluster's internal certificate, `openshift-ai-inference-service-tls`, on
the public hostname. Clients don't trust it.

**Fix:** add your own certificate for the MaaS hostname
([MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/maas-certificate.md)).

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
reload the page ([observability](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/07-observability.md);
[known gaps](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/known-gaps.md)).

## A model's catalog Applications don't appear

**Cause:** the catalog ApplicationSets' git generator didn't pick up the catalog's first commits.

**Fix:** refresh them once ([model delivery](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/hub/05-console-and-model-delivery.md#model-delivery)).
