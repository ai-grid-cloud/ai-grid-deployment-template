# Install with one command

At the end of this page, `make install` has installed the hub and imported every site into ACM, with no prompt and no
browser, and has written the endpoints a test suite needs to `.install/outputs.json`.

You came here from the README and already created your deployment repository from the template.

## Before you start

You need the following. In step 9, `make prereqs` checks the clusters and logins for you; it doesn't check the
worker nodes or the network.

- [ ] **A hub and one or more sites on OpenShift 4.21 or later,** with nothing of AI Grid on them, and a
  `cluster-admin` login and the API URL for each.
- [ ] **A role for each site:** `combined` (tenants enter and models run), `ingress` (tenants enter, no models) or
  `inference` (models only). At least one site is `ingress` or `combined`.
- [ ] **A default StorageClass on each cluster.**
- [ ] **Two worker nodes on each cluster** for Submariner's gateways. On a compact cluster or single-node OpenShift,
  you label the gateway nodes by hand, as [site networking](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/b96c26578e893a5094b424b0ae55b15a8590c7b7/docs/install/spokes/networking.md) describes.
- [ ] **Network:** each cluster has a load-balancer provider for Submariner's LoadBalancer Service, each cluster
  reaches the other clusters' load balancers on UDP 4500 and 4490, and every router name answers `AAAA` queries
  without `NXDOMAIN`.
- [ ] **On each `ingress` or `combined` site, a cert-manager ClusterIssuer that issues publicly trusted certificates
  by DNS-01,** for the site's MaaS certificate. If a site has none, add one, or give the site the role `inference`.
- [ ] **A `quay.io/rhoai` login** in a container auth file. This template installs a pre-release OpenShift AI 3.6
  build from `quay.io/rhoai`; Red Hat gives `quay.io/rhoai` robot tokens to early-access partners, so ask your Red Hat
  contact.
- [ ] **Tools:** `oc`, `kubectl`, `git`, `jq`, `curl`, `openssl`, `base64`, `python3`, `clusteradm` and `make`.

## Install

### Create the repositories and tokens

The install writes to two GitHub repositories and needs a token for each.

1. Create your catalog repository. The provider console writes your models and subscriptions there.
   [Create a new repository](https://github.com/new), name it, such as `ai-grid-catalog`, make it public, and turn
   on **Add README**. With the GitHub CLI instead:

   ```sh
   gh repo create OWNER/CATALOG_REPO --add-readme --public
   ```

   Leave it holding nothing but its README: `make install` stops if it holds anything else.

2. Create the catalog token.
   [Create a fine-grained token](https://github.com/settings/personal-access-tokens/new), named such as
   `ai-grid-catalog`. If an organization owns the repository, set **Resource owner** to that organization. Under
   **Repository access**, select **Only select repositories** and your catalog repository. Under **Permissions**,
   click **Add permissions** > **Contents**, and set it to **Read and write**. Leave every other
   permission off. Click **Generate token**, and keep the token for step 6.

   When this token expires, the console can't save models or subscriptions until you replace it.

3. Create the deployment token. Create a second fine-grained token the same way, named such as
   `ai-grid-deployment`, with **Contents** set to **Read and write** on your deployment repository only. Keep it for
   step 6. `make install` pushes your settings and the sites' files with it.

### Set up your deployment repository

Tell the install which clusters to use and where its credentials are.

4. Clone your deployment repository by its HTTPS URL, because `make install` pushes with the token, not with SSH:

   ```sh
   git clone https://github.com/OWNER/DEPLOYMENT_REPO.git deployment && cd deployment
   ```

   Replace `OWNER/DEPLOYMENT_REPO` with your deployment repository. Run every later command from the `deployment`
   directory, on branch `main`.

5. Write `clusters.yaml`. Copy the example file:

   ```sh
   cp clusters-example.yaml clusters.yaml
   ```

   Replace each `REQUIRED-` value, and add a block for each site. Keep the hub's name, `hub`. A site's name is a DNS
   label; it becomes the site's ACM cluster name, and you can't change it once the site is imported. For example:

   ```yaml
   apiVersion: ai-grid.dev/v1alpha1
   kind: Clusters
   hub:
     name: hub
     api: https://api.hub.example.com:6443
   sites:
     - name: site-east-1
       role: combined
       location: us-east
       api: https://api.site-east-1.example.com:6443
     - name: site-east-2
       role: inference
       location: us-east
       api: https://api.site-east-2.example.com:6443
   ```

6. Put the logins and tokens in `.config/`, which git ignores. Create the directory, readable only by you:

   ```sh
   mkdir -p .config && chmod 700 .config
   ```

   Then create these files. `NAME` is a cluster's name in `clusters.yaml`, such as `hub` or `site-east-1`.

   | File | What it holds |
   |---|---|
   | `.config/NAME/token` | A `cluster-admin` token for the cluster, such as the output of `oc whoami -t`. One per cluster. Such a token usually expires in about 24 hours; for a rerun the next day, use a kubeconfig instead (see **Other options**). |
   | `.config/deployment-token` | The deployment token from step 3. |
   | `.config/catalog-token` | The catalog token from step 2. |
   | `.config/quay-auth.json` | A container auth file with your `quay.io/rhoai` login. |

   To write a token file without showing the token, run the following, paste the token when it asks, and press
   Enter:

   ```sh
   mkdir -p .config/NAME && (umask 077 && printf 'Paste the token: ' && read -rs t && printf '%s' "$t" > .config/NAME/token && echo)
   ```

   Replace `NAME` with the cluster's name, and run it once for each cluster. For the repository tokens, replace
   `.config/NAME/token` with `.config/deployment-token`, then with `.config/catalog-token`.

   To write the auth file with your `quay.io/rhoai` robot token, run the following and enter the robot account's
   name and token when it asks:

   ```sh
   podman login --authfile .config/quay-auth.json quay.io/rhoai
   ```

   If you have a general `quay.io` login instead, log in to `quay.io` the same way and set `ALLOW_GENERIC_LOGIN=1` in
   `install.env`.

7. Set `install.env`. Copy the example file:

   ```sh
   cp install-example.env install.env
   ```

   In `install.env`, set `CATALOG_REPO_URL` to your catalog repository's URL, such as
   `https://github.com/my-org/ai-grid-catalog.git`. Leave the other values: their defaults match the file names in
   step 6, and `LIBRARY_REVISION=deployment-template` follows the library branch this template is tested against.
   `install.env` holds no secrets. A setting `make install` doesn't know, or a value still starting with `REQUIRED-`,
   stops it before it touches a cluster.

### Check the prerequisites

Confirm that every cluster and credential is ready before anything is installed.

8. Log in to each cluster:

   ```sh
   make login NONINTERACTIVE=1
   ```

   It writes `.config/NAME/kubeconfig` for each cluster from its token in `.config/NAME/token` and the API URL in
   `clusters.yaml`, and keeps a kubeconfig that already works. For each cluster it prints `Logged in to NAME as USER.`
   or `NAME: already logged in.` If it names a token file instead, put the cluster's token there and run it again.

9. Check the prerequisites:

   ```sh
   make prereqs
   ```

   It prints one line per check, starting with `ok`, `MISSING`, `OLD`, `FAIL` or `skipped`. It checks the tools, the
   `quay.io/rhoai` login in `QUAY_AUTH_FILE`, the catalog token in `CATALOG_TOKEN_FILE`, and, for each cluster in
   `clusters.yaml`, that it's reachable, runs OpenShift 4.21 or later, has a default StorageClass and gives you
   `cluster-admin`, and that each `ingress` or `combined` site has a DNS-01 ClusterIssuer. It changes nothing.

   Fix each `MISSING`, `OLD` or `FAIL` line, then run it again. When everything is ready, its last line counts only
   `ok` lines, with no `Nothing was changed; fix these` line after it, such as:

   ```text
   42 ok
   ```

   If a site had an earlier install, also run `make site-check SITE=SITE_NAME`. It also looks for a previous AI Grid
   install and checks that the site's apps domain resolves.

### Run the install

Run the install and confirm the end state.

10. Commit your two files:

    ```sh
    git add clusters.yaml install.env && git commit -m "deployment: our clusters and install settings"
    ```

    `make install` pushes this commit with its own.

11. Run the install:

    ```sh
    make install
    ```

    On new clusters it takes about 75 minutes; waiting for the hub's Applications takes about 55 of them. It prints
    `== STEP` as each step starts, and ends with:

    ```text
    Installed. Outputs: .install/outputs.json
    ```

    If it stops instead, see [If it stops](#if-it-stops).

12. Check the end state, without changing anything:

    ```sh
    make ready-check
    ```

    It prints one `OK`, `WARN` or `FAIL` line per check, and ends with:

    ```text
    Ready. Outputs: .install/outputs.json
    ```

    A `WARN` line lists the hub Applications that wait for a site to join the grid. They turn healthy after you add
    the first site.

You now have:

- the hub, installed: ACM, Argo CD, Keycloak, the MaaS database, the provider console and monitoring;
- every site imported into the hub's ACM and available, but **not in the grid**: no `ai-grid/` or `location` label
  and no OpenShift AI on it;
- no organizations, models or subscriptions.

## If it stops

When a step fails, `make install` prints why, then stops with a line like the following:

```text
make install stopped at hub-apps. Fix the cause, then run make install again.
```

- If the line names a readiness check, such as `hub-apps` or `site-site-east-1-import`, the evidence is above it and in
  `.install/report.txt`: `make status`, `make site-status` for a site, and the conditions of whatever isn't ready.
- If the line names a step, the step's own error is above it.
- If it stopped at `ready`, the ready check's last output is in `.install/ready-check.txt`.

`.install/report.txt` can quote your manifests: read it before you share it.

Fix the cause, then run `make install` again. Every step first checks whether its work is done and skips it if so,
so the install picks up where it stopped. On a finished install, a second run changes nothing on the clusters except
a fresh provider-admin token, and passes the ready check again, but only before your tests start. Once a test adds a
site to the grid or creates an organization, model or subscription, the `catalog` step and the ready check's label
and content checks fail by design.

## What the install does

Each step prints `== STEP` as it starts:

1. `login`: writes `.config/NAME/kubeconfig` for each cluster from its token and the API URL in `clusters.yaml`.
2. `inputs`: pins the library at `LIBRARY_REVISION`, writes your names to `root/inputs.env`, and pushes.
3. `catalog`: checks that your catalog repository holds only its README.
4. `bootstrap`: installs OpenShift GitOps and applies your root on the hub, then waits until Argo CD has synced it.
5. `acm`: waits until ACM is running.
6. `console-secrets`: creates the provider console's Secrets from your catalog token.
7. `hub-apps`: waits until every hub Application is `Synced` and `Healthy`, except those that wait for a site.
8. `site-files`: writes the values and MaaS certificate files of each `ingress` or `combined` site, and pushes.
9. `site NAME`: for each site, checks it and imports it into ACM, then waits until it's available.
10. `provider-admin`: creates the provider-admin ServiceAccount and its token.
11. `ready`: runs the ready check until it passes, which writes `.install/outputs.json`.

## Outputs and the provider-admin token

`.install/outputs.json`, which git ignores, has these keys:

| Key | Value |
|---|---|
| `hub.name`, `hub.api` | The hub's name in `clusters.yaml` and its API URL |
| `hub.consoleURL` | The provider console |
| `hub.keycloakURL`, `hub.keycloakRealm` | The tenant Keycloak and its realm, `tenants` |
| `hub.persesURL` | Perses's in-cluster URL; it isn't reachable from outside the hub |
| `hub.thanosURL` | The Thanos query Route |
| `hub.lokiStack` | The usage-log LokiStack, `redhat-ods-monitoring/usage-logs` |
| `providerAdminTokenFile` | The path of the provider-admin token file, never the token |
| `library.url`, `library.revision` | The library and the commit you pin |
| `sites[]` | For each site: `name`, `role`, `location`, `api`, `appsDomain`, and `acmName`, its ManagedCluster's name |

The provider-admin token is in `.config/provider-admin-token`. It belongs to ServiceAccount
`ai-grid-test/provider-admin`, which is bound to the console's ClusterRole `ai-grid-provider-admin`, so a test suite
can call the console's API with no browser. Send it as an `Authorization: Bearer` header from a file, never on a
command line. It lasts 168 hours. To get a new one, run `make provider-admin`.

## Add a site to the grid

`make install` leaves each site imported but outside the grid, with the files an `ingress` or `combined` site needs
already pushed. To add a site, do one of the following:

- In the provider console, click **Clusters**, and add the site to AI Grid with its role.
- From your deployment repository, label the site with the role and location from `clusters.yaml`:

  ```sh
  make site-join SITE=SITE_NAME
  ```

The hub then installs OpenShift AI, MaaS and the grid on the site. To follow it, run
`make site-status SITE=SITE_NAME`.

## Other options

- **A CI job:** everything `make install` reads is a file in your deployment repository or under `.config/`, so a CI
  job supplies the same files.
- **A kubeconfig instead of a token:** put a working kubeconfig, such as the installer's `auth/kubeconfig`, in
  `.config/NAME/kubeconfig`. `make install` keeps a kubeconfig that works.
- **An untrusted API certificate:** put the CA of the cluster's API in `.config/NAME/ca.crt`.
- **A token from the environment:** instead of `.config/NAME/token`, set `AI_GRID_TOKEN_NAME`, the cluster's name
  upper-cased with `-` turned into `_`, such as `AI_GRID_TOKEN_SITE_B`.
- **A general `quay.io` login:** set `ALLOW_GENERIC_LOGIN=1` in `install.env` when your auth file has a `quay.io`
  login but no `quay.io/rhoai` entry.
- **Several DNS-01 issuers on a site:** set `SITE_ISSUER_SITE_NAME` in `install.env`, the site's name upper-cased with
  `-` turned into `_`, such as `SITE_ISSUER_SITE_B=letsencrypt-dns`.
- **Another library revision:** set `LIBRARY_REVISION` in `install.env` to a branch, tag or commit, or leave it empty
  to keep the template's own commit pin.
- **Another token lifetime:** set `PROVIDER_ADMIN_TOKEN_DURATION` in `install.env` for `make install`, or in the
  environment for `make provider-admin`.
- **Another catalog token file for the console:** if the environment variable `AI_GRID_GIT_TOKEN_FILE` is set, the
  console's Secrets use the file it names instead of `CATALOG_TOKEN_FILE`.
- **Longer or shorter waits:** each `GATE_*_SECONDS` value in `install.env` sets a readiness check's time limit, in
  seconds. The hub's Applications get 90 minutes (`GATE_HUB_APPS_SECONDS=5400`).
- **The hub alone,** without the sites, the provider-admin token or the ready check:

  ```sh
  scripts/install.sh --hub-only
  ```

## Known limits

- An `ingress` or `combined` site needs a DNS-01 ClusterIssuer that issues publicly trusted certificates. Supplying
  a certificate another way is a later option.
- `make install` always installs its own Keycloak. Using an existing one, with `KEYCLOAK` in `install.env`, comes
  later; any value but `install` stops the install.
- Starting over means new clusters, and new deployment and catalog repositories. `make install` doesn't uninstall;
  to remove AI Grid from clusters, see [Uninstall](08-uninstall.md).
