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
org() { # N
  printf '{"id": "fixed-%s", "name": "Grid Tenant %s", "alias": "grid-tenant-%s", "domains": [{"name": "grid-tenant-%s.test", "identityProviderAlias": "grid-tenant-%s"}]}' "$1" "$1" "$1" "$1" "$1"
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
case "$a" in
  *" whoami "*) echo admin ;;
  *" get route "*) printf console.apps.hub.example.com ;;
  *" get configmap keycloak-public-url -n maas-db "*) [ -f "$d/no-keycloak" ] || printf 'https://keycloak.apps.hub.example.com/' ;;
  *" extract secret/keycloak-secrets -n maas-db "*)
    t=$(to "$@"); printf admin > "$t/KC_BOOTSTRAP_ADMIN_USERNAME"; printf '%s' "$FAKE_ADMIN" > "$t/KC_BOOTSTRAP_ADMIN_PASSWORD" ;;
  *" extract secret/grid-tenant-"*"-idp -n ai-grid-idp-secrets --keys=client-secret "*)
    n=${2#secret/}; [ -f "$d/secrets/$n" ] || { echo "Error from server (NotFound): secrets \"$n\" not found" >&2; exit 1; }
    cp "$d/secrets/$n" "$(to "$@")/client-secret" ;;
  *" get namespace ai-grid-idp-secrets "*) echo namespace/ai-grid-idp-secrets ;;
  *" create secret generic "*" -n ai-grid-idp-secrets --from-file=client-secret="*" --dry-run=client -o yaml "*)
    for x in "$@"; do case "$x" in --from-file=client-secret=*) f=${x#--from-file=client-secret=} ;; esac; done
    printf 'name: %s\nclient-secret: %s\n' "$4" "$(base64 < "$f" | tr -d '\n')" ;;
  *" apply -f - "*) y=$(cat); n=$(sed -n 's/^name: //p' <<<"$y"); mkdir -p "$d/secrets"
    sed -n 's/^client-secret: //p' <<<"$y" | base64 -d > "$d/secrets/$n"; echo "secret/$n configured" ;;
  *" delete secret "*" -n ai-grid-idp-secrets --ignore-not-found "*) rm -f "$d/secrets/$3" ;;
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
  "GET $kc/admin/realms/"*)
    r=${url##*/}; [ -f "$d/realms/$r.json" ] && reply 200 "{\"realm\":\"$r\"}"; reply 404 '{"error":"Realm not found."}' ;;
  "PUT $kc/admin/realms/"*"/reset-password")
    p=${url#"$kc/admin/realms/"}; r=${p%%/*}; u=${p#*/users/}; u=${u%%/*}
    jq -e --arg u "$u" 'any(.users[]; .id == $u)' "$d/realms/$r.json" >/dev/null || reply 404 '{"error":"User not found"}'
    cp "${data#@}" "$d/reset-$r-$u.json"; reply 204 '' ;;
  "DELETE $kc/admin/realms/saas/users/"*) echo "${url##*/}" >> "$d/deleted-users"; reply 204 '' ;;
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
    id=$(jq -r .id <<<"$data"); n=${id#id-}
    reply 200 "{\"items\":[{\"id\":\"user-$n\",\"email\":\"alice@$n.test\"},{\"id\":\"user-elsewhere\",\"email\":\"dave@elsewhere.test\"}]}" ;;
  "POST https://console.apps.hub.example.com/ai_grid.v1.Tenants/Delete")
    id=$(jq -r .id <<<"$data"); n=${id#id-}; echo "$data" >> "$d/deleted-orgs"; rm "$d/orgs/$n.json"; reply 200 '{}' ;;
  *) echo "stub curl: unexpected: $m $url" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

# --- The deployment repository.
D="$T/repo"; mkdir -p "$D/root" "$D/.config/hub"; cp -R "$SRC/scripts" "$D/"; : > "$D/.config/hub/kubeconfig"
printf '  libraryRepoURL: file://%s\n  libraryRevision: &libraryRevision %s\n' "$T/lib" "$(git -C "$T/lib" rev-parse HEAD)" > "$D/root/applicationset.yaml"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"
printf 'keycloakOverlay=core\n' > "$D/root/inputs.env"
TOK="$D/.config/provider-admin-token"; (umask 077; printf '%s\n' "$FAKE_SA" > "$TOK")
PW="$D/.config/test-tenants"
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

run() { # [ARGS]: runs test-tenants.sh with the stubs reading $W; sets rc and out
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" LIBRARY="$T/lib" "$D/scripts/test-tenants.sh" "$@" 2>&1) && rc=0 || rc=$?
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
t "CLEAN: deletes the organizations, their users, the Secrets, the realms and the password files" 0 \
  "organization grid-tenant-1: deleted \(1 of its users deleted from realm saas\)" \
  'grep -q "realm grid-tenant-2-idp: deleted" <<<"$out"' \
  'grep -qxF "{\"id\":\"id-grid-tenant-1\",\"version\":1}" "$W/deleted-orgs"' \
  '[ "$(sort "$W/deleted-users" | tr "\n" " ")" = "user-grid-tenant-1 user-grid-tenant-2 " ]' \
  '[ -z "$(find "$W/realms" "$W/orgs" "$W/secrets" -type f)" ]' '[ ! -e "$PW/grid-tenant-1-idp" ] && [ ! -e "$PW/grid-tenant-2-idp" ]'
run --clean
t "CLEAN again: nothing to delete" 0 "organization grid-tenant-1: none" 'grep -q "realm grid-tenant-1-idp: none" <<<"$out"'
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
t "no Keycloak yet: stops with the friendly message" 1 "no ConfigMap maas-db/keycloak-public-url on hub"

W="$T/default"; mkdir -p "$W"; printf 'keycloakOverlay=default\n' > "$D/root/inputs.env"; run
t "keycloakOverlay=default: refuses, the examples are already there" 1 "keycloakOverlay is default .*make test-tenants is for keycloakOverlay=core" \
  '[ ! -f "$W/curl.log" ]'
run --clean
t "  ... CLEAN too: never deletes the library's realms" 1 "keycloakOverlay is default" '[ ! -f "$W/curl.log" ]'
printf 'keycloakOverlay=core\n' > "$D/root/inputs.env"

W="$T/usage"; mkdir -p "$W"; run --bogus
t "an unknown argument: usage" 2 "usage: test-tenants.sh \[--clean\]"

echo "test-tenants tests: $((total-fails)) ok, $fails failed"; exit "$fails"
