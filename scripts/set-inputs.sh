#!/usr/bin/env bash
# Set the values that name your repositories and hosts (install guide, page 2),
# then check the repository:
#
#   root/kustomization.yaml             deploymentRepoURL, catalogRepoURL, idpIssuerURL
#   root/self.yaml                      repoURL (deploymentRepoURL)
#   tenant-idp/manifests/settings.yaml  portalRedirectURI
#
# deploymentRepoURL is this repository's origin, catalogRepoURL the argument,
# idpIssuerURL https://keycloak-tenant-idp.HUB_APPS_DOMAIN/realms/tenants, and
# portalRedirectURI https://maas.SITE_APPS_DOMAIN/*, with the apps domains read
# from the hub and the first combined or ingress site in clusters.yaml through
# their logins. Only those REQUIRED-<name> placeholders are replaced; a value
# that's already set is left alone, and so are the root's "op: test" lines.
#
# Usage: scripts/set-inputs.sh CATALOG_REPO_URL
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
[ $# -eq 1 ] || { echo "usage: set-inputs.sh CATALOG_REPO_URL" >&2; exit 2; }

https_url() { # a git remote URL -> https://HOST/OWNER/REPO.git, no credentials
  local u=${1%/}
  case "$u" in
    git@*:*) u="${u#git@}"; u="https://${u/://}" ;;
    ssh://git@*) u="https://${u#ssh://git@}" ;;
  esac
  u=$(sed -E 's#^https://[^@/]+@#https://#' <<<"$u")
  [[ "$u" =~ ^https://[^/]+/.+ ]] || { echo "error: $1 isn't a repository URL" >&2; return 1; }
  [ "${u%.git}" = "$u" ] && u="$u.git"
  echo "$u"
}

catalog=$(https_url "$1")
origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || { echo "error: this repository has no origin remote" >&2; exit 1; }
deployment=$(https_url "$origin")

. "$here/clusters.sh"
clusters_load "$dir"
site=""
for s in $(site_names); do
  case "$(cluster_field "$s" role)" in combined|ingress) site=$s; break ;; esac
done
[ -n "$site" ] || { echo "error: clusters.yaml has no combined or ingress site" >&2; exit 1; }
apps_domain() {
  "$here/with-cluster.sh" "$1" oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
}
hub_domain=$(apps_domain "$(hub_name)") && [ -n "$hub_domain" ] || { echo "error: no apps domain for the hub" >&2; exit 1; }
site_domain=$(apps_domain "$site") && [ -n "$site_domain" ] || { echo "error: no apps domain for $site" >&2; exit 1; }

DIR=$dir python3 - "$deployment" "$catalog" "https://keycloak-tenant-idp.$hub_domain/realms/tenants" \
  "https://maas.$site_domain/*" <<'PY'
import os, sys
deployment, catalog, issuer, redirect = sys.argv[1:]
d = os.environ["DIR"]
sets = [
    ("root/kustomization.yaml", "deploymentRepoURL", deployment),
    ("root/kustomization.yaml", "catalogRepoURL", catalog),
    ("root/kustomization.yaml", "idpIssuerURL", issuer),
    ("root/self.yaml", "deploymentRepoURL", deployment),
    ("tenant-idp/manifests/settings.yaml", "portalRedirectURI", redirect),
]
for path, name, value in sets:
    f = os.path.join(d, path)
    lines = open(f).read().split("\n")
    token = "REQUIRED-" + name
    hit = False
    for i, line in enumerate(lines):
        if token in line and "op: test" not in line:
            lines[i] = line.replace(token, value)
            hit = True
    if hit:
        tmp = f + ".tmp"
        open(tmp, "w").write("\n".join(lines))
        os.replace(tmp, f)
        print(f"set      {path}: {name} = {value}")
    else:
        print(f"kept     {path}: {name} is already set")
PY
"$here/check-deployment.sh" "$dir"
