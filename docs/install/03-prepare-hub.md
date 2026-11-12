# Prepare the hub

On this page you check the hub, install OpenShift GitOps, and apply your root. From then on, Argo CD installs
everything from git.

If the cluster ran an AI Grid hub before, uninstall that hub first ([uninstall](08-uninstall.md)).

## 1. Check the infrastructure

```sh
RHOAI_QUAY_PULL_SECRET_FILE=QUAY_AUTH_FILE scripts/check-prerequisites.sh --step hub --cluster hub
```

Replace `QUAY_AUTH_FILE` with your container auth file with both pre-release registry logins
([before you start](01-before-you-start.md)), such as
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

## 2. Install OpenShift GitOps and apply your root

`scripts/bootstrap-hub.sh` checks your deployment, installs OpenShift GitOps, applies `root/` once, and seeds
the registry logins that a Policy copies to every site. It reads them from the auth file and never prints them.

```sh
RHOAI_QUAY_AUTH_FILE=QUAY_AUTH_FILE scripts/bootstrap-hub.sh
```

You should see `Bootstrapped.` at the end. The prerequisites check it runs first reports the items that the hub
components install as missing; that's expected.

## 3. Check that Argo CD follows your repository

```sh
scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops deployment-root
scripts/with-cluster.sh hub oc get applicationset apps -n openshift-gitops \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

On an ACM hub, `oc get application` means ACM's kind; always write `applications.argoproj.io`.

You should see `deployment-root` `Synced`, and the ApplicationSet conditions with `ParametersGenerated=True` and no
`ErrorOccurred=True`. For `missing input: NAME` or `invalid input: NAME`, see
[troubleshooting](troubleshooting.md#the-root-reports-missing-input-name-or-invalid-input-name).

## Checkpoint

- The hub check shows `OK` for everything except object storage.
- `deployment-root` is `Synced`, and the root ApplicationSet `apps` reports no error.
