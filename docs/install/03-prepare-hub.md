# Prepare the hub

On this page you check the hub, install OpenShift GitOps, and apply your root. From then on, Argo CD installs
everything from git.

If the cluster ran an AI Grid hub before, uninstall that hub first ([uninstall](08-uninstall.md)).

## 1. Install OpenShift GitOps and apply your root

Bootstrap the hub:

```sh
make bootstrap
```

It checks your deployment, your registry logins and the hub, labels two of the hub's worker nodes for Submariner's
gateways, then installs OpenShift GitOps, applies `root/` once, and seeds the registry logins that a Policy copies to
every site. It reads the logins from the same auth file as
`make prereqs`, or from `QUAY_AUTH_FILE=AUTH_FILE` if you add it, and never prints them. If your auth file is refused,
nothing on the hub has changed yet. It stops if the auth file has no `registry.stage.redhat.io` login, because sites
pull model runtimes only from there ([limits of `main`, L20](../upstream-main-limits.md#l20-model-runtimes-pull-only-from-registrystageredhatio)).

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
MISSING  object storage                           Secret open-cluster-management-observability/thanos-object-storage (apps/odf writes it once ODF is installed)
```

`MISSING object storage` is expected: ODF object storage installs it on the next page. For any other `MISSING` line, see
[troubleshooting](troubleshooting.md#the-hub-check-prints-missing).

Next it gives the hub its Submariner gateway nodes, because nothing in the library labels them
([limits of `main`, L21](../upstream-main-limits.md#l21-nothing-labels-the-submariner-gateway-nodes)). It prints a
line similar to `hub: labelled worker-a, worker-b submariner.io/gateway=true for Submariner's gateways.`, or `already
labelled` on a hub that has two. If it stops with `needs two Submariner gateway nodes` (or `one`, on single-node OpenShift), the hub has too few workers
outside the control plane, as on a compact cluster: run the `oc label node` command it prints, then run
`make bootstrap` again. You should see `Bootstrapped.` at the end.

## 2. Check that Argo CD follows your repository

Check that `deployment-root`, the Application that syncs `root/`, has synced, and that the root ApplicationSet `apps`
reports no error:

```sh
make status
```

You should see `deployment-root: Synced`, followed by its health, under the hub's name, and no line starting with
`!! The root ApplicationSet apps`. `deployment-root` can show `OutOfSync` for a few minutes after the bootstrap; run
`make status` again until it's `Synced`. For `missing input: NAME` or `invalid input: NAME`, see
[troubleshooting](troubleshooting.md#the-root-reports-missing-input-name-or-invalid-input-name).

## Checkpoint

- `make bootstrap` printed `Bootstrapped.`, and its hub check showed `OK` for everything except object storage.
- Two of the hub's nodes carry `submariner.io/gateway=true`.
- `deployment-root` is `Synced`, and the root ApplicationSet `apps` reports no error.

Next: [4. Install the hub components](04-hub-components.md)
