# Limits of installing from the library's main branch

This branch of the template installs from the library's `main` branch with no
changes to the library. This page lists what that branch can't do for a
deployment repository, and what the template does about each limit. Each entry
names the file and line in
[`ai-grid-cluster-gitops`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops)
at commit `498527d`, which is upstream `main` (`a9dbf3b`) plus
[PR 322](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/pull/322). The
template pins that commit.

Each entry is a candidate for a library pull request. The template doesn't work
around these limits. It documents them, skips the check, or reports the limit
when an install runs into it.

## Summary

| ID | Limit | What the template does |
|---|---|---|
| L1 | The library's own ApplicationSets read the library at `HEAD` | Reports them (`scripts/check-revisions.sh`); they follow upstream `main` |
| L2 | The console's catalog is the shared environment's | Carries its own copy (`hub/catalog/`, `apps/catalog.yaml`) |
| L3 | The tenant IdP is the library's Keycloak, and only that | Selects the library's Keycloak (core profile); there's no IdP input |
| L4 | A site's values come only from the library | Writes no site files; `make site-add` says why |
| L5 | The MaaS gateway presents the cluster-internal certificate | `ready-check.sh` warns, and `tenant-call.sh` names the limit when it fails |
| L6 | The tenant client has no password grant | `tenant-call.sh` names the limit when it fails |
| L7 | The OpenShift AI nightly and chart follow `HEAD` | Covered by L1; `make prereqs` checks the pin's nightly, not `HEAD`'s |
| L8 | Two odh-gitops charts are read at `main` | Left at `main`, as upstream ships them |
| L9 | ODF is the only observability object store | Selects `apps/odf` |
| L10 | No per-deployment cluster admins | Nothing grants Argo CD admin beyond the operator's default |
| L11 | A fresh hub needs PR 322, which isn't on `main` yet | Pins `498527d`, the PR's commit |
| L12 | `acm-models` bundles samples and a duplicate GitOpsCluster | Doesn't select `acm-models` |
| L13 | The dedicated-hub root re-syncs itself from `HEAD` | Doesn't select `dedicated-hub-root`; has its own root |
| L14 | Keycloak's default profile adds example tenant realms | Selects the core profile |

## L1: the library's own ApplicationSets read `HEAD`

Several components render ApplicationSets that generate Applications reading
the library at `targetRevision: HEAD`:

- `apps/rhoai/hub/01-applicationset.yaml:51,143,162`: each site's OpenShift AI,
  MaaS gateway hostname and nightly catalog.
- `apps/maas-db/hub/05-applicationset.yaml:55`: the MaaS database.
- `apps/acm/manifests/submariner/submariner-applicationset.yaml:24`: Submariner.
- `apps/metallb/hub/00-applicationset.yaml:29,32` and
  `apps/external-services/hub/05-applicationset.yaml:59` (not selected here).

The root pins every Application it generates, through its `templatePatch`
(`root/applicationset.yaml`). Argo CD applies that patch only to the
Applications the root generates, not to the objects they render. So site
installs, the MaaS database and Submariner follow upstream `main`, whatever the
template pins.

**Template:** `scripts/check-revisions.sh` lists them as `HEAD` lines, not
failures.

**Upstream fix:** take the library revision as an input, for example a value
these ApplicationSets read, and let a deployment set it.

## L2: the console's catalog is the shared environment's

`apps/acm-models/hub/catalog-03-appprojects.yaml:19,38`,
`apps/acm-models/hub/catalog-04-applicationsets.yaml:45,56,118,133,194,209` and
`apps/console/application.yaml:57-58` name
`https://github.com/ai-grid-cloud/ai-grid-shared-catalog.git` at `main`.

**Template:**

- The root sets the console's `backend.git.url` and `branch` from
  `catalogRepoURL` and `catalogRevision`.
- `hub/catalog/` is a copy of the two catalog files with this deployment's
  catalog, which `scripts/set-inputs.sh` writes and `scripts/check-deployment.sh`
  checks against `root/inputs.env`.
- The copy can drift from upstream's.

**Upstream fix:** the catalog repository as an input (as in
`feat/deployment-inputs-v2` commit `146fbf0`).

## L3: the tenant IdP is the library's Keycloak

`apps/rhoai/hub/02-ingress-clusters-policy.yaml` hard-codes the tenant IdP:

- `:26`: the Keycloak CA from Route `maas-db/keycloak`.
- `:92,96`: the client secret from Secret `maas-db/keycloak-secrets`, key
  `KEYCLOAK_CLIENT_SECRET`.
- `:125-126,128`: client and audience `tenant-demo`.
- `:132`: issuer `https://<Route maas-db/keycloak>/realms/saas`.

`apps/keycloak/base/manifests/secrets.yaml:236` makes the client ID
`tenant-demo`.

**Template:**

- It selects `apps/keycloak` and drops its own `tenant-idp/`.
- `scripts/create-console-secrets.sh` and `scripts/create-test-tenant.sh`
  default to namespace `maas-db` and realm `saas`.
- There's no bring-your-own IdP.

**Upstream fix:** tenant IdP inputs (as in `feat/deployment-inputs-v2` commit
`f3699e0`).

## L4: a site's values come only from the library

`apps/rhoai/hub/01-applicationset.yaml:65,152` layer
`$values/apps/rhoai/values-<cluster>.yaml`, where `$values` is the library.
A deployment repository can't set a site's values.

**Template:** `scripts/add-site.sh` writes nothing and says why; `make install`
has no site-files step.

**Upstream fix:** read a site's values from the deployment repository (as in
`feat/deployment-inputs-v2` commit `eb38f7d`).

## L5: the MaaS gateway presents the cluster-internal certificate

The ingress and combined profiles of the odh-gitops chart (`3.6.0-dev.36.1`,
pinned at `apps/rhoai/hub/01-applicationset.yaml:55`) set the MaaS HTTPS
listener's certificate to `maas-default-gateway-service-tls`, the
service-serving certificate (`profiles/ai-grid-ingress.yaml:93-101` in that
chart). Tenants call `https://maas.<apps domain>`, which that certificate
doesn't name, and clients don't trust its CA. Changing the listener needs a
site value (L4).

**Template:**

- `scripts/ready-check.sh` prints a `WARN` for each ingress or combined site.
- `scripts/tenant-call.sh` names this limit when TLS verification fails.
- `make prereqs` no longer asks for a DNS-01 ClusterIssuer on sites.

**Upstream fix:** L4. A publicly trusted certificate then needs no library
change.

## L6: the tenant client has no password grant

`apps/keycloak/base/manifests/realms/saas-realm.json:20` sets
`"directAccessGrantsEnabled": false` on `tenant-demo`. The PostSync realm-sync
Jobs (`apps/keycloak/base/manifests/saas-realm-sync.yaml:17,98`) re-apply the
client definition on every sync.

**Template:** `scripts/tenant-call.sh` (page 7) signs in with a password, so on
`main` it stops and names this limit. Tenants use the MaaS portal and an API
key instead.

**Upstream fix:** a test client with direct access grants, or an option on
`tenant-demo`, for automated end-to-end checks.

## L7: the nightly and chart follow `HEAD`

These are read through the `rhoai` ApplicationSet (L1), so a site installs the
nightly at library `HEAD`:

- `apps/rhoai/nightly.yaml:8` (the 3.6 nightly FBC).
- `apps/rhoai/hub/01-applicationset.yaml:55` (the chart version).

**Template:** `make prereqs` checks it can pull the nightly at the template's
pin, which may differ from `HEAD`'s.

## L8: odh-gitops charts at `main`

`apps/grid-bootstrap/application.yaml:13` and
`apps/ai-grid-usage-logs/application.yaml:39` read
`opendatahub-io/odh-gitops` at `main`.

**Template:** leaves them at `main`, as upstream ships them. The root's
`templatePatch` could pin them, but no input names an odh-gitops commit.

## L9: ODF is the only observability object store

`apps/acm/manifests/observability/obc.yaml:1` and
`apps/acm/manifests/observability/observability-bridge-job.yaml:28` take the
store from ODF's Multicloud Object Gateway.

**Template:** selects `apps/odf`, through its own ODF generator: a git files generator matrixed with the hub's
cluster labels, as upstream's root does. That the matrix keeps the git generator's `values` next to the cluster's
labels is checked offline only (`tests/root-selection-test.sh` merges them itself); only a run on a hub shows it. There's no bring-your-own or S4 object
storage (`feat/deployment-inputs-v2` commit `a058013`).

## L10: no per-deployment cluster admins

`apps/gitops-config/manifests/argocd.yaml:21` grants Argo CD admin to Group
`ai-grid-admins`, which nothing on a dedicated hub creates. The lab's
`cluster-config` is selected only by the lab root `bootstrap/applicationset.yaml`.

**Template:** doesn't select `cluster-config`. Only the operator's default
`cluster-admins` binding applies.

## L11: a fresh hub needs PR 322

Without PR 322 (`apps/gitops-config/manifests/argocd.yaml`, the Placement
health check), a Placement that matches no cluster yet is Degraded. So a fresh
hub stops before the image mirror Policy and Loki.

**Template:** pins `498527d`. `LIBRARY_REVISION=main` in `install.env` moves to
upstream `main`, which lacks the fix until PR 322 merges.

## L12: `acm-models` bundles samples and a duplicate GitOpsCluster

`apps/acm-models/hub/` holds:

- the sample model and MaaS objects (`facebook-opt-125m-03-applicationset.yaml`,
  `maas-03-applicationset.yaml`);
- the shared catalog (L2);
- `gitops-cluster.yaml`, which registers every cluster in Argo CD, as
  `apps/argo-registration/manifests/gitops-cluster.yaml` does.

Upstream's dedicated-hub root leaves out the GitOpsCluster
(`bootstrap/dedicated-hub/applicationset.yaml:136`).

**Template:** doesn't select `acm-models`. Its catalog files are copies
(`hub/catalog/`).

## L13: the dedicated-hub root re-syncs itself from `HEAD`

`bootstrap/dedicated-hub/applicationset.yaml:44` selects
`bootstrap/dedicated-hub/application.yaml`, an Application that syncs that
ApplicationSet from `HEAD`.

**Template:** has its own root (`root/applicationset.yaml`), synced by
`deployment-root`, and doesn't select `dedicated-hub-root`.

## L14: Keycloak's default profile adds example tenants

`apps/keycloak/application.yaml:11` installs `overlays/default`, which adds the
example realms `grid-tenant-1-idp` and `grid-tenant-2-idp` and their
organizations.

**Template:** the root sets `apps/keycloak/overlays/core`.
