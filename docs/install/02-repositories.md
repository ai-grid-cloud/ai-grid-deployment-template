# Set up your deployment repository

Your deployment repository starts with the template's tested choices. On this page you create your catalog
repository, set the names that must be yours, check the result, and push it.

## 1. Clone your repository and the library

Clone your deployment repository, then the library at the commit your repository pins. The scripts this guide runs
come from the library checkout, so they always match your pin:

```sh
git clone DEPLOYMENT_REPO_URL deployment && cd deployment
git clone -q https://github.com/cfchase/ai-grid-cluster-gitops.git ../library
git -C ../library checkout -q "$(sed -n 's/^ *libraryRevision: *//p' root/kustomization.yaml)"
```

Replace `DEPLOYMENT_REPO_URL` with your deployment repository's clone URL. Run every command in this guide from the
`deployment` directory.

## 2. Create your catalog repository and its token

The catalog repository holds your models and subscriptions: the hub delivers them to your sites, and the provider
console writes them there with a token that can write only this repository.

1. [Create a new repository](https://github.com/new): name it, such as `ai-grid-catalog`, make it public, and turn on
   **Add README**.

   <img src="images/new-catalog-repository.png" width="420" alt="The new repository form with Add README on">

   With the GitHub CLI instead: `gh repo create OWNER/CATALOG_REPO --add-readme --public`.

2. [Create a fine-grained token](https://github.com/settings/personal-access-tokens/new):
   - **Repository access:** **Only select repositories**, and select your catalog repository.
   - **Permissions:** **Contents: Read and write**. Leave every other permission off.

   Note its expiration date: when it expires, the console can't save models or subscriptions until you replace it.

3. Save the token to a file outside your repository that only you can read, and never commit it:

   ```sh
   mkdir -p ~/.ai-grid && install -m 600 /dev/null ~/.ai-grid/catalog-token
   ```

   Paste the token into `~/.ai-grid/catalog-token` with an editor. You use it in
   [install the hub components](04-hub-components.md#2-create-the-consoles-secrets).

## 3. Set your names

Find each cluster's apps domain:

```sh
oc --context CONTEXT get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}'
```

Replace `CONTEXT` with the cluster's kubeconfig context. The output is similar to `apps.hub.example.com`.

Replace each `REQUIRED-` placeholder:

| File | Placeholder | Set it to |
|---|---|---|
| `root/kustomization.yaml` | `REQUIRED-deploymentRepoURL` | Your deployment repository's URL, such as `https://github.com/my-org/ai-grid-deployment.git` |
| `root/kustomization.yaml` | `REQUIRED-catalogRepoURL` | Your catalog repository's URL, such as `https://github.com/my-org/ai-grid-catalog.git` |
| `root/kustomization.yaml` | `REQUIRED-idpIssuerURL` | `https://keycloak-tenant-idp.HUB_APPS_DOMAIN/realms/tenants`, with the hub's apps domain |
| `root/self.yaml` | `REQUIRED-deploymentRepoURL` | Your deployment repository's URL, as in `root/kustomization.yaml` |
| `tenant-idp/manifests/settings.yaml` | `REQUIRED-portalRedirectURI` | `https://maas.SITE_APPS_DOMAIN/*`, with the site's apps domain |

Keep every other value. Each one is a tested choice: for what it means and how to change it, see
[Appendix A: inputs and values](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/appendix-a-inputs.md) and
[Hub components](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/README.md#select-components).

## 4. Check and push

1. Check your repository:

   ```sh
   ../library/scripts/check-deployment.sh .
   ```

   You should see `root renders; every input is set; every repository is an input.` If you see
   `unset inputs:` or `placeholders left in your files:`, set the values it names and run it again.

2. Commit and push:

   ```sh
   git add -A && git commit -m "deployment: set our names" && git push origin HEAD:main
   ```

## Checkpoint

- `../library/scripts/check-deployment.sh .` prints `root renders; every input is set; every repository is an input.`
- Your deployment repository is pushed, your catalog repository has a `main` branch, and your catalog token is in
  `~/.ai-grid/catalog-token`.
