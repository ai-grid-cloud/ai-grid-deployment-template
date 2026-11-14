# Install with one command

`make install` installs the hub and imports every site into ACM, with no prompt and no browser, so a test suite or a
CI job can start from blank clusters. It runs the same scripts as pages 2 to 5, and between them waits on named
readiness checks instead of your judgement.

When it finishes, you have:

- the hub, fully installed: ACM, Argo CD, Keycloak, the MaaS database, the provider console and monitoring, with
  every hub Application `Synced` and `Healthy`;
- every site in `clusters.yaml` imported into the hub's ACM and available, but **not added to the grid**: no
  `ai-grid/` or `location` label and no OpenShift AI on it;
- no organizations, models or subscriptions;
- `.install/outputs.json`, the endpoints a test suite needs, and a provider-admin token for the console's API.

Adding a site to the grid is your next step, or your test suite's
([add a site to the grid](#add-a-site-to-the-grid)).

## Set up once

Do this once per install. Everything `make install` reads afterwards is a file in your deployment repository, so a CI
job can supply the same files.

### Clusters

You need the clusters from [before you start](01-before-you-start.md): a hub and one or more sites on OpenShift 4.21
or later, with nothing of AI Grid on them, and the same network and tools. Each site can have any role: `combined`,
`ingress` or `inference`.

If a site has the role `ingress` or `combined`, it needs a cert-manager ClusterIssuer that issues publicly trusted
certificates by DNS-01, for its MaaS certificate. `make install` checks for one and stops if there's none. An
`inference` site needs no issuer.

### Repositories and tokens

1. Create your deployment repository from the template ([start here](../../README.md#start-here)), and your catalog
   repository and its token ([page 2, part 2](02-repositories.md#2-create-your-catalog-repository-and-its-token)).
   The catalog repository must hold nothing but its README.
2. Create a second fine-grained token, with **Contents** set to **Read and write** on your deployment repository only.
   `make install` pushes your inputs and the sites' files with it.
3. Clone your deployment repository by its HTTPS URL, because `make install` pushes with the token, not with SSH:

   ```sh
   git clone https://github.com/OWNER/DEPLOYMENT_REPO.git deployment && cd deployment
   ```

   Replace `OWNER/DEPLOYMENT_REPO` with your deployment repository. Run every command on this page from the
   `deployment` directory, on branch `main`.

### `clusters.yaml`

Copy the example file:

```sh
cp clusters-example.yaml clusters.yaml
```

Replace each `REQUIRED-` value, as on [page 2](02-repositories.md#1-clone-your-repository-and-log-in-to-your-clusters),
and add a block for each site. Keep the hub's name, `hub`. Set each site's `role`: the install prepares each site for
that role, and `make site-join` uses it later. A site's name becomes its ACM cluster name.

### Secret files under `.config/`

`make install` reads its secrets only from files under `.config/`, which git ignores. Create the directory, readable
only by you:

```sh
mkdir -p .config && chmod 700 .config
```

Put these files in it. `NAME` is the cluster's name in `clusters.yaml`, such as `hub`.

| File | What it holds |
|---|---|
| `.config/NAME/token` | A `cluster-admin` token for the cluster, such as from `oc whoami -t`. One per cluster. |
| `.config/NAME/kubeconfig` | Instead of a token: a working kubeconfig, such as the installer's `auth/kubeconfig`. |
| `.config/NAME/ca.crt` | Optional: the CA of the cluster's API, when your system doesn't trust its certificate. |
| `.config/deployment-token` | The token that can push to your deployment repository. |
| `.config/catalog-token` | The token that can write your catalog repository. |
| `.config/quay-auth.json` | A container auth file with a `quay.io/rhoai` login, such as a copy of `~/.config/containers/auth.json`. |

For a cluster with a token file, `make install` writes `.config/NAME/kubeconfig` from the token and the API URL in
`clusters.yaml`. A kubeconfig that already works is kept as it is. Instead of a token file, you can set the
environment variable `AI_GRID_TOKEN_NAME`, with the cluster's name upper-cased and `-` turned into `_`, such as
`AI_GRID_TOKEN_SITE_B`.

To write a token file without showing the token, run the following, and paste the token when it asks:

```sh
mkdir -p .config/NAME && (umask 077 && printf 'Paste the token: ' && read -rs t && printf '%s' "$t" > .config/NAME/token && echo)
```

Replace `NAME` with the cluster's name. For the repository tokens, write `.config/deployment-token` and
`.config/catalog-token` the same way.

### `install.env`

Copy the example file:

```sh
cp install-example.env install.env
```

In `install.env`, set `CATALOG_REPO_URL` to your catalog repository's URL, such as
`https://github.com/my-org/ai-grid-catalog.git`. The other values have defaults that match the file names above.
`install.env` holds no secrets. It also sets the following, each explained in the file:

- `LIBRARY_REVISION`: a library branch, tag or commit to pin instead of the template's pin, to test a library change.
- `SITE_ISSUER_NAME`: which DNS-01 ClusterIssuer to use, when an `ingress` or `combined` site has several.
- `GATE_*_SECONDS`: each readiness check's time limit.

A line `make install` doesn't know, or a value still starting with `REQUIRED-`, stops it before it touches a
cluster.

### Commit

Commit your two files:

```sh
git add clusters.yaml install.env && git commit -m "deployment: our clusters and install settings"
```

`make install` pushes this commit with its own.

## Run it

```sh
make install
```

It prints `== STEP` as each step starts, and ends with:

```text
Installed. Outputs: .install/outputs.json
```

The steps, in order:

1. **`login`:** a kubeconfig for each cluster from `.config/`.
2. **`inputs`:** your names in `root/inputs.env` (`scripts/set-inputs.sh`), pushed.
3. **`catalog`:** checks that your catalog repository holds only its README.
4. **`bootstrap`:** OpenShift GitOps and your root on the hub ([page 3](03-prepare-hub.md)).
5. **`acm`:** waits until ACM is running.
6. **`console-secrets`:** the console's Secrets ([page 4](04-hub-components.md#1-create-the-consoles-secrets)).
7. **`hub-apps`:** waits until every hub Application is `Synced` and `Healthy`.
8. **`site-files`:** for each `ingress` or `combined` site, its values and MaaS certificate files
   ([page 6, part 1](06-join-grid.md#1-add-the-sites-values)), pushed.
9. **`site NAME`:** for each site, the infrastructure check and the import into ACM ([page 5](05-prepare-site.md)).
10. **`provider-admin`:** the provider-admin ServiceAccount and its token.
11. **`ready`:** the ready check, which also writes `.install/outputs.json`.

To install the hub alone, without the sites, the provider-admin token or the ready check, run:

```sh
scripts/install.sh --hub-only
```

## Run it again after a failure

When a step fails, `make install` prints why, then stops with a line like the following:

```text
make install stopped at hub-apps. Fix the cause, then run make install again.
```

If the line names a readiness check, such as `hub-apps` or `site-site-b-import`, the evidence is printed above it and
saved in `.install/report.txt`: `make status`, `make site-status` for a site, and the conditions of whatever isn't
ready. If the line names a step, the step's own error is above it. If it stopped at `ready`, the ready check's last
output is in `.install/ready-check.txt`.

Fix the cause, then run the same command:

```sh
make install
```

Every step first checks whether its work is done and skips it if so, so the install picks up where it stopped. On a
finished install, a second run changes nothing and passes the ready check again. `.install/report.txt` can quote
your manifests: read it before you share it.

To check the end state again at any time, without changing anything, run:

```sh
make ready-check
```

## Hand off to a test suite

The ready check writes `.install/outputs.json`, which git ignores. It has these keys:

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
command line. It lasts 168 hours, or `PROVIDER_ADMIN_TOKEN_DURATION` from `install.env`. To get a new one, run:

```sh
make provider-admin
```

## Add a site to the grid

`make install` leaves each site imported but outside the grid, with the files an `ingress` or `combined` site needs
already pushed. To add a site, use either of these:

- In the provider console, click **Clusters**, and add the site to AI Grid with its role.
- From your deployment repository, label the site with the role and location from `clusters.yaml`:

  ```sh
  make site-join SITE=SITE_NAME
  ```

The hub then installs OpenShift AI, MaaS and the grid on the site. To follow it, see
[page 6, part 3](06-join-grid.md#3-verify).

## Known limits

- An `ingress` or `combined` site needs a DNS-01 ClusterIssuer that issues publicly trusted certificates. Supplying
  a certificate another way is a later option.
- `make install` always installs its own Keycloak. Using an existing one, with `KEYCLOAK` in `install.env`, comes
  later; any value but `install` stops the install.
- Starting over means new clusters, and new deployment and catalog repositories. `make install` doesn't uninstall;
  to remove AI Grid from clusters, see [Uninstall](08-uninstall.md).
