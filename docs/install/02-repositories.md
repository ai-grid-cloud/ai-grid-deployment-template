# Create your deployment and catalog repositories

Your hub installs from two repositories you own: a **deployment repository** with your choices and inputs, and a
**catalog repository** that the provider console writes models and subscriptions to. You create both from templates on
GitHub: the deployment repository from a template, and the catalog repository empty. The deployment template is
[`ai-grid-cloud/ai-grid-deployment-template`](https://github.com/ai-grid-cloud/ai-grid-deployment-template), and it carries the example deployment's own values
([Appendix B](appendix-b-example.md)); this section changes them into yours.

## 1. Create the repositories

1. Create both repositories. The deployment repository comes from the template; the catalog repository starts with
   only a README on `main`, and the console's git writer adds everything else:

   ```sh
   gh repo create OWNER/DEPLOYMENT_REPO --template ai-grid-cloud/ai-grid-deployment-template --private
   gh repo create OWNER/CATALOG_REPO --add-readme --private
   ```

   Replace the following:

   - `OWNER`: your GitHub user or organization.
   - `DEPLOYMENT_REPO` and `CATALOG_REPO`: the names, for example `ai-grid-deployment` and `ai-grid-catalog`.

   Use `--public` instead of `--private` if you prefer; the hub's Argo CD must be able to read both. On the GitHub
   website, **Use this template** > **Create a new repository** on the template does the same as the first command.
   *(Unverified.)*

2. Give the console's token write access to the catalog repository only
   ([provider console](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/05-console-and-model-delivery.md#provider-console)).
   You create the token in [install the hub components](04-hub-components.md).

3. Clone your deployment repository:

   ```sh
   git clone DEPLOYMENT_REPO_URL deployment
   ```

   Replace `DEPLOYMENT_REPO_URL` with your deployment repository's clone URL.

4. Review the example's files. Your repository starts with the example deployment's values, and you change these:

   | File | What to do | Where |
   |---|---|---|
   | `root/kustomization.yaml` | Set the library pin, your component selection and every input. | Parts 2 to 4 |
   | `root/self.yaml` | Point `spec.source.repoURL` at your deployment repository. | Part 6 |
   | `values/cluster-admins.yaml`, `values/grid-bootstrap.yaml` | Set your cluster admins and grid CA mode. | Part 5 |
   | `values/clusters/site-b/` | The example site's values. Delete them, and add a folder per ingress or combined site. | [Join each site to the grid](06-join-grid.md#1-add-the-sites-values) |
   | `apps/site-b-maas-tls.yaml`, `sites/site-b/` | The example site's MaaS certificate. Delete them, or change them for your site. | [MaaS gateway certificate](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/spokes/maas-certificate.md) |
   | `apps/tenant-idp.yaml`, `idp/`, `scripts/create-test-tenant.sh` | The example's own Keycloak. Keep them only if you run your own Keycloak the way the example does, and then set its hostnames in `idp/`; otherwise delete them. | [Tenant identity provider](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/04-tenant-identity.md#tenant-identity-provider) |

   Keep `docs/` and `scripts/sync-guide-pin.sh`: they're this guide and the script that points its links at your pin.

## 2. Pin the library commit

The root takes the library's `bootstrap/hub` at one commit. Every component then reads the library at that commit.

1. Choose the library commit:

   ```sh
   git ls-remote LIBRARY_REPO_URL refs/heads/LIBRARY_BRANCH
   ```

   Replace `LIBRARY_REPO_URL` and `LIBRARY_BRANCH` with the library's repository and branch. Until the library lands
   upstream, they are `https://github.com/cfchase/ai-grid-cluster-gitops` and `proto/library-v2`.

2. In `deployment/root/kustomization.yaml`, set the full 40-character SHA and the library URL in all three places:
   the remote base (`//bootstrap/hub?ref=SHA`), the generator `revision`, and `values.libraryRevision`; and
   `values.libraryRepoURL` plus the generator `repoURL`.

   ```sh
   cd deployment
   grep -n -e 'ref=' -e 'revision:' -e libraryRevision -e libraryRepoURL root/kustomization.yaml
   ```

   You should see the same SHA on every `ref=`, generator `revision` and `libraryRevision` line.

3. Check out the library at that commit, next to your deployment checkout. The scripts this guide runs come from it,
   so they always match your pin:

   ```sh
   git clone -q LIBRARY_REPO_URL ../library && git -C ../library checkout -q LIBRARY_SHA
   ```

   Replace `LIBRARY_SHA` with the full SHA. After an upgrade, check out the new SHA here too.

4. Point this guide's links into the library at your pin, so each reference page you open matches the components you
   install:

   ```sh
   scripts/sync-guide-pin.sh
   scripts/sync-guide-pin.sh --check
   ```

   You should see `guide links at https://github.com/.../blob/LIBRARY_SHA/`. The script reads `libraryRevision` and
   `libraryRepoURL` from `root/kustomization.yaml` and rewrites the links in `docs/install/`.

## 3. Select components

Your root has three generators. The first is the library's components; the second is ODF (keep it only if you select
ODF); the third, which the example adds, reads your own `apps/*.yaml`. Keep the third: the tenant IdP, site
certificates and any other app of your own go there, and its `repoURL` and `revision` reuse your
`deploymentRepoURL` and `deploymentRevision` values through YAML aliases (generator fields can't take `@NAME@`).

In `root/kustomization.yaml`, the patch that replaces `/spec/generators/0/git/files` is your component list. For each
[hub item](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/README.md), keep the example's lines, or swap in the lines for your choice from that item's page. The
example's list, by item:

| Hub item | The example's lines | Change them when |
|---|---|---|
| [0. Platform services](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/00-platform-services.md#select-it) | `apps/gitops-config`, `cluster-config`, `apps/external-secrets` | Add `apps/cert-manager` if the hub has no cert-manager. |
| [1. ACM](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/01-acm.md#select-it) | `apps/acm`, `apps/object-storage/s4` | Use `apps/object-storage/odf` or your own bucket instead of S4; add `apps/metallb` for bare-metal sites. |
| [2. Grid](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/02-grid.md#select-it) | `apps/grid-bootstrap`, `apps/ai-grid-policies` | Never. |
| [3. MaaS shared services](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/03-maas-shared-services.md#select-it) | `apps/maas-db`, `apps/limitador-redis`, `apps/external-services` | To run them on a site instead of the hub, keep `apps/external-services` and label that site ([run them on a site](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/03-maas-shared-services.md#run-the-shared-services-on-a-site)); otherwise you can leave it out. |
| [4. Tenant identity](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/04-tenant-identity.md#select-it) | None: its own IdP is in `apps/tenant-idp.yaml` | Add `apps/keycloak` to use the library's Keycloak. |
| [5. Provider console and model delivery](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/05-console-and-model-delivery.md#select-it) | `apps/acm-models`, `apps/console` | Leave out `apps/console` with an IdP that isn't Keycloak. |
| [6. Site delivery](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/06-site-delivery.md#select-it) | `apps/ai-grid-spokes`, `apps/argo-registration`, `apps/rhoai`, `apps/rhoai-prerequisites` | Never. |
| [7. Observability and usage logs](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/07-observability.md#select-it) | None | Add `apps/ai-grid-o11y` and `apps/ai-grid-usage-logs` to turn it on. |

Each line is `- path: apps/NAME/application.yaml`, except `- path: cluster-config/application.yaml` and the object
storage options, `- path: apps/object-storage/s4/application.yaml` and `- path: apps/object-storage/odf/application.yaml`.

- If you select ODF object storage, keep generator 1 and set its `repoURL`, `revision` and `values` the same way.
  Otherwise keep the example's `remove` of `/spec/generators/1`.
- Your own apps go in `apps/*.yaml` in your deployment repository, one Argo CD Application each; the example's last
  patch adds a generator for them.

## 4. Set every input

The library writes each deployment value as `@NAME@`; your root's `values` set them once. Set all 14 in the `values`
patch (the example uses a YAML anchor, `&inputs`, so its own-apps generator gets the same values).

| Input | Meaning | Example | Read by |
|---|---|---|---|
| `libraryRepoURL` | The library's repository | `https://github.com/cfchase/ai-grid-cluster-gitops.git` | every component (self-references) |
| `libraryRevision` | The pinned commit, a full 40-character SHA | `LIBRARY_SHA` | every component |
| `deploymentRepoURL` | Your deployment repository | `https://github.com/my-org/ai-grid-deployment.git` | `cluster-config`, `grid-bootstrap`, `rhoai` (the `values/` files) |
| `deploymentRevision` | Its branch or commit | `main` | the same |
| `catalogRepoURL` | Your catalog repository | `https://github.com/my-org/ai-grid-catalog.git` | `acm-models`, `console` (git writer) |
| `catalogRevision` | Its branch: the git writer pushes to it, so use a branch | `main` | `acm-models`, `console` |
| `idpIssuerURL` | The tenant OIDC issuer | `https://keycloak-tenant-idp.apps.HUB_DOMAIN/realms/tenants` | `rhoai` (the tenant Policy and the sites' AITenant) |
| `idpClientID` | The tenant client; MaaS matches the token's `azp` against it | `ai-grid-tenants` | `rhoai` |
| `idpClientSecretNamespace` | Namespace of the hub Secret with that client's secret | `tenant-idp-client` | `rhoai` (the tenant Policy) |
| `idpClientSecretName` | That Secret's name | `tenant-idp-client` | `rhoai` (the tenant Policy) |
| `idpClientSecretKey` | Its key | `client-secret` | `rhoai` (the tenant Policy) |
| `idpCANamespace` | Namespace of the hub ConfigMap with the CA that signs the issuer's certificate | `openshift-config-managed` | `rhoai` (the tenant Policy) |
| `idpCAName` | That ConfigMap's name | `default-ingress-cert` | `rhoai` (the tenant Policy) |
| `idpCAKey` | Its key | `ca-bundle.crt` | `rhoai` (the tenant Policy) |

Rules:

- A value must be non-empty and must not contain `"`, `'`, `\` or `@`. Otherwise the root reports
  `invalid input: NAME` and creates no Applications.
- An input you don't set reports `missing input: NAME`.
- A bare render of the library's `bootstrap/hub` shows 33 lines with `REQUIRED-`: these 14 inputs in the `values` of
  both generators (28), the library URL and revision in each generator's own `repoURL` and `revision` (4), and the
  root's own check for leftover markers (1). Every one of the 32 markers is set by the steps in this section.
- If you bring your own tenant identity provider, the `idp*` inputs point at it. If you use ours (`apps/keycloak`),
  use the values its page gives ([Keycloak](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/04-tenant-identity.md#keycloak)).

## 5. Fill in the values files

Your deployment repository holds three kinds of values file. The library reads them from
`deploymentRepoURL` at `deploymentRevision`.

1. `values/cluster-admins.yaml` (required): the users bound to `cluster-admin` on every cluster.

   ```yaml
   cluster_admins:
     - ADMIN_USER
   ```

   Use `cluster_admins: []` for none. If the file is missing, `cluster-config` fails rather than removing every
   binding ([cluster sign-in and admins](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/00-platform-services.md#cluster-sign-in-and-admins)).

2. `values/grid-bootstrap.yaml`: `Generate` starts a new grid with a new CA; `Existing` keeps a CA you already have
   ([grid bootstrap](https://github.com/cfchase/ai-grid-cluster-gitops/blob/3ccbe609b841affcd02ce9d4f132f48baa5b27bc/docs/install/hub/02-grid.md#grid-bootstrap)).

   ```yaml
   external:
     certManager:
       ca:
         mode: Generate
   managedClusters:
     createClusterSetBinding: true
   ```

   `createClusterSetBinding: true` is the library's default: grid-bootstrap binds the ACM
   ClusterSet `global` into namespace `redhat-ai-grid`, and the root removes the `rhoai` component's copy of that
   binding. Keep the line so the choice is visible in your repository.

3. `values/clusters/SITE/rhoai.yaml`: one per ingress or combined site. You add these in
   [join each site to the grid](06-join-grid.md#1-add-the-sites-values), before you label the site.

## 6. Render and push

1. Render the root and check for unset inputs:

   ```sh
   ../library/scripts/check-deployment.sh .
   ```

   You should see `root renders; every input is set; every repository is an input.`

   - `unset inputs:` lists each `REQUIRED-NAME` you still have to set.
   - `repositories that aren't your library, deployment or catalog input:` lists a `repoURL` left over from the
     example, in `root/self.yaml` or `apps/*.yaml`. Change it to your repository, or to `'@deploymentRepoURL@'`.

2. Point `root/self.yaml` (Application `deployment-root`) at your deployment repository: set `spec.source.repoURL`.
   Your own `apps/*.yaml` must use `'@deploymentRepoURL@'` and `'@deploymentRevision@'`, never a literal URL.

3. Commit and push:

   ```sh
   git add -A && git commit -m "deployment: first selection and inputs" && git push origin HEAD:main
   ```

## Checkpoint

- `../library/scripts/check-deployment.sh .` prints `root renders; every input is set; every repository is an input.`
- `root/self.yaml` points at your deployment repository.
- Both repositories are pushed, and the catalog repository has a `main` branch.
