# Tenant identity provider

This directory is the deployment's own tenant identity provider: a Red Hat build
of Keycloak in namespace `tenant-idp`, with realm `tenants` and client
`ai-grid-tenants`. It's the prototype's Keycloak skip test. The deployment
doesn't select the library's `keycloak` component, installs this one as its own
app (`apps/tenant-idp.yaml`), and connects it to the library only through the
declared inputs below.

It's adapted from the library's Keycloak, `ai-grid-cluster-gitops`
`apps/keycloak/base` at commit `60578f5` (Apache-2.0). Each copied file names its
source in a header comment. `manifests/realms/tenants-realm.json` is derived from
`apps/keycloak/base/manifests/realms/saas-realm.json@60578f5`; JSON holds no
comments, so its citation is here and in `kustomization.yaml`.

## Inputs this satisfies

Set these in the deployment root's generator `values`. `APPS_DOMAIN` is the hub's
ingress domain.

| Input | Value |
|---|---|
| `idpIssuerURL` | `https://keycloak-tenant-idp.APPS_DOMAIN/realms/tenants` |
| `idpClientID` | `ai-grid-tenants` |
| `idpClientSecretNamespace` | `tenant-idp-client` |
| `idpClientSecretName` | `tenant-idp-client` |
| `idpClientSecretKey` | `client-secret` |
| `idpCANamespace` | `openshift-config-managed` |
| `idpCAName` | `default-ingress-cert` |
| `idpCAKey` | `ca-bundle.crt` |

The client secret lives in its own namespace, `tenant-idp-client`, because the
library's hub-templating service account gets read access to the input Secret's
namespace. That namespace holds only Secret `tenant-idp-client` plus the objects
that make it (a `Password` generator, an `ExternalSecret`, and the Role and
RoleBinding that let Keycloak's `SecretStore` read it), none of which hold a
secret value. The plan's Inputs table lists `tenant-idp` as
`idpClientSecretNamespace`; use `tenant-idp-client`.

For the provider console, run `apps/console/create-secrets.sh` with
`KEYCLOAK_NAMESPACE=tenant-idp` and `KEYCLOAK_REALM=tenants`. It reads Route
`keycloak` and Secret `keycloak-secrets` (`KC_BOOTSTRAP_ADMIN_USERNAME`,
`KC_BOOTSTRAP_ADMIN_PASSWORD`) in that namespace.

## Settings

ConfigMap `tenant-idp-settings` (`manifests/settings.yaml`), key
`portalRedirectURI`, is the tenant portal's redirect URI pattern for client
`ai-grid-tenants`. It ships as `https://REPLACE-ME/*`. Prototype Task 12 sets it to
`site-b`'s MaaS gateway host, for example `https://MAAS_HOST/*`.

The realm is imported only when it doesn't exist (`kc.sh import --override
false`), so editing the ConfigMap after Keycloak's first start doesn't change the
client. Change the redirect URI in the Keycloak admin console as well, or set the
ConfigMap before the first sync.

## How it fits together

1. External Secrets generates the admin password into Secret `keycloak-secrets`
   and the client secret into `tenant-idp-client/tenant-idp-client`, each once
   (`refreshPolicy: CreatedOnce`, `deletionPolicy: Retain`).
2. `SecretStore` `tenant-idp-client` (kubernetes provider) reads that Secret as
   ServiceAccount `tenant-idp-client-reader`, which may only `get` that one
   Secret by name. `ExternalSecret` `keycloak-client` copies it into
   `tenant-idp/keycloak-client`, key `client-secret`.
3. CloudNativePG creates `Cluster` `tenant-idp-db` (one instance, 10Gi on the
   default StorageClass, database and owner `keycloak`) and Secrets
   `tenant-idp-db-app` and `tenant-idp-db-ca`. Keycloak connects with
   `sslmode=verify-full` against that CA.
4. OpenShift assigns Route `keycloak` the host `keycloak-tenant-idp.APPS_DOMAIN`.
   ACM Policy `tenant-idp-public-url` looks it up with a hub template, as the
   library's Keycloak does, and writes it into ConfigMap `tenant-idp-public-url`,
   which sets `KC_HOSTNAME`. Keycloak waits for that ConfigMap before it starts.
5. Keycloak's init container renders `tenants-realm.json` with the client secret
   and the redirect URI into a memory-backed volume. The keycloak container
   imports it if the realm doesn't exist, then starts.

## Prerequisites

- The External Secrets operator (`external-secrets.io/v1`,
  `generators.external-secrets.io/v1alpha1`), installed by the library.
- The CloudNativePG operator, installed cluster-wide by the library's `maas-db`
  component.
- ACM on the hub with ManagedClusterSet `global`, for the public-URL Policy.
- Pull access to `registry.redhat.io` (the cluster's global pull secret).

## Image

The image is `registry.redhat.io/rhbk/keycloak-rhel9:26.4`, a tag, not a digest.
Pinning a digest needs `registry.redhat.io` credentials to look it up; do that
before anything beyond the prototype.

## Prototype-only choices

- `directAccessGrantsEnabled: true` on `ai-grid-tenants`, so the prototype's
  tenant test can get a token with a password grant. Turn it off for real use.
- One Keycloak replica and one database instance.

## Differences from the library's Keycloak

Left out:

- The `keycloak-redirect-uris` and `keycloak-realm-sync` clients, their
  service-account users, CronJob, sync hook and Secrets. The redirect URI is a
  setting here, and Git edits to the realm aren't applied after the first import.
- The example tenant IdP realms, broker identity providers, organizations and
  test users. The provider console creates organizations; users are added
  through the admin API.
- The fixed signing keystore (`keycloak-saas-signing`). Keycloak generates its
  own realm keys and keeps them in its database.
- The shared `maas-db` database. This IdP has its own CloudNativePG cluster.

Kept from `saas-realm.json`: Organizations, the token lifespans, the declarative
user profile with unmanaged attributes editable by admins (the claim mappers read
user attributes `maas_groups`, `maas_org_id`, `maas_org_name` and `maas_roles`),
and the client's six protocol mappers: `groups`, `org_id`, `org_name`, `roles`,
the audience (now `ai-grid-tenants`, the client's own ID) and `token_use: access`.

## Test

```sh
bash idp/tests/render-test.sh
```

It builds the kustomization, renders the realm with dummy values, and checks the
realm, client and mappers. It needs `kustomize` and `python3`, and no cluster.
