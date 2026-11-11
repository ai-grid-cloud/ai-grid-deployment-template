# Prepare the hub

On this page you check the hub's infrastructure, install OpenShift GitOps, and apply your root. From then on, Argo CD
installs everything from git.

Set the hub's context once in your shell for this section:

```sh
export HUB_CONTEXT=HUB_CONTEXT_NAME
```

Replace `HUB_CONTEXT_NAME` with the hub's kubeconfig context. Run every command in this section from your deployment
repository's checkout, with the library checked out at your pin in `../library`
([repositories, part 2](02-repositories.md#2-pin-the-library-commit)).

## 1. Add a break-glass admin

If the hub's only sign-in is an external identity provider, add an htpasswd admin first
([cluster sign-in and admins](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/00-platform-services.md#cluster-sign-in-and-admins)):

```sh
oc config use-context "$HUB_CONTEXT"
../library/scripts/add-htpasswd-admin.sh --kubeconfig "$KUBECONFIG" --password-file HUB_ADMIN_PASSWORD_FILE
```

Replace `HUB_ADMIN_PASSWORD_FILE` with a path outside any repository, such as `~/.ai-grid/hub-admin`. The script
generates a password into that file (mode 600) if it doesn't exist and never prints it. If your `KUBECONFIG` lists
several files, pass a single kubeconfig file instead.

You should see the script confirm the sign-in. Sign in once in the web console as `admin` with the
`htpasswd` provider to confirm it yourself. The existing providers are unchanged.

## 2. Check the infrastructure

1. Use the library checkout at your pinned commit, `../library`, from the [repositories page](02-repositories.md#2-pin-the-library-commit).

2. Run the hub check:

   ```sh
   RHOAI_QUAY_PULL_SECRET_FILE=QUAY_AUTH_FILE bash ../library/scripts/check-prerequisites.sh --step hub --context "$HUB_CONTEXT"
   ```

   Replace `QUAY_AUTH_FILE` with your container auth file that holds the `quay.io/rhoai` login, such as
   `~/.config/containers/auth.json`. The check reads nothing from it; it only checks the file exists.

   The output is similar to the following:

   ```text
   OK       OpenShift 4.21 or later                  4.22.18
   OK       default StorageClass                     gp3-csi
   OK       cert-manager CRDs
   OK       quay.io/rhoai pull secret file           $RHOAI_QUAY_PULL_SECRET_FILE
   MISSING  object storage                           Secret open-cluster-management-observability/thanos-object-storage (apps/object-storage)
   ```

3. Fix each `MISSING` line that you didn't select a component for:

   | Line | Fix |
   |---|---|
   | OpenShift version | Upgrade the cluster to 4.21 or later. |
   | default StorageClass | Annotate one StorageClass `storageclass.kubernetes.io/is-default-class=true`. |
   | cert-manager CRDs | Install the cert-manager Operator for Red Hat OpenShift, or select `apps/cert-manager` ([cert-manager](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/00-platform-services.md#cert-manager)). |
   | quay.io/rhoai pull secret file | Log in: `podman login quay.io` with a `quay.io/rhoai` robot token ([OpenShift AI prerequisites](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). |
   | object storage | Expected here if you selected `apps/object-storage/s4` or `odf`: it appears when you [install the hub components](04-hub-components.md). If you bring your own, create the Secret now ([object storage](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/01-acm.md#object-storage)). |

4. If you bring your own tenant identity provider, check its two hub objects as well:

   ```sh
   bash ../library/scripts/check-prerequisites.sh --step hub --context "$HUB_CONTEXT" --expect-idp own \
     --idp-secret IDP_SECRET_NAMESPACE/IDP_SECRET_NAME:IDP_SECRET_KEY --idp-ca IDP_CA_NAMESPACE/IDP_CA_NAME:IDP_CA_KEY
   ```

   Replace the placeholders with your `idpClientSecret*` and `idpCA*` inputs. You should see `OK` on the
   `IdP client secret` and `IdP CA` lines. If your IdP runs on the hub from your own apps (as the example's does),
   these appear only after you install the hub components; run this check again then.

## 3. Install OpenShift GitOps and apply your root

The library's `bootstrap-hub.sh` checks your deployment, installs OpenShift GitOps from the library at your pinned
commit, applies `root/` once, and seeds the
`quay.io/rhoai` and `registry.stage.redhat.io` logins that the prerequisites Policy copies to every site
([OpenShift AI prerequisites](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/06-site-delivery.md#registry-access-and-openshift-ai-prerequisites)). It reads them from the auth file and never prints them. It stops if
`../library` isn't checked out at your `libraryRevision`.

```sh
KUBECONFIG=HUB_KUBECONFIG RHOAI_QUAY_AUTH_FILE=QUAY_AUTH_FILE ../library/scripts/bootstrap-hub.sh --deployment .
```

Replace the following:

- `HUB_KUBECONFIG`: a kubeconfig file whose current context is the hub.
- `QUAY_AUTH_FILE`: the auth file from the previous step, with both logins. Without a stage login the script
  warns, and model images won't pull on the sites.

If the file holds only a general `quay.io` login, the script stops: that login would be copied to every site. Add a
robot token for `quay.io/rhoai`, or accept the risk with `RHOAI_QUAY_ALLOW_GENERIC_LOGIN=1`.

You should see `Bootstrapped.` at the end. The script runs the prerequisites check first and reports what's missing;
the items that this script and the hub components install are expected to be missing.

## 4. Check that Argo CD follows your repository

```sh
oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops deployment-root
oc --context "$HUB_CONTEXT" get applicationset apps -n openshift-gitops \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

On an ACM hub, `oc get application` means ACM's kind; always write `applications.argoproj.io`.

You should see `deployment-root` `Synced`, and the ApplicationSet conditions with `ParametersGenerated=True` and no
`ErrorOccurred=True`. A message `missing input: NAME` or `invalid input: NAME` means an input in your root
([repositories, part 4](02-repositories.md#4-set-every-input)); fix it in git and push.

## Checkpoint

- You can sign in to the hub as the break-glass admin.
- The hub check shows `OK` for everything except the items your selected components install.
- `deployment-root` is `Synced`, and the root ApplicationSet `apps` reports no error.
