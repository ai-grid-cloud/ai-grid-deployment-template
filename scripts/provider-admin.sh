#!/usr/bin/env bash
# Give an API-only test suite a provider-admin login on the hub: a ServiceAccount
# bound to the console chart's ClusterRole ai-grid-provider-admin, and a token
# for it in .config/provider-admin-token (git-ignored, mode 600).
#
#   scripts/provider-admin.sh
#
# Inputs: clusters.yaml and the hub's login (.config/HUB/kubeconfig, from make
# login). PROVIDER_ADMIN_TOKEN_DURATION sets the token's lifetime (default 168h).
#
# It applies, so a second run changes nothing: namespace ai-grid-test,
# ServiceAccount ai-grid-test/provider-admin, and ClusterRoleBinding
# ai-grid-test-provider-admin. It makes a new token each run, proves it with one
# call to the console's ai_grid.v1.Clusters/List (HTTP 200), and only then saves
# it. It exits 1, leaving any previous token file as it was, when the ClusterRole
# doesn't exist yet (the console isn't installed), there's no console Route, or
# the console refuses the token. The token goes from oc straight to the file and
# to curl through a header file: never on a command line or in the output.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")
ns=ai-grid-test sa=provider-admin role=ai-grid-provider-admin
token_file="$CLUSTERS_DIR/.config/provider-admin-token"

oc get clusterrole "$role" >/dev/null 2>&1 ||
  { echo "error: no ClusterRole $role on $hub yet: the provider console isn't installed (see make status)" >&2; exit 1; }

oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
---
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: $ns
  name: $sa
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $ns-$sa
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $role
subjects:
  - kind: ServiceAccount
    namespace: $ns
    name: $sa
EOF

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# The new token stays in $tmp until the console accepts it, so a refused token
# never replaces a working one.
( umask 077
  oc create token "$sa" -n "$ns" --duration="${PROVIDER_ADMIN_TOKEN_DURATION:-168h}" > "$tmp/token"
  [ -s "$tmp/token" ] || { echo "error: oc create token gave no token" >&2; exit 1; }
  { printf 'Authorization: Bearer '; tr -d '\r\n' < "$tmp/token"; printf '\n'; } > "$tmp/auth" )

console=$(oc get route -n ai-grid-provider-console -o jsonpath='{.items[*].spec.host}' 2>/dev/null || true)
console=${console%% *}
[ -n "$console" ] || { echo "error: no console Route on $hub yet: see make status" >&2; exit 1; }
code=$(curl -sS -o "$tmp/body" -X POST -H "@$tmp/auth" -H 'Content-Type: application/json' \
  -H 'Connect-Protocol-Version: 1' --data-binary '{}' -w '%{http_code}' \
  "https://$console/ai_grid.v1.Clusters/List") || code=000
if [ "$code" != 200 ]; then
  echo "error: HTTP $code from https://$console/ai_grid.v1.Clusters/List: the console didn't accept the ServiceAccount token; $token_file is unchanged" >&2
  exit 1
fi
mkdir -p "$CLUSTERS_DIR/.config"
mv "$tmp/token" "$token_file"
chmod 600 "$token_file"
echo "The console accepted the provider-admin token (ai_grid.v1.Clusters/List: HTTP 200)"
echo "Wrote the provider-admin token to $token_file"
