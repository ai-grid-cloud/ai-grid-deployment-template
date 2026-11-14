# First use: deploy a model and call it

In this section you create an organization, deploy a model to the site, subscribe the organization's users to it,
and call it as a tenant. The provider console writes the model and subscription to your catalog repository, and Argo
CD delivers them to the site.

Steps 2 to 4 use the console. To script them instead, take the JSON bodies from
[call the console's API](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/ee0eb3755609a93ff305ea3e1278bee8c96301f3/docs/install/hub/05-console-and-model-delivery.md#call-the-consoles-api)
and send them with this repository's `scripts/console-call.sh METHOD 'JSON'`, which signs in with your hub login; its
flags differ from the library script's of the same name.

## 1. Sign in to the console

1. Open `https://CONSOLE_HOST` (from [install the hub components](04-hub-components.md#2-verify)) and sign in as a
   user with `cluster-admin` on the hub.

   You should see the **AI Grid** page, with your user name followed by `(provider admin)`.

2. Click **Clusters**. You should see your site with AI Grid status **Provisioned**, its role and its location. The
   hub (`local-cluster`) shows **Not added**, which is expected.

The **Monitoring** page shows the hub's dashboards. If it can't load them, see
[troubleshooting](troubleshooting.md#the-monitoring-page-cant-load-dashboards).

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
   - **Hardware**: **CPU only**. It fills in the **Runtime image**
     `registry.redhat.io/rhaii/vllm-cpu-rhel9@sha256:0ec0f5ff9a5ff263f58db0cfb19e3d7eef24b94c2d8629fe5145f5a8747e28c9`,
     **CPU** `4` and **Memory** `8Gi`, and sets `OMP_NUM_THREADS=4` and `VLLM_CPU_KVCACHE_SPACE=4`. Keep them.

   Click **Next**.
4. In **Clusters**, pick your site. Click **Next**.
5. In **Review**, click **Deploy**.

You should see the model in the **Models** list with status **Saved to Git**, and about 5 minutes later
**Ready** and **Available**.

## 4. Subscribe the organization

1. Go to **Subscriptions** and click **Create subscription**.
2. Enter the **Name**, such as `smollm2-users`, and pick the **Organization**.
3. In **Groups**, type `ai-grid-users` and pick **Add group "ai-grid-users"**.
4. Click **Add models**, tick the model, and click **Add models**.
5. Click **Add token limit**, keep the defaults (`1000` per `1` `hour`), and click **Save**.
6. Click **Create subscription**.

You should see the subscription with status **Pending**, and **Active** within about 5 minutes. For the first few
minutes, while the site's ExtProc starts, the subscription can show **Failed** and the model a message that it's
waiting for the tenant ExtProc Deployment; both clear by themselves.

## 5. Check the delivery

```sh
make site-status
```

Under `Models, subscriptions and auth policies` you should see the model `Ready`, and the subscription and its auth
policy. With several sites, add `SITE=SITE_NAME`. If they don't appear within a few
minutes, see [troubleshooting](troubleshooting.md#a-models-catalog-applications-dont-appear).

## 6. Call the model as a tenant

1. Create a test user in the organization, in group `ai-grid-users`. The script generates the password into a file:

   ```sh
   make tenant-user ORG=ORG_NAME TENANT_USER=TENANT_USER PASSWORD_FILE=TENANT_PASSWORD_FILE
   ```

   Replace `ORG_NAME` with the organization's name, `TENANT_USER` with a user name, and `TENANT_PASSWORD_FILE` with
   a path outside any repository.

2. Call the model as that user, and see which site served it:

   ```sh
   make tenant-call TENANT_USER=TENANT_USER PASSWORD_FILE=TENANT_PASSWORD_FILE SUBSCRIPTION=SUBSCRIPTION_ID \
     MODEL=MODEL_NAME
   ```

   Replace `SUBSCRIPTION_ID` with the subscription you created, and `MODEL_NAME` with the model's resource name. It
   gets the user's token from your tenant Keycloak (the `idpIssuerURL` in `root/inputs.env`), calls the site's MaaS
   hostname, and prints no password or token. You should see a short reply, `HTTP 200` and `x-grid-site: SITE`.

Tenants normally call with an API key, and create keys in the Org UI at `https://maas.SITE_APPS_DOMAIN/maas-portal`.
For API keys, refusal checks and revoking a key, see [tenant access](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/ee0eb3755609a93ff305ea3e1278bee8c96301f3/docs/install/tenant-access.md). To remove what you created,
see [operate](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/ee0eb3755609a93ff305ea3e1278bee8c96301f3/docs/install/operate.md#remove-a-subscription-model-or-organization).

## Checkpoint

- The model is **Ready** and the subscription **Active** in the console.
- A tenant's chat call returns a reply with an `x-grid-site` header.

To add more sites, repeat [5. Prepare the site](05-prepare-site.md) and
[6. Join the site to the grid](06-join-grid.md) for each. Back to the [install guide](README.md).
