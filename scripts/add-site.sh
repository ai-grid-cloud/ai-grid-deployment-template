#!/usr/bin/env bash
# Add a site's files to this deployment repository from site-template/
# (install guide, page 6): its values, which point its MaaS gateway at a
# publicly trusted certificate, the certificate, and the Application that
# delivers it. Only ingress and combined sites need them.
#
#   scripts/add-site.sh [NAME] [ISSUER]
#
# NAME defaults to the only site in clusters.yaml ("site" means the same).
# ISSUER is the site's DNS-01 ClusterIssuer; without it, the site's only one.
# The apps domain comes from the site through its login. Then it runs
# check-deployment.sh and prints the git commands to commit and push.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
. "$here/clusters.sh"
[ $# -le 2 ] || { echo "usage: add-site.sh [NAME] [ISSUER]" >&2; exit 2; }
clusters_load "$dir"
name=$(site_name "${1:-}")
role=$(cluster_field "$name" role)
case "$role" in
  combined|ingress) ;;
  inference) echo "$name is an inference site: it needs no MaaS files. Next: scripts/join-site.sh $name"; exit 0 ;;
  *) echo "error: $name is the hub" >&2; exit 1 ;;
esac
cluster_login_ok "$name"
site_oc() { KUBECONFIG=$(cluster_kubeconfig "$name") oc "$@"; }

domain=$(site_oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
[ -n "$domain" ] || { echo "error: can't read $name's apps domain" >&2; exit 1; }
issuers=$(site_oc get clusterissuers.cert-manager.io -o json |
  jq -r '.items[] | select(any(.spec.acme.solvers[]?; .dns01 != null)) | .metadata.name')
issuer=${2:-}
if [ -n "$issuer" ]; then
  grep -qx -- "$issuer" <<<"$issuers" ||
    { echo "error: $issuer isn't a DNS-01 ClusterIssuer on $name; those are: $(echo ${issuers:-none})" >&2; exit 1; }
else
  case $(grep -c . <<<"$issuers" || true) in
    0) echo "error: $name has no DNS-01 ClusterIssuer; the MaaS certificate needs one (page 1)" >&2; exit 1 ;;
    1) issuer=$issuers ;;
    *) echo "$name has several DNS-01 ClusterIssuers:"; sed 's/^/  /' <<<"$issuers"
       echo "Choose the one that issues publicly trusted certificates for *.$domain, and run:"
       echo "  scripts/add-site.sh $name ISSUER"
       exit 1 ;;
  esac
fi

DIR=$dir python3 - "$name" "$domain" "$issuer" <<'PY'
import os, sys
name, domain, issuer = sys.argv[1:]
d = os.environ["DIR"]
for rel in ["apps/SITE-maas-tls.yaml", "sites/SITE/maas-tls/certificate.yaml", "values/clusters/SITE/rhoai.yaml"]:
    text = open(os.path.join(d, "site-template", rel)).read()
    text = text.replace("SITE", name).replace("APPS_DOMAIN", domain).replace("DNS01_ISSUER", issuer)
    out = os.path.join(d, rel.replace("SITE", name))
    if os.path.exists(out):
        if open(out).read() == text:
            print(f"kept     {os.path.relpath(out, d)} (already written)")
            continue
        sys.exit(f"error: {os.path.relpath(out, d)} exists and differs; remove it to write it again")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    open(tmp, "w").write(text)
    os.replace(tmp, out)
    print(f"wrote    {os.path.relpath(out, d)}")
PY
echo "MaaS hostname maas.$domain, certificate from ClusterIssuer $issuer."
"$here/check-deployment.sh" "$dir"
cat <<EOF

Commit and push:

  git add apps/$name-maas-tls.yaml sites/$name values/clusters/$name
  git commit -m "site $name: values and MaaS certificate"
  git push origin HEAD:main
EOF
