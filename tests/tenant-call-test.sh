#!/usr/bin/env bash
# Tests for scripts/tenant-call.sh with a stub oc and a stub curl (no IdP, no
# cluster). The stub curl logs its arguments, never a file's contents.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0

c() { # name want_rc expect_grep cmd...: a plain command
  local name=$1 want=$2 expect=$3; shift 3; local rc out; total=$((total+1))
  out=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}
t() { # name want_rc expect_grep [args...]
  local name=$1 want=$2 expect=$3; shift 3; local rc out
  total=$((total+1)); : > "$T/curl.log"
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$T" "$D/scripts/tenant-call.sh" "$@" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && ! grep -q "FAKE_" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
case " $* " in
  *" whoami "*) echo admin ;;
  *" get ingresses.config.openshift.io "*) printf 'apps.site-b.example.com' ;;
  *" get secret tenant-idp-client "*) printf 'RkFLRV9jbGllbnRfc2VjcmV0' ;;   # base64 of FAKE_client_secret
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/curl.log"
headers="" out="" prev="" url=""
for a in "$@"; do
  [ "$prev" = -D ] && headers=$a; [ "$prev" = -o ] && out=$a; prev=$a
  case "$a" in https://*) url=$a ;; esac
done
case "$url" in
  */protocol/openid-connect/token)
    if [ -f "$STUB_DIR/bad-login" ]; then echo '{"error":"invalid_grant","error_description":"Invalid user credentials"}'
    else echo '{"access_token":"FAKE_token"}'; fi ;;
  */v1/chat/completions)
    printf 'HTTP/2 200\r\nx-grid-site: site-b\r\n\r\n' > "$headers"
    echo '{"choices":[{"message":{"content":"Hello there, nice to meet."}}]}' > "$out"; printf 200 ;;
esac
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

D="$T/repo"; mkdir -p "$D/root"; cp -R "$SRC/scripts" "$D/"; cp "$SRC/root/kustomization.yaml" "$SRC/root/inputs.yaml" "$D/root/"
sed -i.bak 's#REQUIRED-idpIssuerURL#https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants#' "$D/root/inputs.yaml"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
for n in hub site-b; do mkdir -p "$D/.config/$n"; : > "$D/.config/$n/kubeconfig"; done
printf 'FAKE_password' > "$T/pw"
ARGS=(--user alice --password-file "$T/pw" --subscription smollm2-users --model smollm2-chat)

t "prints the reply" 0 "^Hello there, nice to meet.$" "${ARGS[@]}"
t "  ... the HTTP status" 0 "^HTTP 200$" "${ARGS[@]}"
t "  ... and the site that served it" 0 "^x-grid-site: site-b$" "${ARGS[@]}"
env PATH="$T/bin:$PATH" STUB_DIR="$T" "$D/scripts/tenant-call.sh" "${ARGS[@]}" >/dev/null 2>&1; cp "$T/curl.log" "$T/calls"
c "token from the issuer in inputs.yaml" 0 "curl .*https://keycloak-tenant-idp.apps.hub.example.com/realms/tenants/protocol/openid-connect/token" cat "$T/calls"
c "call to the site's MaaS host" 0 "https://maas.apps.site-b.example.com/v1/chat/completions" cat "$T/calls"
c "no secret on curl's command line" 0 "^clean$" bash -c 'grep -q FAKE_ "$0" && echo leaked || echo clean' "$T/calls"
touch "$T/bad-login"
t "a refused login says why" 1 "the IdP gave no token for alice: Invalid user credentials" "${ARGS[@]}"
rm "$T/bad-login"
t "missing arguments: usage" 2 "usage: tenant-call.sh" --user alice
sed -i.bak 's#^  value: &idpIssuerURL .*#  value: \&idpIssuerURL REQUIRED-idpIssuerURL#' "$D/root/inputs.yaml"
t "an unset issuer points to set-inputs.sh" 1 "idpIssuerURL isn't set in root/inputs.yaml" "${ARGS[@]}"

echo "tenant-call tests: $((total-fails)) ok, $fails failed"; exit "$fails"
