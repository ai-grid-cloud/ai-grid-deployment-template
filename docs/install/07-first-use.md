# First use: deploy a model and call it

In this section you create an organization, deploy a model to the site, subscribe the organization's users to it,
and call it as a tenant. The provider console writes the model and subscription to your catalog repository, and Argo
CD delivers them to the site. To script these steps instead, see
[call the console's API](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/05-console-and-model-delivery.md#call-the-consoles-api).

## 1. Sign in to the console

1. Open `https://CONSOLE_HOST` (from [install the hub components](04-hub-components.md#3-verify)), choose `htpasswd`,
   and sign in as `admin`.

   You should see the **AI Grid** page, with your user shown as `admin (provider admin)`.

2. Click **Clusters**. You should see your site with AI Grid status **Provisioned**, its role and its location. The
   hub (`local-cluster`) shows **Not added**, which is expected.

The **Monitoring** page shows no dashboards, because observability isn't selected
([troubleshooting](troubleshooting.md#the-monitoring-page-cant-load-dashboards)).

## 2. Create an organization

1. Go to **Organizations** and click **Create organization**.
2. In **Organization details**, enter the **Name**. Click **Add domain** and enter the organization's email domain in
   **Domain 1**. Click **Next**.
3. In **Identity provider**, leave every field empty, and click **Next**. The organization's users then sign in with
   accounts in your tenant Keycloak.
4. In **Review**, click **Create organization**.

You should see the organization in the **Organizations** list.

## 3. Deploy a model

Use a chat model: a model without a chat template, such as OPT-125m, answers `400`.

1. Go to **Models** and click **Deploy model**.
2. In **Source**, enter the **Model URI** `hf://HuggingFaceTB/SmolLM2-135M-Instruct`. Click **Next**.
3. In **Deployment**, keep the **Model name** the wizard fills in from the URI, and note the resource name shown
   under it as `MODEL_NAME`: tenants send it as `model`. Set:
   - **Hardware**: **CPU only**.
   - **Runtime image**:
     `registry.redhat.io/rhaii/vllm-cpu-rhel9@sha256:0ec0f5ff9a5ff263f58db0cfb19e3d7eef24b94c2d8629fe5145f5a8747e28c9`.
   - **CPU**: `4`. **Memory**: `8Gi`.

   Click **Next**.
4. In **Clusters**, pick your site. Click **Next**.
5. In **Review**, click **Deploy**.

You should see the model in the **Models** list with status **Saved to Git**, and about 5 to 7 minutes later
**Ready** and **Available**.

## 4. Subscribe the organization

1. Go to **Subscriptions** and click **Create subscription**.
2. Enter the **Name**, such as `smollm2-users`, and pick the **Organization**.
3. In **Groups**, type `ai-grid-users` and pick **Add group "ai-grid-users"**.
4. Click **Add models**, tick the model, and click **Add models**.
5. Click **Add token limit**, keep the defaults (`1000` per `1` `hour`), and click **Save**.
6. Click **Create subscription**.

You should see the subscription with status **Pending**, and **Active** about 5 minutes later.

## 5. Check the delivery

```sh
oc --context "$SITE_CONTEXT" get llminferenceservices,maassubscriptions,maasauthpolicies -A
```

You should see the model `Ready`, and the subscription and its auth policy. If they don't appear within a few
minutes, see [troubleshooting](troubleshooting.md#a-models-catalog-applications-dont-appear).

## 6. Call the model as a tenant

1. Create a test user in the organization, in group `ai-grid-users`. The script generates the password into a file:

   ```sh
   scripts/create-test-tenant.sh --kubeconfig "$HUB_KUBECONFIG" --org ORG_NAME --user TENANT_USER \
     --password-file TENANT_PASSWORD_FILE
   ```

   Replace `ORG_NAME` with the organization's name, `TENANT_USER` with a user name, and `TENANT_PASSWORD_FILE` with
   a path outside any repository.

2. Get the user's access token. The client secret and password stay in files:

   ```sh
   T=$(mktemp -d); (umask 077
   oc --context "$HUB_CONTEXT" get secret tenant-idp-client -n tenant-idp-client \
     -o jsonpath='{.data.client-secret}' | base64 -d > "$T/client-secret"
   curl -sS "IDP_ISSUER_URL/protocol/openid-connect/token" \
     --data-urlencode grant_type=password --data-urlencode client_id=ai-grid-tenants \
     --data-urlencode client_secret@"$T/client-secret" --data-urlencode username=TENANT_USER \
     --data-urlencode password@TENANT_PASSWORD_FILE --data-urlencode scope=openid \
     | jq -r '"Authorization: Bearer " + .access_token' > "$T/auth")
   ```

   Replace `IDP_ISSUER_URL` with your `idpIssuerURL`.

3. Call the model, and see which site served it:

   ```sh
   curl -sS -D "$T/h" -H @"$T/auth" -H 'X-MaaS-Subscription: SUBSCRIPTION_ID' -H 'Content-Type: application/json' \
     -d '{"model":"MODEL_NAME","messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":20}' \
     "https://maas.$APPS_DOMAIN/v1/chat/completions" | jq -r '.choices[0].message.content'
   grep -i '^x-grid-site' "$T/h"
   ```

   Replace `SUBSCRIPTION_ID` with the subscription you created, and `MODEL_NAME` with the model's resource name. You
   should see a short reply and `x-grid-site: SITE`.

Tenants normally call with an API key, and create keys in the Org UI at `https://maas.SITE_APPS_DOMAIN/maas-portal`.
For API keys, refusal checks and revoking a key, see [tenant access](tenant-access.md). To remove what you created,
see [operate](operate.md#remove-a-subscription-model-or-organization).

## Checkpoint

- The model is **Ready** and the subscription **Active** in the console.
- A tenant's chat call returns a reply with an `x-grid-site` header.
