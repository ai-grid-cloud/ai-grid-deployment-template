# Appendix B: the example deployment

This template is the deployment this guide was tested with on 2026-11-10, with its own names replaced by `REQUIRED-`
placeholders and its site's files moved to `site-template/`: a hub on OpenShift 4.22.18 with ACM 2.17.4, and one
combined site, `site-b`, on OpenShift 4.21.37 (6 nodes, CPU model only), on AWS. The full worked example, with its
names in place, is [`cfchase/ai-grid-deployment-proto`](https://github.com/cfchase/ai-grid-deployment-proto); its
catalog is [`cfchase/ai-grid-catalog-proto`](https://github.com/cfchase/ai-grid-catalog-proto).

## What it chose

| Area | Chose | Where |
|---|---|---|
| Library pin | one SHA, in three places | `root/kustomization.yaml` |
| Components | 16, grouped by hub item | `root/kustomization.yaml` |
| cert-manager | the platform's (not `apps/cert-manager`) | |
| Object storage | S4 (not ODF) | `root/kustomization.yaml` |
| Load balancers | AWS (not MetalLB) | |
| Tenant identity provider | its own community Keycloak 26.8.0, realm `tenants`, client `ai-grid-tenants` (not `apps/keycloak`) | `tenant-idp/`, `apps/tenant-idp.yaml`, the `idp*` inputs |
| Observability and usage logs | off: Loki has no object-storage input yet | |
| Cluster admins | `admin` (an htpasswd break-glass user) | `values/cluster-admins.yaml` |
| Grid CA | a new grid (`Generate`), with the ClusterSet binding | `values/grid-bootstrap.yaml` |
| The site | combined, `location=us-east`, MaaS host `maas.APPS_DOMAIN` on a DNS-01 certificate | `site-template/` |

## Files

| Path | What it is |
|---|---|
| `root/kustomization.yaml` | The library's `bootstrap/hub` at a pinned SHA; the selected components; the 14 inputs; the ODF generator removed; a generator for `apps/*.yaml` |
| `root/self.yaml` | `deployment-root`, which keeps the root in step with git (no prune) |
| `values/cluster-admins.yaml` | `cluster_admins: [admin]` |
| `values/grid-bootstrap.yaml` | A new grid (`Generate`), with the ClusterSet binding |
| `apps/tenant-idp.yaml`, `tenant-idp/` | Its own tenant Keycloak: community Keycloak 26.8.0 pinned by digest, realm `tenants`, client `ai-grid-tenants`, its own CloudNativePG database, `strategy: Recreate`; the client secret in a namespace of its own ([tenant-idp/README.md](../../tenant-idp/README.md)) |
| `site-template/` | One site's files, copied per ingress or combined site: `values/clusters/SITE/rhoai.yaml` (MaaS hostname prefix `maas`, the HTTPS listener on a trusted certificate), `apps/SITE-maas-tls.yaml` and `sites/SITE/maas-tls/certificate.yaml` (a DNS-01 certificate for the MaaS hostname) |
| `scripts/create-test-tenant.sh` | A test tenant user in its Keycloak |
| `docs/install/`, `scripts/sync-guide-pin.sh` | This guide, and the script that points its links into the library at the pin |

Every other script this guide runs is the library's, from `../library/scripts/` at your pin.
