#!/usr/bin/env bash
# Tests for scripts/test-tenants.sh with a stub oc, a stub curl and a stub
# library (no cluster, no Keycloak, no console). The stubs keep the hub's state
# in files under $STUB_DIR: realms/REALM.json (each realm Keycloak has, as it was
# imported), orgs/NAME.json (each organization the provider API has) and
# secrets/NAME (each identity provider Secret's client-secret). They log every
# command line to $STUB_DIR/oc.log and $STUB_DIR/curl.log.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# The fakes' credentials, built at runtime.
FAKE_SA="fake-sa-$RANDOM$RANDOM" FAKE_ADMIN="fake-admin-$RANDOM$RANDOM" FAKE_KC="fake-kc-$RANDOM$RANDOM"
export FAKE_SA FAKE_ADMIN FAKE_KC
KC=https://keycloak.apps.hub.example.com

# --- The stub library: upstream's example files, trimmed to what the script reads.
L="$T/lib/apps/keycloak"; mkdir -p "$L/components/examples" "$L/base/manifests/scripts"
cat > "$L/base/manifests/scripts/render-realm.sh" <<'EOF'
#!/usr/bin/env bash
# As upstream's: each ${NAME} below becomes the variable NAME, which must be set when the file holds it.
set -Eeuo pipefail
placeholders=(KEYCLOAK_PUBLIC_URL GRID_TENANT_1_BROKER_CLIENT_SECRET GRID_TENANT_2_BROKER_CLIENT_SECRET
  GRID_TENANT_1_TEST_USER_PASSWORD GRID_TENANT_2_TEST_USER_PASSWORD KEYCLOAK_SIGNING_KEYSTORE_PASSWORD)
while IFS= read -r line || [[ -n "$line" ]]; do
  for name in "${placeholders[@]}"; do
    p="\${$name}"; [[ "$line" == *"$p"* ]] || continue
    [[ -n "${!name+set}" ]] || { echo "render-realm.sh: $name is not set" >&2; exit 1; }
    line=${line//"$p"/"${!name}"}
  done
  printf '%s\n' "$line"
done
EOF
realm_file() { # N USERS_JSON
  cat <<EOF
{
  "realm": "grid-tenant-$1-idp",
  "enabled": true,
  "clients": [
    {
      "clientId": "saas-broker",
      "secret": "\${GRID_TENANT_$1_BROKER_CLIENT_SECRET}",
      "redirectUris": ["\${KEYCLOAK_PUBLIC_URL}/realms/saas/broker/grid-tenant-$1/endpoint"]
    }
  ],
  "components": {
    "org.keycloak.keys.KeyProvider": [
      {
        "name": "grid-tenant-$1-idp-signing",
        "providerId": "java-keystore",
        "config": {
          "keystore": ["/opt/keycloak/data/grid-tenant-$1-idp/keystore.jks"],
          "keystorePassword": ["\${KEYCLOAK_SIGNING_KEYSTORE_PASSWORD}"]
        }
      }
    ],
    "org.keycloak.userprofile.UserProfileProvider": [
      { "providerId": "declarative-user-profile" }
    ]
  },
  "groups": [ { "name": "ai-grid-users" } ],
  "users": $2
}
EOF
}
user() { # ID NAME EMAIL N
  printf '{"id": "%s", "username": "%s", "email": "%s", "groups": ["/ai-grid-users"], "credentials": [{"type": "password", "value": "${GRID_TENANT_%s_TEST_USER_PASSWORD}", "temporary": false}]}' "$@"
}
realm_file 1 "[$(user id-alice-1 alice alice@grid-tenant-1.test 1)]" > "$L/components/examples/grid-tenant-1-idp-realm.json"
realm_file 2 "[$(user id-alice-2 alice alice@grid-tenant-2.test 2), $(user id-bob bob bob@grid-tenant-2.test 2), $(user id-carol carol carol@grid-tenant-2.test 2)]" \
  > "$L/components/examples/grid-tenant-2-idp-realm.json"
idp() { # N
  cat <<EOF
    {
      "alias": "grid-tenant-$1", "displayName": "Grid Tenant $1", "providerId": "oidc",
      "config": {
        "clientId": "saas-broker", "clientSecret": "\${GRID_TENANT_$1_BROKER_CLIENT_SECRET}", "clientAuthMethod": "client_secret_post",
        "issuer": "\${KEYCLOAK_PUBLIC_URL}/realms/grid-tenant-$1-idp",
        "authorizationUrl": "\${KEYCLOAK_PUBLIC_URL}/realms/grid-tenant-$1-idp/protocol/openid-connect/auth",
        "tokenUrl": "\${KEYCLOAK_PUBLIC_URL}/realms/grid-tenant-$1-idp/protocol/openid-connect/token",
        "userInfoUrl": "\${KEYCLOAK_PUBLIC_URL}/realms/grid-tenant-$1-idp/protocol/openid-connect/userinfo",
        "logoutUrl": "\${KEYCLOAK_PUBLIC_URL}/realms/grid-tenant-$1-idp/protocol/openid-connect/logout",
        "jwksUrl": "\${KEYCLOAK_PUBLIC_URL}/realms/grid-tenant-$1-idp/protocol/openid-connect/certs",
        "useJwksUrl": "true", "validateSignature": "true", "defaultScope": "openid email profile"
      }
    }
EOF
}
org() { # N: tenant 2 has a second domain
  local more=""; [ "$1" = 1 ] || more=", {\"name\": \"grid-tenant-$1.example\"}"
  printf '{"id": "fixed-%s", "name": "Grid Tenant %s", "alias": "grid-tenant-%s", "domains": [{"name": "grid-tenant-%s.test", "identityProviderAlias": "grid-tenant-%s"}%s]}' "$1" "$1" "$1" "$1" "$1" "$more"
}
printf '{"realm": "saas", "identityProviders": [\n%s,\n%s], "organizations": [%s, %s]}\n' "$(idp 1)" "$(idp 2)" "$(org 1)" "$(org 2)" \
  > "$L/components/examples/saas-realm.json"
git -c init.defaultBranch=main -C "$T/lib" init -q && git -C "$T/lib" add -A && git -c core.hooksPath=/dev/null -C "$T/lib" commit -qm lib

# --- The stubs.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "oc $*" >> "$d/oc.log"; a=" $* "
to() { local x; for x in "$@"; do case "$x" in --to=*) echo "${x#--to=}" ;; esac; done; }
ns() { local p=""; for x in "$@"; do [ "$p" = -n ] && echo "$x"; p=$x; done; }
idp=$(cat "$d/idp-ns" 2>/dev/null || echo ai-grid-idp-secrets)
case "$a" in
  *" whoami "*) echo admin ;;
  *" get deployment ai-grid-provider-console -n ai-grid-provider-console -o json "*)
    [ -f "$d/idp-ns" ] || { echo 'Error from server (NotFound): deployments.apps "ai-grid-provider-console" not found' >&2; exit 1; }
    printf '{"spec":{"template":{"spec":{"containers":[{"name":"console","env":[{"name":"X","value":"y"}]},{"name":"backend","env":[{"name":"AI_GRID_IDP_SECRET_NAMESPACE","value":"%s"}]}]}}}}' "$idp" ;;
  *" get route keycloak -n "*) [ -f "$d/no-keycloak" ] || printf keycloak.apps.hub.example.com ;;
  *" get route ai-grid-provider-console -n ai-grid-provider-console "*) printf console.apps.hub.example.com ;;
  *" get configmap keycloak-public-url -n "*) cat "$d/public-url" 2>/dev/null || printf 'https://keycloak.apps.hub.example.com/' ;;
  *" extract secret/keycloak-secrets -n "*)
    t=$(to "$@"); printf admin > "$t/KC_BOOTSTRAP_ADMIN_USERNAME"; printf '%s' "$FAKE_ADMIN" > "$t/KC_BOOTSTRAP_ADMIN_PASSWORD" ;;
  *" extract secret/grid-tenant-"*"-idp -n $idp --keys=client-secret "*)
    n=${2#secret/}; [ -f "$d/secrets/$n" ] || { echo "Error from server (NotFound): secrets \"$n\" not found" >&2; exit 1; }
    cp "$d/secrets/$n" "$(to "$@")/client-secret" ;;
  *" get namespace $idp "*) echo "namespace/$idp" ;;
  *" get namespace "*) echo "Error from server (NotFound): namespaces \"$3\" not found" >&2; exit 1 ;;
  *" get secret grid-tenant-"*"-idp -n $idp "*) [ -f "$d/secrets/$3" ] || { echo NotFound >&2; exit 1; } ;;
  *" create secret generic "*" -n $idp --from-file=client-secret="*" --dry-run=client -o yaml "*)
    for x in "$@"; do case "$x" in --from-file=client-secret=*) f=${x#--from-file=client-secret=} ;; esac; done
    printf 'name: %s\nclient-secret: %s\n' "$4" "$(base64 < "$f" | tr -d '\n')" ;;
  *" apply --server-side --force-conflicts -f - "*) y=$(cat); n=$(sed -n 's/^name: //p' <<<"$y"); mkdir -p "$d/secrets"
    sed -n 's/^client-secret: //p' <<<"$y" | base64 -d > "$d/secrets/$n"; echo "secret/$n serverside-applied" ;;
  *" delete secret "*" -n $idp --ignore-not-found "*) rm -f "$d/secrets/$3" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
d=$STUB_DIR; echo "curl $*" >> "$d/curl.log"
out="" m=GET url="" data="" prev="" hdr=""; form=()
for a in "$@"; do
  case "$prev" in
    -o) out=$a ;; -X) m=$a ;;
    -H) case "$a" in @*) hdr=$(cat "${a#@}") ;; esac ;;
    --data-binary) data=$a ;; --data-urlencode) form+=("$a") ;;
  esac
  case "$a" in http*) url=$a ;; esac
  prev=$a
done
reply() { printf '%s' "$2" > "$out"; printf '%s' "$1"; exit 0; }
users() { if [ -f "$d/saas-users.json" ]; then echo "$d/saas-users.json"; else echo "$DEFAULT_USERS"; fi; }
kc=https://keycloak.apps.hub.example.com
case "$url" in
  "$kc/admin/realms"*) [ "$hdr" = "Authorization: Bearer $FAKE_KC" ] || reply 401 '{"error":"HTTP 401 Unauthorized"}' ;;
  https://console.apps.hub.example.com/*)
    [ "$hdr" = "Authorization: Bearer $FAKE_SA" ] || reply 401 '{"code":"unauthenticated","message":"not the provider-admin token"}' ;;
esac
mkdir -p "$d/realms" "$d/orgs"
case "$m $url" in
  "POST $kc/realms/master/protocol/openid-connect/token")
    # The credential only from files (name@FILE), never on the command line.
    [ "${form[*]}" = "grant_type=password client_id=admin-cli username@${form[2]#username@} password@${form[3]#password@}" ] &&
      [ "$(cat "${form[3]#password@}")" = "$FAKE_ADMIN" ] || reply 401 '{"error":"invalid_grant"}'
    reply 200 "{\"access_token\":\"$FAKE_KC\"}" ;;
  "POST $kc/admin/realms")
    body=${data#@}; r=$(jq -r .realm "$body")
    [ ! -f "$d/fail-import" ] || reply 500 '{"errorMessage":"unknown_error"}'
    [ ! -f "$d/realms/$r.json" ] || reply 409 '{"errorMessage":"Conflict detected. See logs for details"}'
    cp "$body" "$d/realms/$r.json"; echo "$r" >> "$d/imports"; reply 201 '' ;;
  "GET $kc/admin/realms/"*"/clients?clientId=saas-broker")
    r=${url#"$kc/admin/realms/"}; r=${r%%/*}; reply 200 "[{\"id\":\"cid-$r\",\"clientId\":\"saas-broker\"}]" ;;
  "GET $kc/admin/realms/"*"/client-secret")
    r=${url#"$kc/admin/realms/"}; r=${r%%/*}
    reply 200 "$(jq -c '{type: "secret", value: (.clients[] | select(.clientId == "saas-broker") | .secret)}' "$d/realms/$r.json")" ;;
  "GET $kc/admin/realms/"*"/users?idpAlias="*)
    # The users linked to an identity provider, a page at a time (first, max).
    q=${url#*\?}; a=$(sed -E 's/.*idpAlias=([^&]*).*/\1/' <<<"$q"); f=$(sed -E 's/.*first=([0-9]+).*/\1/' <<<"$q"); n=$(sed -E 's/.*max=([0-9]+).*/\1/' <<<"$q")
    echo "search $a first=$f max=$n" >> "$d/searches"
    reply 200 "$(jq -c --arg a "$a" --argjson f "$f" --argjson n "$n" '[.[] | select(.idps | index($a)) | {id, email}] | .[$f:$f+$n]' "$(users)")" ;;
  "GET $kc/admin/realms/"*"/federated-identity")
    u=${url%/federated-identity}; u=${u##*/}
    [ ! -f "$d/vanish-$u" ] || reply 404 '{"error":"User not found"}'
    jq -e --arg u "$u" 'any(.[]; .id == $u)' "$(users)" >/dev/null || reply 404 '{"error":"User not found"}'
    reply 200 "$(jq -c --arg u "$u" '[.[] | select(.id == $u) | .idps[] | {identityProvider: ., userId: "upstream", userName: "x"}]' "$(users)")" ;;
  "GET $kc/admin/realms/"*"/credentials")
    u=${url%/credentials}; u=${u##*/}
    reply 200 "$(jq -c --arg u "$u" '[.[] | select(.id == $u) | (.creds // [])[]]' "$(users)")" ;;
  "GET $kc/admin/realms/"*)
    r=${url##*/}; [ -f "$d/realms/$r.json" ] && reply 200 "{\"realm\":\"$r\"}"; reply 404 '{"error":"Realm not found."}' ;;
  "PUT $kc/admin/realms/"*"/reset-password")
    p=${url#"$kc/admin/realms/"}; r=${p%%/*}; u=${p#*/users/}; u=${u%%/*}
    jq -e --arg u "$u" 'any(.users[]; .id == $u)' "$d/realms/$r.json" >/dev/null || reply 404 '{"error":"User not found"}'
    cp "${data#@}" "$d/reset-$r-$u.json"; reply 204 '' ;;
  "DELETE $kc/admin/realms/"*"/users/"*)
    u=${url##*/}; echo "user $u" >> "$d/events"; [ ! -f "$d/gone-$u" ] || reply 404 '{"error":"User not found"}'
    echo "$u" >> "$d/deleted-users"; reply 204 '' ;;
  "DELETE $kc/admin/realms/"*)
    r=${url##*/}; [ -f "$d/realms/$r.json" ] || reply 404 '{"error":"Realm not found."}'; rm "$d/realms/$r.json"; reply 204 '' ;;
  "POST https://console.apps.hub.example.com/ai_grid.v1.Tenants/List")
    if ls "$d"/orgs/*.json >/dev/null 2>&1; then reply 200 "$(jq -cs '{items: .}' "$d"/orgs/*.json)"; else reply 200 '{}'; fi ;;
  "POST https://console.apps.hub.example.com/ai_grid.v1.Tenants/Create")
    [ ! -f "$d/fail-create" ] || reply 400 '{"code":"failed_precondition","message":"identity provider secret \"grid-tenant-1-idp\" not found"}'
    n=$(jq -r .object.metadata.name <<<"$data"); printf '%s' "$data" > "$d/create-$n.json"
    jq -c --arg id "id-$n" '.object | .id = $id | .metadata.version = 1' <<<"$data" > "$d/orgs/$n.json"
    reply 200 "$(jq -c '{object: .}' "$d/orgs/$n.json")" ;;
  "POST https://console.apps.hub.example.com/ai_grid.v1.Tenants/ListMembers")
    # As the console: it doesn't expose member lists.
    touch "$d/listmembers-called"; reply 404 '{"code":"not_found","message":"this procedure is not exposed by the console"}' ;;
  "POST https://console.apps.hub.example.com/ai_grid.v1.Tenants/Delete")
    id=$(jq -r .id <<<"$data"); n=${id#id-}; echo "$data" >> "$d/deleted-orgs"; echo "org $id" >> "$d/events"; rm "$d/orgs/$n.json"; reply 200 '{}' ;;
  *) echo "stub curl: unexpected: $m $url" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

# Realm saas's users, for CLEAN: each with its email and the identity providers it's linked to.
# Deleted only with both an email in the organization's domains and a link to its identity provider.
DEFAULT_USERS="$T/saas-users.json"; export DEFAULT_USERS
cat > "$DEFAULT_USERS" <<'EOF'
[
  {"id": "11111111-1111-4111-8111-111111111111", "email": "alice@grid-tenant-1.test", "idps": ["grid-tenant-1"]},
  {"id": "22222222-1111-4111-8111-111111111111", "email": "Alice@grid-tenant-2.test", "idps": ["grid-tenant-2"]},
  {"id": "33333333-1111-4111-8111-111111111111", "email": "erin@grid-tenant-2.example", "idps": ["grid-tenant-2"]},
  {"id": "44444444-1111-4111-8111-111111111111", "email": "mallory@grid-tenant-1.test", "idps": ["other-idp"]},
  {"id": "55555555-1111-4111-8111-111111111111", "email": "bob@grid-tenant-2.test", "idps": []},
  {"id": "99999999-1111-4111-8111-111111111111", "email": "dave@elsewhere.test", "idps": ["grid-tenant-1"]},
  {"id": "66666666-1111-4111-8111-111111111111", "email": "eve@grid-tenant-1.test.evil.example", "idps": ["grid-tenant-1"]},
  {"id": "77777777-1111-4111-8111-111111111111", "email": "frank@grid-tenant-1.test", "idps": ["grid-tenant-1", "other-idp"]},
  {"id": "88888888-1111-4111-8111-111111111111", "email": "gina@grid-tenant-2.test", "idps": ["grid-tenant-2"], "creds": [{"type": "password"}]}
]
EOF

# --- The deployment repository.
D="$T/repo"; mkdir -p "$D/root" "$D/.config/hub"; cp -R "$SRC/scripts" "$D/"; : > "$D/.config/hub/kubeconfig"
printf '  libraryRepoURL: file://%s\n  libraryRevision: &libraryRevision %s\n' "$T/lib" "$(git -C "$T/lib" rev-parse HEAD)" > "$D/root/applicationset.yaml"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"
printf 'keycloakOverlay=core\n' > "$D/root/inputs.env"
TOK="$D/.config/provider-admin-token"; (umask 077; printf '%s\n' "$FAKE_SA" > "$TOK")
PW="$D/.config/test-tenants"
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

ENVS=()
run() { # [ARGS]: runs test-tenants.sh with the stubs reading $W, and ENVS; sets rc and out
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" LIBRARY="$T/lib" ${ENVS[@]+"${ENVS[@]}"} "$D/scripts/test-tenants.sh" "$@" 2>&1) && rc=0 || rc=$?
}
# Every secret the run saw: the fakes' credentials, the passwords and client secrets.
leaks() {
  local s f
  for s in "$FAKE_SA" "$FAKE_ADMIN" "$FAKE_KC"; do echo "$s"; done
  for f in "$PW"/*/* "$W"/secrets/*; do [ -f "$f" ] && cat "$f" && echo; done
}
t() { # name want_rc expect_grep [check...]: each check is a command that must succeed
  local name=$1 want=$2 expect=$3; shift 3; local check ok=1 s
  total=$((total+1))
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then
    while read -r s; do
      [ -n "$s" ] || continue
      for f in "$W/oc.log" "$W/curl.log"; do [ ! -f "$f" ] || ! grep -qF -- "$s" "$f" || { ok=0; echo "      a secret is on a command line ($f)"; }; done
      ! grep -qF -- "$s" <<<"$out" || { ok=0; echo "      a secret is in the output"; }
    done < <(leaks)
    for check in "$@"; do eval "$check" || { ok=0; echo "      check failed: $check"; }; done
  else ok=0; fi
  if [ "$ok" = 1 ]; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
# What Keycloak imported, its generated values replaced by markers, against the library's file rendered the same way.
imported_is_upstream() { # N
  local f="$L/components/examples/grid-tenant-$1-idp-realm.json"
  diff <(jq -S '.clients[].secret = "S" | .users[].credentials[].value = "P"' "$W/realms/grid-tenant-$1-idp.json") \
    <(sed "s#\${KEYCLOAK_PUBLIC_URL}#$KC#g" "$f" | jq -S '.clients[].secret = "S" | .users[].credentials[].value = "P"
        | .components["org.keycloak.keys.KeyProvider"] |= map(select(.providerId != "java-keystore"))
        | del(.components["org.keycloak.keys.KeyProvider"])')
}

W="$T/first"; mkdir -p "$W"; run
t "create: two realms, two Secrets, two organizations, the passwords in files" 0 "realm grid-tenant-1-idp: created" \
  'grep -q "^note: can.t read Deployment ai-grid-provider-console/ai-grid-provider-console on hub; using ai-grid-idp-secrets" <<<"$out"' \
  'grep -q "organization grid-tenant-1: created, id id-grid-tenant-1" <<<"$out"' \
  'grep -q "organization grid-tenant-2: created, id id-grid-tenant-2" <<<"$out"' \
  'grep -q "test deployments only, never a real install" <<<"$out"' \
  '[ "$(cat "$W/imports")" = "$(printf "grid-tenant-1-idp\ngrid-tenant-2-idp")" ]'
t "  ... each realm is the library's file, without its java-keystore key, placeholders filled" 0 "" \
  'imported_is_upstream 1' 'imported_is_upstream 2' '! grep -q "\${" "$W/realms/grid-tenant-1-idp.json"' \
  'jq -e ".components | has(\"org.keycloak.userprofile.UserProfileProvider\") and (has(\"org.keycloak.keys.KeyProvider\") | not)" "$W/realms/grid-tenant-2-idp.json" >/dev/null'
t "  ... the passwords: one file per user, mode 600, in a directory only you can read, matching the import" 0 \
  "user bob of grid-tenant-2-idp \(sign in as bob@grid-tenant-2.test\): password in $PW/grid-tenant-2-idp/bob" \
  '[ "$(cat "$PW/grid-tenant-1-idp/alice")" = "$(jq -r ".users[0].credentials[0].value" "$W/realms/grid-tenant-1-idp.json")" ]' \
  '[ "$(cat "$PW/grid-tenant-2-idp/carol")" = "$(jq -r ".users[2].credentials[0].value" "$W/realms/grid-tenant-2-idp.json")" ]' \
  '[ "$(wc -c < "$PW/grid-tenant-1-idp/alice")" -ge 32 ]' \
  '[ "$(cat "$PW/grid-tenant-1-idp/alice")" != "$(cat "$PW/grid-tenant-2-idp/bob")" ]' \
  '[ "$(mode "$PW/grid-tenant-2-idp/bob")" = 600 ] && [ "$(mode "$PW/grid-tenant-2-idp")" = 700 ] && [ "$(mode "$PW")" = 700 ]'
t "  ... each Secret holds its realm's saas-broker client secret" 0 "" \
  '[ "$(cat "$W/secrets/grid-tenant-1-idp")" = "$(jq -r ".clients[0].secret" "$W/realms/grid-tenant-1-idp.json")" ]' \
  '[ "$(cat "$W/secrets/grid-tenant-1-idp")" != "$(cat "$W/secrets/grid-tenant-2-idp")" ]'
t "  ... the organization create: the name, the domain and the identity provider link from saas-realm.json" 0 "" \
  'jq -e --arg kc "'"$KC"'" ".object.metadata.name == \"grid-tenant-1\" and .object.spec.domains == [\"grid-tenant-1.test\"]
     and .object.spec.identityProvider.title == \"Grid Tenant 1\"
     and .object.spec.identityProvider.config == {clientId: \"saas-broker\", clientSecretSecretName: \"grid-tenant-1-idp\",
       issuer: (\$kc + \"/realms/grid-tenant-1-idp\"), authorizationUrl: (\$kc + \"/realms/grid-tenant-1-idp/protocol/openid-connect/auth\"),
       tokenUrl: (\$kc + \"/realms/grid-tenant-1-idp/protocol/openid-connect/token\"),
       userInfoUrl: (\$kc + \"/realms/grid-tenant-1-idp/protocol/openid-connect/userinfo\"),
       jwksUrl: (\$kc + \"/realms/grid-tenant-1-idp/protocol/openid-connect/certs\"),
       logoutUrl: (\$kc + \"/realms/grid-tenant-1-idp/protocol/openid-connect/logout\"),
       defaultScopes: \"openid email profile\", validateSignature: true}" "$W/create-grid-tenant-1.json" >/dev/null' \
  '! grep -q "clientSecret\"" "$W/create-grid-tenant-2.json"' \
  'grep -q "https://console.apps.hub.example.com/ai_grid.v1.Tenants/Create" "$W/curl.log"'

before=$(wc -l < "$W/curl.log")
run
t "rerun: nothing new, everything reported as existing" 0 "realm grid-tenant-1-idp: exists$" \
  'grep -q "organization grid-tenant-2: exists, id id-grid-tenant-2" <<<"$out"' \
  '[ "$(grep -c . "$W/imports")" = 2 ]' '! sed -n "$((before+1)),\$p" "$W/curl.log" | grep -q "Tenants/Create\|reset-password"' \
  '[ "$(ls "$W/orgs" | wc -l | tr -d " ")" = 2 ]'

rm "$PW/grid-tenant-2-idp/bob"; old=$(cat "$PW/grid-tenant-2-idp/carol"); run
t "rerun with a password file gone: new passwords for that realm's users" 0 "realm grid-tenant-2-idp: exists; set new passwords" \
  'grep -q "realm grid-tenant-1-idp: exists$" <<<"$out"' \
  '[ -s "$PW/grid-tenant-2-idp/bob" ] && [ "$(cat "$PW/grid-tenant-2-idp/carol")" != "$old" ]' \
  '[ "$(jq -r .value "$W/reset-grid-tenant-2-idp-id-bob.json")" = "$(cat "$PW/grid-tenant-2-idp/bob")" ]' \
  'jq -e ".type == \"password\" and .temporary == false" "$W/reset-grid-tenant-2-idp-id-carol.json" >/dev/null' \
  '[ ! -f "$W/reset-grid-tenant-1-idp-id-alice-1.json" ]'

run --clean
t "CLEAN: a preview, deleting nothing" 0 "organization grid-tenant-1 \(id id-grid-tenant-1\): would delete it, and its 1 users from realm saas" \
  'grep -q "organization grid-tenant-2 (id id-grid-tenant-2): would delete it, and its 2 users from realm saas" <<<"$out"' \
  'grep -q "Secret ai-grid-idp-secrets/grid-tenant-1-idp: would delete it" <<<"$out"' \
  'grep -q "realm grid-tenant-2-idp: would delete it" <<<"$out"' 'grep -q "password files .*grid-tenant-1-idp: would delete them" <<<"$out"' \
  'grep -q "CLEAN=1 CONFIRM=1 would delete" <<<"$out"' \
  'grep -q "its 1 users from realm saas: alice@grid-tenant-1.test$" <<<"$out"' \
  'grep -q "its 2 users from realm saas: Alice@grid-tenant-2.test erin@grid-tenant-2.example$" <<<"$out"' \
  '! grep -q "mallory\|bob@\|dave@" <<<"$out"' '[ ! -f "$W/listmembers-called" ]' \
  '[ ! -f "$W/events" ]' '[ "$(find "$W/realms" "$W/orgs" "$W/secrets" -type f | wc -l | tr -d " ")" = 6 ]' \
  '[ -s "$PW/grid-tenant-1-idp/alice" ]' '! grep -q "Tenants/Delete\|-X DELETE" "$W/curl.log"' '! grep -q "oc delete" "$W/oc.log"'
run --clean --confirm
t "CLEAN CONFIRM: deletes the users, then the organizations, the Secrets, the realms and the password files" 0 \
  "organization grid-tenant-1: deleted, and 1 of its users from realm saas" \
  'grep -q "organization grid-tenant-2: deleted, and 2 of its users from realm saas" <<<"$out"' \
  'grep -q "realm grid-tenant-2-idp: deleted" <<<"$out"' 'grep -q "Secret ai-grid-idp-secrets/grid-tenant-1-idp: deleted" <<<"$out"' \
  'grep -qxF "{\"id\":\"id-grid-tenant-1\",\"version\":1}" "$W/deleted-orgs"' \
  '[ "$(tr "\n" " " < "$W/events")" = "user 11111111-1111-4111-8111-111111111111 org id-grid-tenant-1 user 22222222-1111-4111-8111-111111111111 user 33333333-1111-4111-8111-111111111111 org id-grid-tenant-2 " ]' \
  '! grep -qE "user (44444444|55555555|99999999)-" "$W/events"' \
  'grep -qx "search grid-tenant-2 first=0 max=100" "$W/searches"' '[ ! -f "$W/listmembers-called" ]' \
  '! grep -qE "user (66666666|77777777|88888888)-" "$W/events"' \
  'grep -q "user frank@grid-tenant-1.test of grid-tenant-1: kept: also linked elsewhere" <<<"$out"' \
  'grep -q "user gina@grid-tenant-2.test of grid-tenant-2: kept: has local credentials" <<<"$out"' \
  '! grep -q "eve@" <<<"$out"' \
  '[ -z "$(find "$W/realms" "$W/orgs" "$W/secrets" -type f)" ]' '[ ! -e "$PW/grid-tenant-1-idp" ] && [ ! -e "$PW/grid-tenant-2-idp" ]'
run --clean --confirm
t "CLEAN CONFIRM again: nothing to delete" 0 "organization grid-tenant-1: none" 'grep -q "realm grid-tenant-1-idp: none" <<<"$out"' \
  'grep -q "Secret ai-grid-idp-secrets/grid-tenant-2-idp: none" <<<"$out"'
run
t "create after CLEAN: all new again" 0 "organization grid-tenant-2: created" '[ "$(grep -c . "$W/imports")" = 4 ]'

W="$T/no-token"; mkdir -p "$W"; mv "$TOK" "$T/token.bak"; run
t "no provider-admin token: stops before any call" 1 "no provider-admin token in $TOK: run make provider-admin" \
  '[ ! -f "$W/curl.log" ]' '[ ! -f "$W/oc.log" ]'
mv "$T/token.bak" "$TOK"
printf 'not-the-sa-token\n' > "$TOK"; run
t "a token the console refuses: stops with the code and the message" 1 \
  "provider API ai_grid.v1.Tenants/List failed: HTTP 401: not the provider-admin token" '[ ! -d "$W/realms" ] || [ -z "$(ls "$W/realms")" ]'
(umask 077; printf '%s\n' "$FAKE_SA" > "$TOK")

# A realm made elsewhere: not imported again; its users get new passwords, and
# the organization's Secret takes the realm's own client secret.
W="$T/realm-exists"; mkdir -p "$W/realms"; rm -rf "$PW"
sed "s#\${KEYCLOAK_PUBLIC_URL}#$KC#g; s#\${GRID_TENANT_1_BROKER_CLIENT_SECRET}#made-elsewhere-$RANDOM#; s#\${[A-Z_0-9]*}#x#g" \
  "$L/components/examples/grid-tenant-1-idp-realm.json" > "$W/realms/grid-tenant-1-idp.json"
run
t "a realm that already exists: kept, new passwords, its client secret in the Secret" 0 "realm grid-tenant-1-idp: exists; set new passwords" \
  'grep -q "realm grid-tenant-2-idp: created" <<<"$out"' '[ "$(cat "$W/imports")" = grid-tenant-2-idp ]' \
  '[ "$(jq -r .value "$W/reset-grid-tenant-1-idp-id-alice-1.json")" = "$(cat "$PW/grid-tenant-1-idp/alice")" ]' \
  'grep -q "^made-elsewhere-" "$W/secrets/grid-tenant-1-idp"'

# An organization that outlived its realm: the new realm keeps the Secret's client secret.
W="$T/secret-kept"; mkdir -p "$W/secrets"; rm -rf "$PW"; printf 'kept-%s' "$RANDOM" > "$W/secrets/grid-tenant-1-idp"; run
t "a Secret without its realm: the new realm takes the Secret's client secret" 0 "realm grid-tenant-1-idp: created" \
  '[ "$(jq -r ".clients[0].secret" "$W/realms/grid-tenant-1-idp.json")" = "$(cat "$W/secrets/grid-tenant-1-idp")" ]' \
  'grep -q "^kept-" "$W/secrets/grid-tenant-1-idp"'

W="$T/create-fails"; mkdir -p "$W"; touch "$W/fail-create"; rm -rf "$PW"; run
t "an API error: stops, naming the call, the code and the backend's message" 1 \
  'provider API ai_grid.v1.Tenants/Create failed: HTTP 400: identity provider secret "grid-tenant-1-idp" not found' \
  '! grep -q "grid-tenant-2-idp" "$W/curl.log"'

W="$T/import-fails"; mkdir -p "$W"; touch "$W/fail-import"; rm -rf "$PW"; run
t "a Keycloak error: stops, naming the step, the code and Keycloak's message" 1 \
  "Keycloak: import realm grid-tenant-1-idp: HTTP 500: unknown_error" \
  '[ ! -e "$PW/grid-tenant-1-idp" ]' '! grep -q Tenants/Create "$W/curl.log"'

W="$T/no-keycloak"; mkdir -p "$W"; touch "$W/no-keycloak"; run
t "no Keycloak yet: stops with the friendly message" 1 "no Route maas-db/keycloak on hub"

# The admin credential goes only to the keycloak Route's host: a public URL elsewhere, or over http, stops before it's sent.
for u in https://keycloak.attacker.example.net http://keycloak.apps.hub.example.com; do
  W="$T/public-url-${u%%:*}"; mkdir -p "$W"; printf '%s' "$u" > "$W/public-url"; run
  t "public URL $u, not the Route's https host: stops, sends nothing" 1 \
    "public URL in ConfigMap maas-db/keycloak-public-url isn't https://keycloak.apps.hub.example.com, its Route's host over https" \
    '! grep -q "openid-connect/token" "$W/curl.log" 2>/dev/null' '! grep -q "extract secret/keycloak-secrets" "$W/oc.log"'
done

W="$T/default"; mkdir -p "$W"; printf 'keycloakOverlay=default\n' > "$D/root/inputs.env"; run
t "keycloakOverlay=default: refuses, the examples are already there" 1 "keycloakOverlay is default .*make test-tenants is for keycloakOverlay=core" \
  '[ ! -f "$W/curl.log" ]'
run --clean --confirm
t "  ... CLEAN too: never deletes the library's realms" 1 "keycloakOverlay is default" '[ ! -f "$W/curl.log" ]'
printf 'keycloakOverlay=core\n' > "$D/root/inputs.env"

W="$T/usage"; mkdir -p "$W"; run --bogus
t "an unknown argument: usage" 2 "usage: test-tenants.sh \[--clean \[--confirm\]\]"
run --confirm
t "  ... --confirm alone: usage" 2 "usage: test-tenants.sh"

fresh() { W="$T/$1"; mkdir -p "$W"; rm -rf "$PW"; run >/dev/null; [ "$rc" = 0 ] || { echo "setup of $1 failed: $out"; exit 1; }; }

# CLEAN counts only the users it deleted: a 404 is one already gone.
fresh gone; touch "$W/gone-22222222-1111-4111-8111-111111111111"; run --clean --confirm
t "CLEAN CONFIRM: a user already gone (404) isn't counted, and isn't an error" 0 \
  "organization grid-tenant-2: deleted, and 1 of its users from realm saas"

# An organization of that name whose identity provider isn't the test realm: kept, with its Secret.
fresh foreign; jq -c '.spec.identityProvider.config.issuer = "https://idp.example.com/acme"' "$W/orgs/grid-tenant-1.json" > "$W/o" && mv "$W/o" "$W/orgs/grid-tenant-1.json"
run
t "create: an organization with another issuer is reported, not changed" 0 \
  "organization grid-tenant-1: exists, id id-grid-tenant-1, but its identity provider's issuer isn't $KC/realms/grid-tenant-1-idp"
run --clean
t "CLEAN preview: an organization with another issuer would be kept" 0 \
  "organization grid-tenant-1: kept, with Secret ai-grid-idp-secrets/grid-tenant-1-idp: its identity provider's issuer isn't $KC/realms/grid-tenant-1-idp"
run --clean --confirm
t "CLEAN CONFIRM: that organization and its Secret stay; the rest goes" 0 "organization grid-tenant-1: kept" \
  'grep -q "realm grid-tenant-1-idp: the kept organization grid-tenant-1 doesn.t use it (another issuer)" <<<"$out"' \
  '[ -f "$W/orgs/grid-tenant-1.json" ] && [ -f "$W/secrets/grid-tenant-1-idp" ]' '! grep -q "id-grid-tenant-1" "$W/deleted-orgs"' \
  '! grep -q "user 11111111-" "$W/events"' '[ ! -f "$W/realms/grid-tenant-1-idp.json" ]' 'grep -q "organization grid-tenant-2: deleted" <<<"$out"'

# A foreign organization's Secret is never read or written by a create run, even when the realm is missing.
fresh foreign-secret; jq -c '.spec.identityProvider.config.issuer = "https://idp.example.com/acme"' "$W/orgs/grid-tenant-1.json" > "$W/o" && mv "$W/o" "$W/orgs/grid-tenant-1.json"
rm "$W/realms/grid-tenant-1-idp.json"; printf 'foreign-value-%s' "$RANDOM" > "$W/secrets/grid-tenant-1-idp"; cp "$W/secrets/grid-tenant-1-idp" "$T/foreign.want"
mark=$(wc -l < "$W/oc.log"); run
t "create: a foreign organization's Secret stays as it was, and the new realm doesn't take its value" 0 \
  "Secret ai-grid-idp-secrets/grid-tenant-1-idp: kept, it belongs to organization grid-tenant-1, whose issuer isn.t $KC/realms/grid-tenant-1-idp" \
  'grep -q "realm grid-tenant-1-idp: created" <<<"$out"' 'cmp -s "$T/foreign.want" "$W/secrets/grid-tenant-1-idp"' \
  '[ "$(jq -r ".clients[0].secret" "$W/realms/grid-tenant-1-idp.json")" != "$(cat "$T/foreign.want")" ]' \
  '! tail -n +$((mark+1)) "$W/oc.log" | grep -q "secret/grid-tenant-1-idp\|secret generic grid-tenant-1-idp"' \
  'tail -n +$((mark+1)) "$W/oc.log" | grep -q "secret generic grid-tenant-2-idp"'

# CLEAN's member filter uses the organization's own domains, as Tenants/List has them.
fresh org-domains; jq -c '.spec.domains = ["grid-tenant-2.test"]' "$W/orgs/grid-tenant-2.json" > "$W/o" && mv "$W/o" "$W/orgs/grid-tenant-2.json"
run --clean --confirm
t "CLEAN CONFIRM: members only of the organization's own domains (Tenants/List), not the library's" 0 \
  "organization grid-tenant-2: deleted, and 1 of its users from realm saas" '! grep -q "user 33333333-" "$W/events"'

# Members come from Keycloak, never from the console, which doesn't expose Tenants/ListMembers.
fresh no-listmembers; run --clean; run --clean --confirm
t "CLEAN, preview and CONFIRM: never calls Tenants/ListMembers" 0 "organization grid-tenant-1: deleted" \
  '[ ! -f "$W/listmembers-called" ]' '! grep -q "Tenants/ListMembers" "$W/curl.log"'

# No users left to delete: normal, for example after someone deleted them in Keycloak. (Deleting an
# organization deletes only its MANAGED members, and the default link is unmanaged.)
fresh none-left; printf '[]' > "$W/saas-users.json"; run --clean
t "CLEAN preview with no users of the organization: says so" 0 "organization grid-tenant-1 \(id id-grid-tenant-1\): would delete it; no users of it in realm saas"
run --clean --confirm
t "CLEAN CONFIRM with no users of the organization: none left, not an error" 0 \
  "organization grid-tenant-1: deleted; none of its users left in realm saas" '[ ! -f "$W/deleted-users" ]'

# A member id that isn't a UUID never reaches a URL.
fresh baduuid; printf '[{"id":"../../realms/saas","email":"alice@grid-tenant-1.test","idps":["grid-tenant-1"]}]' > "$W/saas-users.json"
run --clean --confirm
t "CLEAN CONFIRM: a user id that isn't a UUID stops it, deleting nothing" 1 "a user id in realm saas that isn't a UUID: deleting nothing" \
  '[ ! -f "$W/events" ]' '[ -f "$W/orgs/grid-tenant-1.json" ]' '! grep -q "\.\./" "$W/curl.log"'

# Paging: one page at a time until a short page; past the cap, it stops, deleting nothing.
fresh paging; ENVS=(TEST_TENANTS_PAGE=2); run --clean --confirm
t "CLEAN CONFIRM: reads the users a page at a time, until a short page" 0 "organization grid-tenant-1: deleted, and 1 of its users" \
  'grep -qx "search grid-tenant-1 first=0 max=2" "$W/searches"' 'grep -qx "search grid-tenant-1 first=2 max=2" "$W/searches"' \
  'grep -qx "search grid-tenant-1 first=4 max=2" "$W/searches"' '! grep -q "first=6" "$W/searches"'
fresh cap; ENVS=(TEST_TENANTS_PAGE=2 TEST_TENANTS_MAX_USERS=2); run --clean --confirm
t "CLEAN CONFIRM: more users than the cap: stops, deleting nothing" 1 \
  "more than 2 users are linked to identity provider grid-tenant-1 in realm saas: deleting nothing" \
  '[ ! -f "$W/events" ]' '[ -f "$W/orgs/grid-tenant-1.json" ]'
ENVS=()

# A domain that isn't a hostname never reaches a URL.
fresh bad-domain; jq -c '.spec.domains = ["grid-tenant-1.test&x=y"]' "$W/orgs/grid-tenant-1.json" > "$W/o" && mv "$W/o" "$W/orgs/grid-tenant-1.json"
run --clean --confirm
t "CLEAN CONFIRM: an organization domain that isn't a hostname stops it, deleting nothing" 1 \
  "organization grid-tenant-1 has a domain that isn't a hostname: deleting nothing" '[ ! -f "$W/events" ]' '[ ! -f "$W/searches" ]'

# A user that goes while it's read: skipped, named, not an error.
fresh vanish; touch "$W/vanish-11111111-1111-4111-8111-111111111111"; run --clean --confirm
t "CLEAN CONFIRM: a user gone while it's read (404) is skipped and named" 0 "user alice@grid-tenant-1.test: gone while reading it" \
  '! grep -q "user 11111111-" "$W/events"' 'grep -q "organization grid-tenant-1: deleted; none of its users left" <<<"$out"'

# The identity provider Secret namespace: the console backend's setting, else the default; IDP_SECRETS_NAMESPACE wins.
W="$T/idp-ns"; mkdir -p "$W"; rm -rf "$PW"; printf custom-idp > "$W/idp-ns"; run
t "the Secret goes to the console backend's AI_GRID_IDP_SECRET_NAMESPACE" 0 "organization grid-tenant-1: created" \
  'grep -q "create secret generic grid-tenant-1-idp -n custom-idp " "$W/oc.log"' '! grep -q "^note:" <<<"$out"'
W="$T/idp-ns-env"; mkdir -p "$W"; rm -rf "$PW"; printf custom-idp > "$W/idp-ns"; ENVS=(IDP_SECRETS_NAMESPACE=other-idp); run
t "  ... IDP_SECRETS_NAMESPACE overrides it" 1 "no namespace other-idp on hub for identity provider secrets" \
  '! grep -q "Tenants/Create" "$W/curl.log"'
ENVS=()

# options.KEYCLOAK_NAMESPACE and KEYCLOAK_REALM in clusters.yaml apply (deployment_load).
cp "$D/clusters.yaml" "$T/clusters.bak"
printf 'options: {KEYCLOAK_NAMESPACE: kc-test, KEYCLOAK_REALM: brokers}\n' >> "$D/clusters.yaml"
fresh options-kc; run --clean --confirm
t "options.KEYCLOAK_NAMESPACE and KEYCLOAK_REALM from clusters.yaml apply" 0 "of its users from realm brokers" \
  'grep -q "get route keycloak -n kc-test " "$W/oc.log"' 'grep -q "extract secret/keycloak-secrets -n kc-test " "$W/oc.log"' \
  '! grep -q " -n maas-db " "$W/oc.log"'
cp "$T/clusters.bak" "$D/clusters.yaml"

# Upstream's own realm files, when a library checkout is at hand (LIBRARY_CHECKOUT, else the
# repository's .library/): the transform leaves no placeholder, no java-keystore key, and the users the library documents.
real=${LIBRARY_CHECKOUT:-$SRC/.library}
if [ -f "$real/apps/keycloak/components/examples/grid-tenant-2-idp-realm.json" ]; then
  W="$T/real-lib"; mkdir -p "$W"; rm -rf "$PW"; cp "$real/apps/keycloak/components/examples/"grid-tenant-*-idp-realm.json "$L/components/examples/"
  cp "$real/apps/keycloak/base/manifests/scripts/render-realm.sh" "$L/base/manifests/scripts/render-realm.sh"
  git -C "$T/lib" add -A && git -c core.hooksPath=/dev/null -C "$T/lib" commit -qm real
  sed -i.bak -E "s#(libraryRevision: &libraryRevision )[0-9a-f]+#\1$(git -C "$T/lib" rev-parse HEAD)#" "$D/root/applicationset.yaml"
  run
  t "upstream's realm files ($real): imported with no placeholder and no java-keystore key, with the documented users" 0 "realm grid-tenant-2-idp: created" \
    '! grep -q "\${" "$W/realms/grid-tenant-1-idp.json" "$W/realms/grid-tenant-2-idp.json"' \
    '! grep -q java-keystore "$W/realms/grid-tenant-1-idp.json" "$W/realms/grid-tenant-2-idp.json"' \
    '[ "$(jq -r "[.users[].username] | join(\" \")" "$W/realms/grid-tenant-1-idp.json")" = alice ]' \
    '[ "$(jq -r "[.users[].username] | sort | join(\" \")" "$W/realms/grid-tenant-2-idp.json")" = "alice bob carol" ]' \
    'jq -e "[.clients[] | select(.clientId == \"saas-broker\") | .redirectUris[]] == [\"'"$KC"'/realms/saas/broker/grid-tenant-2/endpoint\"]" "$W/realms/grid-tenant-2-idp.json" >/dev/null'
else
  echo "   skip upstream's realm files: no library checkout at $real (set LIBRARY_CHECKOUT)"
fi

echo "test-tenants tests: $((total-fails)) ok, $fails failed"; exit "$fails"
