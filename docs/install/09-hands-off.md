# Install with one command

At the end of this page, `make install` has installed the hub and imported every site into ACM, with no prompt and no
browser, and has written the endpoints a test suite needs to `.install/outputs.json`.

You came here from the README and already created your deployment repository from the template.

## Before you start

You need the following. In step 6, `make prereqs` checks the clusters and logins for you; it doesn't check the
worker nodes or the network.

- [ ] **A hub and one or more sites on OpenShift 4.21 or later,** with nothing of AI Grid on them, and the API URL
  and a `cluster-admin` login for each: a token, or a username and password. For a test, one cluster can be both
  ([All-in-one: one cluster](#all-in-one-one-cluster)).
- [ ] **A role in mind for each site:** `combined` (tenants enter and models run), `ingress` (tenants enter, no
  models) or `inference` (models only). At least one site is `ingress` or `combined`. You choose each site's role
  and location after the install, when you add it to the grid in the provider console; `.config/clusters.yaml` has
  neither.
- [ ] **A default StorageClass on each cluster.**
- [ ] **No platform cert-manager Operator on a site.** A site whose namespace `cert-manager-operator` has an
  OperatorGroup other than `openshift-cert-manager-operator` can't join the grid yet: the install's `site` step stops
  on it ([limits of `main`](../upstream-main-limits.md#l4-sites-that-need-per-site-values)).
- [ ] **Two worker nodes outside the control plane on each cluster** for Submariner's gateways. The install labels two
  of them `submariner.io/gateway=true` on the hub and on each site, preferring nodes without GPUs
  ([limits of `main`, L21](../upstream-main-limits.md#l21-nothing-labels-the-submariner-gateway-nodes)). On a compact
  cluster or single-node OpenShift it stops and prints the `oc label node` command to run, as the library's
  [site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide) describe.
- [ ] **Network:** each cluster has a load-balancer provider for Submariner's LoadBalancer Service, each cluster
  reaches the other clusters' load balancers on UDP 4500 and 4490, and every router name answers `AAAA` queries
  without `NXDOMAIN`.
- [ ] **A `quay.io/rhoai` robot account:** its username and password. This template installs a pre-release
  OpenShift AI 3.6 build from `quay.io/rhoai`; Red Hat gives `quay.io/rhoai` robot accounts to early-access partners,
  so ask your Red Hat contact.
- [ ] **A `registry.stage.redhat.io` login:** its username and password. Sites pull model runtime images only from
  there ([limits of `main`, L20](../upstream-main-limits.md#l20-model-runtimes-pull-only-from-registrystageredhatio)).
- [ ] **Tools:** `oc`, `kubectl`, `git`, `jq`, `curl`, `openssl`, `base64`, `python3`, `clusteradm` and `make`. Get
  `clusteradm` from its [releases page](https://github.com/open-cluster-management-io/clusteradm/releases).

## Install

### Set up your repositories

Clone your deployment repository, and create the catalog repository and its token. The provider console writes
your models and subscriptions to the catalog repository, with a token that can write that repository and no other.

1. Clone your deployment repository, by its HTTPS or SSH URL:

   ```sh
   git clone https://github.com/OWNER/DEPLOYMENT_REPO.git && cd DEPLOYMENT_REPO
   ```

   Replace `OWNER/DEPLOYMENT_REPO` with your deployment repository. Run every later command from the
   `DEPLOYMENT_REPO` directory, on branch `main`. `make install` pushes to this repository with your own git login,
   the one this clone uses; `make prereqs` checks that it can push without a prompt.

2. Create your catalog repository:

   1. Open [Create a new repository](https://github.com/new).
   2. Fill in the form:
      - **Owner:** your account, or the organization that will own the repository
      - **Repository name:** such as `ai-grid-catalog`
      - **Choose visibility:** **Public**
      - **Add README:** **On**
      - **Everything else:** leave it as it is: no template, no `.gitignore` and no license
   3. Click **Create repository**.

   <img src="images/new-catalog-repository.png" width="420" alt="The new repository form with Add README on">

   With the GitHub CLI instead:

   ```sh
   gh repo create OWNER/CATALOG_REPO --add-readme --public
   ```

   Leave it holding nothing but its README: `make install` stops if it holds anything else.

3. Create the catalog token:

   1. Open [New fine-grained personal access token](https://github.com/settings/personal-access-tokens/new). You can
      also reach it from your profile picture: **Settings** > **Developer settings** > **Personal access tokens** >
      **Fine-grained tokens** > **Generate new token**.
   2. Fill in the form:
      - **Token name:** `ai-grid-catalog`
      - **Expiration:** **90 days**, or a later **Custom** date if your organization allows one. When it expires,
        the console can't save models or subscriptions until you replace it, so note the date.
      - **Description:** optional, such as `AI Grid console writes the catalog`
      - **Resource owner:** your account, or the organization that owns your catalog repository. If that
        organization requires approval for fine-grained tokens, the token can only read until an organization owner
        approves it.
      - **Repository access:** **Only select repositories**, then open **Select repositories** and choose your
        catalog repository, and only that one.
      - **Permissions:** on the **Repositories** tab, click **Add permissions**, select **Contents**, and set it to
        **Access: Read and write**. GitHub adds **Metadata: Read-only** itself.
      - **Everything else:** no access. Add no other repository permission and no **Account** permission.

      <img src="images/token-repository-access.png" width="480" alt="Repository access set to Only select repositories">

      <img src="images/token-permissions.png" width="480" alt="Contents set to Read and write, and Metadata Read-only">

   3. Click **Generate token** at the bottom of the form.
   4. Copy the token from the page that follows. GitHub shows it only once, so keep it until you put it in
      `.config/clusters.yaml` in step 5.

### Fill in your settings

Tell the install which clusters and repositories to use, and give it the credentials, in one private file.

4. Create `.config/clusters.yaml`, the one file you edit:

   ```sh
   make config
   ```

   It copies `clusters-example.yaml` to `.config/clusters.yaml`, readable only by you, with the secret lines that
   `make install` needs uncommented, and prints `edit it`. If you already have a `clusters.yaml` at the root (from
   pages 1 to 8), it copies that one as it is instead. Git ignores `.config/`, so the file stays on your machine and
   can hold your secrets. It never overwrites a file that's already there.

5. Open `.config/clusters.yaml` in an editor and fill it in. Each field has a comment that says what it is. Replace
   every `REQUIRED-` value: `make prereqs` and `make login` both name each one you leave.

   - **`hub` and `sites`:** replace each `REQUIRED-` value, and add an entry under `sites:` for each site, with
     its `name` and `api`; for an [all-in-one](#all-in-one-one-cluster), write `sites: []`. A site's name is a DNS label; it becomes the site's ACM cluster name, and you can't
     change it once the site is imported. The hub's name is always `hub`. The file says only how to reach each
     cluster: no role and no location. If a cluster's API or apps certificate isn't publicly trusted, such as a
     self-signed one, its entry also needs a `ca:`: see step 6.
   - **`catalog`:** `url` is the URL of the catalog repository you created in step 2, such as
     `https://github.com/my-org/ai-grid-catalog.git`, and `token` is the token from step 3. The token is in
     `catalog.token` in `.config/clusters.yaml`, and nowhere else.
   - **The secrets:** in `hub:` and in each site's entry, fill in a `cluster-admin` `username` and `password`. To use
     a token instead, uncomment `token:`, fill it in, and delete `username:` and `password:`. A cluster token usually
     expires in about 24 hours; with a username and password, the scripts get a fresh token on every run, so a rerun
     the next day works. Fill in `quay:` and `stage:` too. Leave `deployment:` commented: without it,
     `make install` pushes with your own git login.

   For example:

   ```yaml
   apiVersion: ai-grid.dev/v1alpha1
   kind: Clusters
   hub:
     api: https://api.hub.example.com:6443
     username: kubeadmin
     password: PASSWORD
   sites:
     - name: site-east-1
       api: https://api.site-east-1.example.com:6443
       token: sha256~TOKEN
     - name: site-east-2
       api: https://api.site-east-2.example.com:6443
       username: kubeadmin
       password: PASSWORD
   catalog:
     url: https://github.com/my-org/ai-grid-catalog.git
     token: github_pat_TOKEN
   quay:
     username: rhoai+robot
     password: PASSWORD
   stage:
     username: STAGE_USERNAME
     password: PASSWORD
   ```

   A file in the old format, with `credentials:`, `repositories:`, `github:`, a `kubeconfig` key, `hub.name`, or a
   `role` or `location` on a site, stops with a message that says what to change. So does a site's
   `maasCertificate`: on the library's `main` branch a site's MaaS gateway keeps the cluster's internal certificate.

   The tenant portal's sign-in redirects need nothing from you: once you add a site to the grid as `ingress` or
   `combined`, the library's Keycloak registers its redirect, `https://maas.APPS_DOMAIN/oauth2/callback`.

   The install writes `root/inputs.env` with `keycloakOverlay=core`: the tenants' Keycloak has the `saas` broker
   realm only, with no example organizations and no test users. For a test deployment that wants the library's
   example organizations and test users, set `keycloakOverlay=default` in `root/inputs.env`, commit and push it
   before you run `make install`; the install keeps a value that's already set. Never use `default` for a real
   install ([set your names](02-repositories.md#4-set-your-names)).

   It also writes `hubCertManager=library`: the hub installs the library's cert-manager. If the hub already runs
   the platform's cert-manager, set `hubCertManager=platform` the same way; the install stops and says so if you
   don't. Such a hub can't also be a site, so it can't be an
   [all-in-one](#all-in-one-one-cluster).

   Never paste a secret into a chat, a command line or a file you commit.

### Check the prerequisites

Confirm that every cluster and credential is ready before anything is installed.

6. Log in to each cluster, then check the prerequisites:

   ```sh
   make login
   make prereqs
   ```

   If `make login` stops with `self signed certificate in certificate chain`, or another certificate problem, the
   cluster's certificates aren't publicly trusted, which is usual on a new cluster. Fetch its CA, then log in again:

   ```sh
   make fetch-ca NAME=hub
   make login
   ```

   Replace `hub` with the cluster's name. `make fetch-ca` prints the subject, issuer and SHA-256 fingerprint of each
   certificate it fetches. Compare each fingerprint with the one that a cluster admin who already trusts the cluster
   sees, then keep it. For more, see [An untrusted cluster certificate](#an-untrusted-cluster-certificate).

   `make login` writes `.config/NAME/kubeconfig` for each cluster from the cluster's API URL and its credentials in
   `.config/clusters.yaml`. It uses the first of these that it finds:

   1. A working `.config/NAME/kubeconfig`, which it keeps.
   2. The cluster's `token`, in `hub:` or in its entry under `sites:`.
   3. The cluster's `username` and `password`, in the same place.

   Only for a cluster with none of these does it open your browser to log in, with `oc login --web`. For each cluster
   it prints `Logged in to NAME as USER.` or `NAME: already logged in.` If a cluster's login fails, replace its
   credentials as in step 5, then run `make login` again.

   `make prereqs` prints one line per check, starting with `ok`, `MISSING`, `OLD`, `FAIL` or `skipped`. It checks
   the tools, the `quay.io/rhoai` login, the catalog token, how `make install` pushes this repository (with your
   git login, a dry-run push that sends nothing), and, for each cluster in `.config/clusters.yaml`, that it's reachable, runs
   OpenShift 4.21 or later, has a default StorageClass and gives you `cluster-admin`. It changes nothing.

   Fix each `MISSING`, `OLD` or `FAIL` line, then run it again. Everything is ready when it prints no `MISSING`,
   `OLD` or `FAIL` lines.

   If a site had an earlier install, also run `make site-check SITE=SITE_NAME`. It also looks for a previous AI Grid
   install and the platform's cert-manager OperatorGroup, and checks that the site's apps domain resolves.

### Run the install

Run the install and confirm the end state.

7. Run the install:

   ```sh
   make install
   ```

   You don't commit `.config/clusters.yaml`: git ignores it. `make install` commits and pushes the files it
   generates itself, with your git login, or with the deployment token if you set one. On new clusters it takes
   about 75 minutes; waiting for the hub's Applications takes about 55 of them. It prints `== STEP` as each step starts, and ends with:

   ```text
   Installed. Outputs: .install/outputs.json
   ```

   If it stops instead, see [If it stops](#if-it-stops).

8. Check the end state, without changing anything:

   ```sh
   make ready-check
   ```

   It prints one `OK`, `WARN` or `FAIL` line per check, and ends with:

   ```text
   Ready. Outputs: .install/outputs.json
   ```

   A `WARN` line lists the hub Applications that wait for a site to join the grid. They turn healthy after you add
   the first site.
   With `keycloakOverlay=default`, the console lists the library's example organizations, which the check reports
   as an `INFO` line, not a `FAIL`.

You now have:

- the hub, installed: ACM, Argo CD, Keycloak, the MaaS database, the provider console and monitoring;
- every site imported into the hub's ACM and available, but **not in the grid**: no `ai-grid/` or `location` label
  and no OpenShift AI on it;
- no organizations, models or subscriptions.

## All-in-one: one cluster

For a test, one cluster can be both the hub and a `combined` site. It needs everything a hub and a site need,
including no platform cert-manager Operator, so install it with `hubCertManager=library`. The network items about
reaching the other clusters' load balancers don't apply. The Submariner gateway labels are needed only once a second
cluster joins, so on a compact cluster the install warns that it can't label them and continues.

1. In `.config/clusters.yaml`, give the hub's `api` and login, and write `sites: []` with no entries.
2. Run `make install`, not `make install HUB_ONLY=1`: `HUB_ONLY=1` skips the provider-admin token and the ready
   check. With no sites, the install imports nothing, and the ready check reports the hub Applications that wait for a
   site as `WARN`.
3. Before you add the hub to the grid, set `hubCertManager=site` in `root/inputs.env`, commit and push it, and wait
   until `make status` shows `deployment-root` synced. OpenShift AI's chart then takes over the cert-manager the hub
   already runs, instead of two Applications managing it
   ([limits of `main`, L17](../upstream-main-limits.md#l17-the-hubs-cert-manager-is-the-librarys-or-the-platforms-not-both)).
4. Add the hub to the grid: in the provider console, click **Clusters**, then **Add to AI Grid** for
   `local-cluster`, and choose role **combined** and a location.

The hub is `local-cluster` in ACM and in the console. With no site in `clusters.yaml`, `make status`,
`make site-status` and `make tenant-call` use the hub, and `sites[]` in `.install/outputs.json` names the hub with
`acmName` `local-cluster`. `make site-check` and `make site-import` are for separate sites only. Such a hub has no
usage logs, and its Limitador keeps its counters in memory
([limits of `main`, L18](../upstream-main-limits.md#l18-a-hub-that-is-also-a-site-has-no-usage-logs)). Page 6 has
[the same steps](06-join-grid.md#the-hub-as-a-site-all-in-one).

## If it stops

When a step fails, `make install` prints why, then stops with a line like the following:

```text
make install stopped at hub-apps. Fix the cause, then run make install again.
```

- If the line names a readiness check, such as `hub-apps` or `site-site-east-1-import`, the evidence is printed
  before it. `.install/report.txt` holds the same evidence: the output of `make status`, of `make site-status` for a
  site, and the conditions of whatever isn't ready.
- If the line names a step, the step's own error is printed before it.
- If it stopped at `ready`, the ready check's last output is in `.install/ready-check.txt`.

`.install/report.txt` can quote your manifests: read it before you share it. For known problems and their fixes, see
[Troubleshooting](troubleshooting.md).

Fix the cause, then run `make install` again. Every step first checks whether its work is done and skips it if so,
so the install picks up where it stopped. On a finished install, a second run changes nothing on the clusters except
a fresh provider-admin token, and passes the ready check again. A rerun on a hub that already uses your catalog, such
as one that [imports a new site](#import-a-new-site-after-the-install), doesn't check that the catalog is empty, and
its ready check reports sites in the grid, OpenShift AI on a site, and the console's organizations, models and
subscriptions as `INFO`, not `FAIL`, and so are the console's model Applications that aren't `Healthy`, such as a
model still starting on a site. Run on its own, `make ready-check` still fails on them, because it checks the state
before your tests start; `make ready-check IN_USE=1` checks as the rerun does. A rerun after a first install that
stopped after `bootstrap` also counts as one on a hub in use: the catalog was checked empty before the hub first used
it.

## What the install does

Each step prints `== STEP` as it starts. Before the first one, the install turns the secrets into files under
`.config/generated/`, readable only by you, and passes them to its scripts by path: the catalog token, the
deployment token if you set one, and a `quay.io` auth file built from `quay:`, which the `bootstrap` step uses.

1. `login`: writes `.config/NAME/kubeconfig` for each cluster from its credentials and the API URL in
   `.config/clusters.yaml`.
2. `inputs`: sets the library revision to `LIBRARY` under `options:`, if you set it, writes your names to
   `root/inputs.env` and the catalog to `hub/catalog/`, and pushes.
3. `catalog`: checks that your catalog repository holds only its README, unless the hub already uses it.
4. `bootstrap`: installs OpenShift GitOps and applies your root on the hub, then waits until Argo CD has synced it.
5. `acm`: waits until ACM is running.
6. `console-secrets`: creates the provider console's Secrets from your catalog token.
7. `hub-apps`: waits until every hub Application is `Synced` and `Healthy`, except those that wait for a site.
8. `site NAME`: for each site, checks it, imports it into ACM, then waits until it's available. It writes no files
   for the site. A site that runs the platform's cert-manager Operator stops the install here, with a `FOUND` line for
   its `cert-manager OperatorGroup`.
9. `provider-admin`: creates the provider-admin ServiceAccount and its token.
10. `ready`: runs the ready check until it passes, which writes `.install/outputs.json`. On a rerun on a hub that
    already uses your catalog, it runs it with `--in-use`.

## Outputs and the provider-admin token

`.install/outputs.json`, which git ignores, has these keys:

| Key | Value |
|---|---|
| `hub.name`, `hub.api` | The hub's name, `hub`, and its API URL |
| `hub.consoleURL` | The provider console |
| `hub.keycloakURL`, `hub.keycloakRealm` | The tenants' Keycloak, Route `maas-db/keycloak`, and its realm |
| `hub.persesURL` | Perses's in-cluster URL; it isn't reachable from outside the hub |
| `hub.thanosURL` | The Thanos query Route |
| `hub.lokiStack` | The usage-log LokiStack, `redhat-ods-monitoring/usage-logs` |
| `providerAdminTokenFile` | The path of the provider-admin token file, never the token |
| `library.url`, `library.revision`, `library.commit` | The library; the branch you follow or the commit you pin; and the commit that revision was at when the check ran (`null` when the library couldn't be reached) |
| `sites[]` | For each site: `name`, `api`, `appsDomain`, and `acmName`, its ManagedCluster's name. On an [all-in-one](#all-in-one-one-cluster), the hub, with `acmName` `local-cluster` |

The provider-admin token is in `.config/provider-admin-token`. It belongs to ServiceAccount
`ai-grid-test/provider-admin`, which is bound to the console's ClusterRole `ai-grid-provider-admin`, so a test suite
can call the console's API with no browser. Send it as an `Authorization: Bearer` header from a file, never on a
command line. It lasts 168 hours. To get a new one, run `make provider-admin`.

## Add a site to the grid

`make install` leaves each site imported but outside the grid. To add a site, open the provider console
(`hub.consoleURL` in `.install/outputs.json`), click **Clusters**, and click **Add to AI Grid** for the site. Choose
its role and location there. The hub then installs OpenShift AI, MaaS and the grid on the site. To follow it, run
`make site-status SITE=SITE_NAME`. If the Org UI then fails on every page, see
[troubleshooting](troubleshooting.md#the-org-ui-fails-on-every-page-on-a-new-site).

## Import a new site after the install

To bring another cluster into the hub after the install, even after the console has written models and
subscriptions:

1. Add the site's entry under `sites:` in `.config/clusters.yaml`, with its `name`, `api` and credentials.
2. Run `make install` again.

The rerun checks the site and imports it. The sites already there are left as they are. Then add the site to
the grid in the console, as in [Add a site to the grid](#add-a-site-to-the-grid).

## Other options

- **A CI job:** a CI job can write `.config/clusters.yaml` itself, or keep the secrets out of it and set them as
  environment variables, which take precedence over the file:

  | Environment variable | Replaces |
  |---|---|
  | `AI_GRID_TOKEN_NAME` | The cluster's `token` |
  | `AI_GRID_USERNAME_NAME`, `AI_GRID_PASSWORD_NAME` | The cluster's `username` and `password` |
  | `AI_GRID_DEPLOYMENT_TOKEN`, else the file that `DEPLOYMENT_TOKEN_FILE` names | `deployment.token` |
  | `AI_GRID_CATALOG_TOKEN`, else the file that `CATALOG_TOKEN_FILE` names | `catalog.token` |
  | `AI_GRID_QUAY_USERNAME`, `AI_GRID_QUAY_PASSWORD`, else the auth file that `QUAY_AUTH_FILE` names | `quay.username`, `quay.password` |

  For each GitHub token and the `quay.io` login, the scripts use the first that's set: the `AI_GRID_` variable, the
  file that the `*_FILE` variable names, the value in `.config/clusters.yaml`, then an older secret file,
  `.config/deployment-token`, `.config/catalog-token` or `.config/quay-auth.json`. For a cluster's login, they use a
  working `.config/NAME/kubeconfig`, then a token (`AI_GRID_TOKEN_NAME`, then
  the file), then a username and password (the `AI_GRID_` variables, then the file).

  In a variable's name, `NAME` is the cluster's name upper-cased with `-` turned into `_`, such as
  `AI_GRID_TOKEN_SITE_EAST_1`. A setting that the file leaves out of `options:` comes from the environment variable
  of the same name. To make `make login` fail instead of opening a browser for a cluster with no credentials, run
  `make login NONINTERACTIVE=1`; `make install` never opens a browser.
- **A deployment token, for CI or an unattended run:** by default `make install` pushes your deployment repository
  with your own git login. Where there's none, such as a CI job, uncomment `deployment:` in `.config/clusters.yaml`
  and set its `token`, or set `AI_GRID_DEPLOYMENT_TOKEN`, to a fine-grained token with the same fields as the
  catalog token in step 3, except **Token name** `ai-grid-deployment` and **Repository access** your deployment
  repository only. With a token, `make install` uses only the token and skips your git credential helpers.
- **A login you already have:** copy a working kubeconfig, such as the installer's `auth/kubeconfig`, to
  `.config/NAME/kubeconfig`. `make install` keeps a login that works.
- **An untrusted cluster certificate:** see [An untrusted cluster certificate](#an-untrusted-cluster-certificate).
- **A general `quay.io` account:** put its name and password under `quay:`. The install uses it for `quay.io/rhoai`
  as it would a robot account, so it works only when that account can pull from `quay.io/rhoai`.
- **An auth file instead of `quay:`:** set `QUAY_AUTH_FILE`, or save it as `.config/quay-auth.json`. It must hold the
  `quay.io/rhoai` and `registry.stage.redhat.io` logins, and `stage:` must be left out: the install stops when both
  are set.
- **Another library revision:** by default the hub follows the library's `main` branch, so your clusters update on
  their own as `main` moves. To pin one commit, so that your clusters change only when you change the pin, set
  `LIBRARY` under `options:` to a tag or a full 40-character SHA. To follow another branch, set it to the branch's
  name. Left out or empty, `libraryRevision` in `root/applicationset.yaml` stands. For more, see
  [Follow the library or pin it](../../README.md#follow-the-library-or-pin-it).
- **Another token lifetime:** set `PROVIDER_ADMIN_TOKEN_DURATION` under `options:` for `make install`, or in the
  environment for `make provider-admin`.
- **Longer or shorter waits:** each `GATE_*_SECONDS` value under `options:` sets a readiness check's time limit, in
  seconds. The hub's Applications get 90 minutes (`GATE_HUB_APPS_SECONDS: 5400`).
- **The hub alone,** without the sites, the provider-admin token or the ready check:

  ```sh
  make install HUB_ONLY=1
  ```

## An untrusted cluster certificate

The scripts check each cluster's certificates: the API server's, and, with a username and password, the OAuth
server's, which the ingress router serves. On a new cluster, neither is usually signed by a public CA. Give such a
cluster a `ca:` in its `hub:` or `sites:` entry, in `.config/clusters.yaml` or in `clusters.yaml`. A CA isn't a
secret, so the committed file can hold it too. `ca:` takes one of these values:

- **The PEM certificates,** as a block:

  ```yaml
  hub:
    api: https://api.hub.example.com:6443
    ca: |
      -----BEGIN CERTIFICATE-----
      ...
      -----END CERTIFICATE-----
  ```

  `make fetch-ca NAME=NAME` writes this for you. It reads the certificate chain that the cluster's API host and its
  OAuth host, `oauth-openshift.apps.DOMAIN`, present. From each chain it keeps the self-signed certificates, else the
  last certificate the server sent, and warns when one it keeps isn't a self-signed CA, because such a certificate
  changes when the cluster renews it. It writes them after the cluster's `api:` line, keeping the file's comments. If
  the OAuth host doesn't answer, it writes the API's CA alone and warns; a login with a password then still fails until
  you run it again. It edits `.config/clusters.yaml` if that file exists, else
  `clusters.yaml`. If the cluster already has a `ca:`, it changes nothing and prints the block for you to paste; run
  `make fetch-ca NAME=NAME FORCE=1` to replace it.
- **A PEM file's path,** relative to your deployment repository or absolute, such as `ca: certs/hub-ca.pem`.
- **`ignore`:** the scripts don't check the cluster's certificates at all, and every run warns that your password is
  sent unverified. Anyone between you and the cluster can then read your password and tokens. Use it only on a
  throwaway test cluster, when you can't get its CA.

With no `ca:`, the scripts use `.config/NAME/ca.crt` if it exists, else your system's trust.

A `ca:` replaces your system's trust for that cluster, so it must cover every certificate the scripts check: the API
server's, and the ingress router's, which serves the OAuth server and the hub's Routes, such as the provider console.
`make fetch-ca` fetches both. `ca:` doesn't apply to a site's MaaS gateway, which presents the cluster's internal
certificate ([limits of `main`](../upstream-main-limits.md#l5-the-maas-gateway-presents-the-cluster-internal-certificate)).

`make fetch-ca` trusts what the cluster presents the first time you run it, so check what it fetched. It prints the
subject, issuer and SHA-256 fingerprint of each certificate. A cluster admin who already trusts the cluster, such as
one with the installer's `auth/kubeconfig`, can print the same fingerprints:

```sh
# The API's CAs, from the installer's kubeconfig, one file each
oc config view --kubeconfig auth/kubeconfig --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d |
  awk '/BEGIN CERTIFICATE/ { f = "api-ca-" ++n ".pem" } f { print > f }'
# The router's CA
oc get secret router-ca -n openshift-ingress-operator --kubeconfig auth/kubeconfig \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > router-ca.pem
for f in api-ca-*.pem router-ca.pem; do openssl x509 -noout -subject -fingerprint -sha256 -in "$f"; done
```

The installer's kubeconfig holds several CAs; one of them matches the API's. If the router serves a custom
certificate, compare with the CA that issued it instead of `router-ca`.

## Known limits

- A site's MaaS gateway uses the cluster's internal certificate, so tenants' clients don't trust it. A site can also
  need its Org UI restarted once after it's added
  ([troubleshooting](troubleshooting.md#the-org-ui-fails-on-every-page-on-a-new-site)).
- For everything the library's `main` branch can't do yet, see [the limits of `main`](../upstream-main-limits.md).
- `make install` always installs the library's Keycloak. Using an existing one, with `KEYCLOAK` under `options:`, comes
  later; any value but `install` stops the install.
- Starting over means new clusters, and new deployment and catalog repositories. `make install` doesn't uninstall;
  to remove AI Grid from clusters, see [Uninstall](08-uninstall.md).
