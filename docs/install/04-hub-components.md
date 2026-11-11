# Install the hub components

Argo CD now installs the components you selected, from the library at your pinned commit. This page waits for them,
creates the secrets that never go in git, and checks the result.

## 1. Watch the components install

```sh
watch -n 30 "oc --context $HUB_CONTEXT get applications.argoproj.io -n openshift-gitops"
```

Components start in sync-wave order: GitOps settings and cluster configuration, then ACM, External Secrets and the
databases, then grid bootstrap, policies and the console. On the tested hub, every Application was created within a
few minutes and ACM's MultiClusterHub reached `Running` in about 20 minutes.

Expected until the first site [joins the grid](06-join-grid.md), and not a problem:

| Application | State | Why |
|---|---|---|
| `acm-submariner-local-cluster` | Progressing or Degraded | Submariner has no peer to connect to yet. |
| `limitador-redis` | OutOfSync or Degraded | Its ServiceExport CRD comes with Submariner. |
| `maas-db-local-cluster` | Degraded (ServiceExport) | No Globalnet address until a peer joins. |

Check ACM:

```sh
oc --context "$HUB_CONTEXT" get multiclusterhub -A
```

You should see the MultiClusterHub with status `Running`.

## 2. Create the secrets that don't go in git

1. **Your tenant identity provider's objects,** if you bring your own: the client Secret and CA ConfigMap that your
   `idp*` inputs name, and anything your IdP's own apps need. See
   [tenant identity provider](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/04-tenant-identity.md#tenant-identity-provider). Then rerun the `--expect-idp own` check from
   [prepare the hub](03-prepare-hub.md#2-check-the-infrastructure).

2. **The provider console's secrets,** if you selected the console: the catalog token for the git writer, and the
   console's Keycloak admin credentials. The console needs a Keycloak tenant IdP with Organizations, with Route
   `keycloak` and Secret `keycloak-secrets` in `KEYCLOAK_NAMESPACE`; with another IdP, skip the console
   ([provider console](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/05-console-and-model-delivery.md#provider-console)).

   The script calls Keycloak with `curl`. On a hub whose ingress certificate isn't publicly trusted, give it the
   ingress CA, and let the backend reach Keycloak in-cluster:

   ```sh
   oc config use-context "$HUB_CONTEXT"
   oc get configmap default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ingress-ca.crt
   AI_GRID_GIT_TOKEN_FILE=CATALOG_TOKEN_FILE KEYCLOAK_NAMESPACE=KEYCLOAK_NAMESPACE KEYCLOAK_REALM=TENANT_REALM \
     CURL_CA_BUNDLE=ingress-ca.crt KEYCLOAK_BACKEND_URL=http://keycloak.KEYCLOAK_NAMESPACE.svc:8080 \
     bash ../library/apps/console/create-secrets.sh
   ```

   With a publicly trusted ingress certificate (as on the tested hub), you can leave out `CURL_CA_BUNDLE` and
   `KEYCLOAK_BACKEND_URL`. *(The private-CA form is unverified.)*

   Replace the following:

   - `CATALOG_TOKEN_FILE`: a file holding a token that can write only your catalog repository.
   - `KEYCLOAK_NAMESPACE`: the hub namespace where the tenant Keycloak runs (`tenant-idp` in the example; the
     library's Keycloak runs in `maas-db`).
   - `TENANT_REALM`: the tenant realm (`tenants` in the example).

   See [provider console](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/05-console-and-model-delivery.md#provider-console) for every variable. The console restarts to read the new Secrets.

## 3. Verify

1. Every Application is `Synced` and `Healthy`, except those in the table in part 1:

   ```sh
   oc --context "$HUB_CONTEXT" get applications.argoproj.io -n openshift-gitops \
     -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' \
     | grep -v ' Synced Healthy$'
   ```

   You should see only the Applications listed in part 1.

2. Every Application that reads the library runs your pinned commit:

   ```sh
   ../library/scripts/check-revisions.sh --deployment . --kubeconfig HUB_KUBECONFIG
   ```

   You should see `N library sources checked, 0 not at SHA7`. The tested hub showed 21 sources before any site
   joined and 28 after. Any `OFF` line names an Application that still reads another commit.

3. The grid's ClusterSet binding exists:

   ```sh
   oc --context "$HUB_CONTEXT" get managedclustersetbinding global -n redhat-ai-grid
   ```

   You should see `global`. grid-bootstrap creates it ([grid bootstrap](https://github.com/cfchase/ai-grid-cluster-gitops/blob/f6ffc2377c29d1b7c68bf737ab2dbf3b47e98d95/docs/install/hub/02-grid.md#grid-bootstrap)).

4. The console is up:

   ```sh
   oc --context "$HUB_CONTEXT" get pods -n ai-grid-provider-console
   oc --context "$HUB_CONTEXT" get route -n ai-grid-provider-console -o jsonpath='{.items[0].spec.host}{"\n"}'
   ```

   You should see the console pod `3/3 Running` and its hostname. Open `https://HOSTNAME` and sign in as a
   cluster admin.

5. Object storage now passes the hub check, if you selected S4 or ODF:

   ```sh
   RHOAI_QUAY_PULL_SECRET_FILE=QUAY_AUTH_FILE bash ../library/scripts/check-prerequisites.sh --step hub --context "$HUB_CONTEXT"
   ```

   You should see only `OK` lines.

## Checkpoint

- Every Application is `Synced` and `Healthy`, apart from the three that wait for a site.
- `check-revisions.sh` reports 0 sources off the pin.
- The hub check is all `OK`.
- The console opens and you can sign in.
