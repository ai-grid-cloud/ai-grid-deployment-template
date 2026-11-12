#!/usr/bin/env bash
# Set the values that name your repositories and hosts (install guide, page 2),
# then check the repository:
#
#   root/inputs.env                     deploymentRepoURL, deploymentRevision,
#                                       catalogRepoURL, catalogRevision, idpIssuerURL
#   tenant-idp/manifests/settings.yaml  portalRedirectURI
#
# deploymentRepoURL is this repository's origin, catalogRepoURL the argument,
# idpIssuerURL https://keycloak-tenant-idp.HUB_APPS_DOMAIN/realms/tenants, and
# portalRedirectURI https://maas.SITE_APPS_DOMAIN/*, with the apps domains read
# from the hub and the first combined or ingress site in clusters.yaml through
# their logins; both revisions are main. root/inputs.env is yours: the
# template has none, and root/kustomization.yaml copies its values into the
# root. A value that's already set, in either file, is left alone.
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

# root/inputs.env: keep each value that's set, add the rest.
path = "root/inputs.env"
f = os.path.join(d, path)
want = [("deploymentRepoURL", deployment), ("deploymentRevision", "main"), ("catalogRepoURL", catalog),
        ("catalogRevision", "main"), ("idpIssuerURL", issuer)]
lines = open(f).read().splitlines() if os.path.exists(f) else [
    "# Your deployment's inputs (install guide, page 2), written by scripts/set-inputs.sh.",
    "# root/kustomization.yaml copies them into the root. This file is yours: the",
    "# template has none. Reference: the library's docs/install/appendix-a-inputs.md.",
]
have = {}
for i, line in enumerate(lines):
    if "=" in line and not line.lstrip().startswith("#"):
        have[line.split("=", 1)[0].strip()] = i
for name, value in want:
    i = have.get(name)
    old = lines[i].split("=", 1)[1].strip() if i is not None else ""
    if old and not old.startswith("REQUIRED-"):
        print(f"kept     {path}: {name} is already set")
        continue
    if i is None:
        lines.append(f"{name}={value}")
    else:
        lines[i] = f"{name}={value}"
    print(f"set      {path}: {name} = {value}")
tmp = f + ".tmp"
open(tmp, "w").write("\n".join(lines) + "\n")
os.replace(tmp, f)

# Placeholders in your other files.
for path, name, value in [("tenant-idp/manifests/settings.yaml", "portalRedirectURI", redirect)]:
    f = os.path.join(d, path)
    text = open(f).read()
    token = "REQUIRED-" + name
    if token in text:
        tmp = f + ".tmp"
        open(tmp, "w").write(text.replace(token, value))
        os.replace(tmp, f)
        print(f"set      {path}: {name} = {value}")
    else:
        print(f"kept     {path}: {name} is already set")
PY
"$here/check-deployment.sh" "$dir"
