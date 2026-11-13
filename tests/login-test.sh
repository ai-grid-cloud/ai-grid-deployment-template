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
  *) echo "stub oc: unexpected: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/oc"

new_repo() { # a fresh repository copy in $D, a fresh stub log in $W
  D="$T/repo-$total"; W="$T/stub-$total"; rm -rf "$D" "$W"; mkdir -p "$D" "$W"; : > "$W/argv.log"
  cp -R "$SRC/scripts" "$D/"
  printf 'apiVersion: ai-grid.dev/v1alpha1\nkind: Clusters\nhub: {name: hub, api: "https://api.hub.example.com:6443"}\nsites:\n  - {name: site-b, role: combined, location: us-east, api: "https://api.site-b.example.com:6443"}\n' > "$D/clusters.yaml"
}
run() { # [VAR=value...] -- args: runs login.sh in $D; sets rc and out
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out=$(env -u AI_GRID_TOKEN_HUB -u AI_GRID_TOKEN_SITE_B PATH="$T/bin:$PATH" STUB_DIR="$W" ${envs[@]+"${envs[@]}"} \
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
no_token() { [ "$rc" = 1 ] && grep -qF .config/hub/token <<<"$out" && ! grep -q -- --web "$W/argv.log"; }
t "no token file: stops with the path, no --web" no_token

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

echo "login tests: $((total-fails)) ok, $fails failed"; exit "$fails"
