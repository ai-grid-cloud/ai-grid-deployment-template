# Set up your deployment repository

Your deployment repository starts with the template's tested choices. On this page you set the names that must be
yours, check the result, and push it.

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

## 2. Set your names

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

## 3. Check and push

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
- Your deployment repository is pushed, and your catalog repository has a `main` branch.
