#!/usr/bin/env bash
# Tests for scripts/tenant-call.sh with a stub oc and a stub curl (no cluster).
# The stub curl logs its arguments and the headers file it was given.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
KEY="fake-key-$RANDOM$RANDOM"   # the API key, built at runtime, not a literal

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
  if [ "$rc" = "$want" ] && grep -qE -- "$expect" <<<"$out" && ! grep -qF "$KEY" <<<"$out"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc, wanted $want; output:)"; echo "$out"; fi
}

mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
case " $* " in
  *" whoami "*) echo admin ;;
  *" get ingresses.config.openshift.io "*) case "$KUBECONFIG" in */hub/*) printf 'apps.hub.example.com' ;; *) printf 'apps.site-b.example.com' ;; esac ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/curl.log"
headers="" out="" prev="" url=""
for a in "$@"; do
  [ "$prev" = -D ] && headers=$a; [ "$prev" = -o ] && out=$a
  [ "$prev" = -H ] && [ "${a#@}" != "$a" ] && cp "${a#@}" "$STUB_DIR/sent-headers"
  prev=$a
  case "$a" in https://*) url=$a ;; esac
done
case "$url" in
  */v1/chat/completions)
    if [ -f "$STUB_DIR/untrusted" ]; then echo "curl: (60) SSL certificate problem: self-signed certificate in certificate chain" >&2; exit 60; fi
    printf 'HTTP/2 200\r\nx-grid-site: site-b\r\n\r\n' > "$headers"
    echo '{"choices":[{"message":{"content":"Hello there, nice to meet."}}]}' > "$out"; printf 200 ;;
esac
STUB
chmod +x "$T/bin/oc" "$T/bin/curl"

D="$T/repo"; mkdir -p "$D"; cp -R "$SRC/scripts" "$D/"
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
for n in hub site-b; do mkdir -p "$D/.config/$n"; : > "$D/.config/$n/kubeconfig"; done
printf '%s\n' "$KEY" > "$T/key"
ARGS=(--key-file "$T/key" --model smollm2-chat)

t "prints the reply" 0 "^Hello there, nice to meet.$" "${ARGS[@]}"
t "  ... the HTTP status" 0 "^HTTP 200$" "${ARGS[@]}"
t "  ... and the site that served it" 0 "^x-grid-site: site-b$" "${ARGS[@]}"
c "call to the site's MaaS host" 0 "https://maas.apps.site-b.example.com/v1/chat/completions" cat "$T/curl.log"
c "the key as a bearer token, from a file" 0 "^Authorization: Bearer $KEY$" cat "$T/sent-headers"
c "  ... no subscription header unless asked" 0 "^none$" bash -c 'grep -qi "^X-MaaS-Subscription" "$0" && echo sent || echo none' "$T/sent-headers"
c "no key on curl's command line" 0 "^clean$" bash -c 'grep -qF "$1" "$0" && echo leaked || echo clean' "$T/curl.log" "$KEY"
t "--subscription sends X-MaaS-Subscription" 0 "^HTTP 200$" "${ARGS[@]}" --subscription smollm2-users
c "  ... with the name" 0 "^X-MaaS-Subscription: smollm2-users$" cat "$T/sent-headers"
t "missing arguments: usage" 2 "usage: tenant-call.sh" --model m
: > "$T/empty"
t "an empty key file: says where the key comes from" 1 "no API key in .*Org UI" --key-file "$T/empty" --model m
printf '%s extra\n' "$KEY" > "$T/two"
t "a key file with more than the key: refused" 1 "must hold only the API key" --key-file "$T/two" --model m
touch "$T/untrusted"
t "an untrusted MaaS certificate: names the limit" 1 "maas.apps.site-b.example.com.*not trusted.*internal certificate" "${ARGS[@]}"
rm "$T/untrusted"

# No site in clusters.yaml: a hub is never a site, so there's nothing to call.
printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites: []\n' > "$D/clusters.yaml"
: > "$T/curl.log"
t "no site: refused, the hub never serves the call" 1 "error: clusters.yaml has no site: a hub needs at least one site; all-in-one isn't supported" "${ARGS[@]}"
c "  ... and no call is made" 0 "^$" cat "$T/curl.log"
t "  ... --site still has to name a site" 1 "isn't a site" "${ARGS[@]}" --site site-b

echo "tenant-call tests: $((total-fails)) ok, $fails failed"; exit "$fails"
