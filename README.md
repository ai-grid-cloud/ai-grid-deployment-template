> **Prototype:** this template pins [`ai-grid-cloud/ai-grid-cluster-gitops`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops)
> branch `feat/deployment-inputs` until it merges into `main`.

# AI Grid deployment template

A GitHub template for an AI Grid **deployment repository**: the components one hub runs, its inputs, and its sites'
files. It installs from the component library
[`ai-grid-cloud/ai-grid-cluster-gitops`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops) at one pinned commit. Tested end
to end on 2026-11-10 ([install guide](docs/install/README.md)).

## Start here

1. Create your deployment repository from this template:

   1. Click **Use this template** > **Create a new repository**.

      <img src="docs/install/images/use-this-template.png" width="300" alt="The Use this template menu">

   2. Choose the owner, name it, such as `ai-grid-deployment`, keep **Public**, and click **Create repository**. The
      hub's Argo CD reads it; this guide was tested with public repositories and doesn't cover the credentials that
      private ones need.

      <img src="docs/install/images/new-deployment-repository.png" width="480" alt="The new repository form with this template selected">

   With the GitHub CLI instead:
   `gh repo create OWNER/DEPLOYMENT_REPO --template ai-grid-cloud/ai-grid-deployment-template --public`.

2. Follow the [install guide](docs/install/README.md) in your new repository.
