#!/usr/bin/env bash
# Add the tenant portal's redirects for every site to the live tenant realm
# (make tenant-redirects; make install runs it after the hub's Applications).
#
# The tenant Keycloak imports its realm only on its first start (--override
# false), so a site added to clusters.yaml later is in
# tenant-idp/manifests/settings.yaml's portalRedirectURI (scripts/set-inputs.sh
# adds it there) but not in the realm. This adds each URI of portalRedirectURI
# that client ai-grid-tenants in realm tenants lacks to its redirectUris. It
# never removes one.
#
# It signs in to Keycloak's admin API on the hub with the bootstrap admin from
# Secret tenant-idp/keycloak-secrets. The password and the token stay in files
# (mode 600) and never reach a command line or the output.
#
# Usage: scripts/tenant-redirects.sh
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$here/.." && pwd)"
. "$here/clusters.sh"
clusters_load "$dir"
hub=$(hub_name)
cluster_login_ok "$hub"
ns=${KEYCLOAK_NAMESPACE:-tenant-idp} realm=${KEYCLOAK_REALM:-tenants} client=ai-grid-tenants
die() { echo "error: $*" >&2; exit 1; }
k() { KUBECONFIG=$(cluster_kubeconfig "$hub") oc "$@"; }

# The value, without a trailing YAML comment or quotes.
want=$(sed -n 's/^  portalRedirectURI:[ \t]*//p' "$dir/tenant-idp/manifests/settings.yaml" | sed -E 's/[[:space:]]+#.*$//' |
  tr -d "'\"" | tr ',' ' ')
case "$want" in ""|*REQUIRED-*) die "tenant-idp/manifests/settings.yaml has no portalRedirectURI: run make inputs first" ;; esac

host=$(k get route keycloak -n "$ns" -o jsonpath='{.spec.host}' 2>/dev/null) && [ -n "$host" ] ||
  die "the hub has no Route $ns/keycloak: the tenant Keycloak isn't installed yet"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
(umask 077
 k get secret keycloak-secrets -n "$ns" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_USERNAME}' | base64 -d > "$tmp/admin-user"
 k get secret keycloak-secrets -n "$ns" -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d > "$tmp/admin-pass") ||
  die "can't read Secret $ns/keycloak-secrets on the hub"
(umask 077
 curl -fsS "https://$host/realms/master/protocol/openid-connect/token" \
   --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
   --data-urlencode "username@$tmp/admin-user" --data-urlencode "password@$tmp/admin-pass" |
   jq -r '.access_token // empty | "Authorization: Bearer " + .' > "$tmp/auth") && [ -s "$tmp/auth" ] ||
  die "Keycloak admin sign-in at https://$host failed"
api() { curl -fsS -H "@$tmp/auth" -H 'Content-Type: application/json' "$@"; }
base="https://$host/admin/realms/$realm"

api "$base/clients?clientId=$client" > "$tmp/clients" || die "can't read client $client in realm $realm"
id=$(jq -r --arg c "$client" '[.[] | select(.clientId == $c)][0].id // empty' "$tmp/clients")
[ -n "$id" ] || die "realm $realm has no client $client"
jq --arg c "$client" '[.[] | select(.clientId == $c)][0]' "$tmp/clients" > "$tmp/client"
# The update sends the whole client back: never with a masked secret, which
# would replace the real one.
jq -e '(.secret // "") | test("^\\*+$") | not' "$tmp/client" >/dev/null ||
  die "Keycloak returned client $client with its secret masked; not updating it (add the redirects in the admin console)"
missing=$(jq -r --arg want "$want" '($want | split(" ") | map(select(. != ""))) - (.redirectUris // []) | .[]' "$tmp/client")
if [ -z "$missing" ]; then
  echo "kept     client $client: it has every site's portal redirect"
  exit 0
fi
jq --arg add "$missing" '.redirectUris = ((.redirectUris // []) + ($add | split("\n")))' "$tmp/client" > "$tmp/update"
api -X PUT "$base/clients/$id" -d "@$tmp/update" >/dev/null || die "can't update client $client in realm $realm"
echo "added    client $client: $(tr '\n' ' ' <<<"$missing" | sed 's/ $//')"
