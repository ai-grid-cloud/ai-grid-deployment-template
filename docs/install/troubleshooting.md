# Troubleshooting

Each entry gives the symptom, the cause and the fix. The [hub](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/README.md) and [spokes](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/spokes/README.md) pages list more under **Known issues**.

## `check-deployment.sh` reports `unset inputs` or `placeholders left in your files`

**Cause:** an input in `root/kustomization.yaml`, or a value in another file, is still a `REQUIRED-NAME` placeholder.

**Fix:** set each one it names ([set your names](02-repositories.md#3-set-your-names);
[inputs](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/appendix-a-inputs.md#inputs)), and run the check again.

## The hub check prints `MISSING`

**Fix:** for each `MISSING` line that a selected component doesn't install:

| Line | Fix |
|---|---|
| OpenShift version | Upgrade the cluster to 4.21 or later. |
| default StorageClass | Annotate one StorageClass `storageclass.kubernetes.io/is-default-class=true`. |
| cert-manager CRDs | Install the cert-manager Operator for Red Hat OpenShift, or select `apps/cert-manager` ([cert-manager](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/00-platform-services.md#cert-manager)). |
| quay.io/rhoai pull secret file | Log in: `podman login quay.io` with a `quay.io/rhoai` robot token ([OpenShift AI prerequisites](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). |
| object storage | Expected with `apps/object-storage/s4` or `odf` selected: it appears when you [install the hub components](04-hub-components.md). If you bring your own bucket, create the Secret now ([object storage](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/01-acm.md#object-storage)). |

## `bootstrap-hub.sh` refuses a general `quay.io` login

**Cause:** the auth file holds a login for all of `quay.io`, which the hub would copy to every site.

**Fix:** use a robot token scoped to `quay.io/rhoai`, or accept the risk with `RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1`.

## The root reports `missing input: NAME` or `invalid input: NAME`

**Cause:** your root's `values` don't set input `NAME`, or set it empty or with `"`, `'`, `\` or `@`.

**Fix:** set it in `root/kustomization.yaml` ([inputs](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/appendix-a-inputs.md#inputs)), run
`../library/scripts/check-deployment.sh .`, and push. Read the message with
`oc get applicationset apps -n openshift-gitops -o jsonpath='{.status.conditions}'`.

## A site's `rhoai-SITE` Application doesn't appear or doesn't render

**Cause:** an ingress or combined site has no `values/clusters/SITE/rhoai.yaml` with its MaaS hostname prefix.

**Fix:** add it ([join the site to the grid, part 1](06-join-grid.md#1-add-the-sites-values)) and push.

## Organization create fails with Bad Request

**Cause:** the console backend sends `autoRedirect` in organization domains, which Red Hat build of Keycloak 26.4 and
26.6 reject.

**Fix:** run community Keycloak 26.8.0 for tenants, as the library and the example do
([Keycloak](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/04-tenant-identity.md#known-issues-1)).

## Tenants get certificate errors on the MaaS hostname

**Cause:** the MaaS gateway presents its in-cluster service certificate on the public hostname.

**Fix:** give the gateway a trusted certificate through the site's values file
([join the site to the grid, part 1](06-join-grid.md#1-add-the-sites-values); [MaaS gateway certificate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/spokes/maas-certificate.md)).

## Every model call returns `403`, "access denied to requested subscription"

**Cause:** the token's `groups` are already prefixed with the organization ID (`ORG_ID/ai-grid-users`). MaaS adds the
prefix itself and drops groups that already carry one.

**Fix:** emit plain group names from the IdP ([tenant identity provider](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/04-tenant-identity.md#tenant-identity-provider)).

## A chat call returns `400` "Field required: messages" or a template error

**Cause:** the model has no chat template (such as OPT-125m), and the MaaS gateway sends completions to the chat
endpoint.

**Fix:** deploy a chat model.

## Keycloak doesn't start after a version change

**Cause:** the pod runs `kc.sh import` before `kc.sh start`, and the import refuses to migrate an older database.

**Fix:** use `strategy: Recreate`, back up the database before a version change, and see
[Keycloak](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/04-tenant-identity.md#known-issues-1).

## An API key reaches a model outside its subscription, or is refused with `403`

**Cause:** an API key is bound to the subscription it was created under, and MaaS ignores the `X-MaaS-Subscription`
header for keys, by design. A key reaches exactly the models its subscription covers, whatever the header says, and
gets `403` for any other model. A revoked key also gets `403`, not `401`.

**Fix:** to limit what a key reaches, create it under a subscription that covers only those models
([tenant access](tenant-access.md#create-an-api-key-and-call-with-it)). For a `403`, check the key's `subscription` and
`status` with `GET https://MAAS_HOST/v1/api-keys/KEY_ID`.

## The Org UI can't load models or API keys

**Symptom:** a tenant signs in to the Org UI (`https://MAAS_HOST/maas-portal`), but the models page says "Unable to
load MaaS models" and **API keys** says "Unable to load settings". The portal's calls return `401`, and the site's
`maas-portal` pod logs `missing required header: x-forwarded-access-token`.

**Cause:** on OpenShift AI 3.6 nightly builds before FBC `d0ee30a`, the gateway's portal session policy sends the
tenant's token only as `x-forwarded-id-token`, and the portal reads `x-forwarded-access-token`
([RHAI-21554](https://redhat.atlassian.net/browse/RHAI-21554)). The library pins `add544e` in
`apps/rhoai/nightly.yaml`, which has the fix; a deployment that pins an older build has the bug.

**Fix:** pin FBC `d0ee30a` or later, such as the library's `add544e`;
ai-gateway-controller [PR 246](https://github.com/opendatahub-io/ai-gateway-controller/pull/246) restores the header.
Until then, tenants create API keys through the MaaS API
([tenant access](tenant-access.md#create-an-api-key-and-call-with-it)). Don't edit the AuthPolicy or the `maas-portal`
Deployment by hand: their controllers revert the change.

## Calls fail with `401` or `503` after the IdP was down

**Cause:** Authorino on the site cached the failed OIDC discovery or the old signing keys.

**Fix:** `oc --context SITE_CONTEXT rollout restart deployment/authorino -n kuadrant-system` on each ingress or combined
site.

## A tenant's users get no organization claims

**Cause:** Keycloak 26.8 didn't apply the realm import's user profile, so it drops admin-set `maas_*` attributes.

**Fix:** set the realm's `unmanagedAttributePolicy` to `ADMIN_EDIT` through the admin API, as the example's
`scripts/create-test-tenant.sh` does.

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

**Fix:** none needed if you skipped observability on purpose; see [observability](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/07-observability.md) and
[known gaps](appendix-c-gaps.md).

## A model's catalog Applications don't appear

**Cause:** the catalog ApplicationSets' git generator didn't pick up the catalog's first commits.

**Fix:** refresh them once ([model delivery](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/05-console-and-model-delivery.md#model-delivery)).

## A deleted model stays on the site for several minutes

**Cause:** the model's ExternalModel keeps its finalizer `inference.opendatahub.io/external-model-cleanup` until the
model's pods end, about 9 minutes after the delete.

**Fix:** none needed; wait. Check with `oc --context SITE_CONTEXT get externalmodels,llminferenceservices -A`.

## About one call in six fails the TLS handshake

**Cause:** one of the MaaS gateway load balancer's addresses doesn't answer, probably a zone with no gateway pod behind
it.

**Fix:** see [load balancers](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/spokes/networking.md#load-balancers).

## Hub Applications for Submariner, `limitador-redis` or the MaaS database stay unhealthy

**Cause:** they wait for the first site to join.

**Fix:** none needed before the first site joins the grid ([install the hub components](04-hub-components.md#1-watch-the-components-install)). After a site joins, check the site's Submariner gateways ([Submariner](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/06226f8e9f92a20ee40db8f46f1e3ac2bbfffb36/docs/install/hub/01-acm.md#submariner)).
