> **Prototype:** this template pins [`ai-grid-cloud/ai-grid-cluster-gitops`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops)
> branch `feat/deployment-inputs` until it merges into `main`.

# AI Grid deployment template

A GitHub template for an AI Grid **deployment repository**. You create your own repository from it, and your hub's
Argo CD installs AI Grid from that repository:

- **On the hub:** ACM, the grid, the MaaS database and Redis, a Keycloak for tenants, and the provider console.
- **On each site:** OpenShift AI with MaaS and the grid, in the site's role.

The template carries choices tested end to end on 2026-11-10, so you change only your names.

## The three repositories

| Repository | What it holds | Who changes it |
|---|---|---|
| Library, [`ai-grid-cloud/ai-grid-cluster-gitops`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops) | The components (Argo CD applications, ACM policies, charts) and their reference docs | Its maintainers; you pin one commit and don't edit it |
| Your deployment repository, from this template | The library pin, which components run, your inputs, each site's files, the install guide and its scripts | You |
| Your catalog repository, created in the install guide | Models and subscriptions | The provider console |

The hub's Argo CD reads all three. Your deployment repository points at the library and the catalog in
`root/kustomization.yaml`; to upgrade, you move the library pin. For more, see
[How AI Grid works](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/2a96b90291a23a9fbd044ca2e3decdba1e09fae4/docs/install/README.md#how-ai-grid-works).

## Start here

1. Create your deployment repository from this template:

   1. Click **Use this template** > **Create a new repository**.

      <img src="docs/install/images/use-this-template.png" width="300" alt="The Use this template menu">

   2. Choose the owner, name it, such as `ai-grid-deployment`, keep **Public**, and click **Create repository**. The
      hub's Argo CD reads it; this guide was tested with public repositories and doesn't cover the credentials that
      private ones need.

      <img src="docs/install/images/new-deployment-repository.png" width="480" alt="The new repository form with this template selected">

   With the GitHub CLI instead:

   ```sh
   gh repo create OWNER/DEPLOYMENT_REPO --template ai-grid-cloud/ai-grid-deployment-template --public
   ```

2. Follow the [install guide](docs/install/README.md) in your new repository.

## Update from the template

Your repository doesn't follow the template by itself. To pick up the template's later fixes, merge it in from your
repository's directory:

```sh
git remote add template https://github.com/ai-grid-cloud/ai-grid-deployment-template.git
git fetch template
git merge --allow-unrelated-histories template/main
```

Repositories made from a template share no history with it, so the first merge needs `--allow-unrelated-histories` and
shows a conflict in each file the template changed since you created yours: keep your values, take the rest. If you
haven't changed anything yet, take the template's version of every conflict instead:

```sh
git merge --allow-unrelated-histories -X theirs template/main
```

After the first merge, update with:

```sh
git fetch template
git merge template/main
git push
```
