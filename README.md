# ai-grid-deployment-proto

A prototype **deployment repository** for AI Grid. It installs a hub and its sites from the component library
[`cfchase/ai-grid-cluster-gitops`](https://github.com/cfchase/ai-grid-cluster-gitops/tree/proto/library) (branch
`proto/library`), pinned at one commit. This repository holds only this deployment's choices: which components run,
their inputs, per-cluster values, and its own extra apps. Models and subscriptions live in a third repository,
[`cfchase/ai-grid-catalog-proto`](https://github.com/cfchase/ai-grid-catalog-proto), which only the console's git
writer changes.

Draft install documentation, written from what was run on the prototype hub `proto-hub` and site `site-b`.
Steps 3 and 4 are added as they are run.

## Layout

| Path | What it is |
|---|---|
| `root/kustomization.yaml` | The hub's root: the library's `bootstrap/hub` at a pinned commit, the selected components, and every input. |
| `root/self.yaml` | Application `deployment-root`, which keeps the root in sync with this repository. |
| `values/` | Values the library reads from here: `cluster-admins.yaml`, `grid-bootstrap.yaml`, `clusters/<cluster>/rhoai.yaml`. |
| `apps/*.yaml` | This deployment's own apps, one Argo CD Application each. |
| `idp/` | Our own tenant identity provider (the Keycloak skip test). |
| `bootstrap.sh` | Step 1's GitOps install and the one-time apply of `root/`. |
| `scripts/` | `add-htpasswd-admin.sh`, `wipe-site.sh`, `render.sh`, `check-revisions.sh`. |

## Inputs

Set once, in `root/kustomization.yaml` (generator `values`). The library writes each as `@<name>@`; a missing one
fails the root with `missing input: <name>`.

| Input | Here |
|---|---|
| `libraryRepoURL`, `libraryRevision` | the library and the pinned commit |
| `deploymentRepoURL`, `deploymentRevision` | this repository, `main` |
| `catalogRepoURL`, `catalogRevision` | the catalog repository, `main` (a branch: the git writer pushes to it) |
| `idpIssuerURL`, `idpClientID` | our tenant Keycloak, realm `tenants`, client `ai-grid-tenants` |
| `idpClientSecretNamespace`, `idpClientSecretName`, `idpClientSecretKey` | `tenant-idp-client`/`tenant-idp-client`/`client-secret` (a namespace holding only that Secret) |
| `idpCANamespace`, `idpCAName`, `idpCAKey` | `openshift-config-managed`/`default-ingress-cert`/`ca-bundle.crt` |

## Components

Selected: `acm`, `acm-models`, `ai-grid-policies`, `ai-grid-spokes`, `argo-registration`, `console`,
`external-secrets`, `external-services`, `gitops-config`, `grid-bootstrap`, `limitador-redis`, `maas-db`,
`object-storage/s4`, `rhoai`, `rhoai-prerequisites`, `cluster-config`; and our own `tenant-idp`.

Not selected, and why:

| Component | Why |
|---|---|
| `cert-manager` | The platform installed cert-manager already. |
| `keycloak` | We bring our own (`idp/`), connected through the `idp*` inputs. |
| `metallb` | AWS provides load balancers. |
| `object-storage/odf`, `odf` | S4 provides ACM observability's object storage. |
| `ai-grid-o11y`, `ai-grid-usage-logs` | Loki's storage isn't an input yet (gap). |

## Step 1: prepare the hub

Prerequisites: OpenShift 4.21 or later, a default StorageClass, cert-manager, a `quay.io/rhoai` login in a container
auth file, and `oc`, `kustomize`, `jq`, `git`, `htpasswd`.

1. On a demo.redhat.com cluster, add an htpasswd admin first. The platform's Keycloak is the only sign-in there;
   never delete namespace `keycloak` or IdP `rhbk`.

   ```sh
   scripts/add-htpasswd-admin.sh --kubeconfig HUB_KUBECONFIG --password-file PASSWORD_FILE
   ```

2. Install GitOps, apply the root and seed the pull secret:

   ```sh
   KUBECONFIG=HUB_KUBECONFIG RHOAI_QUAY_AUTH_FILE=~/.config/containers/auth.json ./bootstrap.sh
   ```

## Step 2: install the hub components

Argo CD installs the selected components from the root. Then create the console's secrets with the library's script,
pointed at our Keycloak and a token that can write only the catalog repository:

```sh
AI_GRID_GIT_TOKEN_FILE=TOKEN_FILE KEYCLOAK_NAMESPACE=tenant-idp KEYCLOAK_REALM=tenants \
  bash LIBRARY_CHECKOUT/apps/console/create-secrets.sh
```

Check that every Application reading the library runs the pinned commit:

```sh
scripts/check-revisions.sh --kubeconfig HUB_KUBECONFIG
```

## Upgrade

Change the library commit in `root/kustomization.yaml` (three places, one commit). `deployment-root` applies it and
every component follows; `scripts/check-revisions.sh` confirms it.
