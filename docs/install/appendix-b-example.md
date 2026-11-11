# Appendix B: the example deployment

This template is a copy of [`cfchase/ai-grid-deployment-proto`](https://github.com/cfchase/ai-grid-deployment-proto), the
deployment this guide was tested with, on 2026-11-10: one hub (OpenShift 4.22, ACM 2.17) and one combined site
(OpenShift 4.21) on AWS. Its catalog is [`cfchase/ai-grid-catalog-proto`](https://github.com/cfchase/ai-grid-catalog-proto).
A repository you make from the template starts with these files, and
[create your repositories](02-repositories.md) says which ones you change.

| Path | What it is |
|---|---|
| `root/kustomization.yaml` | The library's `bootstrap/hub` at a pinned SHA; the 16 selected components; the 14 inputs; the ODF generator removed; a generator for `apps/*.yaml` |
| `root/self.yaml` | `deployment-root`, which keeps the root in step with git (no prune) |
| `values/cluster-admins.yaml` | `cluster_admins: [admin]` |
| `values/grid-bootstrap.yaml` | A new grid (`Generate`), with the ClusterSet binding |
| `values/clusters/site-b/rhoai.yaml` | MaaS hostname prefix `maas` and the HTTPS listener on a trusted certificate |
| `apps/tenant-idp.yaml`, `idp/` | Its own tenant Keycloak: community Keycloak 26.8.0 pinned by digest, realm `tenants`, client `ai-grid-tenants`, its own CloudNativePG database, `strategy: Recreate`; the client secret in a namespace of its own |
| `apps/site-b-maas-tls.yaml`, `sites/site-b/maas-tls/` | A DNS-01 certificate for the site's MaaS hostname |
| `scripts/create-test-tenant.sh` | A test tenant user in its Keycloak |
| `docs/install/`, `scripts/sync-guide-pin.sh` | This guide, and the script that points its links into the library at the pin |

The scripts this guide runs live in the library's `scripts/`: `bootstrap-hub.sh`, `check-deployment.sh`,
`check-revisions.sh`, `add-htpasswd-admin.sh`, `wipe-site.sh`, `console-call.sh`. The example keeps only
`create-test-tenant.sh`, which is specific to its own Keycloak.

What it chose: [your choices](README.md#your-choices), last column, and each [hub item](https://github.com/cfchase/ai-grid-cluster-gitops/blob/edf8e09fb0de642ff739e0ecbb99605a297035b5/docs/install/hub/README.md)'s "Example chose".
