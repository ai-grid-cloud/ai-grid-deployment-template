#!/usr/bin/env bash
# Tests for scripts/login.sh against a stub oc that logs its arguments.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd -P)
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
total=0 fails=0
SENTINEL='sha256~SENTINEL'

# The stub oc logs its arguments. whoami answers admin only when $KUBECONFIG
# holds the token $STUB_TOKEN (default the sentinel), as a cluster that accepts
# only that token. With STUB_X509 set, whoami fails as on an untrusted API certificate.
mkdir -p "$T/bin"
cat > "$T/bin/oc" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/argv.log"; a=" $* "
case "$a" in
  *" whoami "*) [ -z "${STUB_X509:-}" ] || { echo "error: tls: failed to verify certificate: x509: certificate signed by unknown authority" >&2; exit 1; }
               grep -qF "token: '${STUB_TOKEN:-sha256~SENTINEL}'" "${KUBECONFIG:-/dev/null}" 2>/dev/null ||
               grep -qxF "    token: ${STUB_TOKEN:-sha256~SENTINEL}" "${KUBECONFIG:-/dev/null}" 2>/dev/null && echo admin ||
                { echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1; } ;;
  *" login "*) echo "stub oc: login $*" ;;
  *" config view --raw --flatten "*) echo "# flattened"; cat "$KUBECONFIG" ;;
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

# The stub curl plays the cluster's OAuth server. It logs its arguments to
# argv.log and its stdin (curl -K - config) to stdin.log. The authorize call
# answers a 302 with the sentinel token in the Location fragment when the
# config holds user = "admin:$STUB_PASSWORD" (default $PW) and argv has
# X-CSRF-Token: 1; else 401. STUB_CURL_X509 makes every call fail as an
# untrusted certificate.
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/argv.log"; a=" $* "
in=""; case "$a" in *" -K - "*) in=$(cat); printf '%s\n' "$in" >> "$STUB_DIR/stdin.log" ;; esac
[ -z "${STUB_CURL_X509:-}" ] || { echo "curl: (60) SSL certificate problem: unable to get local issuer certificate" >&2; exit 60; }
case "$a" in
  *"/.well-known/oauth-authorization-server "*)
    echo '{"issuer":"https://oauth.apps.example.com","authorization_endpoint":"https://oauth.apps.example.com/oauth/authorize"}' ;;
  *"/oauth/authorize?"*)
    want=$(printf 'user = "admin:%s"' "${STUB_PASSWORD_ESCAPED:-${STUB_PASSWORD:-PW~SENTINEL pass}}")
    if grep -qxF "$want" <<<"$in" && [[ "$a" == *"X-CSRF-Token: 1"* ]]; then
      printf 'HTTP/1.1 302 Found\r\nLocation: https://oauth.apps.example.com/oauth/token/implicit#access_token=sha256%%7ESENTINEL&expires_in=86400&scope=user%%3Afull&token_type=Bearer\r\n\r\n'
    else printf 'HTTP/1.1 401 Unauthorized\r\n\r\n'; fi ;;
  *) echo "stub curl: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/curl"

new_repo() { # a fresh repository copy in $D, a fresh stub log in $W
  D="$T/repo-$total"; W="$T/stub-$total"; rm -rf "$D" "$W"; mkdir -p "$D" "$W"; : > "$W/argv.log"
  cp -R "$SRC/scripts" "$D/"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
}
run() { # [VAR=value...] -- args: runs login.sh in $D; sets rc and out
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out=$(env -u AI_GRID_TOKEN_HUB -u AI_GRID_TOKEN_SITE_B -u AI_GRID_USERNAME_HUB -u AI_GRID_PASSWORD_HUB PATH="$T/bin:$PATH" STUB_DIR="$W" ${envs[@]+"${envs[@]}"} \
    "$D/scripts/login.sh" "$@" 2>&1) && rc=0 || rc=$?
}
t() { # name condition...: passes when the condition (a command) succeeds
  local name=$1; shift
  total=$((total+1))
  if "$@"; then echo "   ok   $name"
  else fails=$((fails+1)); echo "   FAIL $name (rc=$rc; output:)"; echo "$out"; fi
}
mode600() { [ "$(ls -l "$1" | cut -c1-10)" = "-rw-------" ]; }
working_kubeconfig() { # NAME API
  local k="$D/.config/$1/kubeconfig"
  [ "$rc" = 0 ] && mode600 "$k" && grep -qx "    server: $2" "$k" && ! grep -q insecure "$k" &&
    KUBECONFIG=$k STUB_DIR="$W" "$T/bin/oc" whoami >/dev/null 2>&1
}

new_repo; mkdir -p "$D/.config/hub" "$D/.config/site-b"
printf '%s\n' "$SENTINEL" > "$D/.config/hub/token"; printf '%s\n' "$SENTINEL" > "$D/.config/site-b/token"
run -- --non-interactive hub
t "token file: writes a working kubeconfig" working_kubeconfig hub https://api.hub.example.com:6443

new_repo
run AI_GRID_TOKEN_SITE_B="$SENTINEL" -- --non-interactive site-b
t "env token: AI_GRID_TOKEN_SITE_B" working_kubeconfig site-b https://api.site-b.example.com:6443

new_repo; mkdir -p "$D/.config/hub" "$D/.config/site-b"
for n in hub site-b; do
  printf 'apiVersion: v1\nkind: Config\nusers:\n- name: x\n  user:\n    token: %s\n' "$SENTINEL" > "$D/.config/$n/kubeconfig"
  chmod 600 "$D/.config/$n/kubeconfig"
done
before=$(cksum "$D/.config/hub/kubeconfig" "$D/.config/site-b/kubeconfig")
run -- --non-interactive
t "working kubeconfig: left alone" test "$rc:$(cksum "$D/.config/hub/kubeconfig" "$D/.config/site-b/kubeconfig")" = "0:$before"

new_repo
run -- --non-interactive hub
no_token() { [ "$rc" = 1 ] && grep -qF "set a token, or a username and password, in hub in .config/clusters.yaml (make config creates it), or AI_GRID_TOKEN_HUB" <<<"$out" &&
  ! grep -q -- --web "$W/argv.log"; }
t "nothing to log in with: names hub and AI_GRID_TOKEN_HUB, no --web" no_token

never_in_argv() { [ "$rc" = 0 ] && ! grep -rqF "$SENTINEL" "$T"/stub-*/argv.log && ! grep -qF "$SENTINEL" <<<"$all_out"; }
all_out=""
new_repo; mkdir -p "$D/.config/hub"; printf '%s\n' "$SENTINEL" > "$D/.config/hub/token"
run AI_GRID_TOKEN_SITE_B="$SENTINEL" -- --non-interactive; all_out+=$out
t "token never in argv" never_in_argv

new_repo
run -- hub
t "without --non-interactive: unchanged" grep -qx 'login --server https://api.hub.example.com:6443 --web' "$W/argv.log"

new_repo; mkdir -p "$D/.config/hub"; printf '%s\n' "$SENTINEL" > "$D/.config/hub/token"
run STUB_X509=1 -- --non-interactive hub
x509() { [ "$rc" = 1 ] && grep -q "certificate problem" <<<"$out" && grep -q "x509" <<<"$out" && ! grep -q replace <<<"$out"; }
t "x509 from whoami: says certificate, not replace the token" x509

new_repo; mkdir -p "$D/.config/hub"; printf '%s\n' "$SENTINEL" > "$D/.config/hub/token"; : > "$D/.config/hub/ca.crt"
run -- --non-interactive hub
t "ca.crt: the kubeconfig names it" grep -qx "    certificate-authority: $D/.config/hub/ca.crt" "$D/.config/hub/kubeconfig"

new_repo; mkdir -p "$D/.config/hub"; printf '%s\n' 12345 > "$D/.config/hub/token"
run STUB_TOKEN=12345 -- --non-interactive hub
t "all-digit token: written as a quoted string" grep -qx "    token: '12345'" "$D/.config/hub/kubeconfig"

new_repo; mkdir -p "$D/.config/hub"; printf '%s\r\n' "$SENTINEL" > "$D/.config/hub/token"
run -- --non-interactive hub
t "token file ending in CRLF: works" working_kubeconfig hub https://api.hub.example.com:6443

# The private .config/clusters.yaml with each cluster's credentials inline.
PW='PW~SENTINEL pass'
OTHER_TOKEN=sha256~OTHER EXPIRED_TOKEN=sha256~EXPIRED
private() { # "NAME: {credentials}"...: writes $D/.config/clusters.yaml (mode 600), the same clusters with those credentials inline
  local creds; mkdir -p "$D/.config"
  creds=$({ printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\ndata:\n'; printf '  %s\n' "$@"; } |
    KUBECONFIG=/dev/null kubectl label --local -f - x=y -o json | jq .data)
  KUBECONFIG=/dev/null kubectl label --local -f "$D/clusters.yaml" x=y -o json | jq --argjson c "$creds" '
    del(.metadata) | .catalog = {url: "https://github.com/o/c.git"}
    | .hub += ($c.hub // {}) | .sites = [.sites[] | . + ($c[.name] // {})]' > "$D/.config/clusters.yaml"
  chmod 600 "$D/.config/clusters.yaml"
}
no_secret() { # [SECRET...]: none in the stubs' argv or the output (default the token and $PW)
  local s; [ $# -gt 0 ] || set -- "$SENTINEL" "$PW"
  for s in "$@"; do ! grep -qF -- "$s" "$W/argv.log" && ! grep -qF -- "$s" <<<"$out" || return 1; done
}
no_curl() { ! grep -q '^curl' "$W/argv.log"; }

new_repo; private "hub: {token: '$SENTINEL'}"
run -- --non-interactive hub
t "hub.token: writes a working kubeconfig" working_kubeconfig hub https://api.hub.example.com:6443
t "  ... never in argv or output" no_secret

new_repo; private "hub: {token: '$OTHER_TOKEN'}"
run AI_GRID_TOKEN_HUB="$SENTINEL" -- --non-interactive hub
t "AI_GRID_TOKEN_HUB beats hub.token" working_kubeconfig hub https://api.hub.example.com:6443

new_repo; private "hub: {token: '$SENTINEL'}"; mkdir -p "$D/.config/hub"; printf 'sha256~LEGACY\n' > "$D/.config/hub/token"
run -- --non-interactive hub
t "hub.token beats the legacy .config/hub/token" working_kubeconfig hub https://api.hub.example.com:6443

new_repo; private "hub: {username: admin, password: '$PW'}"
run -- --non-interactive hub
t "hub password: writes a working kubeconfig" working_kubeconfig hub https://api.hub.example.com:6443
t "  ... asks the OAuth server with X-CSRF-Token: 1, as the challenging client" \
  grep -q "X-CSRF-Token: 1.*client_id=openshift-challenging-client" "$W/argv.log"
t "  ... the password and token never in argv or output" no_secret
t "  ... the password passed on stdin" grep -qxF "user = \"admin:$PW\"" "$W/stdin.log"
t "  ... says where the password came from" grep -qF "hub: logging in as admin with hub.password" <<<"$out"

new_repo; private "hub: {username: nobody, password: wrong}"
run AI_GRID_USERNAME_HUB=admin AI_GRID_PASSWORD_HUB="$PW" -- --non-interactive hub
t "AI_GRID_USERNAME_HUB and AI_GRID_PASSWORD_HUB beat the file" working_kubeconfig hub https://api.hub.example.com:6443
t "  ... never in argv or output" no_secret

new_repo; private "hub: {token: '$EXPIRED_TOKEN', username: admin, password: '$PW'}"
run -- --non-interactive hub
t "expired token, then the password gets a fresh one" working_kubeconfig hub https://api.hub.example.com:6443

new_repo; private "hub: {token: '$SENTINEL', username: admin, password: '$PW'}"
run -- --non-interactive hub
t "a working token wins over the password" bash -c '[ "$0" = 0 ] && ! grep -q "^curl" "$1/argv.log"' "$rc" "$W"

new_repo; private "hub: {token: '$SENTINEL', username: admin, password: '$PW'}"
run STUB_X509=1 -- --non-interactive hub
t "a certificate error with the token: no fall-through to the password" \
  bash -c '[ "$0" = 1 ] && grep -q "certificate problem" <<<"$1" && ! grep -q "^curl" "$2/argv.log"' "$rc" "$out" "$W"

new_repo; private "hub: {username: admin, password: 'PW~WRONG'}"
run -- --non-interactive hub
bad_pw() { [ "$rc" = 1 ] && grep -q "hub: the OAuth server refused admin" <<<"$out" && no_secret PW~WRONG; }
t "wrong password: stops, naming the user, not the password" bad_pw

new_repo; private "hub: {username: admin, password: 'q\"u\\ote'}"
run STUB_PASSWORD_ESCAPED='q\"u\\ote' -- --non-interactive hub
t "password with \" and \\: escaped for curl's config" working_kubeconfig hub https://api.hub.example.com:6443
t "  ... never in argv" no_secret 'q"u\ote'

new_repo; private "hub: {username: admin, password: '$PW'}"; mkdir -p "$D/.config/hub"; : > "$D/.config/hub/ca.crt"
run -- --non-interactive hub
t "ca.crt: curl checks the OAuth server against it" grep -q -- "--cacert $D/.config/hub/ca.crt" "$W/argv.log"

new_repo; private "hub: {username: admin, password: '$PW'}"
run STUB_CURL_X509=1 -- --non-interactive hub
t "OAuth certificate problem: says certificate" bash -c '[ "$0" = 1 ] && grep -q "certificate problem" <<<"$1"' "$rc" "$out"

new_repo; private "hub: {username: admin}"
run -- --non-interactive hub
t "a username with no password: names the missing key" \
  bash -c '[ "$0" = 1 ] && grep -qF "hub.password" <<<"$1"' "$rc" "$out"

new_repo; private "site-b: {username: admin}"
run -- --non-interactive site-b
t "a site's username with no password: names its sites: entry" \
  bash -c '[ "$0" = 1 ] && grep -qF "sites[site-b].password" <<<"$1"' "$rc" "$out"

# Plain make login (no flag): stored credentials first, oc login --web only for a cluster with none.
new_repo; private "hub: {token: '$SENTINEL'}" "site-b: {username: admin, password: '$PW'}"
run --
plain_stored() { [ "$rc" = 0 ] && ! grep -q -- --web "$W/argv.log" && no_secret; }
t "no flag, stored token and password: logs in with them, no --web" plain_stored
t "  ... the hub's kubeconfig works" working_kubeconfig hub https://api.hub.example.com:6443
t "  ... the site's too" working_kubeconfig site-b https://api.site-b.example.com:6443

new_repo; private "hub: {token: '$SENTINEL'}"
run -- hub
t "no flag, NAME=hub with a stored token: no --web" bash -c '[ "$0" = 0 ] && ! grep -q -- --web "$1/argv.log"' "$rc" "$W"

new_repo; private "hub: {token: '$SENTINEL'}"
run --
plain_mixed() { [ "$rc" = 0 ] && grep -qx 'login --server https://api.site-b.example.com:6443 --web' "$W/argv.log" &&
  ! grep -q 'api.hub.example.com:6443 --web' "$W/argv.log"; }
t "no flag, nothing stored for site-b: --web for site-b only" plain_mixed

new_repo; private "hub: {token: '$SENTINEL'}"
run -- hub --token=x
t "explicit oc flags: passed to oc login as today, stored credentials unused" \
  grep -qx 'login --server https://api.hub.example.com:6443 --token=x' "$W/argv.log"

# M1: a username or password with a line break is refused, never sent.
new_repo; private "hub: {username: \"ad\\nmin\", password: \"$PW\"}"
run -- --non-interactive hub
t "a username with a line break: refused, no OAuth call" bash -c '[ "$0" = 1 ] && grep -q "line break" <<<"$1" && ! grep -q "^curl" "$2/argv.log"' "$rc" "$out" "$W"
echo "login tests: $((total-fails)) ok, $fails failed"; exit "$fails"
