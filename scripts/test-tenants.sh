#!/usr/bin/env bash
# Test deployments only, never a real install: recreate the library's example
# tenants on a hub whose Keycloak is the core profile (keycloakOverlay=core),
# the way a provider would, so tests have organizations and users to sign in as.
#
#   scripts/test-tenants.sh                    create what's missing; report what exists
#   scripts/test-tenants.sh --clean            preview what --clean --confirm deletes
#   scripts/test-tenants.sh --clean --confirm  delete what it creates
#
# For each example tenant N (1 and 2):
#
# 1. Realm grid-tenant-N-idp, through Keycloak's admin API: the library's
#    apps/keycloak/components/examples/grid-tenant-N-idp-realm.json at your
#    library revision, rendered with the library's render-realm.sh. The realm
#    stands in for an organization's own identity provider. Its placeholders get
#    values generated here: the users' password and the saas-broker client
#    secret. One change: the file's java-keystore signing key reads a keystore
#    that only the library's default profile mounts, so it's left out, and
#    Keycloak generates the realm's signing keys.
# 2. Secret grid-tenant-N-idp in the console's identity provider namespace
#    (the console backend's AI_GRID_IDP_SECRET_NAMESPACE, else
#    ai-grid-idp-secrets; IDP_SECRETS_NAMESPACE overrides it), key client-secret:
#    the realm's saas-broker client secret, for the organization's identity
#    provider.
# 3. Organization grid-tenant-N, through the provider API
#    (ai_grid.v1.Tenants/Create, the console's Create organization), as the
#    provider-admin ServiceAccount (make provider-admin). Its domains and
#    identity provider settings come from the library's example saas-realm.json.
#    The backend creates the identity provider and its mappers, and Keycloak
#    gives the organization a new id.
#
# Each user's password goes to .config/test-tenants/REALM/USER (mode 600, in a
# directory only you can read), never to the output or a command line. The
# library's render-realm.sh reads the generated values from its environment, as
# upstream's Keycloak does, so they're in that child process's environment while
# it renders. A rerun
# creates only what's missing; for a realm that exists without its password
# files, it sets new passwords for the file's users.
#
# --clean lists, and with --confirm deletes, for each tenant: the users that
# signed in through the organization (in realm saas, with an email in one of
# its domains and a link to its identity provider, found with Keycloak's admin
# API; the console doesn't list members), the organization (provider API), the
# Secret, the realm, and the password files. It deletes an organization only
# when its identity provider's issuer is the test realm's, and otherwise keeps
# it and its Secret and says why. Without --clean nothing is deleted.
#
# Inputs: clusters.yaml, the hub's login (make login), the provider-admin token
# (.config/provider-admin-token), and the library (scripts/library.sh). The
# Keycloak admin's credential is read from Secret keycloak-secrets in
# KEYCLOAK_NAMESPACE (default maas-db) into a temporary file, and sent only to
# the host of Route keycloak there. KEYCLOAK_REALM (default saas) is the broker
# realm. Both can be set in the environment or in clusters.yaml's options:.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/clusters.sh"
. "$here/library.sh"

clean="" confirm=""
case "$*" in
  "") ;;
  --clean) clean=1 ;;
  "--clean --confirm") clean=1 confirm=1 ;;
  *) echo "usage: test-tenants.sh [--clean [--confirm]]" >&2; exit 2 ;;
esac
die() { echo "error: $*" >&2; exit 1; }

deployment_load "$here/.."   # options.KEYCLOAK_NAMESPACE and options.KEYCLOAK_REALM
dir=$CLUSTERS_DIR
overlay=$(sed -n 's/^keycloakOverlay=//p' "$dir/root/inputs.env" 2>/dev/null | tail -n 1)
[ "${overlay:-core}" = core ] ||
  die "keycloakOverlay is ${overlay} in root/inputs.env: the library's example tenants are already there; make test-tenants is for keycloakOverlay=core"
token_file="$dir/.config/provider-admin-token"
[ -s "$token_file" ] || die "no provider-admin token in $token_file: run make provider-admin"

library_dir "$dir" || exit 1
examples="$LIB/apps/keycloak/components/examples"
render="$LIB/apps/keycloak/base/manifests/scripts/render-realm.sh"
for f in "$examples/saas-realm.json" "$examples/grid-tenant-1-idp-realm.json" "$examples/grid-tenant-2-idp-realm.json" "$render"; do
  [ -f "$f" ] || die "the library has no ${f#"$LIB/"}: test-tenants needs the library's Keycloak examples"
done

hub=$(hub_name)
cluster_login_ok "$hub"
cluster_tls "$hub"   # the hub's ca: in clusters.yaml, for Keycloak's Route
export KUBECONFIG; KUBECONFIG=$(cluster_kubeconfig "$hub")
kc_ns=${KEYCLOAK_NAMESPACE:-maas-db} saas=${KEYCLOAK_REALM:-saas}
# Where the console backend reads identity provider Secrets: its own setting, else the chart's default.
idp_ns=${IDP_SECRETS_NAMESPACE:-}
if [ -z "$idp_ns" ]; then
  if backend=$(oc get deployment ai-grid-provider-console -n ai-grid-provider-console -o json 2>/dev/null); then
    idp_ns=$(jq -r 'first(.spec.template.spec.containers[].env[]? | select(.name == "AI_GRID_IDP_SECRET_NAMESPACE") | .value) // empty' <<<"$backend" 2>/dev/null || true)
  else
    echo "note: can't read Deployment ai-grid-provider-console/ai-grid-provider-console on $hub; using ai-grid-idp-secrets for identity provider Secrets (IDP_SECRETS_NAMESPACE sets another)" >&2
  fi
  idp_ns=${idp_ns:-ai-grid-idp-secrets}
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# The admin credential goes only to the keycloak Route's host, by name. The
# public URL the realms name (ConfigMap keycloak-public-url, Keycloak's
# KC_HOSTNAME) must be that host over https, or nothing is sent.
kc_host=$(oc get route keycloak -n "$kc_ns" -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$kc_host" ] || die "no Route $kc_ns/keycloak on $hub: Keycloak isn't installed yet (see make status)"
kc_url="https://$kc_host"
public_url=$(oc get configmap keycloak-public-url -n "$kc_ns" -o jsonpath='{.data.KEYCLOAK_PUBLIC_URL}' 2>/dev/null || true)
[ -n "$public_url" ] || die "no ConfigMap $kc_ns/keycloak-public-url on $hub: Keycloak isn't ready yet (see make status)"
[ "${public_url%/}" = "$kc_url" ] ||
  die "Keycloak's public URL in ConfigMap $kc_ns/keycloak-public-url isn't $kc_url, its Route's host over https: test-tenants sends nothing"
mkdir -p "$tmp/admin"
oc extract secret/keycloak-secrets -n "$kc_ns" --keys=KC_BOOTSTRAP_ADMIN_USERNAME,KC_BOOTSTRAP_ADMIN_PASSWORD \
  --to="$tmp/admin" >/dev/null 2>&1 || die "can't read Keycloak's admin credential from Secret $kc_ns/keycloak-secrets on $hub"

# A new secret: 64 hex characters, to a file.
gen() { (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$1"); }

# kc_login: a Keycloak admin token, in a header file. The master realm's tokens
# last a minute, so each step signs in again.
kc_login() {
  local code
  code=$(curl -sS --max-time 30 ${CURL_TLS[@]+"${CURL_TLS[@]}"} -o "$tmp/token.json" -w '%{http_code}' -X POST \
    --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode "username@$tmp/admin/KC_BOOTSTRAP_ADMIN_USERNAME" \
    --data-urlencode "password@$tmp/admin/KC_BOOTSTRAP_ADMIN_PASSWORD" \
    "$kc_url/realms/master/protocol/openid-connect/token") || code=000
  [ "$code" = 200 ] || die "Keycloak at $kc_url refused the admin sign-in: HTTP $code"
  (umask 077; { printf 'Authorization: Bearer '; jq -j '.access_token // ""' "$tmp/token.json"; printf '\n'; } > "$tmp/kc-auth")
  rm -f "$tmp/token.json"
}

# kc METHOD PATH [BODY_FILE]: one admin API call under /admin/realms; the HTTP
# code in $code, the reply in $tmp/kc.json.
kc() {
  local body=(); [ -z "${3:-}" ] || body=(-H 'Content-Type: application/json' --data-binary "@$3")
  code=$(curl -sS --max-time 60 ${CURL_TLS[@]+"${CURL_TLS[@]}"} -o "$tmp/kc.json" -w '%{http_code}' -X "$1" \
    -H "@$tmp/kc-auth" ${body[@]+"${body[@]}"} "$kc_url/admin/realms$2") || code=000
}
kc_fail() { # WHAT: stops with the call's code and Keycloak's message
  local msg; msg=$(jq -r '.errorMessage // .error_description // .error // empty' "$tmp/kc.json" 2>/dev/null || true)
  die "Keycloak: $1: HTTP $code${msg:+: $msg}"
}

# api METHOD JSON: one provider API call (scripts/console-call.sh) as the
# provider-admin ServiceAccount; the reply in $tmp/api.json. Stops on an error,
# with the code and the backend's message.
api() {
  if ! CONSOLE_TOKEN_FILE="$token_file" "$here/console-call.sh" "ai_grid.v1.$1" "$2" > "$tmp/api.json" 2> "$tmp/api.err"; then
    local msg status
    msg=$(jq -r '.message // empty' "$tmp/api.json" 2>/dev/null || true)
    status=$(grep -oE 'HTTP [0-9]+' "$tmp/api.err" | tail -n 1 || true)
    [ -n "$msg$status" ] || msg=$(grep -v '^HTTP ' "$tmp/api.err" | tail -n 1 || true)
    die "provider API ai_grid.v1.$1 failed${status:+: $status}${msg:+: $msg}"
  fi
}
all_passwords() { # DIR, the users on stdin: whether each has a password file
  local uid user rest
  while read -r uid user rest; do [ -s "$1/$user" ] || return 1; done
}
is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
org_of() { # NAME: the organization's JSON from $tmp/orgs.json, empty when there's none
  jq -c --arg n "$1" 'first(.items[]? | select(.metadata.name == $n)) // empty' "$tmp/orgs.json"
}

summary=()
api Tenants/List '{}'; cp "$tmp/api.json" "$tmp/orgs.json"

for n in 1 2; do
  org=grid-tenant-$n realm=grid-tenant-$n-idp secret=grid-tenant-$n-idp
  file="$examples/$realm-realm.json" pwdir="$dir/.config/test-tenants/$realm"
  issuer="$kc_url/realms/$realm"
  o=$(org_of "$org")
  # ours: the organization exists and signs in through the test realm. foreign:
  # an organization of that name signs in elsewhere; it and its Secret are never
  # read, changed or deleted.
  ours="" foreign=""
  if [ -n "$o" ]; then
    if [ "$(jq -r '.spec.identityProvider.config.issuer // ""' <<<"$o")" = "$issuer" ]; then ours=1; else foreign=1; fi
  fi

  if [ -n "$clean" ]; then
    if [ -z "$o" ]; then
      summary+=("organization $org: none")
    elif [ -n "$foreign" ]; then
      summary+=("organization $org: kept, with Secret $idp_ns/$secret: its identity provider's issuer isn't $issuer, so it isn't a test organization")
    else
      id=$(jq -r .id <<<"$o") version=$(jq -r '.metadata.version // 1' <<<"$o")
      # The users that signed in through the organization, from Keycloak: an
      # email in one of the organization's own domains (Tenants/List) and a
      # link to its identity provider (alias: the organization's name). They're
      # found before the organization goes, because deleting its identity
      # provider also deletes those links. The console doesn't list members.
      kc_login; : > "$tmp/candidates"; : > "$tmp/members"
      for d in $(jq -r '.spec.domains[]?' <<<"$o"); do
        [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || die "organization $org has a domain that isn't a hostname: deleting nothing"
        kc GET "/$saas/users?email=%40$d&exact=false&briefRepresentation=true&max=1000"
        [ "$code" = 200 ] || kc_fail "find the users of domain $d in realm $saas"
        jq -r --arg s "@$d" '.[]? | select((.email // "") | ascii_downcase | endswith($s | ascii_downcase)) | "\(.id) \(.email)"' \
          "$tmp/kc.json" >> "$tmp/candidates"
      done
      sort -u -o "$tmp/candidates" "$tmp/candidates"
      while read -r uid email; do
        [ -n "$uid" ] || continue
        is_uuid "$uid" || die "Keycloak listed a user id in realm $saas that isn't a UUID: deleting nothing"
        kc GET "/$saas/users/$uid/federated-identity"
        case "$code" in
          200) ! jq -e --arg a "$org" 'any(.[]?; .identityProvider == $a)' "$tmp/kc.json" >/dev/null || echo "$uid $email" >> "$tmp/members" ;;
          404) ;;
          *) kc_fail "read the identity provider links of user $uid in realm $saas" ;;
        esac
      done < "$tmp/candidates"
      count=$(grep -c . "$tmp/members" || true)
      if [ -z "$confirm" ]; then
        if [ "$count" = 0 ]; then summary+=("organization $org (id $id): would delete it; no users of it in realm $saas")
        else summary+=("organization $org (id $id): would delete it, and its $count users from realm $saas: $(cut -d' ' -f2 "$tmp/members" | paste -sd ' ' -)"); fi
      else
        # The users first: once the identity provider is gone, so are their links to it.
        gone=0
        while read -r uid _; do
          kc DELETE "/$saas/users/$uid"
          case "$code" in 204) gone=$((gone+1)) ;; 404) ;; *) kc_fail "delete user $uid from realm $saas" ;; esac
        done < "$tmp/members"
        api Tenants/Delete "$(jq -cn --arg id "$id" --argjson v "$version" '{id: $id, version: $v}')"
        if [ "$gone" = 0 ]; then summary+=("organization $org: deleted; none of its users left in realm $saas")
        else summary+=("organization $org: deleted, and $gone of its users from realm $saas"); fi
      fi
    fi
    if [ -n "$foreign" ]; then :
    elif oc get secret "$secret" -n "$idp_ns" >/dev/null 2>&1; then
      if [ -n "$confirm" ]; then oc delete secret "$secret" -n "$idp_ns" --ignore-not-found >/dev/null; summary+=("Secret $idp_ns/$secret: deleted")
      else summary+=("Secret $idp_ns/$secret: would delete it"); fi
    else summary+=("Secret $idp_ns/$secret: none"); fi
    # The realm goes even when a foreign organization of that name stays: that
    # organization can't be using it, because its issuer isn't the test realm's.
    [ -z "$foreign" ] || summary+=("realm $realm: the kept organization $org doesn't use it (another issuer), so it's not kept for it")
    kc_login
    if [ -n "$confirm" ]; then
      kc DELETE "/$realm"
      case "$code" in 204) summary+=("realm $realm: deleted") ;; 404) summary+=("realm $realm: none") ;; *) kc_fail "delete realm $realm" ;; esac
      rm -rf "$pwdir"
    else
      kc GET "/$realm"
      case "$code" in 200) summary+=("realm $realm: would delete it") ;; 404) summary+=("realm $realm: none") ;; *) kc_fail "read realm $realm" ;; esac
      [ ! -d "$pwdir" ] || summary+=("password files $pwdir: would delete them")
    fi
    continue
  fi

  # 1. The realm.
  kc_login; kc GET "/$realm"
  case "$code" in 200) exists=1 ;; 404) exists="" ;; *) kc_fail "read realm $realm" ;; esac
  users=$(jq -r '.users[] | "\(.id) \(.username) \(.email // "")"' "$file")
  if [ -z "$exists" ]; then
    gen "$tmp/password"
    # The organization's Secret, when there is one, keeps its client secret, so
    # an organization that outlived its realm still signs in.
    # Never a foreign organization's Secret: it isn't this realm's.
    rm -rf "$tmp/old"; mkdir "$tmp/old"
    if [ -z "$foreign" ] && oc extract "secret/$secret" -n "$idp_ns" --keys=client-secret --to="$tmp/old" >/dev/null 2>&1 && [ -s "$tmp/old/client-secret" ]; then
      cp "$tmp/old/client-secret" "$tmp/client-secret"
    else gen "$tmp/client-secret"; fi
    # Without the java-keystore key provider, which reads a keystore only the default profile mounts.
    # With no key provider left, the key goes, so that Keycloak adds its default ones.
    jq '.components["org.keycloak.keys.KeyProvider"] |= ((. // []) | map(select(.providerId != "java-keystore")))
      | if (.components["org.keycloak.keys.KeyProvider"] | length) == 0 then del(.components["org.keycloak.keys.KeyProvider"]) else . end' \
      "$file" > "$tmp/realm.json"
    ( umask 077
      export KEYCLOAK_PUBLIC_URL="$kc_url"
      export "GRID_TENANT_${n}_BROKER_CLIENT_SECRET=$(cat "$tmp/client-secret")"
      export "GRID_TENANT_${n}_TEST_USER_PASSWORD=$(cat "$tmp/password")"
      bash "$render" < "$tmp/realm.json" > "$tmp/realm.rendered.json" ) ||
      die "can't render the library's ${file#"$LIB/"}"
    kc POST "" "$tmp/realm.rendered.json"
    rm -f "$tmp/realm.rendered.json"
    case "$code" in 201) state=created ;; *) kc_fail "import realm $realm" ;; esac
  elif [ -n "$users" ] && ! all_passwords "$pwdir" <<<"$users"; then
    # The realm exists, but not every password is in a file: set new ones.
    gen "$tmp/password"
    jq -n --rawfile p "$tmp/password" '{type: "password", value: $p, temporary: false}' > "$tmp/credential.json"
    while read -r uid user _; do
      kc PUT "/$realm/users/$uid/reset-password" "$tmp/credential.json"
      [ "$code" = 204 ] || kc_fail "set the password of $user in realm $realm (a realm that isn't the library's? make test-tenants CLEAN=1 deletes it)"
    done <<<"$users"
    rm -f "$tmp/credential.json"
    state="exists; set new passwords"
  else
    state=exists
  fi
  if [ -f "$tmp/password" ]; then
    (umask 077; mkdir -p "$pwdir"; chmod 700 "$dir/.config" "$dir/.config/test-tenants" "$pwdir"
     while read -r uid user _; do cp "$tmp/password" "$pwdir/$user"; chmod 600 "$pwdir/$user"; done <<<"$users")
    rm -f "$tmp/password"
  fi
  summary+=("realm $realm: $state")

  # 2. The organization's client secret: the realm's saas-broker secret. Not
  # for a foreign organization, whose Secret is its own.
  if [ -n "$foreign" ]; then
    summary+=("Secret $idp_ns/$secret: kept, it belongs to organization $org, whose issuer isn't $issuer")
  else
    kc_login
    oc get namespace "$idp_ns" >/dev/null 2>&1 ||
      die "no namespace $idp_ns on $hub for identity provider secrets: set IDP_SECRETS_NAMESPACE to the console chart's backend.idpSecrets.namespace"
    kc GET "/$realm/clients?clientId=saas-broker"
    [ "$code" = 200 ] || kc_fail "find client saas-broker in realm $realm"
    cid=$(jq -r '.[0].id // empty' "$tmp/kc.json")
    [ -n "$cid" ] || die "realm $realm has no client saas-broker"
    kc GET "/$realm/clients/$cid/client-secret"
    [ "$code" = 200 ] || kc_fail "read client saas-broker's secret in realm $realm"
    (umask 077; jq -j '.value // ""' "$tmp/kc.json" > "$tmp/client-secret"); rm -f "$tmp/kc.json"
    [ -s "$tmp/client-secret" ] || die "client saas-broker in realm $realm has no secret"
    oc create secret generic "$secret" -n "$idp_ns" --from-file=client-secret="$tmp/client-secret" --dry-run=client -o yaml |
      oc apply --server-side --force-conflicts -f - >/dev/null
    # Server-side, so a Secret this creates holds no copy of its data in a
    # last-applied annotation; one first applied client-side keeps its old one.
    rm -f "$tmp/client-secret"
  fi

  # 3. The organization, through the provider API.
  if [ -n "$ours" ]; then
    summary+=("organization $org: exists, id $(jq -r .id <<<"$o")")
  elif [ -n "$o" ]; then
    summary+=("organization $org: exists, id $(jq -r .id <<<"$o"), but its identity provider's issuer isn't $issuer: its users don't sign in through the test realm")
  else
    body=$(jq -c --arg a "$org" --arg url "$kc_url" --arg secret "$secret" '
      def u: gsub("\\$\\{KEYCLOAK_PUBLIC_URL\\}"; $url);
      first(.identityProviders[] | select(.alias == $a)) as $i
      | first(.organizations[] | select(.alias == $a)) as $o
      | {object: {metadata: {name: $a}, spec: {
          domains: [$o.domains[].name],
          identityProvider: {title: $i.displayName, enabled: true, config: {
            clientId: $i.config.clientId, clientSecretSecretName: $secret,
            issuer: ($i.config.issuer | u), authorizationUrl: ($i.config.authorizationUrl | u),
            tokenUrl: ($i.config.tokenUrl | u), userInfoUrl: ($i.config.userInfoUrl // "" | u),
            jwksUrl: ($i.config.jwksUrl // "" | u), logoutUrl: ($i.config.logoutUrl // "" | u),
            defaultScopes: ($i.config.defaultScope // "openid profile email"),
            validateSignature: (($i.config.validateSignature // "true") == "true")}}}}}' "$examples/saas-realm.json")
    [ -n "$body" ] || die "the library's saas-realm.json has no identity provider $org"
    api Tenants/Create "$body"
    summary+=("organization $org: created, id $(jq -r '.object.id // "?"' "$tmp/api.json")")
  fi
  while read -r uid user email; do
    if [ -s "$pwdir/$user" ]; then summary+=("user $user of $realm (sign in as $email): password in $pwdir/$user")
    else summary+=("user $user of $realm: no password file"); fi
  done <<<"$users"
done

if [ -n "$confirm" ]; then echo "Test tenants removed (test deployments only):"
elif [ -n "$clean" ]; then echo "Test tenants: what make test-tenants CLEAN=1 CONFIRM=1 would delete (test deployments only):"
else echo "Test tenants (test deployments only, never a real install):"; fi
printf '  %s\n' "${summary[@]}"
[ -n "$clean" ] || echo "Each user signs in to the Org UI with their email; Keycloak sends them to their realm."
