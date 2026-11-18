# First use: deploy a model and call it

In this section you create an organization, deploy a model to the site, subscribe the organization's users to it,
and call it as a tenant. The provider console writes the model and subscription to your catalog repository, and Argo
CD delivers them to the site.

Steps 2 to 4 use the console. To script them instead, send each request with
`make console-call METHOD=METHOD BODY='JSON'`, which signs in with your hub login, such as
`make console-call METHOD=ai_grid.v1.Tenants/List BODY='{}'`. For a body on several lines, or one that contains a
`$`, save it to a file and pass `BODY_FILE=FILE` instead of `BODY`.

## 1. Sign in to the console

1. Open `https://CONSOLE_HOST` (from [install the hub components](04-hub-components.md#2-verify)) and sign in as a
   user with `cluster-admin` on the hub.

   You should see the **AI Grid** page, with your user name followed by `(provider admin)`.

2. Click **Clusters**. You should see your site with AI Grid status **Provisioned**, its role and its location. The
   hub (`local-cluster`) shows **Not added**, which is expected.

The **Monitoring** page shows the hub's dashboards. If it can't load them, see
[troubleshooting](troubleshooting.md#the-monitoring-page-cant-load-dashboards).

## 2. Create an organization

What you do here depends on `keycloakOverlay` in `root/inputs.env`
([set your names](02-repositories.md#4-set-your-names)):

- **`core`:** create an organization and link its own identity provider. Its users sign in there.
- **`default`, on a test deployment:** the library's example organizations `grid-tenant-1` and `grid-tenant-2`
  already exist, with test users. Skip to [3. Deploy a model](#3-deploy-a-model) and use `grid-tenant-1`.

If you switched from `core` to `default` after the hub was installed, the example organizations aren't there until
you [re-import realm `saas`](troubleshooting.md#example-organizations-are-missing-after-switching-keycloakoverlay-to-default).

To create an organization:

1. Go to **Organizations** and click **Create organization**.
2. In **Organization details**, enter the **Name**, and enter the organization's email domain in **Domain 1**. Click
   **Next**.
3. In **Identity provider**, enter the organization's identity provider, as the library's
   [organization identity providers](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/organization-identity-providers/README.md) page describes. Its users
   sign in there, and Keycloak brokers the sign-in. Click **Next**.
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

1. Choose a tenant user in group `ai-grid-users`:

   - **`core`:** a user of the organization's identity provider, in its group `ai-grid-users`.
   - **`default`, on a test deployment:** `alice` of `grid-tenant-1`. Her password is the key
     `GRID_TENANT_1_TEST_USER_PASSWORD` of Secret `maas-db/keycloak-secrets` on the hub. To save it to a file in a
     directory only you can read, without printing it:

     ```sh
     (umask 077 && mkdir -p ~/.ai-grid/alice && scripts/with-cluster.sh hub oc extract secret/keycloak-secrets \
       -n maas-db --keys=GRID_TENANT_1_TEST_USER_PASSWORD --to=$HOME/.ai-grid/alice)
     ```

     The library lists its test users in
     [example tenant identity providers](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/apps/keycloak/README.md#example-tenant-identity-providers).

2. As that user, open the Org UI at `https://maas.SITE_APPS_DOMAIN/maas-portal` and sign in. Keycloak sends you to
   the organization's identity provider. Your browser warns about the site's certificate, which is the cluster's
   internal one ([limits of `main`](../upstream-main-limits.md#l5-the-maas-gateway-presents-the-cluster-internal-certificate)).
   If every Org UI page fails with an error, see
   [troubleshooting](troubleshooting.md#the-org-ui-fails-on-every-page-on-a-new-site).

3. In the Org UI, create an API key. Save it to a file outside any repository that only you can read, and that holds
   the key and nothing else:

   ```sh
   (umask 077 && mkdir -p "$HOME/.ai-grid" && printf 'Paste the API key: ' && read -rs k && printf '%s' "$k" > "$HOME/.ai-grid/api-key" && echo)
   ```

4. Call the model with the key, and see which site served it:

   ```sh
   make tenant-call KEY_FILE="$HOME/.ai-grid/api-key" MODEL=MODEL_NAME SUBSCRIPTION=SUBSCRIPTION_ID
   ```

   Replace `MODEL_NAME` with the model's resource name. `SUBSCRIPTION` is optional: set it to the subscription you
   created when the user is in several. With several sites, add `SITE=SITE_NAME` for the ingress or combined site to
   call. It calls `https://maas.SITE_APPS_DOMAIN/v1/chat/completions` and prints no key. You should see a short
   reply, `HTTP 200` and `x-grid-site: SITE`.

   > **Note:** The site's MaaS gateway presents the cluster's internal certificate, which `curl` doesn't trust
   > unless your system already trusts the cluster's service CA. Then `make tenant-call` stops with a message that
   > the certificate isn't trusted, and names this limit
   > ([limits of `main`](../upstream-main-limits.md#l5-the-maas-gateway-presents-the-cluster-internal-certificate)).

To remove what you created, delete the subscription, then the model, then the organization in the console. Deleting
a subscription doesn't revoke its API keys: revoke them in the Org UI first.

## Checkpoint

- The model is **Ready** and the subscription **Active** in the console.
- A tenant's chat call with an Org UI API key returns a reply with an `x-grid-site` header, or `make tenant-call`
  names the internal-certificate limit.

To add more sites, repeat [5. Prepare the site](05-prepare-site.md) and
[6. Join the site to the grid](06-join-grid.md) for each. Back to the [install guide](README.md).
