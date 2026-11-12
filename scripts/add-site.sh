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
# Files that already exist are kept as they are; the apps domain and the issuer
# are read only to write a missing one.
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
files=("apps/$name-maas-tls.yaml" "sites/$name/maas-tls/certificate.yaml" "values/clusters/$name/rhoai.yaml")
missing=()
for f in "${files[@]}"; do
  if [ -e "$dir/$f" ]; then echo "kept     $f (exists)"; else missing+=("$f"); fi
done

# The apps domain and the issuer are needed only to write a missing file.
if [ ${#missing[@]} -gt 0 ]; then
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
  DIR=$dir python3 - "$name" "$domain" "$issuer" "${missing[@]}" <<'PY'
import os, sys
name, domain, issuer, *missing = sys.argv[1:]
d = os.environ["DIR"]
for out_rel in missing:
    rel = out_rel.replace(name, "SITE", 1) if out_rel.startswith("apps/") else "/".join("SITE" if p == name else p for p in out_rel.split("/"))
    text = open(os.path.join(d, "site-template", rel)).read()
    text = text.replace("SITE", name).replace("APPS_DOMAIN", domain).replace("DNS01_ISSUER", issuer)
    out = os.path.join(d, out_rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    open(tmp, "w").write(text)
    os.replace(tmp, out)
    print(f"wrote    {out_rel}")
PY
  echo "MaaS hostname maas.$domain, certificate from ClusterIssuer $issuer."
fi
"$here/check-deployment.sh" "$dir"
if [ ${#missing[@]} -eq 0 ] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 &&
   [ -z "$(git -C "$dir" status --porcelain -- "${files[@]}")" ]; then
  echo; echo "Nothing to commit: the site's files are already committed."
  exit 0
fi
cat <<EOF

Commit and push:

  git add ${files[*]}
  git commit -m "site $name: values and MaaS certificate"
  git push origin HEAD:main
EOF
