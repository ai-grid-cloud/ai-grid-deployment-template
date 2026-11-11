# Prepare the hub

On this page you check the hub, install OpenShift GitOps, and apply your root. From then on, Argo CD installs
everything from git.

Set the hub's context and a kubeconfig file for it:

```sh
export HUB_CONTEXT=HUB_CONTEXT_NAME HUB_KUBECONFIG=HUB_KUBECONFIG_FILE
```

Replace `HUB_CONTEXT_NAME` with the hub's kubeconfig context, and `HUB_KUBECONFIG_FILE` with a kubeconfig file whose
current context is the hub.

## 1. Add a break-glass admin

Add an htpasswd admin before anything else. If the hub's external sign-in breaks later, it's the only way back in:

```sh
oc config use-context "$HUB_CONTEXT"
../library/scripts/add-htpasswd-admin.sh --kubeconfig "$HUB_KUBECONFIG" --password-file HUB_ADMIN_PASSWORD_FILE
```

Replace `HUB_ADMIN_PASSWORD_FILE` with a path outside any repository, such as `~/.ai-grid/hub-admin`. The script
generates a password into that file if it doesn't exist and never prints it.

You should see the script confirm the sign-in. Sign in once in the web console as `admin` with the `htpasswd`
provider. Never delete an identity provider, or the namespace that runs it, that your platform's sign-in depends on
([cluster sign-in and admins](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/af39e2d92420931c1865d5d28a646030fbea8cf9/docs/install/hub/00-platform-services.md#cluster-sign-in-and-admins)).

## 2. Check the infrastructure

```sh
RHOAI_QUAY_PULL_SECRET_FILE=QUAY_AUTH_FILE bash ../library/scripts/check-prerequisites.sh --step hub --context "$HUB_CONTEXT"
```

Replace `QUAY_AUTH_FILE` with your container auth file with both registry logins, such as
`~/.config/containers/auth.json`. The check only checks that the file exists.

The output is similar to the following:

```text
OK       OpenShift 4.21 or later                  4.22.18
OK       default StorageClass                     gp3-csi
OK       cert-manager CRDs
OK       quay.io/rhoai pull secret file           $RHOAI_QUAY_PULL_SECRET_FILE
MISSING  object storage                           Secret open-cluster-management-observability/thanos-object-storage (apps/object-storage)
```

`MISSING object storage` is expected: S4 installs it on the next page. For any other `MISSING` line, see
[troubleshooting](troubleshooting.md#the-hub-check-prints-missing).

## 3. Install OpenShift GitOps and apply your root

The library's `bootstrap-hub.sh` checks your deployment, installs OpenShift GitOps, applies `root/` once, and seeds
the registry logins that a Policy copies to every site. It reads them from the auth file and never prints them.

```sh
KUBECONFIG="$HUB_KUBECONFIG" RHOAI_QUAY_AUTH_FILE=QUAY_AUTH_FILE ../library/scripts/bootstrap-hub.sh --deployment .
```

You should see `Bootstrapped.` at the end. The prerequisites check it runs first reports the items that the hub
components install as missing; that's expected.

## 4. Check that Argo CD follows your repository

```sh
oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops deployment-root
oc --context "$HUB_CONTEXT" get applicationset apps -n openshift-gitops \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

On an ACM hub, `oc get application` means ACM's kind; always write `applications.argoproj.io`.

You should see `deployment-root` `Synced`, and the ApplicationSet conditions with `ParametersGenerated=True` and no
`ErrorOccurred=True`. For `missing input: NAME` or `invalid input: NAME`, see
[troubleshooting](troubleshooting.md#the-root-reports-missing-input-name-or-invalid-input-name).

## Checkpoint

- You can sign in to the hub as the break-glass admin.
- The hub check shows `OK` for everything except object storage.
- `deployment-root` is `Synced`, and the root ApplicationSet `apps` reports no error.
