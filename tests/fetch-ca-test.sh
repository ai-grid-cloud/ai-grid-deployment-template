#!/usr/bin/env bash
# Tests for scripts/fetch-ca.sh (make fetch-ca) with a stub openssl whose
# s_client prints certificate chains made here with the real openssl, and a
# guard that nothing in scripts/ turns certificate checks off except ca: ignore.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
OPENSSL=$(command -v openssl)

# Throwaway CAs and the servers' certificates they sign.
mkcert() { # NAME CN [CA]: NAME.pem, self-signed or signed by CA
  local n=$1 cn=$2 ca=${3:-}
  if [ -z "$ca" ]; then
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$T/$n.key" -out "$T/$n.pem" -days 1 -subj "/CN=$cn" 2>/dev/null
  else
    "$OPENSSL" req -newkey rsa:2048 -nodes -keyout "$T/$n.key" -out "$T/$n.csr" -subj "/CN=$cn" 2>/dev/null
    "$OPENSSL" x509 -req -in "$T/$n.csr" -CA "$T/$ca.pem" -CAkey "$T/$ca.key" -CAcreateserial -out "$T/$n.pem" -days 1 2>/dev/null
  fi
}
mkcert api-root api-root; mkcert api-leaf api.hub.example.com api-root
mkcert ingress-root ingress-root; mkcert ingress-leaf oauth-openshift.apps.hub.example.com ingress-root
mkcert other-root other-root
fp() { "$OPENSSL" x509 -noout -fingerprint -sha256 -in "$T/$1.pem" | sed 's/.*=//'; }

# The stub openssl logs its arguments; s_client prints $STUB_DIR/HOST.chain as
# the server's chain, or fails to connect when there's none. Everything else
# goes to the real openssl.
mkdir -p "$T/bin"
cat > "$T/bin/openssl" <<STUB
#!/bin/bash
if [ "\$1" = s_client ]; then
  echo "openssl \$*" >> "\$STUB_DIR/openssl.log"
  host=""; prev=""; for a in "\$@"; do [ "\$prev" = -connect ] && host=\${a%:*}; prev=\$a; done
  [ -f "\$STUB_DIR/\$host.chain" ] || { echo "connect:errno=61" >&2; exit 1; }
  echo "CONNECTED(00000003)"; echo "depth=1 CN = root"; echo "verify error:num=19:self-signed certificate in certificate chain" >&2
  echo "---"; echo "Certificate chain"; cat "\$STUB_DIR/\$host.chain"; echo "---"
  exit 0
fi
exec "$OPENSSL" "\$@"
STUB
chmod +x "$T/bin/openssl"

CLUSTERS='# Our clusters.
apiVersion: ai-grid.dev/v1alpha1
kind: Clusters
hub:
  api: https://api.hub.example.com:6443   # the hub
  # a comment under the hub
sites:
  - name: site-1          # first
    api: https://api.site-1.example.com:6443
  - api: "https://api.site-2.example.com:6443"
    name: site-2
catalog:
  url: REQUIRED-catalogRepoURL   # no catalog yet
'
new_repo() { # a repository in $D with that clusters.yaml, a stub world in $W where every host answers
  D="$T/repo-$total" W="$T/stub-$total"; export D W; rm -rf "$D" "$W"; mkdir -p "$D" "$W"
  cp -R "$SRC/scripts" "$SRC/Makefile" "$D/"; printf '%s' "$CLUSTERS" > "$D/clusters.yaml"
  cat "$T/api-leaf.pem" "$T/api-root.pem" > "$W/api.hub.example.com.chain"
  cat "$T/ingress-leaf.pem" "$T/ingress-root.pem" > "$W/oauth-openshift.apps.hub.example.com.chain"
  for s in site-1 site-2; do
    cat "$T/api-leaf.pem" "$T/other-root.pem" > "$W/api.$s.example.com.chain"
    cat "$T/ingress-leaf.pem" "$T/other-root.pem" > "$W/oauth-openshift.apps.$s.example.com.chain"
  done
}
run() { # [VAR=value...] -- NAME: make fetch-ca in $D; sets rc and out
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out=$(env PATH="$T/bin:$PATH" STUB_DIR="$W" ${envs[@]+"${envs[@]}"} make -s -C "$D" fetch-ca NAME="$1" 2>&1) && rc=0 || rc=$?
}
t() { # name condition...
  local name=$1; shift; total=$((total+1))
  if "$@"; then echo "   ok   $name"; else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}
json() { KUBECONFIG=/dev/null kubectl label --local -f "${1:-$D/clusters.yaml}" x=y -o json; }
ca_of() { # NAME [FILE]: the cluster's ca: as the scripts read it
  json "${2:-}" | jq -r --arg n "$1" '(if $n == "hub" then .hub else first(.sites[] | select(.name == $n)) end).ca // empty'
}
export -f json ca_of

new_repo; run -- hub
t "hub: exits 0" test "$rc" = 0
t "  ... ca: holds the API's root and the router's root, not the leaves" \
  bash -c '[ "$(ca_of hub)" = "$(cat "$0/api-root.pem" "$0/ingress-root.pem")" ]' "$T"
t "  ... the file keeps every comment" bash -c 'for c in "# Our clusters." "# the hub" "  # a comment under the hub" "# first" "# no catalog yet"; do grep -qF -- "$c" "$0" || exit 1; done' "$D/clusters.yaml"
t "  ... ca: | sits after api:, at its indentation" bash -c 'grep -A1 "^  api: https://api.hub" "$0" | tail -n 1 | grep -qx "  ca: |"' "$D/clusters.yaml"
t "  ... the file still loads" bash "$D/scripts/clusters.sh" --rows "$D"
t "  ... the sites are untouched" bash -c '[ -z "$(ca_of site-1)" ] && [ -z "$(ca_of site-2)" ]'
for c in api-root ingress-root; do
  t "  ... prints $c's subject, issuer and SHA-256 fingerprint" \
    bash -c 'grep -q "subject: .*CN=$1" <<<"$0" && grep -q "issuer: .*CN=$1" <<<"$0" && grep -qF "SHA-256 fingerprint: $2" <<<"$0"' "$out" "$c" "$(fp "$c")"
done
t "  ... no warning for self-signed CAs" bash -c '! grep -q "may change" <<<"$0"' "$out"
t "  ... says to compare the fingerprints" grep -qi "compare" <<<"$out"
t "  ... reads the API host and the OAuth host, with SNI" bash -c '
  grep -q -- "-connect api.hub.example.com:6443 -servername api.hub.example.com" "$0" &&
  grep -q -- "-connect oauth-openshift.apps.hub.example.com:443 -servername oauth-openshift.apps.hub.example.com" "$0"' "$W/openssl.log"
t "  ... never asks s_client to skip or relax verification" bash -c '! grep -qiE -- "-verify|-no_|insecure" "$0"' "$W/openssl.log"

new_repo; run -- site-2
t "a site, name after api: ca: on that site only, with one copy of a shared root" \
  bash -c '[ "$0" = 0 ] && [ "$(ca_of site-2)" = "$(cat "$1/other-root.pem")" ] && [ -z "$(ca_of site-1)" ] && [ -z "$(ca_of hub)" ]' "$rc" "$T"
t "  ... indented as the entry's keys" bash -c 'grep -A1 "^  - api: \"https://api.site-2" "$0" | tail -n 1 | grep -qx "    ca: |"' "$D/clusters.yaml"

before=$(cksum < "$D/clusters.yaml"); run -- site-2
t "a cluster that has a ca: already: file unchanged, the block printed to paste, exit non-zero" \
  bash -c '[ "$0" != 0 ] && [ "$(cksum < "$1")" = "$2" ] && grep -qx "ca: |" <<<"$3" && grep -q "FORCE=1" <<<"$3" && grep -q "BEGIN CERTIFICATE" <<<"$3"' "$rc" "$D/clusters.yaml" "$before" "$out"

cat "$T/api-leaf.pem" "$T/api-root.pem" > "$W/api.site-2.example.com.chain"
cat "$T/ingress-leaf.pem" "$T/api-root.pem" > "$W/oauth-openshift.apps.site-2.example.com.chain"
run FORCE=1 -- site-2
t "FORCE=1: replaces the ca: with the new chain's root" \
  bash -c '[ "$0" = 0 ] && [ "$(ca_of site-2)" = "$(cat "$1/api-root.pem")" ] && [ "$(grep -c "ca: |" "$2")" = 1 ]' "$rc" "$T" "$D/clusters.yaml"
t "  ... still loads, comments kept" bash -c 'bash "$0/scripts/clusters.sh" --rows "$0" >/dev/null && grep -qF "# first" "$0/clusters.yaml"' "$D"

new_repo; sed -i.bak 's/^  # a comment under the hub$/  ca: ignore/' "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"
run FORCE=1 -- hub
t "FORCE=1 replaces ca: ignore too" bash -c '[ "$0" = 0 ] && [ "$(ca_of hub)" = "$(cat "$1/api-root.pem" "$1/ingress-root.pem")" ] && ! grep -q "ca: ignore" "$2"' "$rc" "$T" "$D/clusters.yaml"

new_repo; printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\n' > "$D/clusters.yaml"
before=$(cksum < "$D/clusters.yaml"); run -- hub
t "a layout it can't edit (flow style): file unchanged, the block printed to paste" \
  bash -c '[ "$0" != 0 ] && [ "$(cksum < "$1")" = "$2" ] && grep -qx "ca: |" <<<"$3" && grep -qx "  -----BEGIN CERTIFICATE-----" <<<"$3"' "$rc" "$D/clusters.yaml" "$before" "$out"

new_repo; mkdir -p "$D/.config"; (umask 077; cp "$D/clusters.yaml" "$D/.config/clusters.yaml")
sed -i.bak 's/^  url: REQUIRED-catalogRepoURL.*$/  url: https:\/\/github.com\/o\/c.git/' "$D/.config/clusters.yaml"; rm "$D/.config/clusters.yaml.bak"; chmod 600 "$D/.config/clusters.yaml"
before=$(cksum < "$D/clusters.yaml"); run -- hub
t "with .config/clusters.yaml: writes ca: there, mode still 600, clusters.yaml untouched" \
  bash -c '[ "$0" = 0 ] && [ -n "$(ca_of hub "$1/.config/clusters.yaml")" ] && [ "$(ls -l "$1/.config/clusters.yaml" | cut -c1-10)" = -rw------- ] && [ "$(cksum < "$1/clusters.yaml")" = "$2" ]' "$rc" "$D" "$before"

new_repo; rm "$W/oauth-openshift.apps.hub.example.com.chain"; run -- hub
t "the OAuth host unreachable: writes the API's CA, warning that it skipped the router's" \
  bash -c '[ "$0" = 0 ] && [ "$(ca_of hub)" = "$(cat "$2/api-root.pem")" ] && grep -q "skipped oauth-openshift.apps.hub.example.com:443" <<<"$1" && grep -q "router" <<<"$1"' "$rc" "$out" "$T"
new_repo; rm "$W/api.hub.example.com.chain"; before=$(cksum < "$D/clusters.yaml"); run -- hub
t "the API host unreachable: stops, naming it, file unchanged" \
  bash -c '[ "$0" != 0 ] && grep -q "no certificate from api.hub.example.com:6443" <<<"$1" && [ "$(cksum < "$2")" = "$3" ]' "$rc" "$out" "$D/clusters.yaml" "$before"
new_repo; : > "$W/api.hub.example.com.chain"; run -- hub
t "an empty chain: stops" bash -c '[ "$0" != 0 ] && grep -q "no certificate from api.hub.example.com:6443" <<<"$1"' "$rc" "$out"

new_repo; cp "$T/api-leaf.pem" "$W/api.hub.example.com.chain"; run -- hub
t "a chain with no self-signed certificate: the last one" bash -c '[ "$0" = 0 ] && [ "$(ca_of hub)" = "$(cat "$1/api-leaf.pem" "$1/ingress-root.pem")" ]' "$rc" "$T"
t "  ... with a warning that it may change" bash -c 'grep -q "CN=api.hub.example.com.*may change" <<<"$0" && [ "$(grep -c "may change" <<<"$0")" = 1 ]' "$out"

new_repo; sed -i.bak 's#https://api.hub.example.com:6443#https://hub.example.com:6443#' "$D/clusters.yaml"; rm "$D/clusters.yaml.bak"; run -- hub
t "an API host not named api.DOMAIN: stops, saying why" bash -c '[ "$0" != 0 ] && grep -q "apps domain" <<<"$1"' "$rc" "$out"

new_repo; out=$(make -s -C "$D" fetch-ca 2>&1) && rc=0 || rc=$?
t "no NAME: asks for one" bash -c '[ "$0" != 0 ] && grep -q "NAME=hub" <<<"$1"' "$rc" "$out"
out=$(make -s -C "$D" help 2>&1); rc=0
t "make help lists fetch-ca" grep -q "^fetch-ca: " <<<"$out"

# The guard: only ca: ignore, in scripts/clusters.sh's cluster_tls, turns a check off.
bad=$(grep -rnE -- '--insecure|insecure-skip-tls-verify|(^|[[:space:]"(])-k([[:space:]"]|$)|-verify[_ ]|verify_return_error|InsecureSkipVerify|verify=False|NODE_TLS_REJECT_UNAUTHORIZED|CURLOPT_SSL_VERIFY' "$SRC/scripts" "$SRC/Makefile" |
  grep -vE '^[^:]*scripts/clusters\.sh:[0-9]+:.*# ca: ignore only$' |
  grep -vE '^[^:]*scripts/clusters\.sh:[0-9]+:[[:space:]]*if grep -qE .*insecure-skip-tls-verify.* # ca: ignore check$' || true)
rc=0; out=$bad
t "nothing in scripts/ turns certificate checks off but ca: ignore" test -z "$bad"
t "  ... and cluster_tls has exactly that one line" test "$(grep -c '# ca: ignore only$' "$SRC/scripts/clusters.sh")" = 1

echo "fetch-ca tests: $((total-fails)) ok, $fails failed"; exit "$fails"
