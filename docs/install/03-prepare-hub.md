# Prepare the hub

On this page you check the hub, install OpenShift GitOps, and apply your root. From then on, Argo CD installs
everything from git.

If the cluster ran an AI Grid hub before, uninstall that hub first ([uninstall](08-uninstall.md)).

## 1. Install OpenShift GitOps and apply your root

Bootstrap the hub:

```sh
make bootstrap
```

It checks your deployment, your registry logins and the hub, then installs OpenShift GitOps, applies `root/` once,
and seeds the registry logins that a Policy copies to every site. It reads the logins from the same auth file as
`make prereqs`, or from `QUAY_AUTH_FILE=AUTH_FILE` if you add it, and never prints them. If your auth file is refused,
nothing on the hub has changed yet.

If your auth file has a general `quay.io` login instead of a `quay.io/rhoai` one, allow it:

```sh
make bootstrap ALLOW_GENERIC_LOGIN=1
```

The guard exists because the hub copies that login to every site's pull secret, and the credential works for all
of your `quay.io` repositories, not only `quay.io/rhoai`.

The hub check it runs before installing prints output similar to the following:

```text
OK       OpenShift 4.21 or later                  4.22.18
OK       default StorageClass                     gp3-csi
OK       cert-manager CRDs
OK       quay.io/rhoai pull secret file           $RHOAI_QUAY_PULL_SECRET_FILE
MISSING  object storage                           Secret open-cluster-management-observability/thanos-object-storage (apps/object-storage)
```

`MISSING object storage` is expected: S4 installs it on the next page. For any other `MISSING` line, see
[troubleshooting](troubleshooting.md#the-hub-check-prints-missing). You should see `Bootstrapped.` at the end.

## 2. Check that Argo CD follows your repository

Wait for `deployment-root`, the Application that syncs `root/`, to sync:

```sh
scripts/with-cluster.sh hub oc wait applications.argoproj.io/deployment-root -n openshift-gitops --for=jsonpath='{.status.sync.status}'=Synced --timeout=10m
```

It can show `OutOfSync` for a few minutes after the bootstrap. You should see
`application.argoproj.io/deployment-root condition met`. On an ACM hub, `oc get application` means ACM's kind; always
write `applications.argoproj.io`.

Check the root ApplicationSet's conditions:

```sh
scripts/with-cluster.sh hub oc get applicationset apps -n openshift-gitops \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

You should see `ParametersGenerated=True` and no `ErrorOccurred=True`. For `missing input: NAME` or
`invalid input: NAME`, see
[troubleshooting](troubleshooting.md#the-root-reports-missing-input-name-or-invalid-input-name).

## Checkpoint

- `make bootstrap` printed `Bootstrapped.`, and its hub check showed `OK` for everything except object storage.
- `deployment-root` is `Synced`, and the root ApplicationSet `apps` reports no error.

Next: [4. Install the hub components](04-hub-components.md)
