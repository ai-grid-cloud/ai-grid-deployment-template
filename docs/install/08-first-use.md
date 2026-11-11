# First use: deploy a model and call it

In this section you create an organization, deploy a model to a site, subscribe the organization's users to it, and
call it as a tenant. The provider console writes the model and subscription to your catalog repository, and Argo CD
delivers them to the site.

Each step gives the console's pages first, as tested in a browser on 2026-11-10. The same calls through the console's
API follow as an alternative, with the library's [`scripts/console-call.sh`](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/scripts/console-call.sh), which signs
in as an OpenShift user through the htpasswd provider and makes one call:

```sh
../library/scripts/console-call.sh --kubeconfig HUB_KUBECONFIG --password-file HUB_ADMIN_PASSWORD_FILE METHOD 'JSON'
```

## 1. Sign in to the console

1. Open `https://CONSOLE_HOST` (from [install the hub components](04-hub-components.md#3-verify)). OpenShift's sign-in page opens.
2. Choose your identity provider, such as `htpasswd` for the break-glass admin, and sign in as a cluster admin.

   You should see the **AI Grid** page, with your user shown as `USER (provider admin)`. The navigation lists
   **AI Grid**, **Monitoring**, **Clusters**, **Organizations**, **Models** and **Subscriptions**.

3. Click **Clusters**. You should see each site with AI Grid status **Provisioned**, its role and its location. The
   hub (`local-cluster`) shows **Not added**, which is expected for a hub that isn't a site.

The **Monitoring** page shows dashboards only if you selected observability; without it, it reports that
`redhat-ods-monitoring` doesn't exist ([troubleshooting](10-troubleshooting.md#the-monitoring-page-cant-load-dashboards)).

## 2. Create an organization

1. Go to **Organizations** and click **Create organization**. A three-step wizard opens: **Organization details**,
   **Identity provider**, **Review**.
2. In **Organization details**, enter the **Name**. Click **Add domain** and enter the organization's email domain in
   **Domain 1**. Click **Next**.
3. In **Identity provider**, link the organization to the tenant's own OIDC provider: **Title** (shown on the login
   page), **Client ID**, **Client secret reference** (the name of the Secret that holds the client secret), **Issuer**,
   and under **OIDC endpoints** the **Authorization URL**, **Token URL** and **JWKS URL** (required while
   **Validate signature** is on). You can leave every field empty: an organization with no identity provider is
   accepted, and its users then sign in with accounts in your tenant Keycloak itself. Click **Next**.
   *(Unverified: signing in through a linked identity provider.)*
4. In **Review**, check the values and click **Create organization**.

You should see the organization in the **Organizations** list, with its primary domain and its identity provider, or
`—` for none.

Or through the API:

```sh
../library/scripts/console-call.sh --kubeconfig HUB_KUBECONFIG --password-file HUB_ADMIN_PASSWORD_FILE \
  ai_grid.v1.Tenants/Create '{"object":{"metadata":{"name":"ORG_NAME"},"spec":{"domains":["ORG_DOMAIN"]}}}'
```

You should see `HTTP 200` and the organization's `id`. Keep the `id` as `ORG_ID`. It's the Keycloak organization's ID,
and tokens carry it as `org_id`.

If you see `HTTP 400` with a Keycloak error, your Keycloak is the Red Hat build 26.4 or 26.6, which rejects the
console's request; see [troubleshooting](10-troubleshooting.md#organization-create-fails-with-bad-request).

## 3. Deploy a model

Use a chat model: the MaaS gateway sends completions to the chat endpoint, so a model without a chat template, such
as OPT-125m, answers `400`. The tested model is SmolLM2-135M-Instruct on CPU.

1. Go to **Models** and click **Deploy model**. A four-step wizard opens: **Source**, **Deployment**, **Clusters**,
   **Review**.
2. In **Source**, enter the **Model URI**, such as `hf://HuggingFaceTB/SmolLM2-135M-Instruct`. Click **Next**.
3. In **Deployment**:
   - **Model name**: prefilled from the URI. Tenants send the resource name shown under it as `model` in their
     requests.
   - **Hardware**: **NVIDIA GPU** (the default) or **CPU only**. With NVIDIA GPU, **Runtime image** is optional and
     empty means the cluster's default vLLM image. With CPU only, **Runtime image** is required; the tested CPU image is
     `registry.redhat.io/rhaii/vllm-cpu-rhel9@sha256:0ec0f5ff9a5ff263f58db0cfb19e3d7eef24b94c2d8629fe5145f5a8747e28c9`.
   - **Replicas** (default `1`), **CPU** (default `2`) and **Memory** (default `16Gi`). The tested CPU model used `4`
     CPU and `8Gi`.

   Click **Next**.
4. In **Clusters**, pick each site the model runs on. Click **Next**.
5. In **Review**, check the values and click **Deploy**. A CPU-only model on a site with GPUs shows a warning; you can
   still deploy.

You should see the model in the **Models** list with status **Saved to Git**: the console committed it to your catalog
repository. About 5 to 7 minutes later it shows **Ready** and **Available**.

Or through the API:

```sh
../library/scripts/console-call.sh --kubeconfig HUB_KUBECONFIG --password-file HUB_ADMIN_PASSWORD_FILE ai_grid.v1.Models/Create '{
  "object": {
    "id": "smollm2-chat",
    "metadata": {"name": "smollm2-chat", "annotations": {"openshift.io/display-name": "SmolLM2 135M Instruct"}},
    "spec": {
      "model": {"uri": "hf://HuggingFaceTB/SmolLM2-135M-Instruct"},
      "replicas": 1,
      "main": {
        "image": "registry.redhat.io/rhaii/vllm-cpu-rhel9@sha256:0ec0f5ff9a5ff263f58db0cfb19e3d7eef24b94c2d8629fe5145f5a8747e28c9",
        "env": [{"name": "OMP_NUM_THREADS", "value": "4"}, {"name": "VLLM_CPU_KVCACHE_SPACE", "value": "4"}],
        "requests": {"cpu": "4", "memory": "8Gi"}
      },
      "placement": {"label_selector": {"match_expressions": [{"key": "name", "operator": "In", "values": ["SITE"]}]}}
    }
  }
}'
```

You should see `HTTP 200`, and a new commit in your catalog repository under the site's directory.

## 4. Subscribe the organization

A subscription gives an organization's group access to models, with a token rate limit. Give the group name as
plain text, such as `ai-grid-users`; MaaS prefixes it with the organization ID.

1. Go to **Subscriptions** and click **Create subscription**.
2. Enter the **Name**, pick the **Organization**, and set the **Priority** (default `0`; higher numbers win).
3. In **Groups**, type the group name, such as `ai-grid-users`, and pick **Add group "ai-grid-users"**.
4. Click **Add models**, tick the model in the dialog, and click **Add models**.
5. The model's row requires a token limit. Click **Add token limit**, set **Tokens**, **Per** and the time unit
   (defaults `1000` per `1` `hour`), and click **Save**.
6. Click **Create subscription**.

You should see the subscription in the **Subscriptions** list with status **Pending**, "Setting up subscription", and
**Active** about 5 minutes later.

Or through the API:

```sh
../library/scripts/console-call.sh --kubeconfig HUB_KUBECONFIG --password-file HUB_ADMIN_PASSWORD_FILE ai_grid.v1.Subscriptions/Create '{
  "object": {
    "id": "SUBSCRIPTION_ID",
    "metadata": {"name": "SUBSCRIPTION_ID"},
    "spec": {
      "organization": {"id": "ORG_ID"},
      "owner": {"groups": ["ai-grid-users"]},
      "model_refs": [{"name": "smollm2-chat", "token_rate_limits": [{"limit": 100000, "window": "1m"}]}]
    }
  }
}'
```

You should see `HTTP 200` and another catalog commit.

## 5. Check the delivery

Within about two minutes the hub's catalog ApplicationSets create the site's model Applications:

```sh
oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops | grep catalog
oc --context "$SITE_CONTEXT" get llminferenceservices,maassubscriptions,maasauthpolicies -A
```

You should see the model `Ready` and the subscription and its auth policy on the site. In the console, **Models**
shows the model **Ready** and **Available**, and **Subscriptions** shows the subscription **Active**. If no catalog Applications
appear after the catalog's first commits, refresh the ApplicationSets once
([model delivery](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/05-console-and-model-delivery.md#model-delivery)).

## 6. Call the model as a tenant

You need a tenant user: a member of the organization, in group `ai-grid-users`. In your own IdP, the tenant's admin
creates users. To make a test user in the example's Keycloak, use
[`scripts/create-test-tenant.sh`](https://github.com/cfchase/ai-grid-deployment-proto/blob/main/scripts/create-test-tenant.sh),
which generates the password into a file.

1. Get the user's access token from the issuer and write it into a header file. The client secret and password are
   read from files, so neither appears on a command line:

   ```sh
   T=$(mktemp -d); (umask 077
   curl -sS "IDP_ISSUER_URL/protocol/openid-connect/token" \
     --data-urlencode grant_type=password --data-urlencode client_id=IDP_CLIENT_ID \
     --data-urlencode client_secret@CLIENT_SECRET_FILE --data-urlencode username=TENANT_USER \
     --data-urlencode password@TENANT_PASSWORD_FILE --data-urlencode scope=openid \
     | jq -r '"Authorization: Bearer " + .access_token' > "$T/auth")
   ```

   The password grant must be enabled on the client (the example's realm enables it for testing). Tenants
   normally use an API key instead (step 5).

2. List the models:

   ```sh
   curl -sS -H @"$T/auth" https://MAAS_HOST/v1/models | jq -c '[.data[].id]'
   ```

   You should see `["smollm2-chat"]`.

3. Call the model, and see which site served it:

   ```sh
   curl -sS -D "$T/h" -H @"$T/auth" -H 'X-MaaS-Subscription: SUBSCRIPTION_ID' -H 'Content-Type: application/json' \
     -d '{"model":"smollm2-chat","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":20}' \
     https://MAAS_HOST/v1/chat/completions | jq -r '.choices[0].message.content'
   grep -i '^x-grid-site' "$T/h"
   ```

   You should see a short reply and `x-grid-site: SITE`. With a user's token, the `X-MaaS-Subscription` header picks
   the subscription the call runs under.

4. Check the refusals:

   ```sh
   curl -sS -o /dev/null -w '%{http_code}\n' https://MAAS_HOST/v1/models
   curl -sS -o /dev/null -w '%{http_code}\n' -H @"$T/auth" -H 'X-MaaS-Subscription: OTHER_SUBSCRIPTION' \
     -H 'Content-Type: application/json' -d '{"model":"smollm2-chat","messages":[{"role":"user","content":"Hi"}]}' \
     https://MAAS_HOST/v1/chat/completions
   ```

   You should see `401` without a token, and `403` with a subscription that doesn't cover the model.

5. Create an API key and call the model with it. A key is bound to one subscription when you create it:

   ```sh
   (umask 077
   curl -sS -H @"$T/auth" -H 'Content-Type: application/json' \
     -d '{"name":"KEY_NAME","expiresIn":"1h","subscription":"SUBSCRIPTION_ID"}' \
     https://MAAS_HOST/v1/api-keys > "$T/key.json"
   jq -r '"Authorization: Bearer " + .key' "$T/key.json" > "$T/key-auth")
   jq '{id, keyPrefix, subscription, expiresAt}' "$T/key.json"
   curl -sS -H @"$T/key-auth" https://MAAS_HOST/v1/models | jq -c '[.data[].id]'
   curl -sS -o /dev/null -w '%{http_code}\n' -H @"$T/key-auth" -H 'Content-Type: application/json' \
     -d '{"model":"OTHER_MODEL","messages":[{"role":"user","content":"Hi"}]}' https://MAAS_HOST/v1/chat/completions
   ```

   You should see the key's `id`, `keyPrefix`, `subscription` and `expiresAt`; the models that subscription covers;
   and `403` for a model it doesn't cover. Keep the `id` as `KEY_ID`. The chat call in step 3, with `$T/key-auth` in
   place of `$T/auth`, returns a reply and an `x-grid-site` header.

   A key ignores the `X-MaaS-Subscription` header and always uses the subscription it's bound to: a key bound to one
   subscription still reaches its models with another subscription named in the header. This is MaaS's design
   (its e2e test
   [`test_api_key_ignores_subscription_header`](https://github.com/opendatahub-io/models-as-a-service/blob/8d30ae9adcda2a9cddc5c33b3a3121037c72a851/test/e2e/tests/test_models_endpoint.py#L1867-L1875)).
   To limit what a key reaches, create it under a subscription that covers only those models; for other models,
   create another key under another subscription.

   Tenants can also create keys in the Org UI, at `https://MAAS_HOST/maas-portal` under **API keys**. On OpenShift AI
   builds before FBC `d0ee30a`, the Org UI can't load models or keys
   ([troubleshooting](10-troubleshooting.md#the-org-ui-cant-load-models-or-api-keys)).

6. Revoke the key:

   ```sh
   curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE -H @"$T/auth" https://MAAS_HOST/v1/api-keys/KEY_ID
   curl -sS -o /dev/null -w '%{http_code}\n' -H @"$T/key-auth" https://MAAS_HOST/v1/models
   rm -rf "$T"
   ```

   You should see `200` for the delete, and `403`, not `401`, for a call with the revoked key.

Replace the following throughout:

- `IDP_ISSUER_URL`, `IDP_CLIENT_ID`: your `idpIssuerURL` and `idpClientID` inputs.
- `CLIENT_SECRET_FILE`: a file holding the client's secret.
- `TENANT_USER`, `TENANT_PASSWORD_FILE`: the tenant user and a file holding their password.
- `MAAS_HOST`: the ingress site's MaaS hostname, `PREFIX.apps.CLUSTER_DOMAIN`.
- `SUBSCRIPTION_ID`, `OTHER_SUBSCRIPTION`: the subscription you created, and one that doesn't include the model.
- `KEY_NAME`: a name for the API key. `KEY_ID`: the key's `id` from step 5.
- `OTHER_MODEL`: a deployed model that `SUBSCRIPTION_ID` doesn't cover. With only one model, skip that call.

## 7. Delete what you created (optional)

In each list, open the row's menu and click **Delete**, then type the name to confirm. Delete in this order:

1. The subscription. Its authorization policy is deleted with it.
2. The model. It's removed from every site it runs on.
3. The organization, with its identity provider configuration.

Each delete is a commit to your catalog repository (the organization lives in Keycloak). On the site, a model takes
about 9 minutes to go: its ExternalModel waits on the finalizer `inference.opendatahub.io/external-model-cleanup` until
the model's pods end ([troubleshooting](10-troubleshooting.md#a-deleted-model-stays-on-the-site-for-several-minutes)).

## Checkpoint

- A tenant's chat call returns `200` with an `x-grid-site` header.
- Calls without a token get `401`, and calls under the wrong subscription get `403`.
- An API key reaches only its subscription's models, and a revoked key gets `403`.
