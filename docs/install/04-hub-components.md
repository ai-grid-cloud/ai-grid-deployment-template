# Install the hub components

Argo CD now installs the selected components from the library at your pinned commit, and the template's own tenant
Keycloak. On this page you wait for them, create the console's secrets, and check the result.

## 1. Watch the components install

```sh
watch -n 30 scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops
```

Every Application appears within a few minutes. ACM takes longer:

```sh
scripts/with-cluster.sh hub oc get multiclusterhub -A
```

You should see the MultiClusterHub with status `Running`, about 20 minutes after the bootstrap.

These three wait for the first site to [join the grid](06-join-grid.md), and aren't a problem until then:

| Application | State | Why |
|---|---|---|
| `acm-submariner-local-cluster` | Progressing or Degraded | Submariner has no peer to connect to yet. |
| `limitador-redis` | OutOfSync or Degraded | Its ServiceExport CRD comes with Submariner. |
| `maas-db-local-cluster` | Degraded (ServiceExport) | No Globalnet address until a peer joins. |

## 2. Create the console's secrets

The provider console needs your catalog token for its git writer, and an admin login for the tenant Keycloak. Neither
goes in git. Wait until the tenant Keycloak is `Healthy` and the console's Route exists:

```sh
scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops tenant-idp
scripts/with-cluster.sh hub oc get route ai-grid-provider-console -n ai-grid-provider-console
```

Then create the secrets:

```sh
AI_GRID_GIT_TOKEN_FILE=CATALOG_TOKEN_FILE KEYCLOAK_NAMESPACE=tenant-idp KEYCLOAK_REALM=tenants \
  scripts/create-console-secrets.sh
```

Replace `CATALOG_TOKEN_FILE` with the file that holds your catalog token, such as `~/.ai-grid/catalog-token`
([set up your deployment repository](02-repositories.md#2-create-your-catalog-repository-and-its-token)). The script prints no secret value, and
restarts the console to read the new Secrets. For every variable, and for a hub whose ingress certificate isn't
publicly trusted, see
[provider console](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/4aa1c997d86e88955e3e4ea3017e74bdaa100988/docs/install/hub/05-console-and-model-delivery.md#provider-console).

## 3. Verify

1. Every Application is `Synced` and `Healthy`, except the three in part 1:

   ```sh
   scripts/with-cluster.sh hub oc get applications.argoproj.io -n openshift-gitops \
     -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' \
     | grep -v ' Synced Healthy$'
   ```

   You should see only the Applications listed in part 1.

2. The console is up:

   ```sh
   scripts/with-cluster.sh hub oc get pods -n ai-grid-provider-console
   scripts/with-cluster.sh hub oc get route -n ai-grid-provider-console -o jsonpath='{.items[0].spec.host}{"\n"}'
   ```

   You should see the console pod `3/3 Running` and its hostname, `CONSOLE_HOST`. Open `https://CONSOLE_HOST` and
   sign in as a cluster admin.

## Checkpoint

- Every Application is `Synced` and `Healthy`, apart from the three that wait for a site.
- The MultiClusterHub is `Running`.
- The console opens and you can sign in.

Next: [5. Prepare the site](05-prepare-site.md)
