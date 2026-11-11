# Troubleshooting

Each entry gives the symptom, the cause and the fix. The [hub](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/README.md) and [spokes](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/spokes/README.md) pages list more under **Known issues**.

## The root reports `missing input: NAME` or `invalid input: NAME`

**Cause:** your root's `values` don't set input `NAME`, or set it empty or with `"`, `'`, `\` or `@`.

**Fix:** set it in `root/kustomization.yaml` ([repositories, part 4](02-repositories.md#4-set-every-input)), run
`../library/scripts/check-deployment.sh .`, and push. Read the message with
`oc get applicationset apps -n openshift-gitops -o jsonpath='{.status.conditions}'`.

## A site's `rhoai-SITE` Application doesn't appear or doesn't render

**Cause:** an ingress or combined site has no `values/clusters/SITE/rhoai.yaml` with its MaaS hostname prefix.

**Fix:** add it ([join each site to the grid, part 1](06-join-grid.md#1-add-the-sites-values)) and push.

## Organization create fails with Bad Request

**Cause:** the console backend sends `autoRedirect` in organization domains, which Red Hat build of Keycloak 26.4 and
26.6 reject.

**Fix:** run community Keycloak 26.8.0 for tenants, as the library and the example do
([Keycloak](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/04-tenant-identity.md#known-issues-1)).

## Tenants get certificate errors on the MaaS hostname

**Cause:** the MaaS gateway presents its in-cluster service certificate on the public hostname.

**Fix:** give the gateway a trusted certificate through the site's values file
([join each site to the grid, part 1](06-join-grid.md#1-add-the-sites-values); [MaaS gateway certificate](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/spokes/maas-certificate.md)).

## Every model call returns `403`, "access denied to requested subscription"

**Cause:** the token's `groups` are already prefixed with the organization ID (`ORG_ID/ai-grid-users`). MaaS adds the
prefix itself and drops groups that already carry one.

**Fix:** emit plain group names from the IdP ([tenant identity provider](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/04-tenant-identity.md#tenant-identity-provider)).

## A chat call returns `400` "Field required: messages" or a template error

**Cause:** the model has no chat template (such as OPT-125m), and the MaaS gateway sends completions to the chat
endpoint.

**Fix:** deploy a chat model.

## Keycloak doesn't start after a version change

**Cause:** the pod runs `kc.sh import` before `kc.sh start`, and the import refuses to migrate an older database.

**Fix:** use `strategy: Recreate`, back up the database before a version change, and see
[Keycloak](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/04-tenant-identity.md#known-issues-1).

## An API key reaches a model outside its subscription, or is refused with `403`

**Cause:** an API key is bound to the subscription it was created under, and MaaS ignores the `X-MaaS-Subscription`
header for keys, by design. A key reaches exactly the models its subscription covers, whatever the header says, and
gets `403` for any other model. A revoked key also gets `403`, not `401`.

**Fix:** to limit what a key reaches, create it under a subscription that covers only those models
([first use, part 6](08-first-use.md#6-call-the-model-as-a-tenant)). For a `403`, check the key's `subscription` and
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
([first use, part 6](08-first-use.md#6-call-the-model-as-a-tenant)). Don't edit the AuthPolicy or the `maas-portal`
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

**Fix:** none needed if you skipped observability on purpose; see [observability](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/07-observability.md) and
[known gaps](appendix-c-gaps.md).

## A model's catalog Applications don't appear

**Cause:** the catalog ApplicationSets' git generator didn't pick up the catalog's first commits.

**Fix:** refresh them once ([model delivery](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/05-console-and-model-delivery.md#model-delivery)).

## A deleted model stays on the site for several minutes

**Cause:** the model's ExternalModel keeps its finalizer `inference.opendatahub.io/external-model-cleanup` until the
model's pods end. On the tested site every object was gone about 9 minutes after the delete.

**Fix:** none needed; wait. Check with `oc --context SITE_CONTEXT get externalmodels,llminferenceservices -A`.

## About one call in six fails the TLS handshake

**Cause:** one of the MaaS gateway load balancer's addresses doesn't answer, probably a zone with no gateway pod behind
it.

**Fix:** see [load balancers](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/spokes/networking.md#load-balancers).

## Hub Applications for Submariner, `limitador-redis` or the MaaS database stay unhealthy

**Cause:** they wait for the first site to join.

**Fix:** none needed before the first site joins the grid. After a site joins, check the site's Submariner gateways ([Submariner](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/01-acm.md#submariner)).
