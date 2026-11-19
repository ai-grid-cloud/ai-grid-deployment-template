#!/usr/bin/env bash
# Make one call to the provider console's API, as the console's own pages do: a
# Connect call through the console's Route, signed in with your hub login
# (.config/HUB/kubeconfig, from make login).
#
#   scripts/console-call.sh METHOD [JSON]
#
# METHOD is a Connect path such as ai_grid.v1.Tenants/Create; JSON defaults to {}.
# It prints the reply and "HTTP CODE", and exits 1 unless the code is 2xx. When
# stdout isn't a terminal, stdout is the reply alone, so you can pipe it to jq.
# The token goes to curl through a header file, never on a command line or in the
# output. A kubeconfig that holds a client certificate instead of a token, such as
# the installer's auth/kubeconfig, can't call the console: run make login NAME=hub.
# CONSOLE_TOKEN_FILE names a file holding another token to call with instead,
# such as .config/provider-admin-token (scripts/test-tenants.sh).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
[ $# -ge 1 ] || { echo "usage: console-call.sh METHOD [JSON]" >&2; exit 2; }
method=$1 body=${2:-'{}'}
clusters_load "$here/.."
hub=$(hub_name)
cluster_login_ok "$hub"
cluster_tls "$hub"   # the hub's ca: in clusters.yaml, for the call to its console
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
if [ -n "${CONSOLE_TOKEN_FILE:-}" ]; then
  # Another identity's token, from a file, such as make provider-admin's.
  [ -s "$CONSOLE_TOKEN_FILE" ] || { echo "error: no token in CONSOLE_TOKEN_FILE $CONSOLE_TOKEN_FILE" >&2; exit 1; }
  (umask 077; { printf 'Authorization: Bearer '; tr -d '\r\n' < "$CONSOLE_TOKEN_FILE"; printf '\n'; } > "$tmp/auth")
else
  token=$(oc whoami -t 2>/dev/null) ||
    { echo "error: your $hub login has no token (a certificate kubeconfig?): run make login NAME=$hub" >&2; exit 1; }
  (umask 077; printf 'Authorization: Bearer %s\n' "$token" > "$tmp/auth"); unset token
fi
console=$(oc get route -n ai-grid-provider-console -o jsonpath='{.items[0].spec.host}')
[ -n "$console" ] || { echo "error: no console Route on $hub yet: see make status" >&2; exit 1; }
code=$(curl -sS ${CURL_TLS[@]+"${CURL_TLS[@]}"} -o "$tmp/body" -X POST -H "@$tmp/auth" -H 'Content-Type: application/json' \
  -H 'Connect-Protocol-Version: 1' --data-binary "$body" -w '%{http_code}' "https://$console/$method")
cat "$tmp/body"; echo
# On a terminal the status follows the reply; piped, stdout is the reply alone
# (for jq) and the status goes to stderr.
if [ -t 1 ]; then echo "HTTP $code"; else echo "HTTP $code" >&2; fi
case "$code" in 2??) ;; *) exit 1 ;; esac
