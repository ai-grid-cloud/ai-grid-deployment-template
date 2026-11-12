# Set up your deployment repository

Your deployment repository starts with the template's tested choices. On this page you create your catalog
repository, set the names that must be yours, check the result, and push it.

If you're reinstalling with your existing repositories, skip cloning, naming your clusters and
[creating your catalog repository and its token](#2-create-your-catalog-repository-and-its-token). From your
`deployment` directory, log in ([part 1, step 3](#1-clone-your-repository-and-log-in-to-your-clusters)), check your
prerequisites ([part 3](#3-check-your-prerequisites)), then do parts 4 and 5. Every command in them is safe to run
again.

## 1. Clone your repository and log in to your clusters

1. Clone your deployment repository:

   ```sh
   git clone DEPLOYMENT_REPO_URL deployment && cd deployment
   ```

   Replace `DEPLOYMENT_REPO_URL` with your deployment repository's clone URL. Run every command in this guide from the
   `deployment` directory.

2. Name your clusters. Copy the example file:

   ```sh
   cp clusters-example.yaml clusters.yaml
   ```

   In `clusters.yaml`, replace each `REQUIRED-` value: the hub's API URL, and the site's name, location and API URL.
   Keep the hub's name, `hub`, and the site's role, `combined`: the guide's commands use them. To find a cluster's
   API URL, open its web console, click your user name > **Copy login command**, and read the `--server=` value, or
   take it from the cluster installer's output. For example:

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
   ```

   The site's name becomes its ACM cluster name, and you can't change it once the site is imported. Commit
   `clusters.yaml` with your other changes in part 5; it records which clusters make up your grid, and holds no
   secrets.

3. Log in to each cluster as a `cluster-admin` user:

   ```sh
   make login
   ```

   For each cluster in `clusters.yaml`, it runs `oc login --web` against the cluster's API URL, which opens your
   browser, and saves the login in `.config/NAME/kubeconfig`, which git ignores. Your own kubeconfig isn't touched.
   Clusters you're still logged in to are skipped. When one login expires later, run `make login` again, or
   `make login NAME=hub` for one cluster. To use a kubeconfig you already have instead, such as the installer's
   `auth/kubeconfig`, copy it to `.config/NAME/kubeconfig`.

## 2. Create your catalog repository and its token

The catalog repository holds your models and subscriptions: the hub delivers them to your sites, and the provider
console writes them there with a token that can write only this repository.

1. [Create a new repository](https://github.com/new): name it, such as `ai-grid-catalog`, make it public, and turn on
   **Add README**.

   <img src="images/new-catalog-repository.png" width="420" alt="The new repository form with Add README on">

   With the GitHub CLI instead:

   ```sh
   gh repo create OWNER/CATALOG_REPO --add-readme --public
   ```

2. [Create a fine-grained token](https://github.com/settings/personal-access-tokens/new), named such as `ai-grid-catalog`:

   1. Under **Repository access**, select **Only select repositories**, and select your catalog repository.

      <img src="images/token-repository-access.png" width="480" alt="Repository access set to Only select repositories">

   2. Under **Permissions**, click **Add permissions** > **Contents**, then set it to **Read and write**. Leave every
      other permission off; GitHub adds **Metadata: Read-only** itself.

      <img src="images/token-permissions.png" width="480" alt="Contents set to Read and write">

   3. Click **Generate token** and copy it.

   Note its expiration date: when it expires, the console can't save models or subscriptions until you replace it.

3. Save the token to a file outside your repository that only you can read, and never commit it:

   ```sh
   mkdir -p ~/.ai-grid && (umask 077 && printf 'Paste the token: ' && read -rs t && printf '%s' "$t" > ~/.ai-grid/catalog-token && echo)
   ```

   It asks for the token without showing it, and writes it to `~/.ai-grid/catalog-token`, readable only by you. Paste
   the token and press Enter. You use it in
   [install the hub components](04-hub-components.md#1-create-the-consoles-secrets).

## 3. Check your prerequisites

Check your tools, each cluster in `clusters.yaml`, your registry logins and your catalog token:

```sh
make prereqs
```

It reads your registry logins from `~/.config/containers/auth.json`, or from `$XDG_RUNTIME_DIR/containers/auth.json`
when that's where `podman login` saved them, and your catalog token from `~/.ai-grid/catalog-token`. To use another
auth file, add `QUAY_AUTH_FILE=AUTH_FILE`. It also fetches the library at your pin into `.library/`, which git
ignores; the scripts in `scripts/` use it. It changes nothing on your clusters and never blocks. The output is similar
to the following:

```text
Tools
ok       oc                               4.22.17
MISSING  clusteradm                       imports the site into ACM
...
Registry logins (pre-release builds)
ok       auth file                        /home/user/.config/containers/auth.json
ok       quay.io/rhoai login              quay.io/rhoai entry
...
Hub hub
ok       reachable                        https://api.hub.example.com:6443
ok       OpenShift 4.21 or later          4.22.18
...
Site site-east-1 (combined)
ok       ClusterIssuer                    letsencrypt-dns (DNS-01)
...
Catalog token
ok       catalog token file               /home/user/.ai-grid/catalog-token (mode 600, not empty)

24 ok, 1 missing
Nothing was changed; fix these before the page that needs them.
```

Install any tool marked `MISSING` before you continue.

## 4. Set your names

Set the values that name your repositories and hosts:

```sh
scripts/set-inputs.sh CATALOG_REPO_URL
```

Replace `CATALOG_REPO_URL` with your catalog repository's URL, such as
`https://github.com/my-org/ai-grid-catalog.git`. The script reads the apps domains through your cluster logins,
prints each value it sets, and then runs `scripts/check-deployment.sh`:

| File | Value | Set to |
|---|---|---|
| `root/inputs.env` | `deploymentRepoURL` | Your deployment repository's URL, from `git remote get-url origin` |
| `root/inputs.env` | `deploymentRevision`, `catalogRevision` | `main` |
| `root/inputs.env` | `catalogRepoURL` | `CATALOG_REPO_URL` |
| `root/inputs.env` | `idpIssuerURL` | `https://keycloak-tenant-idp.HUB_APPS_DOMAIN/realms/tenants`, with the hub's apps domain |
| `tenant-idp/manifests/settings.yaml` | `portalRedirectURI` | `https://maas.SITE_APPS_DOMAIN/*`, with the apps domain of the first `combined` or `ingress` site |

`root/inputs.env` is yours: the template doesn't have it, so `make update` never changes it.
`root/kustomization.yaml` copies its values over the root's `REQUIRED-` placeholders; leave those. A value that's
already set is kept, so you can run the script again.

You should see `root renders; every input is set; every repository is an input.` at the end. If you see
`unset inputs:` or `placeholders left in your files:`, set the values it names and run `scripts/check-deployment.sh`.

Keep every other value. Each one is a tested choice: for what it means and how to change it, see
[Appendix A: inputs and values](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/9f4befd9e5716cea787c10661ddbf422a4999812/docs/install/appendix-a-inputs.md) and
[Hub components](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/9f4befd9e5716cea787c10661ddbf422a4999812/docs/install/hub/README.md#select-components).

## 5. Commit and push

Commit your clusters file and the files `scripts/set-inputs.sh` changed, and push:

```sh
git add clusters.yaml root tenant-idp && git commit -m "deployment: set our names" && git push origin HEAD:main
```

Run `git status` first if you changed anything else. If git says there's nothing to commit, your repository is
already set; push it:

```sh
git push origin HEAD:main
```

## Checkpoint

- `scripts/set-inputs.sh` ended with `root renders; every input is set; every repository is an input.`
- Your deployment repository is pushed, your catalog repository has a `main` branch, and your catalog token is in
  `~/.ai-grid/catalog-token`.

Next: [3. Prepare the hub](03-prepare-hub.md)
