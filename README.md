# ai-grid-deployment-proto

A GitHub template for an AI Grid **deployment repository**: what one hub and its sites chose. Create yours with
**Use this template**, then **start at the [install guide](docs/install/README.md)**.

It carries the example deployment's own values. It installs from the component library
[`cfchase/ai-grid-cluster-gitops`](https://github.com/cfchase/ai-grid-cluster-gitops), pinned at one commit, with
models and subscriptions in [`cfchase/ai-grid-catalog-proto`](https://github.com/cfchase/ai-grid-catalog-proto) (also
a template), which only the console's git writer changes. This README records only this deployment's choices;
[Appendix B](docs/install/appendix-b-example.md) annotates every file, and
[create your repositories](docs/install/02-repositories.md#1-create-the-repositories) says which ones you change.

Tested 2026-11-10: a hub on OpenShift 4.22 with ACM 2.17 and one combined site, `site-b`, on OpenShift 4.21, on AWS.

## Choices

| Area | Chose | Where |
|---|---|---|
| Library pin | one SHA, in three places | `root/kustomization.yaml` |
| Components | `acm`, `acm-models`, `ai-grid-policies`, `ai-grid-spokes`, `argo-registration`, `console`, `external-secrets`, `external-services`, `gitops-config`, `grid-bootstrap`, `limitador-redis`, `maas-db`, `object-storage/s4`, `rhoai`, `rhoai-prerequisites`, `cluster-config` | `root/kustomization.yaml` |
| cert-manager | the platform's (not `apps/cert-manager`) | |
| Object storage | S4 (not ODF) | |
| Load balancers | AWS (not MetalLB) | |
| Tenant identity provider | its own community Keycloak 26.8.0, realm `tenants`, client `ai-grid-tenants` (not `apps/keycloak`) | `idp/`, `apps/tenant-idp.yaml`, the `idp*` inputs |
| Observability and usage logs | skipped: Loki has no object-storage input yet | |
| Cluster admins | `admin` (an htpasswd break-glass user) | `values/cluster-admins.yaml` |
| Grid CA | a new grid (`Generate`) | `values/grid-bootstrap.yaml` |
| `site-b` | combined, `location=us-east`, MaaS host `maas.<apps domain>` on a DNS-01 certificate | `values/clusters/site-b/rhoai.yaml`, `apps/site-b-maas-tls.yaml`, `sites/site-b/` |

## Scripts

The install scripts live in the library's `scripts/` from commit `e44fa66` on (`bootstrap-hub.sh`,
`check-deployment.sh`, `check-revisions.sh`, `add-htpasswd-admin.sh`, `wipe-site.sh`, `console-call.sh`), and the guide
runs those. This repository's `bootstrap.sh` and `scripts/` copies stay only until its pin moves past that commit;
`scripts/create-test-tenant.sh` stays, because it's specific to this repository's Keycloak.
