#!/usr/bin/env bash
# Make one call to the provider console's API, as the console's own pages do: a
# Connect call through the console's Route, signed in with your hub login
# (.config/HUB/kubeconfig, from make login).
#
#   scripts/console-call.sh METHOD [JSON]
#
# METHOD is a Connect path such as ai_grid.v1.Tenants/Create; JSON defaults to {}.
# The token goes to curl through a header file, never on a command line or in the
# output. A kubeconfig that holds a client certificate instead of a token, such as
# the installer's auth/kubeconfig, can't call the console: run make login NAME=hub.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -ge 1 ] || { echo "usage: console-call.sh METHOD [JSON]" >&2; exit 2; }
method=$1 body=${2:-'{}'}
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
token=$(oc whoami -t 2>/dev/null) ||
  { echo "error: your $hub login has no token (a certificate kubeconfig?): run make login NAME=$hub" >&2; exit 1; }
(umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth"); unset token
console=$(oc get route -n ai-grid-provider-console -o jsonpath='{.items[0].spec.host}')
[ -n "$console" ] || { echo "error: no console Route on $hub yet: see make status" >&2; exit 1; }
curl -sS -X POST -H "@$tmp/auth" -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \
  --data-binary "$body" -w '\nHTTP %{http_code}\n' "https://$console/$method"
