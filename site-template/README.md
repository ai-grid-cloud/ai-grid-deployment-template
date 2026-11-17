# Per-site files

Copy these into your deployment repository for a site, at the same paths with `SITE` replaced by the site's name, and
push them before you add the site to the grid. `make install` writes them for you (`scripts/site-files.sh`); copy
them by hand only on the page-by-page path (pages 1 to 8).

| File | What it does |
|---|---|
| `values/clusters/SITE/rhoai.yaml` | The site's OpenShift AI values: the MaaS gateway's listeners, with its hostname and your certificate, and, on a site that already runs the platform's cert-manager, the chart's cert-manager turned off |
| `sites/SITE/maas-tls/` | A cert-manager `Certificate` for the MaaS hostname, from your DNS-01 ClusterIssuer on the site |
| `apps/SITE-maas-tls.yaml` | The Application that delivers `sites/SITE/maas-tls/` to the site |

Replace the following:

- `SITE`: the site's ACM cluster name.
- `APPS_DOMAIN`: the site's apps domain, as `oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'`
  prints it on the site.
- `DNS01_ISSUER`: a cert-manager ClusterIssuer on the site that issues publicly trusted certificates by DNS-01.

The MaaS hostname is `maas.APPS_DOMAIN`: the install registers the tenant portal's sign-in redirect there.

For an inference site, or a site without a DNS-01 issuer, leave out `sites/SITE/maas-tls/`, `apps/SITE-maas-tls.yaml`
and the `components:` part of the values file. Without a certificate of your own, tenants' clients don't trust the
gateway. For the details, see the library's
MaaS gateway certificate and cert-manager pages, which [Before you add the site](../docs/install/06-join-grid.md#before-you-add-the-site)
links at the library commit you pin.
