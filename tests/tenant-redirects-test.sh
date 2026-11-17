#!/usr/bin/env bash
# Tests for scripts/tenant-redirects.sh, with a stub oc (the hub's Route and
# Secret) and a stub curl (Keycloak's token and admin API), which logs every
# request and keeps the client's redirects in $STUB_DIR/client.json.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SENTINEL=SENTINEL_ADMIN_PASSWORD
t() { # name condition...
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/oc.log"
case " $* " in
  *" whoami "*) echo admin ;;
  *" get route keycloak "*) [ -f "$d/no-route" ] && { echo 'Error from server (NotFound)' >&2; exit 1; }; echo keycloak.apps.hub.example.com ;;
  *"KC_BOOTSTRAP_ADMIN_USERNAME"*) printf admin | base64 ;;
  *"KC_BOOTSTRAP_ADMIN_PASSWORD"*) printf SENTINEL_ADMIN_PASSWORD | base64 ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "$*" >> "$d/curl.log"; method=GET data=""
while [ $# -gt 0 ]; do
  case "$1" in -X) method=$2; shift ;; -d) data=$2; shift ;; https://*) url=$1 ;; esac; shift
done
case "$method $url" in
  "GET https://keycloak.apps.hub.example.com/realms/master/protocol/openid-connect/token") echo '{"access_token":"tok"}' ;;
  "GET https://keycloak.apps.hub.example.com/admin/realms/tenants/clients?clientId=ai-grid-tenants")
    [ -f "$d/no-client" ] && { echo '[]'; exit 0; }; jq -c '[.]' "$d/client.json" ;;
  "PUT https://keycloak.apps.hub.example.com/admin/realms/tenants/clients/c1")
    [ -f "$d/put-fails" ] && exit 22; cp "${data#@}" "$d/client.json"; echo "put" >> "$d/puts" ;;
  *) echo "stub curl: unexpected: $method $url" >&2; exit 22 ;;
esac
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

setup() { # NAME REDIRECTS_IN_FILE CLIENT_REDIRECTS_JSON
  D="$T/$1/repo" W="$T/$1/stub"; mkdir -p "$W" "$D/.config/hub" "$D/tenant-idp/manifests"
  cp -R "$SRC/scripts" "$D/"; touch "$D/.config/hub/kubeconfig"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n- {name: site-a, api: "https://api.site-a.example.com:6443"}\n' > "$D/clusters.yaml"
  printf 'data:\n  portalRedirectURI: %s\n' "$2" > "$D/tenant-idp/manifests/settings.yaml"
  jq -n --argjson r "$3" --arg s "${4:-real-secret}" '{id: "c1", clientId: "ai-grid-tenants", publicClient: false, secret: $s,
    attributes: {"realm_client": "false"}, protocolMappers: [{name: "org_id"}], redirectUris: $r}' > "$W/client.json"
}
run() { out=$(cd "$D" && env PATH="$T/bin:$PATH" STUB_DIR="$W" scripts/tenant-redirects.sh 2>&1) && rc=0 || rc=$?; all+="$out"; }
all=""
A='https://maas.apps.a.example.com/*' C='https://maas.apps.c.example.com/*'

setup missing "$A $C" "[\"$A\"]"
run
t "adds the missing site's redirect" eval '[ "$rc" = 0 ] && grep -qx "added    client ai-grid-tenants: https://maas.apps.c.example.com/\*" <<<"$out" &&
  jq -e --arg a "$A" --arg c "$C" ".redirectUris == [\$a, \$c]" "$W/client.json" >/dev/null'
t "  ... keeping the client's other fields, its secret included" eval 'jq -e ".publicClient == false and .id == \"c1\" and .secret == \"real-secret\"
  and .attributes.realm_client == \"false\" and .protocolMappers == [{name: \"org_id\"}]" "$W/client.json" >/dev/null'
run
t "a second run changes nothing" eval '[ "$rc" = 0 ] && grep -q "^kept     client ai-grid-tenants" <<<"$out" && [ "$(wc -l < "$W/puts" | tr -d " ")" = 1 ]'

setup extra "$A" "[\"$A\", \"https://portal.example.com/*\"]"
run
t "never removes a redirect the realm has" eval '[ "$rc" = 0 ] && grep -q "^kept" <<<"$out" && [ ! -f "$W/puts" ] &&
  jq -e ".redirectUris | length == 2" "$W/client.json" >/dev/null'

setup commas "$A,$C" "[]"
run
t "commas separate redirects too" eval '[ "$rc" = 0 ] && jq -e ".redirectUris | length == 2" "$W/client.json" >/dev/null'

setup comment "$A $C   # east and west" "[\"$A\"]"
run
t "a trailing YAML comment isn't a redirect" eval '[ "$rc" = 0 ] && jq -e --arg a "$A" --arg c "$C" ".redirectUris == [\$a, \$c]" "$W/client.json" >/dev/null'

setup masked "$A $C" "[\"$A\"]" "**********"
run
t "a masked secret: refuses to update" eval '[ "$rc" = 1 ] && grep -q "secret masked" <<<"$out" && [ ! -f "$W/puts" ]'

setup placeholder "REQUIRED-portalRedirectURI" "[]"
run
t "a placeholder: says to run make inputs" eval '[ "$rc" = 1 ] && grep -q "run make inputs first" <<<"$out" && [ ! -s "$W/curl.log" ]'

setup noroute "$A" "[]"; touch "$W/no-route"
run
t "no Keycloak on the hub: says so" eval '[ "$rc" = 1 ] && grep -q "tenant Keycloak isn.t installed yet" <<<"$out"'

setup noclient "$A" "[]"; touch "$W/no-client"
run
t "no client: says so" eval '[ "$rc" = 1 ] && grep -q "realm tenants has no client ai-grid-tenants" <<<"$out"'

setup putfails "$A $C" "[\"$A\"]"; touch "$W/put-fails"
run
t "a failed update stops with an error" eval '[ "$rc" = 1 ] && grep -q "can.t update client ai-grid-tenants" <<<"$out"'

t "the password and token never reach argv or the output" eval '! grep -rqF "$SENTINEL" "$T"/*/stub/curl.log "$T"/*/stub/oc.log <<<"" &&
  ! grep -qF "$SENTINEL" <<<"$all" && ! grep -rqw tok "$T"/*/stub/curl.log && ! grep -qw tok <<<"$all"'

echo "tenant-redirects tests: $((total-fails)) ok, $fails failed"; exit "$fails"
