# Limits of installing from the library's main branch

This branch of the template tracks the library's `main` branch directly. It
carries no library patches or overlays; its only copies of library files are
the catalog's AppProjects and ApplicationSets in `hub/catalog/` (L2). This page lists what that branch can't do for a
deployment repository, and what the template does about each limit. Each entry
names the file and line in
[`ai-grid-cluster-gitops`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops)
at commit `a3c63a9`, upstream `main` with
[PR 322](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/pull/322)
merged; a later `main` can move a line. The template follows `main`
(`libraryRevision` in `root/applicationset.yaml`). To pin a commit instead, see
[Follow the library or pin it](../README.md#follow-the-library-or-pin-it).

Each entry is a candidate for a library pull request. The template doesn't work
around these limits. It documents them, skips the check, or reports the limit
when an install runs into it. **Fix: upstream PR** names what a library pull
request would add. [Losses compared with the earlier library
branch](#losses-compared-with-the-earlier-library-branch) lists the limits the
template's earlier library branch didn't have.

## Summary

| ID | Limit | What the template does |
|---|---|---|
| L1 | The library's own ApplicationSets read the library at `HEAD` | Reports them (`scripts/check-revisions.sh`); they follow upstream `main`, which matters only when you pin a commit |
| L2 | The console's catalog is the shared environment's | Carries its own copy (`hub/catalog/`, `apps/catalog.yaml`) |
| L3 | The tenant IdP is the library's Keycloak, and only that | Selects the library's Keycloak; there's no IdP input |
| L4 | Sites that need per-site values: the platform's cert-manager, GPU settings, a trusted MaaS certificate | Writes no site files; refuses `maasCertificate`; `make site-check` stops a site that runs its own cert-manager |
| L5 | The MaaS gateway presents the cluster-internal certificate | `tenant-call.sh` names the limit when TLS verification fails |
| L6 | No scripted tenant sign-in | `tenant-call.sh` takes an API key a tenant created in the Org UI |
| L7 | The OpenShift AI nightly and chart follow `HEAD` | Covered by L1; `make prereqs` checks the nightly at your library revision |
| L8 | Two odh-gitops charts are read at `main` | Left at `main`, as upstream ships them |
| L9 | ODF is the only observability object store | Selects `apps/odf` |
| L10 | No per-deployment cluster admins | Nothing grants Argo CD admin beyond the operator's default |
| L11 | Resolved: a fresh hub needed PR 322 | Follows `main`, which includes it |
| L12 | `acm-models` bundles samples and a duplicate GitOpsCluster | Doesn't select `acm-models` |
| L13 | The dedicated-hub root re-syncs itself from `HEAD` | Doesn't select `dedicated-hub-root`; has its own root |
| L14 | Keycloak's default profile adds example organizations and test users | `keycloakOverlay`: `core` by default; `default` for test deployments only; chosen before the first push |
| L15 | The tenant client secret shares a Secret with the Keycloak admin password | Documents it |
| L16 | A Keycloak version bump can run two versions against one database | Documents it |
| L17 | The hub's cert-manager has one owner: the library or the platform | `hubCertManager`: `library` by default, or `platform`; `make install` stops on a conflict; `site` is still accepted, with a warning (L18) |
| L18 | All-in-one (unsupported): a hub that is also a site | `make install` refuses `sites: []`, except with `HUB_ONLY=1`; no script uses the hub as a site |
| L19 | Merged into L18 | — |
| L20 | Model runtimes pull only from `registry.stage.redhat.io` (pre-release nightlies) | Requires a stage login: `make prereqs` reports `FAIL`, `make bootstrap` stops |
| L21 | Nothing labels the Submariner gateway nodes | `make bootstrap` and `make site-import` label two workers on each cluster; `make site-check` checks a site can get them |

## Losses compared with the earlier library branch

The template's earlier library branch had these, and the library's `main`
branch doesn't. The template accepts each loss until a library pull request
adds it back:

- Pinning below the top level: every Application the library renders reads
  the commit you pin (L1, L7).
- Per-site values, and with them the platform's own cert-manager, GPU
  settings and a publicly trusted MaaS certificate (L4, L5).
- A bring-your-own tenant IdP, through the `idp*` inputs (L3).
- Bring-your-own or S4 object storage (L9).
- Per-deployment cluster admins (L10).
- A model runtime pull with no stage login, which fell back to
  `registry.redhat.io` (L20).

## L1: the library's own ApplicationSets read `HEAD`

Several components render ApplicationSets that generate Applications reading
the library at `targetRevision: HEAD`:

- `apps/rhoai/hub/01-applicationset.yaml:51,143,162`: each site's OpenShift AI,
  MaaS gateway hostname and nightly catalog.
- `apps/maas-db/hub/05-applicationset.yaml:55`: the MaaS database.
- `apps/acm/manifests/submariner/submariner-applicationset.yaml:24`: Submariner.
- `apps/metallb/hub/00-applicationset.yaml:29,32` and
  `apps/external-services/hub/05-applicationset.yaml:59` (not selected here).

The root sets every Application it generates to `libraryRevision`, through
its `templatePatch` (`root/applicationset.yaml`). Argo CD applies that patch
only to the Applications the root generates, not to the objects they render.
So site installs, the MaaS database and Submariner follow upstream `main`,
whatever the deployment pins.

By default the root follows `main` too, so the two agree, give or take an Argo
CD refresh. The limit matters when you pin a commit: these Applications keep
following `main` past your pin.

**Template:** `scripts/check-revisions.sh` lists them as `HEAD` lines, not
failures.

**Fix: upstream PR** that takes the library revision as an input, a value
these ApplicationSets read, so a deployment pins every Application it renders.

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

**Fix: upstream PR** that takes the catalog repository and revision as
inputs (as in `feat/deployment-inputs-v2` commit `146fbf0`).

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

- It selects `apps/keycloak`, the only tenant IdP, and has no IdP of its own.
- `scripts/create-console-secrets.sh` defaults to namespace `maas-db` and realm
  `saas`, and waits for Application `keycloak`.
- The library's CronJob `keycloak-redirect-uris` registers each ingress or
  combined site's portal redirect,
  `https://maas.SITE_APPS_DOMAIN/oauth2/callback`; the template has no
  redirect step.
- There's no bring-your-own IdP. `make inputs` removes the `idp*` inputs and
  `portalRedirectURI` from an older `root/inputs.env`.

**Fix: upstream PR** that adds tenant IdP inputs: the issuer URL, the client
ID, and the client secret's and CA's Secret and key (as in
`feat/deployment-inputs-v2` commit `f3699e0`).

## L4: sites that need per-site values

`apps/rhoai/hub/01-applicationset.yaml:65,152` layer
`$values/apps/rhoai/values-<cluster>.yaml`, where `$values` is the library.
A deployment repository can't set a site's values, so a site that needs any of
these can't have it:

- **The platform's own cert-manager.** `apps/rhoai/values.yaml` doesn't set
  the chart's `dependencies.certManager.enabled`, which defaults to `auto`. On
  a site that already runs the platform's cert-manager Operator, with an
  OperatorGroup in namespace `cert-manager-operator` other than the chart's
  `openshift-cert-manager-operator`, the chart adds a second OperatorGroup.
  OLM then fails the cert-manager Operator with `TooManyOperatorGroups`, and
  OpenShift AI waits on it. Such a site can't join.
- **GPU settings,** such as a site's NFD and `ClusterPolicy` overrides.
- **A publicly trusted MaaS certificate** on the gateway's HTTPS listener (L5).

**Template:**

- The install writes no site files: there's no `site-template/`, `sites/` or
  `values/clusters/`.
- A site's `maasCertificate` in `clusters.yaml` is an error that names this
  page.
- `make site-check`, and the install's `site` step, print `FOUND` for a site's
  `cert-manager OperatorGroup` and stop.

**Fix: upstream PR.** The first pull request adds an optional deployment
values source to `apps/rhoai/hub/01-applicationset.yaml`: the chart and
`gateway-hostname` also read `$deployment/values/clusters/<site>/rhoai.yaml`,
and a root can set which repository `$deployment` is. With that, the three
cases above need no other library change.

## L5: the MaaS gateway presents the cluster-internal certificate

The ingress and combined profiles of the odh-gitops chart (`3.6.0-dev.36.1`,
pinned at `apps/rhoai/hub/01-applicationset.yaml:55`) set the MaaS HTTPS
listener's certificate to `maas-default-gateway-service-tls`, the
service-serving certificate (`profiles/ai-grid-ingress.yaml:93-101` in that
chart). Tenants call `https://maas.<apps domain>`, which that certificate
doesn't name, and clients don't trust its CA. The library sets the gateway
hostname, `maas.<apps domain>`. Changing the listener's certificate needs a
site value (L4).

**Template:**

- `make site-status` says the gateway answers with the cluster's internal
  certificate.
- `scripts/tenant-call.sh` names this limit when TLS verification fails.
- `make prereqs` doesn't ask for a ClusterIssuer on sites.

**Fix: upstream PR:** the per-site values source in L4.

## L6: no scripted tenant sign-in

`apps/keycloak/base/manifests/realms/saas-realm.json:20` sets
`"directAccessGrantsEnabled": false` on `tenant-demo`. The PostSync realm-sync
Jobs (`apps/keycloak/base/manifests/saas-realm-sync.yaml:17,98`) re-apply the
client definition on every sync.

**Template:** there's no scripted sign-in and no test tenant user. A tenant
user signs in to the Org UI at `https://maas.SITE_APPS_DOMAIN/maas-portal`,
creates an API key there and saves it to a file. `make tenant-call
KEY_FILE=FILE MODEL=MODEL` (page 7) calls the model with that key.

**Fix: upstream PR** that adds a test client with direct access grants, or an
option on `tenant-demo`, for automated end-to-end checks.

## L7: the nightly and chart follow `HEAD`

These are read through the `rhoai` ApplicationSet (L1), so a site installs the
nightly at library `HEAD`:

- `apps/rhoai/nightly.yaml:8` (the 3.6 nightly FBC).
- `apps/rhoai/hub/01-applicationset.yaml:55` (the chart version).

**Template:** `make prereqs` checks it can pull the nightly at your library
revision. Following `main`, that's `HEAD`'s nightly as `make prereqs` fetched
it; with a pinned commit, it may differ from `HEAD`'s.

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
cluster labels, as upstream's root does. That the matrix keeps the git
generator's `values` next to the cluster's labels is checked offline only
(`tests/root-selection-test.sh` merges them itself); only a run on a hub shows
it.

**Fix: upstream PR** that selects the object store per deployment: ODF, S4, or
a bucket you bring with its Secret (as in `feat/deployment-inputs-v2` commit
`a058013`).

## L10: no per-deployment cluster admins

`apps/gitops-config/manifests/argocd.yaml:21` grants Argo CD admin to Group
`ai-grid-admins`, which nothing on a dedicated hub creates. The lab's
`cluster-config` is selected only by the lab root `bootstrap/applicationset.yaml`.

**Template:** doesn't select `cluster-config`, and has no
`values/cluster-admins.yaml`. Only the operator's default `cluster-admins`
binding applies.

**Fix: upstream PR** that reads a per-deployment `cluster-admins` file from the
deployment repository, and renders no binding without one.

## L11: resolved, a fresh hub needed PR 322

Without PR 322 (`apps/gitops-config/manifests/argocd.yaml`, the Placement
health check), a Placement that matches no cluster yet is Degraded, and a fresh
hub stops before the image mirror Policy and Loki. PR 322 is merged, and the
template follows `main`, which includes it. A deployment that pins a commit
needs `a3c63a9` or later.

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

## L14: Keycloak's default profile adds example organizations and test users

`apps/keycloak/application.yaml:11` installs `overlays/default`, which adds the
example realms `grid-tenant-1-idp` and `grid-tenant-2-idp`, their test users,
and the organizations `grid-tenant-1` and `grid-tenant-2` in realm `saas`.

**Template:** the input `keycloakOverlay` in `root/inputs.env` chooses the
overlay:

- `core`, the default: the `saas` broker realm with no example organizations
  or test users.
- `default`: the library's example organizations and test users, for test
  deployments only. Never use it on a real install: the test users' passwords
  are in Secret `maas-db/keycloak-secrets` on the hub, and anyone who reads
  them signs in as a tenant. The ready check reports the example organizations
  as `INFO`, and none as `WARN` (realm `saas` needs a re-import).

Choose it before the first push. Keycloak creates the example organizations
only when it first imports realm `saas`
([`apps/keycloak/base/manifests/keycloak.yaml:84`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/apps/keycloak/base/manifests/keycloak.yaml#L84),
`kc.sh import --override false`), and the realm sync never creates
organizations ([`apps/keycloak/README.md:243`](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/apps/keycloak/README.md?plain=1#L243)). So `core` then `default` on an installed hub
adds the example realms and identity providers but no organizations. `make
inputs` and `make install` stop when `root/inputs.env` says `default` and the
pushed branch says `core`, unless `KEYCLOAK_OVERLAY_CHANGE=1`; the fix is a
[re-import of realm `saas`](install/troubleshooting.md#example-organizations-are-missing-after-switching-keycloakoverlay-to-default).

## L15: the tenant client secret shares a Secret with the Keycloak admin password

`apps/rhoai/hub/02-ingress-clusters-policy.yaml:96` copies the tenant client's
secret, `KEYCLOAK_CLIENT_SECRET`, from Secret `maas-db/keycloak-secrets`. That
Secret also holds the Keycloak bootstrap admin password,
`KC_BOOTSTRAP_ADMIN_PASSWORD` (`apps/keycloak/base/manifests/secrets.yaml:219,248,257`).
Whoever can read the client secret can read the admin password. This is a
known library gap.

**Template:** documents it.

**Fix: upstream PR** that moves the client secret to a Secret of its own.

## L16: a Keycloak version bump can run two versions against one database

`apps/keycloak/base/manifests/keycloak.yaml:14-15` sets the Keycloak
Deployment's `strategy` to `RollingUpdate`. During a rollout the old and new
pods run together against one database. Two Keycloak versions must never do
that: moving from 26.4 to 26.6 showed it. So a version bump can fail.

**Template:** documents it.

**Fix: upstream PR** that sets `strategy: Recreate` on the Keycloak Deployment.

## L17: the hub's cert-manager is the library's or the platform's, not both

Grid enrollment needs cert-manager on the hub. Upstream's dedicated-hub root
installs the library's `apps/cert-manager`, whose OperatorGroup in
`cert-manager-operator` is `openshift-cert-manager-operator`, the same name the
OpenShift AI chart uses. Many clusters, such as demo.redhat.com's, ship the
platform's cert-manager instead, with another OperatorGroup in that namespace.
Two OperatorGroups in one namespace fail every operator there
(`TooManyOperatorGroups`).

**Template:** the input `hubCertManager` in `root/inputs.env` chooses:

- `library` (the default): the root selects `apps/cert-manager`, as upstream's
  root does. `make install` stops before it writes to the hub if the hub
  already runs the platform's cert-manager.
- `platform`: the root's `cert-manager` Application selects no file, and the
  hub's platform cert-manager stays the only one.
- `site` was only for an all-in-one, which isn't supported (L18). The root
  still accepts it, so an existing deployment's root renders, and
  `scripts/check-deployment.sh` (`make check`, `make inputs`) warns about it.

Switching an installed hub from `library` to `platform` leaves the library's
cert-manager in place: Argo CD doesn't prune an Application that renders
nothing.

**Fix: upstream PR**, the same as L4's.

## L18: all-in-one (unsupported)

The supported minimum is a dedicated hub and at least one site, on two
clusters. A hub that is also a site, one cluster with `local-cluster` added to
the grid, isn't supported. At library commit `a3c63a9`, such a cluster has
these problems:

- The hub and the site both own the Loki operator's objects, so two
  Applications manage them.
- The usage-log site Policy leaves out the hub:
  `apps/ai-grid-usage-logs/values.yaml` sets `excludeLocalCluster: true`, so the
  hub never gets the usage-log credentials. The Org UI's usage views return
  `401`, and the provider console's Usage tab stays empty (RHAI-48872).
- PersesDatasource `redhat-ods-monitoring/usage-logs-all` has two owners: the
  hub's `ai-grid-o11y` Application and the site's `maas-controller`. Argo CD
  reverts the site's change, so the Org UI's admin usage view fails.
- The hub's cert-manager needed a third owner, `hubCertManager=site`, so that
  OpenShift AI's chart on the hub took over the cert-manager the library
  installed (L17).
- The root leaves out Limitador's shared-storage files on the hub, and the
  library's Limitador placement leaves out `local-cluster`, so the hub's
  Limitador keeps its counters in memory and doesn't share rate limits with
  other ingress sites.

A fix,
[cluster-gitops PR #337](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/pull/337),
was closed without merging.

**Template:** `make install` stops before any cluster call when `sites:` in
`clusters.yaml` is empty; only `make install HUB_ONLY=1` accepts `sites: []`,
for a hub whose sites you add later. `make status`, `make site-status`,
`make tenant-call` and the ready check never use the hub as a site.
`hubCertManager=site` still renders, with a warning (L17).

**Fix:** none planned. Use two clusters or more.

**If you already run an all-in-one:** take `local-cluster` out of the grid
first (in the provider console, or remove its `ai-grid/enabled` label), wait
until its site Applications are gone, then set `hubCertManager=library` in
`root/inputs.env`, commit and push it. Add a second cluster as a site with
`make site-import`.

## L19: merged into L18

This entry is now part of [L18](#l18-all-in-one-unsupported).

## L20: model runtimes pull only from `registry.stage.redhat.io`

`apps/rhoai-prerequisites/hub/03-policy.yaml:314-331` gives every site an
`ImageDigestMirrorSet` that mirrors `registry.redhat.io/rhaii`,
`rhaii-early-access` and `rhaii-fast` to `registry.stage.redhat.io`. On a site
that isn't HCP, each mirror has `mirrorSourcePolicy: NeverContactSource`, so
the node never falls back to `registry.redhat.io`. Without a
`registry.stage.redhat.io` login in the pull secret, no model runtime image
pulls there. On an HCP site the policy only informs, so the mirrors aren't
written.

The login is required while you install pre-release (nightly) builds. It goes
away with the released catalog at OpenShift AI 3.6 GA, when the pre-release
mirrors do.

**Template:** requires the stage login. `make prereqs` reports
`FAIL registry.stage.redhat.io login` without it, and `make bootstrap` stops
before any write. The login goes in the same auth file as the `quay.io/rhoai`
one (`podman login registry.stage.redhat.io`), or under `stage:` in
`.config/clusters.yaml`. The hub copies it to every site's pull secret.

**Fix: upstream PR** that lets the mirrors fall back to `registry.redhat.io`
(no `NeverContactSource` on the `rhaii*` sources), or makes the stage mirrors
an input, so a deployment without a stage login pulls released runtimes.

## L21: nothing labels the Submariner gateway nodes

`apps/acm/submariner/values.yaml:8` asks for two Submariner gateways on every
managed cluster, the hub (`local-cluster`) included, through the
`SubmarinerConfig`'s `gatewayConfig.gateways`
(`apps/acm/submariner/templates/submariner.yaml:23-24`). Only the add-on's
cloud-prepare step acts on it, and that needs a cloud credentials Secret the
library never gives it: it logs `no CredentialsSecret` and labels nothing.
The library's labelling Policy,
`cluster-config/chart/templates/submariner-gateway-nodes.yaml:50-58`, labels
every node whose only role is `worker`, but `cluster-config` is selected only by
the lab root `bootstrap/applicationset.yaml:37`, not by the dedicated-hub root
(L10). Its
[site requirements](https://github.com/ai-grid-cloud/ai-grid-cluster-gitops/blob/a3c63a980d3130a81af0b367039b547c5c738f22/docs/acm/cluster-onboarding/README.md#what-the-site-must-provide)
say to label two workers `submariner.io/gateway=true` on each cluster by hand.
A cluster without the label runs no Submariner gateway, so the sites can't reach
the hub's services over Submariner, such as `limitador-redis` and the MaaS
database.

**Template:** `scripts/gateway-nodes.sh` labels them. `make bootstrap` runs it
on the hub before its first write, `make install` on every run, and
`make site-import CONFIRM=1` on the site before the import. When fewer than two
nodes carry `submariner.io/gateway=true`, it labels Ready, schedulable workers
outside the control plane, by name: nodes whose only role is `worker` first,
GPU nodes last, and it says when it uses a GPU node. It never removes or changes
a label. A GPU or infra node it falls back to may carry taints the gateway pods
don't tolerate; check that the gateway pods run there. On a compact cluster or
single-node OpenShift it labels nothing and stops with the `oc label` command
to run, except on a hub installed with `make install HUB_ONLY=1` and no sites yet
(`sites: []`), which has no tunnel to carry until its first site joins, where it
only warns; single-node OpenShift needs one gateway node. `make site-check` reports what the import would label, or
`MISSING` with that command.

**Fix: upstream PR** that labels the gateway nodes on every root the library
ships, such as by moving the `submariner-gateway-nodes` Policy out of
`cluster-config` into `apps/acm`, choosing two nodes rather than every worker.
